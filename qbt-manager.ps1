<#
    qbt-manager.ps1
    Automated download curator for qBittorrent (Web API).

    Rules implemented, in the order they run
    ---------------------------------------
    1. DoVi      : any torrent whose name advertises Dolby Vision is deleted
                   immediately, with its files, regardless of state.
    1b. Disc rip : a full Blu-ray disc rip (a BDMV on disk, or the usual names)
                   is deleted with its files. Transcodes and REMUXes are not
                   disc rips and are left alone.
    2. No availability: a magnet that cannot report a size is deleted once it has
                   been really trying for longer than the timeout. qBittorrent
                   works the queue in order, so `priority` is the queue position
                   and a magnet at position 150 has not been given a turn at
                   all. The magnet is therefore judged only while it sits in the
                   first metadataPriorityRankLimit positions, and its clock runs
                   only for the time it spends in there. Priority 0 means "out of
                   the queue", not "at the top of it", so it is not judged.
    2b. Stalled  : an unfinished torrent whose byte count has not moved for
                   stalledDeleteDays days is deleted, with its partial data.
                   Judged on observed progress rather than on qBittorrent's
                   "stalled" state, which also means "no peers this second".
                   Paused and stopped torrents are never touched.
    3. Categories: identified torrents are filed under the movies or series
                   category.
    4. Dedup    : within a title group, the largest version that is 100%
                   downloaded is the keeper, and every other version smaller
                   than it is deleted - finished or not, and at any distance in
                   size. An unfinished version is deleted even when it is not
                   more than 10% bigger than the keeper, because a size
                   difference too small to see is not a better version. A
                   FINISHED version bigger than the keeper is the keeper, and is
                   never deleted. A group with no finished member is untouched.
                    Groups are built in two passes. Series releases of one
                    episode often carry different titles ('ted lasso' versus
                    'ted lasso follow the anger'), so a second pass, for series
                    only, folds the groups of one episode back together. It
                    cannot merge two different shows: the show family is the
                    first word of the name, and a suffix seen on more than one
                    episode is read as part of the show rather than an episode.
    5. Library  : the surviving completed torrents are moved to the movies or
                   series folder. Runs after dedup, so nothing is relocated only
                   to be deleted again.
    6. Reaper   : download leftovers in reapRoots that no torrent claims.

                   Finished torrents are never removed for being finished.

    Safety
    ------
    - Titles must match on a normalised key before anything is deleted. If the
      key cannot be built, the torrent is left alone.
    - Every decision is logged with the full torrent names.
    - -DryRun changes nothing.

    Run with:  powershell -ExecutionPolicy Bypass -File qbt-manager.ps1 [-DryRun]
#>

[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$ConfigPath,
    # Restricts the dedup pass to titles whose parsed name contains this text.
    # Used to stage a first run against a single title.
    [string]$Only
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not populated inside a param() default under -File, so the
# paths are resolved here instead.
if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ConfigPath)    { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }

# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------
#
# TWO FILES, ON PURPOSE, so this project can be published without publishing
# anybody's user name.
#
#   config.json        every tunable, committed. No personal paths: the paths are
#                      written as placeholders and never carry a real user name.
#   config.local.json  YOUR paths only, git-ignored, absent on anyone else's
#                      machine. Read after config.json and wins on every key it
#                      mentions, at the top level only.
#
# The split is deliberately shallow. Only the leaf keys that name a location are
# expected in the local file, so there is no nesting to merge and no rule about
# which side wins for a sub-object: whatever config.local.json says about a key
# replaces config.json's value for that key, and keys it does not mention are left
# alone.
#
# That shallowness is also what makes the local file safe to hand-edit. It is a
# short list of "my paths are these", not a second copy of the configuration that
# can drift out of step with the real one.
#
# A missing local file is not an error. That is the normal case for anyone who
# cloned the repository, and for a first run before the paths have been filled in.
function Get-MergedConfig {
    param(
        [string]$ConfigPath,
        [string]$Root
    )

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        Write-Host "config.json not found at $ConfigPath" -ForegroundColor Red
        Write-Host 'It is committed, so restore it with:  git checkout config.json' -ForegroundColor Red
        exit 2
    }

    $base = [System.IO.File]::ReadAllText($ConfigPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $localPath = Join-Path $Root 'config.local.json'

    if (-not (Test-Path -LiteralPath $localPath)) { return $base }

    try {
        $local = [System.IO.File]::ReadAllText($localPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        # Write-Host, not Write-Log: this function runs during setup, before
        # $logPath and Write-Log exist.
        Write-Host 'config.local.json is unreadable, ignoring it:' -ForegroundColor Yellow
        Write-Host ("  " + $_.Exception.Message) -ForegroundColor DarkGray
        return $base
    }

    # Keys beginning with "//" are comments. JSON has no comment syntax, and a
    # config file people are told to hand-edit wants one, so the convention is a
    # key that is skipped rather than merged. Without this guard the note would
    # become a real property named "//" on the config object.
    foreach ($p in $local.PSObject.Properties) {
        if ($p.Name.StartsWith('//')) { continue }
        $base | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
    }
    return $base
}

$cfg = Get-MergedConfig -ConfigPath $ConfigPath -Root $PSScriptRoot

# ---------------------------------------------------------------------------
# unconfigured paths
# ---------------------------------------------------------------------------
#
# A fresh clone has config.json's placeholders and no config.local.json, so every
# rule that touches the library matches nothing and the run reports "nothing to
# do". That is SAFE - no path can match, so nothing can be deleted - but it is
# indistinguishable from a healthy quiet run, and someone setting this up for the
# first time would have no way to tell which they are looking at.
#
# So say so, loudly, once, naming the keys. It does NOT stop the run: a
# placeholder is not a syntax error, and refusing to run over it would be worse
# than running and saying nothing can match.
$unconfigured = @()
foreach ($k in 'moviesDir', 'seriesDir') {
    $v = [string]$cfg.$k
    if ($v -match 'PUT-YOUR-PATH-HERE' -or [string]::IsNullOrWhiteSpace($v)) { $unconfigured += $k }
}
foreach ($r in @($cfg.reapRoots)) {
    if ([string]$r -match 'PUT-YOUR-PATH-HERE' -or [string]::IsNullOrWhiteSpace([string]$r)) {
        $unconfigured += 'reapRoots'
        break
    }
}

if ($unconfigured.Count -gt 0) {
    Write-Host ''
    Write-Host 'WARNING: these paths are still placeholders' -ForegroundColor Yellow
    foreach ($k in ($unconfigured | Select-Object -Unique)) { Write-Host ("  {0}" -f $k) -ForegroundColor Yellow }
    Write-Host 'Create config.local.json with your own paths. Until you do, the' -ForegroundColor DarkGray
    Write-Host 'library rules match nothing - safe, but no file will be found,' -ForegroundColor DarkGray
    Write-Host 'deduplicated or moved.' -ForegroundColor DarkGray
    Write-Host ''
}

$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$statePath = Join-Path $PSScriptRoot 'state.json'
$logPath   = Join-Path $logDir ('manager-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))

$script:actions = New-Object System.Collections.ArrayList
$script:notes   = New-Object System.Collections.ArrayList
$script:gone    = @{}

# Which show folder each parsed title resolves to. Populated on first use and
# deliberately NOT cleared mid-run: the folder cannot change under a run, and a
# half-changed mapping would make one rule look in a season folder and another in
# a different one.
$script:showDirCache = @{}

function Write-Log {
    param([string]$Level, [string]$Message)
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    # Opened and written by hand, retried once, and never fatal.
    #
    # Add-Content opens the log for the whole run and holds the handle, so a
    # second run starting while the first is still going - the schedule fires
    # every 15 minutes and a full run takes most of that - throws
    # GetContentWriterIOError on its very first log line and dies with exit 1
    # before doing any work. That was not a dry run colliding by accident: the
    # scheduled run and a manual one overlap routinely.
    #
    # The lock cannot prevent this, because it guards the ACTIONS and is taken
    # after the first Write-Log that reports entering the run. Both processes
    # reach the log before either holds the lock.
    #
    # So the log writes independently: a fresh handle per line, sharing read and
    # delete, retried once. A run whose logging is momentarily unavailable still
    # does its work; losing a log line is recoverable, crashing before the first
    # decision is not.
    $written = $false
    for ($try = 1; $try -le 2 -and -not $written; $try++) {
        try {
            $fs = [System.IO.File]::Open(
                $logPath,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($line + [Environment]::NewLine)
                $fs.Write($bytes, 0, $bytes.Length)
                $written = $true
            } finally { $fs.Dispose() }
        }
        catch {
            if ($try -lt 2) { Start-Sleep -Milliseconds 250 }
        }
    }
    # Only say so once, and only for the levels an operator reads. A dry run that
    # cannot log should still print everything to the console.
    if (-not $written -and $script:logWarned -ne $true -and $Level -ne 'INFO') {
        $script:logWarned = $true
        Write-Host "  WARN    could not write to the log file; continuing without it" -ForegroundColor Yellow
    }

    switch ($Level) {
        'DELETE' { Write-Host "  DELETE  $Message" }
        'MOVE'   { Write-Host "  MOVE    $Message" }
        'ACTION' { Write-Host "  ACTION  $Message" }
        'WARN'   { Write-Host "  WARN    $Message" }
        'ERROR'  { Write-Host "  ERROR   $Message" }
        'INFO'   { Write-Host "  INFO    $Message" }
    }
}

# ---------------------------------------------------------------------------
# api helpers
#
# Failure handling here is the difference between an unattended job that degrades
# quietly and one that wedges the scheduler. Three distinct faults need distinct
# answers, and treating them the same is what makes this slow and alarming:
#
#   1. qBittorrent is not running. curl exit 7. Completely normal - the user may
#      have closed the app. Detected on the first attempt and reported without
#      retrying, so the run ends in milliseconds instead of sitting out a
#      20-second timeout to conclude what a refused connection already said.
#
#   2. The API took the connection but never answered. curl exit 28. A wedged
#      handler, normally blocked on disk. Worth two short retries with a backoff,
#      because this is often transient.
#
#   3. The API dropped part way through a run. Every later call would otherwise
#      sit out its full timeout again, so a long run degrades into the timeout
#      multiplied by the number of torrents still to process. The breaker below
#      ends the run after a few consecutive failures rather than grinding on.
#
# On a repeated API failure the run stops immediately and says so. Continuing
# would mean issuing deletes and moves against an API that is not answering, and
# a half-applied set of changes is worse than none.
# ---------------------------------------------------------------------------

$script:base = $cfg.baseUrl

# The CSRF Referer, derived from baseUrl rather than hardcoded.
#
# It has to be the scheme, host and PORT of the API - the same origin, without
# the /api/v2 path - because that is what qBittorrent compares the header against.
# A hardcoded 'http://127.0.0.1:8080' sat here and was never read by anything, so
# it was both dead code and a machine-specific constant in a file meant to be
# published. Anyone running qBittorrent on another port or host would have been
# unaffected by it, which is exactly why nobody noticed it was wrong.
try {
    $baseUri = [uri]$script:base
    $script:referer = '{0}://{1}' -f $baseUri.Scheme, $baseUri.Authority
}
catch {
    # Not a parseable URL. Leave it empty: curl sends no Referer, and if CSRF is
    # on the API will refuse, which is a clearer failure than sending the wrong one.
    $script:referer = ''
}

# "Nothing is listening" as opposed to "something is listening but silent".
# Only the second kind can be helped by waiting.
$script:curlNoListener = @(6, 7)

function Get-ApiSetting {
    param([string]$Name, [int]$Default)
    if ($null -eq $cfg.PSObject.Properties[$Name]) { return $Default }
    $v = $cfg.PSObject.Properties[$Name].Value
    if ($null -eq $v) { return $Default }
    return [int]$v
}

$script:apiConnectTimeout = Get-ApiSetting 'apiConnectTimeoutSeconds' 3
$script:apiGetTimeout     = Get-ApiSetting 'apiGetTimeoutSeconds' 10
$script:apiPostTimeout    = Get-ApiSetting 'apiPostTimeoutSeconds' 30
$script:apiAttempts       = Get-ApiSetting 'apiAttempts' 2
$script:apiFailureBudget  = Get-ApiSetting 'apiFailureBudget' 3

$script:apiFailures = 0

function Invoke-CurlOnce {
    <#
        One curl invocation, with native stderr suppressed so that
        $ErrorActionPreference does not turn curl diagnostics into terminating
        errors.

        The response is written to a temp file and read back as explicit UTF-8.
        Letting curl stream to the pipeline is NOT safe here: PowerShell 5.1
        decodes native output using the console code page, which turns a UTF-8
        "e-acute" (0xC3 0xA9) into two Latin-1 characters and corrupts any
        accented torrent or category name.
    #>
    param([string[]]$CurlArgs)

    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & curl.exe @CurlArgs -o $tmp 2>&1 | Out-Null
            $code = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prev
        }

        $out = ''
        if (Test-Path -LiteralPath $tmp) {
            $out = [System.IO.File]::ReadAllText($tmp, (New-Object System.Text.UTF8Encoding($false)))
        }
        return [pscustomobject]@{ Code = $code; Out = $out }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Curl {
    param(
        [string[]]$CurlArgs,
        [int]$Attempts = 0
    )
    if ($Attempts -le 0) { $Attempts = $script:apiAttempts }

    $r = $null
    for ($i = 1; $i -le $Attempts; $i++) {
        $r = Invoke-CurlOnce -CurlArgs $CurlArgs
        if ($r.Code -eq 0) { return $r }

        # A refused connection or an unresolvable host will not fix itself by
        # waiting. Return at once and let the caller classify it.
        if ($script:curlNoListener -contains $r.Code) { return $r }

        if ($i -lt $Attempts) {
            Write-Log 'WARN' "curl exit $($r.Code); retrying ($i of $($Attempts - 1))"
            Start-Sleep -Seconds (2 * $i)
        }
    }
    return $r
}

function Stop-ApiRun {
    <#
        Ends the run because the API is not usable. Everything already decided
        has been logged, so the reason is recoverable from the log even though
        the remaining work was skipped.
    #>
    param([string]$Message, [int]$Code = 2)

    Write-Log 'ERROR' $Message
    Write-Host ''
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Write-Host 'No further changes were made. The next scheduled run will try again.' -ForegroundColor DarkGray
    Exit-Run -Code $Code
}

function Test-ApiFailure {
    param([int]$CurlCode, [string]$Verb, [string]$Endpoint)

    # Case 1: qBittorrent is simply not there. That is an expected state, not a
    # failure, so it gets a warning and a zero exit code. Reporting it as an
    # error would train the user to ignore real errors.
    if ($script:curlNoListener -contains $CurlCode) {
        # ${Endpoint} rather than $Endpoint: - a colon straight after a variable
        # name is read as a scope qualifier and fails to parse.
        Write-Log 'WARN' "${Verb} ${Endpoint}: nothing listening on $script:base - qBittorrent is not running, or its Web API is off"
        Write-Host ''
        Write-Host "qBittorrent is not answering at $script:base." -ForegroundColor Yellow
        Write-Host 'Nothing was changed. This is normal when the app is closed.' -ForegroundColor DarkGray
        Exit-Run -Code 0
    }

    # Case 3: the breaker. Counted per failed call, and reset by any success,
    # so an isolated failure never trips it.
    $script:apiFailures++
    if ($script:apiFailures -ge $script:apiFailureBudget) {
        Stop-ApiRun -Code 3 -Message (
            "$Verb $Endpoint failed and $script:apiFailures calls have now failed in a row " +
            "(last curl exit $CurlCode). The API stopped responding part way through the run, " +
            'so the run was stopped here instead of repeating the same wait for every ' +
            'remaining torrent.')
    }

    Stop-ApiRun -Code 2 -Message "$Verb $Endpoint failed (curl exit $CurlCode) after $script:apiAttempts attempt(s)."
}

function Invoke-ApiGet {
    param([string]$Endpoint)

    $cArgs = @(
        '-s',
        '--connect-timeout', "$script:apiConnectTimeout",
        '--max-time', "$script:apiGetTimeout",
        '-H', "Referer: $script:referer",
        "$script:base/$Endpoint"
    )
    $r = Invoke-Curl -CurlArgs $cArgs
    if ($r.Code -ne 0 -or [string]::IsNullOrWhiteSpace($r.Out)) {
        Test-ApiFailure -CurlCode $r.Code -Verb 'GET' -Endpoint $Endpoint
    }
    $script:apiFailures = 0
    return ($r.Out | ConvertFrom-Json)
}

function Invoke-ApiPost {
    param(
        [string]$Endpoint,
        [hashtable]$Fields
    )
    # note: do NOT name this $args, that is a PowerShell automatic variable
    $cArgs = @(
        '-s',
        '--connect-timeout', "$script:apiConnectTimeout",
        '--max-time', "$script:apiPostTimeout",
        '-X', 'POST',
        '-H', "Referer: $script:referer"
    )
    foreach ($k in $Fields.Keys) {
        $cArgs += '--data-urlencode'
        $cArgs += ('{0}={1}' -f $k, $Fields[$k])
    }
    $cArgs += "$script:base/$Endpoint"

    $r = Invoke-Curl -CurlArgs $cArgs
    if ($r.Code -ne 0) {
        Test-ApiFailure -CurlCode $r.Code -Verb 'POST' -Endpoint $Endpoint
    }
    $script:apiFailures = 0
}

# ---------------------------------------------------------------------------
# single-instance lock
#
# The scheduled task is IgnoreNew, so it cannot overlap itself. That does not
# stop a run started by hand while a scheduled one is still going, and two runs
# working from the same list can each decide to delete the same torrent and then
# each try to move what is left behind.
#
# A stale lock is not a problem: the PID inside it is checked, and a lock whose
# owner is gone is removed rather than waited on. That also covers a run that
# was killed outright, so an abandoned lock can never wedge the schedule.
# ---------------------------------------------------------------------------

$script:lockPath  = Join-Path $PSScriptRoot 'manager.lock'
$script:lockTaken = $false

function Exit-Run {
    param([int]$Code)
    if ($script:lockTaken -and (Test-Path -LiteralPath $script:lockPath)) {
        Remove-Item -LiteralPath $script:lockPath -Force -ErrorAction SilentlyContinue
    }
    exit $Code
}

function Enter-RunLock {
    $payload = '{0} {1}' -f $PID, (Get-Date).ToString('o')

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            # CreateNew is atomic on Windows: it either wins the file or throws,
            # so two starts cannot both believe they hold the lock.
            $fs = [System.IO.File]::Open(
                $script:lockPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::None)
            try {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
                $fs.Write($bytes, 0, $bytes.Length)
            } finally { $fs.Dispose() }

            $script:lockTaken = $true
            return $true
        }
        catch [System.IO.IOException] {
            $holderPid = 0
            try {
                $existing = [System.IO.File]::ReadAllText($script:lockPath)
                if ($existing -match '^(\d+)') { $holderPid = [int]$Matches[1] }
            } catch { }

            $alive = $false
            if ($holderPid -gt 0) {
                $alive = $null -ne (Get-Process -Id $holderPid -ErrorAction SilentlyContinue)
            }

            if ($alive) {
                Write-Log 'WARN' "another run holds the lock (pid $holderPid); standing down"
                Write-Host ''
                Write-Host "Another qbt-manager run is already in progress (pid $holderPid)." -ForegroundColor Yellow
                Write-Host 'Nothing was changed. That run will handle this pass.' -ForegroundColor DarkGray
                Exit-Run -Code 4
            }

            Write-Log 'WARN' "clearing a stale lock left by pid $holderPid"
            Remove-Item -LiteralPath $script:lockPath -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Log 'WARN' 'could not take the run lock after two attempts; continuing without it'
    return $false
}
# ---------------------------------------------------------------------------
# title normalisation
# ---------------------------------------------------------------------------
#
# Scene names follow a rough convention:
#
#     Title.Year.Source.Resolution.Codec.Audio.Grp
#
# so the reliable place to cut the real title off is the FIRST technical or
# year marker. Everything after it is encode metadata and is discarded. What
# survives is then compared by token containment rather than string equality,
# which tolerates the noise words that sit in front of the cut point
# (country codes, edition words) without risking a false match.

# first marker that ends the title
$script:boundaryPattern = '(?i)(?<!\w)(?:19|20)\d{2}(?!\w)' +
    '|(?<!\w)(?:2160|1080|720|576|480|4k|8k|uhd)[pi]?(?!\w)' +
    # 360p/400p/540p need the suffix spelled out here. Adding the bare
    # numbers to the list above would cut a title like '540' straight in
    # half, because that branch makes p/i optional.
    '|(?<!\w)(?:360|400|540)[pi](?!\w)' +
    '|(?<!\w)(?:blu-?\s?ray|bdrip|brrip|remux|web-?\s?dl|web-?\s?rip|webrip|hdtv|tvrip|dvdrip|dvd)(?!\w)' +
    '|(?<!\w)(?:x26[45]|hevc|avc|xvid|divx|av1)(?!\w)' +
    '|(?<!\w)(?:truehd|atmos|dts|dd|eac3|ec-?3|ac-?3|aac|flac|opus|pcm|mp3|lpcm)(?!\w)' +
    '|(?<!\w)(?:hdr10|hdr|hlg|sdr)(?!\w)' +
    '|(?<!\w)(?:proper|repack|extended|unrated|directors?|theatrical|multi|dual)(?!\w)'

# non-latin scripts that prefix or decorate the real title
$script:nonLatin = '[\p{IsCJKUnifiedIdeographs}\p{IsCyrillic}\p{IsArabic}\p{IsHebrew}\p{IsGreek}\p{IsDevanagari}]+'

# noise words that survive the cut and must not influence matching at all
$script:ignorable = @(
    'disc','discs','complete','season','series','collection','edition','volume','vol',
    'web','rip','hd','sd','full','hdrip','internal','limited','uncut','remastered',
    'dubbed','subbed','subs','sub','final','version'
)

# qualifiers that may be present on one release and absent on another without
# meaning "different work" - but they must AGREE when both are present, so that
# "The Office US" and "The Office UK" stay apart.
$script:softTokens = @(
    'us','uk','gb','ca','au','br','ru','jp','kr','cn','fr','de','it','es','pt','nl',
    'sv','no','da','fi','pl','tr','ar','he','hi','th','gr','cz','hu','ro','ua','il',
    'ita','eng','ger','fre','spa','por','tur','ara','heb','hin','ron','cze','dan',
    'swe','nor','fin','hun','gre','pol','rus','jpn','kor','chi'
)

function Get-TitleParts {
    <#
        Splits a release name into the parts used for matching.
        Returns $null when there is not enough signal to identify a title, in
        which case the caller must leave the torrent alone.
    #>
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $null }

    $orig = $Name
    $work = $Name

    # --- episode / season markers, lifted out before anything else ---------
    $isSeries = $false
    $season = $null
    $episode = $null
    $episodeLast = $null
    $isMulti = $false
    # true when the marker was a bare E.. that carried no season of its own
    $bareEpisode = $false
    # where the marker sat in the name; the show name is only what came before it
    $markerIndex = -1

    # A RANGE has to be part of the pattern, not tidied up afterwards. Matching
    # only the single episode and then removing it left the range end behind as
    # ordinary title text: 'S01E01-10' matched S01/E01, the '-10' survived
    # normalisation, and the release was filed under the show 'widows bay 10' -
    # while 'S01E01-06' became 'widows bay 06'. One series, two invented show
    # names, so overlapping packs could never meet and each pack printed a
    # different title.
    #
    # The trailing group is optional so a single episode still matches here, and
    # the two cases are told apart by whether that group took part. The end must
    # also be greater than the start: 'S01E01-01' is one episode, not a pack.
    # The compact range, 'S18E01E02', with no separator between the two episode
    # numbers. It has to be its own pattern. The one below ends at the episode
    # number and then insists the next character is not a word character - which
    # the 'E' of 'E02' is - so 'S18E01E02' matched nothing here at all, and the
    # bare-E pattern further down claimed its 'E02' half instead. The release
    # then parsed as season 1, episode 2, under the show 'its always sunny in
    # philadelphia s18e01': wrong show, wrong season, and an episode set no
    # other release could ever share, so dedup could not weigh it against
    # anything.
    $m = [regex]::Match($work, '(?i)(?<!\w)S(?<s>\d{1,3})[\s._-]*E(?<e1>\d{1,3})[\s._-]*E(?<e2>\d{1,3})(?!\w)')
    if (-not $m.Success) {
        $m = [regex]::Match($work, '(?i)(?<!\w)S(?<s>\d{1,3})[\s._-]*E(?<e1>\d{1,3})(?:\s*[-~]\s*E?(?<e2>\d{1,3}))?(?!\w)')
    }
    if (-not $m.Success) {
        $m = [regex]::Match($work, '(?i)(?<![\w.])(?<s>\d{1,2})x(?<e1>\d{1,3})(?:\s*[-~]\s*(?:x)?(?<e2>\d{1,3}))?(?![\w])')
    }
    if (-not $m.Success) {
        # That lookbehind was '(?<!\w.])' - a stray ']' where '[\w.]' was meant.
        # It therefore only rejected a three-character sequence ending in ']',
        # which never happens, so it rejected nothing at all and the 'E02' half
        # of 'S18E01E02' matched as a bare episode of season 1, filing it as
        # season 1 episode 2 under the show 'its always sunny in philadelphia
        # s18e01'.
        #
        # 'not preceded by a DIGIT' is the guard, and a digit is the whole of the
        # fault: the 'E02' inside 'S18E01E02' follows '1', while every real
        # spelling puts something else in front - a space in 'Breaking Bad E05',
        # a dot in 'Show.Name.E01', the letter S in 'Se5'. Refusing letters too
        # would have read 'Se5' as season 5, so the digit is precisely the line
        # that has to be drawn here.
        $m = [regex]::Match($work, '(?i)(?<!\d)E(?<e1>\d{1,3})(?:\s*[-~]\s*E?(?<e2>\d{1,3}))?(?!\w)')
        if ($m.Success) {
            $bareEpisode = $true
            $season = 1
        }
    }
    # A season with no episode number is a WHOLE-SEASON pack: it covers every
    # episode of that season, so there is no episode to record and nothing to
    # narrow the comparison by. 'Its Always Sunny In Philadelphia s18 WEB-DL
    # 1080p' is exactly that, and treating it as a film left its season sitting
    # in the title as ordinary text - so it could only ever match another
    # release that spelled its season the same way.
    #
    # Seasons are zero-padded as often as not ('s01', 'S18'), so leading
    # zeros have to be allowed before the first significant digit - otherwise
    # every padded season is invisible to this branch. The number still has to
    # be a real one, which is what stops a group tag like '-S0NNER' or a
    # trailing 'x264-S0' from being read as season zero.
    if (-not $m.Success) {
        $m = [regex]::Match($work, '(?i)(?<!\w)(?:season|se)[\s._-]*(?<s>0*[1-9]\d{0,2})(?!\w)')
        if ($m.Success) { $episode = 0 }
    }
    if (-not $m.Success) {
        # A bare 'S18'. Patterns above have already had their chance, so by the
        # time this runs there is no 'E' anywhere near - an 'S01E01' release was
        # taken by the first pattern and a bare 'E01' by the third. What is left
        # is a season number standing on its own.
        $m = [regex]::Match($work, '(?i)(?<!\w)S(?<s>0*[1-9]\d{0,2})(?!\w)')
        if ($m.Success) { $episode = 0 }
    }
    if ($m.Success) {
        $isSeries = $true
        if ($m.Groups['s'].Success -and $m.Groups['s'].Value -ne '') { $season  = [int]$m.Groups['s'].Value }
        if ($m.Groups['e1'].Success -and $m.Groups['e1'].Value -ne '') { $episode = [int]$m.Groups['e1'].Value }
        if ($m.Groups['e2'].Success -and $m.Groups['e2'].Value -ne '') {
            $last = [int]$m.Groups['e2'].Value
            if ($null -ne $episode -and $last -gt $episode) {
                $isMulti = $true
                $episodeLast = $last
            }
        }
    }
    if ($isSeries) {
        if ($null -eq $season) { $season = 1 }
        $markerIndex = $m.Index
        # remove the whole marker, range included, so it cannot sit inside the
        # title text
        $work = $work.Remove($m.Index, $m.Length)

        # A bare episode marker carries no season, but the season is very often
        # printed EARLIER in the name. 'Euphoria.S03.Dub E01-E08' is season 3;
        # taking the default filed it under season 1 and left 's03 dub' welded
        # onto the show name, so the group printed as 'euphoria s03 dub
        # S1E1-E8' - wrong show, wrong season, comparable with nothing. When the
        # season really is stated up front, use it, and move the title cut up to
        # it so the season and everything after it goes with the marker.
        #
        # The cut moves to an EARLIER index. The marker was removed from the end
        # of $work, which leaves every index in front of it where it was, so
        # $m.Index is still valid here.
        if ($bareEpisode) {
            $front = $work.Substring(0, $m.Index)
            $sm = [regex]::Match($front, '(?i)(?<![\w])(?:s(?<s>0*[1-9]\d{0,2})|(?:season|se)[\s._-]*(?<s>0*[1-9]\d{0,2}))(?![\w])')
            if ($sm.Success) {
                $season = [int]$sm.Groups['s'].Value
                $markerIndex = $sm.Index
            }
        }
    }

    # --- year, from anywhere in the name (brackets included) ---------------
    $year = $null
    $m = [regex]::Match($work, '(?<!\w)(?:19|20)\d{2}(?!\w)')
    if ($m.Success) { $year = $m.Value }

    # The episode TITLE sits AFTER the marker, so removing the marker alone left
    # it welded onto the show name. 'Its Always Sunny In Philadelphia S18E02
    # Dennis And Dee Dont Get Rich 1080p DSNP' parsed as the show 'its always
    # sunny in philadelphia dennis and dee dont get rich' while
    # 'Its.Always.Sunny.in.Philadelphia.S18E02.1080p.rus' parsed as 'its always
    # sunny in philadelphia'. One episode, two show names, so the two releases
    # never met and dedup could not weigh them against each other.
    #
    # Everything from the marker onwards is the episode title or a technical
    # tag, so the show name is the text in front of the marker and nothing else.
    # The year is read before this cut, so a year printed after the marker is
    # still seen. The head must carry real letters or digits, otherwise a name
    # that leads straight into the marker keeps its old title instead of
    # collapsing to nothing.
    if ($isSeries -and $markerIndex -ge 0) {
        $head = $work.Substring(0, [Math]::Min($markerIndex, $work.Length))
        if ([regex]::Replace($head, '[^\p{L}\p{Nd}]', '').Length -ge 2) { $work = $head }
    }

    # --- source tag, e.g. "[ext.to]" ----------------------------------------
    #
    # The cut below can only remove a trailing tag if something technical sits
    # after it to cut at. 'Widows.Bay S01E01-E10 [ext.to]' has nothing after
    # it, so the tag survived normalisation and the release was filed as
    # 'widows bay ext to' - a different show from 'widows bay', which then
    # refused to match it. Only a bracketed group containing a bare domain is
    # dropped, so '(1999)' and '(No Way Home)' are untouched.
    $work = [regex]::Replace($work, '\[[^\]]*?\b[\w-]+\.(?:to|com|net|org|me|tv|cc|io|se|it|ru|pro)\b[^\]]*\]', ' ')
    # --- cut at the first technical marker ---------------------------------
    $work = [regex]::Replace($work, $script:nonLatin, ' ')
    $cut = [regex]::Match($work, $script:boundaryPattern)
    if ($cut.Success) { $work = $work.Substring(0, $cut.Index) }

    $title = $work

    # titles that are themselves numeric, e.g. "1917.2019.1080p.BluRay"
    if ([string]::IsNullOrWhiteSpace($title)) {
        $first = [regex]::Match($orig, '[^\s._\-\[\]\(\)]+')
        if ($first.Success) { $title = $first.Value }
    }

    $title = $title -replace '[._]', ' '

    # An apostrophe is part of the word, not a separator between two words.
    # Turning it into a space split 'It's' into 'it s', so
    # 'Its.Always.Sunny.In.Philadelphia.S18E03.HD1080p' and
    # 'Its.Always.Sunny.in.Philadelphia.S18E03.720p.Ru.Ultradox' arrived as two
    # different shows: 'it s always sunny in philadelphia' and 'its always sunny
    # in philadelphia'. The clustering pass groups a show family by the FIRST
    # WORD of the show name, so 'it' and 'its' became two families, S18E3,
    # S18E5 and S18E6 each printed twice, and no release in one of those groups
    # could ever be weighed against the better copy sitting in the other.
    # Dropping the apostrophe rejoins the word.
    $title = $title -replace '[\u0027\u2019\u02BC]', ''

    $title = [regex]::Replace($title, '[^\p{L}\p{Nd}]+', ' ')
    $title = [regex]::Replace($title, '\s+', ' ').Trim().ToLowerInvariant()

    if ($title.Length -lt 2) { return $null }

    # --- tokens ------------------------------------------------------------
    $raw = @($title -split ' ' | Where-Object { $_.Length -gt 0 })

    # a title that is just a number, e.g. "1917" or "2001", is a real title
    $numericTitle = ($raw.Count -eq 1 -and $raw[0] -match '^\d+$')

    $numbers = @()
    $tokens  = @()
    foreach ($w in $raw) {
        if ($w -match '^\d+$' -and -not $numericTitle) {
            # a bare number inside a title is a sequel marker ("Terminator 2")
            $numbers += $w
            continue
        }
        if ($script:ignorable -contains $w) { continue }
        $tokens += $w
    }

    if ($tokens.Count -eq 0) { return $null }

    return [pscustomobject]@{
        IsSeries = $isSeries
        Season   = $season
        Episode  = $episode
        EpisodeLast    = $episodeLast
        IsMultiEpisode = $isMulti
        Year     = $year
        Title    = $title
        Tokens   = $tokens
        Numbers  = $numbers
    }
}

function Test-SameTitle {
    <#
        Decides whether two torrents are different encodings of one work.
        Deliberately biased towards false negatives: a missed duplicate is
        harmless, a false match deletes somebody's only copy.
    #>
    param([object]$A, [object]$B)

    if ($null -eq $A -or $null -eq $B) { return $false }
    if ($A.IsSeries -ne $B.IsSeries) { return $false }

    if ($A.IsSeries) {
        if ($A.Season -ne $B.Season) { return $false }
        if ($A.Episode -ne $B.Episode) { return $false }
    }

    # A year printed on one release and absent from another is not a
    # disagreement about which work this is. 'Its Always Sunny in Philadelphia
    # S18E04 2026 A Virtual Insanity' and 'Its.Always.Sunny.in.Philadelphia.
    # S18E04.1080p.rus' are the same episode of the same show, but demanding
    # equal years split them into two groups that could not see each other - so a
    # finished copy in one never counted against anything in the other, and the
    # episode printed as '(2026) S18E4' above three rows and 'S18E4' above two.
    # Two DIFFERENT stated years still refuse the match, which is what keeps a
    # remake apart from the original.
    if ($A.Year -and $B.Year -and $A.Year -ne $B.Year) { return $false }

    # sequel numbers must agree, so "Terminator" never matches "Terminator 2"
    if (($A.Numbers -join ',') -ne ($B.Numbers -join ',')) { return $false }

    $at = @($A.Tokens)
    $bt = @($B.Tokens)
    if ($at.Count -eq 0 -or $bt.Count -eq 0) { return $false }

    # identical titles are the common case
    if (($at -join ' ') -eq ($bt -join ' ')) { return $true }

    # otherwise one must contain the other. Extra words are tolerated only when
    # they are soft qualifiers AND the shorter title carries none of its own,
    # so "the office" matches "the office us" but never "the office uk".
    $small = $at
    $large = $bt
    if ($small.Count -gt $large.Count) { $small = $bt; $large = $at }

    foreach ($t in $small) {
        if ($large -notcontains $t) { return $false }
    }

    foreach ($t in $small) {
        if ($script:softTokens -contains $t) { return $false }
    }
    foreach ($t in $large) {
        if ($small -notcontains $t -and $script:softTokens -notcontains $t) { return $false }
    }

    return $true
}
function Get-EpisodeSetKey {
    <#
        The exact set of episodes a release carries, as a short comparable
        string. Two releases are rivals for the same content only when this
        reads the same on both sides.

            film            not a series - the cluster has already decided
                            these are all the same work
            S3-ALL          a whole-season pack ("S03", "Season 1 Complete")
            S3-E7           one episode
            S3-E1-E10       a pack of episodes 1 to 10

        The END of a range is the whole reason this exists. A cluster only ever
        holds releases whose FIRST episode agrees, because that is all
        Test-SameTitle compares. So "S01E01-10" and "S01E01-06" land in the
        same cluster, and comparing their totals would delete the 6-episode
        pack beside the finished 10-episode one - while the four episodes it
        holds and the keeper does not would simply be gone, which is not
        redundancy, it is loss.

        Two packs are therefore comparable exactly when the range is identical:
        same range means the same episodes, so one really is a spare copy of
        the other. A pack is never comparable with a single episode, because
        whichever of the two is larger, the smaller one is still not covered by
        it. Season packs meet each other under the same test.

        An empty result means the episode is unknown, and callers must read it
        as "take no part" - never as a wildcard.
    #>
    param([object]$Parts)

    if (-not $Parts) { return "" }
    if (-not $Parts.IsSeries) { return "film" }
    if ($null -eq $Parts.Episode) { return "" }

    $s = "S$($Parts.Season)"
    if ($Parts.Episode -eq 0) { return "$s-ALL" }

    if ($Parts.IsMultiEpisode -and $null -ne $Parts.EpisodeLast) {
        return "$s-E$($Parts.Episode)-E$($Parts.EpisodeLast)"
    }
    return "$s-E$($Parts.Episode)"
}

# The episode set a release REALLY holds, read from its own file list. Returns
# '' whenever the files cannot say, and '' always means "no opinion" - never a
# wildcard.
#
# This exists because the key above is read off the NAME, and a name is a claim
# rather than a fact. Measured on a live queue:
#
#   Euphoria.S03.COMPLETE.1080p.AMZN.WEB-DL.H.264-EniaHD   40.37 GB, 100%
#       name says season 3, no episode  ->  keyed S3-ALL
#       files say S03E01 .. S03E08      ->  actually eight episodes
#
#   Euphoria US S03e01-08 [720p Ita Eng Spa SubS] byMe7alh  15.69 GB, 96.5%
#       name and files both say eight episodes  ->  keyed S3-E1-E8
#
# Same eight episodes, the first finished and 2.6x bigger, and the two could
# never be weighed against each other: S3-ALL is not a range, so it equals no
# range key, and the set pass had no reason to put them in one group. The 15 GB
# pack sat there downloading. The label was the defect, not the rule - correcting
# it makes this the comparison of two packs of the SAME range, which is exactly
# what the rule permits.
#
# Every refusal returns '' and the caller keeps the name it read, which is the
# safe direction: S<n>-ALL only ever meets S<n>-ALL, which is today's behaviour.
#
#   - every file must place itself by an S..E token in its own NAME, and not in
#     the folders above it, or there is no opinion;
#   - the run must not span seasons;
#   - the run must not skip an episode, because a range is the only shape
#     Get-EpisodeSetKey can compare and 'E01 E02 E04' is not a range;
#   - a token may itself be a range ('S03E01-08'), which is expanded. A bare
#     '.720p' is not a range: the tail must be a dash, or a dot with the letter
#     E, and nothing else.
function Get-EpisodeSetFromFiles {
    param($Files)

    if (-not $Files) { return '' }
    $list = @($Files)
    if ($list.Count -eq 0) { return '' }

    $season = $null
    $eps = New-Object System.Collections.Generic.HashSet[int]

    foreach ($f in $list) {
        $path = [string]$f.name
        if (-not $path) { return '' }

        # The FILE, not the path. The folder 'Euphoria.S03.1080p...' sits above
        # every file in the pack, and a folder named 'Show.S03E01-E08' would
        # stamp episode 1 onto all of them.
        $leaf = $path
        $cut = $path.LastIndexOfAny([char[]]@('/', '\'))
        if ($cut -ge 0) { $leaf = $path.Substring($cut + 1) }

        # The tail carries (?!\d) so it must be the WHOLE number that follows.
        # Without it .NET backtracks: on 'Show.S03E01-720p.mkv' the two-digit
        # tail matches '-72', reads it as episode 72, and the file is believed to
        # hold episodes 1 to 72 - a range wide enough to meet almost any pack of
        # the same show and let it be deleted as a duplicate of it.
        $ms = [regex]::Matches($leaf,
            '(?i)S(\d{1,3})[ ._-]?E(\d{1,3})(?:-(0?\d{1,2})(?!\d)|\.E(0?\d{1,2})(?!\d))?')
        if ($ms.Count -eq 0) { return '' }

        # A dash and digits that the tail could not take is not an episode range
        # at all - it is the resolution, as in 'S03E01-720p'. Reading that as a
        # lone episode 1 would be worse than refusing: S3-E1 is a real key, and a
        # pack of eight episodes would then match one finished single of episode
        # 1. A file whose range cannot be understood is no opinion.
        $dashTail = [regex]::Match($leaf, '(?i)S\d{1,3}[ ._-]?E\d{1,3}-(\d+)')
        if ($dashTail.Success -and [int]$dashTail.Groups[1].Value -gt 99) { return '' }

        $placed = $false
        foreach ($m in $ms) {
            $sn = [int]$m.Groups[1].Value
            $a = [int]$m.Groups[2].Value
            $tail = $m.Groups[3].Value
            if (-not $tail) { $tail = $m.Groups[4].Value }
            $b = $a
            if ($tail) { $b = [int]$tail }

            # Nonsense in, no opinion out. 'S03E01-720p' cannot be a range.
            #
            # The 99 ceiling is what makes this refuse rather than believe: a
            # season has never had 720 episodes, and a file named
            # 'Show.S03E01-720p.mkv' would otherwise be read as holding episodes
            # 1 to 720 - a range so wide it would meet almost any pack of the
            # same show and let it be deleted as a duplicate. Written as 100 the
            # check still passed, because .NET's regex backtracks the tail from
            # two digits to one and reads '-72' as episode 72.
            if ($sn -lt 1 -or $a -lt 1 -or $b -lt $a -or $b -gt 99) { continue }
            if ($null -eq $season) { $season = $sn }
            elseif ($season -ne $sn) { return '' }   # spans seasons
            for ($e = $a; $e -le $b; $e++) { [void]$eps.Add($e) }
            $placed = $true
        }
        if (-not $placed) { return '' }
    }

    if ($null -eq $season -or $eps.Count -eq 0) { return '' }
    $nums = @($eps | Sort-Object)
    $first = [int]$nums[0]
    $last = [int]$nums[$nums.Count - 1]
    if (($last - $first + 1) -ne $nums.Count) { return '' }   # a gap is not a range

    if ($first -eq $last) { return "S$season-E$first" }
    return "S$season-E$first-E$last"
}

function Get-SetTag {
    <#
        A short human tag for the episode set a release carries. DISPLAY ONLY -
        nothing is decided with it. Get-EpisodeSetKey is the comparable key and
        this is its readable twin, so a row can say what it holds without the
        reader having to parse the release name.

            film            not a series
            season          S03, "Season 1 Complete" - the whole season
            E7              one episode
            E1-E8           a pack of eight episodes
    #>
    param([object]$Parts)

    if (-not $Parts) { return "" }
    if (-not $Parts.IsSeries) { return "" }
    if ($null -eq $Parts.Episode) { return "" }
    if ($Parts.Episode -eq 0) { return "season" }

    $tag = "E$($Parts.Episode)"
    if ($Parts.IsMultiEpisode -and $null -ne $Parts.EpisodeLast) {
        $tag += "-E$($Parts.EpisodeLast)"
    }
    return $tag
}
function Get-EpisodeSetLabel {
    <#
        The season/episode part of a group header, derived from an episode SET
        KEY rather than from any one release. DISPLAY ONLY.

            film            nothing at all
            S03             the whole season
            S03E7           one episode
            S03E1-E8        a pack of eight

        Building the header from the key rather than from the first member is
        what stops a header reading S18E1-E8 from sitting above releases that
        hold only episode 1. Get-EpisodeSetKey is what a release is judged
        under; this is its readable twin, so the header a group is printed
        under is the same set the rows were weighed under.
    #>
    param([string]$Key)

    if ([string]::IsNullOrWhiteSpace($Key) -or $Key -eq 'film') { return '' }
    if ($Key -match '^S(?<s>\d+)-ALL$') { return "S$($Matches['s'])" }
    if ($Key -match '^S(?<s>\d+)-E(?<e1>\d+)-E(?<e2>\d+)$') {
        return "S$($Matches['s'])E$($Matches['e1'])-E$($Matches['e2'])"
    }
    if ($Key -match '^S(?<s>\d+)-E(?<e1>\d+)$') { return "S$($Matches['s'])E$($Matches['e1'])" }
    return $Key
}

function Get-CommonRun {
    <#
        The longest run of leading words every one of these titles agrees on, or
        '' when they share no leading word at all.

        This is how a show name is recovered out of titles that disagree about
        everything after it:
            'ted lasso'
            'ted lasso follow the anger'
            'ted lasso mae sull autobus ita eng'
        All three begin 'ted lasso', and 'ted lasso' is the show. Note that the
        two names for the same episode in two languages share no suffix at all,
        so nothing that compares the END of two titles would ever pair them.

        An empty result means no shared first word, which is the signal that
        these are different shows. Callers must read '' as a hard no, never as
        a wildcard or an unknown.
    #>
    param([object[]]$TokenLists)

    # Built by hand rather than through a pipeline on purpose. A pipeline
    # unrolls any array it carries, so a title's word list would arrive as a
    # series of loose words and every one of them would look like its own
    # one-word title - making the common run empty and quietly disabling the
    # whole pass. ',$a' keeps each title's words together.
    $lists = @()
    foreach ($l in $TokenLists) {
        if ($null -eq $l) { continue }
        $a = @($l)
        if ($a.Count -gt 0) { $lists += ,$a }
    }
    if ($lists.Count -eq 0) { return '' }

    $run = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $lists[0].Count; $i++) {
        $word = $lists[0][$i]
        if (-not $word) { break }
        foreach ($l in $lists) {
            if ($i -ge $l.Count) { return ($run -join ' ') }
            if ($l[$i] -ne $word) { return ($run -join ' ') }
        }
        [void]$run.Add($word)
    }
    return ($run -join ' ')
}

function Get-ShowLabel {
    <#
        The show part of a group header, shared by the manager and status.ps1.

        The year is printed only when EVERY member of the group states the same
        one.

        It is there to tell two remakes apart, and it used to be taken from
        whichever member happened to sort first. Once a release that states a
        year is allowed to share a group with one that does not - which is what
        an absent year now means - sorting first alone decides the header, so
        '(2026)' could sit above rows that never claimed a year at all. A header
        has to describe its own rows, so one unstated year among the members
        means no year is printed.
    #>
    param($Parts)

    $list = @($Parts)
    if ($list.Count -eq 0) { return '' }

    $show = $list[0].Title
    $years = @($list | ForEach-Object { $_.Year } | Where-Object { $_ } | Sort-Object -Unique)
    $unstated = @($list | Where-Object { -not $_.Year }).Count
    if ($years.Count -eq 1 -and $unstated -eq 0) { $show += ' (' + $years[0] + ')' }
    return $show
}

function Set-FamilyLabels {
    <#
        DISPLAY ONLY. Stamp every member of every series cluster with one
        canonical name for its show family.

        Why this exists, measured on a live queue. A family is decided by the
        first word of the show name, so 'euphoria' and 'euphoria us' are one
        family and their per-episode clusters DO merge - every one of those
        clusters already held both titles. But each merged cluster was then
        labelled from its own first member's title, and which cluster won the
        merge differs per episode. One show therefore printed as four groups
        ('euphoria', 'euphoria us', 'euforia euphoria (2019)', 'euforie euphoria
        (2026)') and read as four different shows, when it is one.

        This is a second pass rather than a reuse of Merge-SeriesClusters'
        internals for two reasons:

        - PACKS. Merge-SeriesClusters skips every pack ('if ($parts.IsMultiEpisode)
          { continue }'), because a pack must never merge with a single episode -
          that is a correctness rule. So packs leave that pass with no family name
          at all and fall back to the per-cluster label, which is how 17 Euphoria
          packs kept the old wrong name even after the singles were fixed. A pack
          cannot MERGE with a single, but it plainly still belongs to a family for
          naming purposes, and the two are different questions.

        - Not touching a function whose output decides deletions. The merge pass
          computes a canonical name too, discards it, and keeps only the suffixes.
          Rather than change how it computes anything, this reads the final
          clusters and labels them.

        Nothing here decides anything: no verdict, no cluster, no dedup comparison
        and no deletion reads showLabel. Films are skipped (they never entered the
        family logic), and so is anything whose members share no leading word.
    #>
    param($Clusters)

    $list = @($Clusters)
    $count = $list.Count
    if ($count -eq 0) { return }

    # One show name per cluster: the run of leading words its own members agree
    # on. Same helper the merge pass uses, so the two agree on what a name is.
    $show = @('') * $count
    for ($i = 0; $i -lt $count; $i++) {
        $parts = $list[$i][0].parts
        if (-not $parts -or -not $parts.IsSeries) { continue }
        if ($null -eq $parts.Season -or $null -eq $parts.Episode) { continue }
        $tokenLists = @()
        foreach ($m in $list[$i]) { $tokenLists += , @($m.parts.Tokens) }
        $show[$i] = Get-CommonRun -TokenLists $tokenLists
    }

    # The same lost-apostrophe repair the merge pass performs, under the same
    # narrow condition: rejoining is only allowed to land EXACTLY on another
    # cluster's complete show name, and only when exactly one candidate does.
    # 'It s Always Sunny...' has no apostrophe to drop, so 'it' and 'its' were
    # two families - which would print one show as two groups here.
    $names = @{}
    for ($i = 0; $i -lt $count; $i++) { if ($show[$i]) { $names[$show[$i]] = $true } }
    for ($i = 0; $i -lt $count; $i++) {
        if (-not $show[$i]) { continue }
        $words = @($show[$i] -split ' ')
        if ($words.Count -lt 2) { continue }
        if ($words[0].Length -gt 3) { continue }
        $hits = @()
        for ($w = 1; $w -lt $words.Count; $w++) {
            $cand = (@($words[0..($w - 1)]) -join '') + (@($words[$w..($words.Count - 1)]) -join ' ')
            if ($names.ContainsKey($cand)) { $hits += $cand }
        }
        if ($hits.Count -eq 1) { $show[$i] = $hits[0] }
    }

    # Family -> the longest name every member of it agrees on. The year is
    # printed only when EVERY member states the same one, the rule Get-ShowLabel
    # applies within one group, widened to the family so a name cannot claim a
    # year some of its own rows never gave.
    $family = @{}
    for ($i = 0; $i -lt $count; $i++) {
        if (-not $show[$i]) { continue }
        $f = @($show[$i] -split ' ')[0]
        if (-not $family.ContainsKey($f)) { $family[$f] = New-Object System.Collections.ArrayList }
        [void]$family[$f].Add($i)
    }

    $familyLabel = @{}
    foreach ($f in $family.Keys) {
        $members = @($family[$f])
        $runs = @()
        foreach ($i in $members) { $runs += , @($show[$i] -split ' ') }
        $baseText = Get-CommonRun -TokenLists $runs
        if (-not $baseText) { continue }
        $label = $baseText

        $partsAll = @()
        foreach ($i in $members) { $partsAll += , $list[$i][0].parts }
        $yrs = @($partsAll | ForEach-Object { $_.Year } | Where-Object { $_ } | Sort-Object -Unique)
        $unstated = @($partsAll | Where-Object { -not $_.Year }).Count
        if ($yrs.Count -eq 1 -and $unstated -eq 0) { $label += ' (' + $yrs[0] + ')' }
        $familyLabel[$f] = $label
    }

    for ($i = 0; $i -lt $count; $i++) {
        if (-not $show[$i]) { continue }
        $f = @($show[$i] -split ' ')[0]
        if (-not $familyLabel.ContainsKey($f)) { continue }
        foreach ($m in $list[$i]) {
            Add-Member -InputObject $m -NotePropertyName 'showLabel' -NotePropertyValue $familyLabel[$f] -Force
        }
    }
}

# One show-family key per cluster. '' for a film, an unparsed release, or a
# cluster whose own members do not agree on a show name.
#
# This is the whole of "which show is this", lifted out of
# Merge-SeriesClustersCore so the set pass can ask the same question instead of
# guessing again. A second, looser guess is the drift this codebase keeps paying
# for: Set-FamilyLabels already had to be written to match this logic by hand.
#
# The family is the FIRST WORD of the run of leading words a cluster's own
# members agree on, after the lost-apostrophe repair. First word is what keeps
# two different shows apart - 'ted lasso' and 'its always sunny in philadelphia'
# fall in different families, so no rewording of either can produce a merge.
function Get-ClusterFamilies {
    param($Clusters)

    $count = @($Clusters).Count
    $show = @('') * $count
    if ($count -eq 0) {
        return [pscustomobject]@{ Show = $show; Family = $show }
    }

    for ($i = 0; $i -lt $count; $i++) {
        $parts = $Clusters[$i][0].parts
        if (-not $parts -or -not $parts.IsSeries) { continue }
        if ($null -eq $parts.Season -or $null -eq $parts.Episode) { continue }

        # One element per title, each element being that title's whole word
        # list. Written as an explicit loop rather than a pipeline, because a
        # pipeline unrolls arrays on the way out and each title's words would
        # arrive loose - leaving every show name empty and silently disabling
        # this whole computation.
        $lists = @()
        foreach ($m in $Clusters[$i]) { $lists += , @($m.parts.Tokens) }
        $show[$i] = Get-CommonRun -TokenLists $lists
    }

    # Some release groups lose the apostrophe before the name ever reaches
    # qBittorrent: 'It s Always Sunny in Philadelphia S18E03 ... playWEB' carries
    # no apostrophe at all, just a space. There is nothing for the normalisation
    # in Get-TitleParts to drop, so the word stays split - and because the family
    # test keys on the FIRST WORD, 'it' and 'its' became two families and those
    # releases could never see the other 100-odd members of their own show.
    #
    # Rejoining is done only when the rejoined name equals another show name IN
    # FULL, and when exactly one candidate does. Removing one space from a name
    # could have been any of a handful of things, but landing exactly on another
    # show's complete name - every word, in order, nothing left over - is not one
    # of them by accident. The exact match is the evidence; nothing is merged on
    # resemblance. A first word of four letters or more is left alone, since that
    # is longer than any apostrophe-bearing word in a show name needs to be.
    $names = @{}
    for ($i = 0; $i -lt $count; $i++) { if ($show[$i]) { $names[$show[$i]] = $true } }
    for ($i = 0; $i -lt $count; $i++) {
        if (-not $show[$i]) { continue }
        $words = @($show[$i] -split ' ')
        if ($words.Count -lt 2) { continue }
        if ($words[0].Length -gt 3) { continue }
        $hits = @()
        for ($w = 1; $w -lt $words.Count; $w++) {
            $cand = (@($words[0..($w - 1)]) -join '') + (@($words[$w..($words.Count - 1)]) -join ' ')
            if ($names.ContainsKey($cand)) { $hits += $cand }
        }
        if ($hits.Count -eq 1) { $show[$i] = $hits[0] }
    }

    $fam = @('') * $count
    for ($i = 0; $i -lt $count; $i++) {
        if ($show[$i]) { $fam[$i] = @($show[$i] -split ' ')[0] }
    }
    return [pscustomobject]@{ Show = $show; Family = $fam }
}

function Merge-SeriesClustersCore {
<#
        Second pass over the dedup groups, for series only.

        Series releases carry the episode name inconsistently and sometimes not
        at all, so one show and one episode reaches the first pass as several
        different titles and therefore several clusters. Dedup only compares
        inside a cluster, so those never meet - which is how a finished 1080p
        ends up sitting in the library beside a finished 2160p of the same
        episode.

        Each cluster is given a show name: the run of leading words its own
        members agree on. Clusters are then grouped into show families by the
        first word of that name, and clusters of one episode within one family
        are joined.

        What keeps two different shows apart:

        - The family is the FIRST WORD of the show name. 'ted lasso' and
          'its always sunny in philadelphia' fall in different families, so no
          rewording of either can produce a merge. This is the guard that does
          the real work, and it is why this is a first-word test rather than a
          looser similarity score.

          The same guard is what keeps apart names that merely share an opening
          word, which is not hypothetical: a family is decided by one word, so
          'the talented mr ripley', 'the office' and 'the bear' would all land
          in family 'the' and be compared against each other on that word alone.
          Nothing short of the first word prevents it.

          It also has a known cost, measured on a live queue: 'widows bay',
          'wdowia zatoka widows bay' and 'o segredo de widows bay' are the same
          show in three languages, and the guard keeps all three apart because
          their first words differ. Nothing can be done about that from titles
          alone - it needs an alias list - and loosening the guard to guess at
          translated names would trade a known false-negative for a real risk of
          merging two genuinely different shows.

        - A suffix that appears on more than one episode is part of the show's
          name, not an episode title, and never joins anything. 'ted lasso spin
          off' at both S4E8 and S4E9 therefore stays apart from 'ted lasso'.

        Suffixes are measured against ONE show name for the whole family, never
        against whichever other cluster a given one happens to be compared with.
        That matters: measuring per-pair makes 'mae rides the bus' look like a
        suffix seen on two episodes - because it is compared against the S4E8
        cluster as well as its own S4E9 one - and that mistaken reading then
        blocks the very merge it was meant to police. Episode titles differ per
        episode by definition, so a suffix must be judged on the episodes it
        actually appears on.

        Films never enter this pass, so film clustering is unchanged.

        The case that stays ambiguous, and cannot be settled from titles alone: a
        show named exactly like another show plus extra words, present for one
        episode only. 'ted lasso' and 'ted lasso spin off' at S4E8 are
        indistinguishable from 'ted lasso' and 'ted lasso follow the anger' at
        S4E8, because nothing in either title says whether the trailing words
        name the show or the episode. The repeated-suffix guard catches such a
        show as soon as a second episode of it turns up.
    #>
    param($Clusters)

    $count = $Clusters.Count
    if ($count -lt 2) { return ,$Clusters }

    # Show name and episode key per cluster. An empty show name means "not a
    # series, or unparsed", and such a cluster is never merged.
    #
    # The show names come from Get-ClusterFamilies, shared with the set pass so
    # that 'which show is this' has one answer in this file. That helper also
    # names packs, because the set pass needs a family for a pack; excluding
    # packs HERE is this pass's own decision, not a limit of the helper.
    $famInfo = Get-ClusterFamilies -Clusters $Clusters
    $show = @($famInfo.Show)
    $family = @{}
    for ($i = 0; $i -lt $count; $i++) {
        if (-not $show[$i]) { continue }
        # A pack holds a RANGE of episodes, so it has no single episode
        # key. Letting it merge would let it bridge two clusters whose
        # singles are different episodes, quietly folding them together.
        if ($Clusters[$i][0].parts.IsMultiEpisode) { $show[$i] = ''; continue }
        $f = @($famInfo.Family[$i] -split ' ')[0]
        if (-not $family.ContainsKey($f)) { $family[$f] = New-Object System.Collections.ArrayList }
        [void]$family[$f].Add($i)
    }
    if ($family.Count -eq 0) { return ,$Clusters }

    $key = @('') * $count
    for ($i = 0; $i -lt $count; $i++) {
        if (-not $show[$i]) { continue }
        $parts = $Clusters[$i][0].parts
        $key[$i] = "$($parts.Year)|S$($parts.Season)E$($parts.Episode)"
    }

    # One show name per family: the longest run every member agrees on. Each
    # cluster's suffix is then its own run minus that name, so the suffix means
    # the same thing for every member of the family.
    $suffix = @('') * $count
    $familyLabel = @{}
    foreach ($f in $family.Keys) {
        $members = @($family[$f])
        $runs = @()
        foreach ($i in $members) { $runs += , @($show[$i] -split ' ') }
        $baseText = Get-CommonRun -TokenLists $runs
        if (-not $baseText) { continue }
        $base = @($baseText -split ' ')
        foreach ($i in $members) {
            $w = @($show[$i] -split ' ')
            if ($w.Count -le $base.Count) { continue }
            $suffix[$i] = (@($w[$base.Count..($w.Count - 1)]) -join ' ')
        }

        # The family's one canonical name, printed with the year only when EVERY
        # member of the family states the same one - the same rule Get-ShowLabel
        # applies within a group, widened from one group to the whole family so a
        # header cannot claim a year some of its own rows never stated.
        $partsAll = @()
        foreach ($i in $members) { $partsAll += , $Clusters[$i][0].parts }
        $yrs = @($partsAll | ForEach-Object { $_.Year } | Where-Object { $_ } | Sort-Object -Unique)
        $unstated = @($partsAll | Where-Object { -not $_.Year }).Count
        $label = $baseText
        if ($yrs.Count -eq 1 -and $unstated -eq 0) { $label += ' (' + $yrs[0] + ')' }
        $familyLabel[$f] = $label
    }

    # DISPLAY ONLY. The canonical name computed for each family above is used only to
    # derive suffixes, and is then discarded - which is how one show came to print
    # as four groups. Set-FamilyLabels recomputes it over the final clusters,
    # stamps it, and is called on every return path of this function. Deliberately
    # NOT done here: it would only cover the clusters this pass touched, would miss
    # packs (which this pass skips on purpose), and would give two places a
    # showLabel could come from.

    # A suffix seen on two different episodes belongs to the show, not to an
    # episode, so it may not be used to join anything.
    $onEpisode = @{}
    for ($i = 0; $i -lt $count; $i++) {
        if (-not $suffix[$i]) { continue }
        $f = @($show[$i] -split ' ')[0]
        $k = "$f|$($suffix[$i])"
        if (-not $onEpisode.ContainsKey($k)) { $onEpisode[$k] = New-Object System.Collections.ArrayList }
        [void]$onEpisode[$k].Add($key[$i])
    }
    $isQualifier = @{}
    foreach ($k in $onEpisode.Keys) {
        if (@($onEpisode[$k] | Sort-Object -Unique).Count -gt 1) { $isQualifier[$k] = $true }
    }

    # Join clusters of one episode within one family, unless a show qualifier is
    # involved on either side.
    $parent = @{}
    for ($i = 0; $i -lt $count; $i++) { $parent[$i] = $i }

    $merged = 0
    for ($i = 0; $i -lt $count; $i++) {
        if (-not $show[$i]) { continue }
        $f = @($show[$i] -split ' ')[0]
        for ($j = $i + 1; $j -lt $count; $j++) {
            if (-not $show[$j]) { continue }
            if (@($show[$j] -split ' ')[0] -ne $f) { continue }
            if ($key[$i] -ne $key[$j]) { continue }
            if ($suffix[$i] -and $isQualifier.ContainsKey("$f|$($suffix[$i])")) { continue }
            if ($suffix[$j] -and $isQualifier.ContainsKey("$f|$($suffix[$j])")) { continue }

            $a = $i
            while ($parent[$a] -ne $a) { $a = $parent[$a] }
            $b = $j
            while ($parent[$b] -ne $b) { $b = $parent[$b] }
            if ($a -ne $b) { $parent[$b] = $a; $merged++ }
        }
    }
    if ($merged -eq 0) { return ,$Clusters }

    $byRoot = @{}
    for ($i = 0; $i -lt $count; $i++) {
        $r = $i
        while ($parent[$r] -ne $r) { $r = $parent[$r] }
        if (-not $byRoot.ContainsKey($r)) { $byRoot[$r] = New-Object System.Collections.ArrayList }
        foreach ($t in $Clusters[$i]) { [void]$byRoot[$r].Add($t) }
    }
    # The leading comma is load-bearing. Without it the merged groups unroll on
    # the way out and the caller receives the member torrents as if each were a
    # group of its own, which looks exactly like the merge having done nothing.
    return , @($byRoot.Values)
}

function Merge-SeriesClusters {
    <#
        The entry point for the series merge: run the merge, then label.

        Split in two so that the display-only labelling cannot be skipped. The
        merge pass has three return paths - fewer than two clusters, no families,
        and nothing merged - and the labelling belongs on all of them. Deciding
        that inside one function means adding a fourth return path later cannot
        quietly drop the labels, which is exactly the kind of forgetting that
        makes a panel disagree with the rules it previews.
    #>
    param($Clusters)

    $merged = Merge-SeriesClustersCore -Clusters $Clusters
    Set-FamilyLabels -Clusters $merged
    return , $merged
}

function Get-DoviHit {
    param([string]$Name)
    foreach ($p in $cfg.doviPatterns) {
        $m = [regex]::Match($Name, "(?i)$p")
        if ($m.Success) { return $m.Value }
    }
    return $null
}

function Find-BdmvDirectory {
    <#
        Looks for a BDMV directory, which is the unambiguous signature of a
        full Blu-ray disc rip. Searches the content folder and a couple of
        levels down, because the structure is sometimes
        <root>\<movie>\BDMV rather than <root>\BDMV.
    #>
    param(
        [string]$Path,
        [int]$Depth = 2
    )

    if (-not $Path) { return $null }
    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) { return $null }

    $dirs = @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue)

    foreach ($d in $dirs) {
        if ($d.Name -ieq 'BDMV') { return $d.FullName }
    }

    if ($Depth -gt 1) {
        foreach ($d in $dirs) {
            $hit = Find-BdmvDirectory -Path $d.FullName -Depth ($Depth - 1)
            if ($hit) { return $hit }
        }
    }

    return $null
}

function Get-DiscRipHit {
    <#
        Decides whether a torrent is a full Blu-ray disc structure.

        The BDMV check on disk is conclusive and takes priority. The name
        patterns exist for the common case where a disc rip is still
        downloading and its structure has not been extracted yet.

        Note that "Blu-ray" on its own does NOT count: most transcodes and
        REMUXes are sourced from a Blu-ray but ship as a single .mkv and are
        deliberately kept.
    #>
    param([object]$T)

    $bdmv = Find-BdmvDirectory -Path $T.content_path -Depth ([int]$cfg.bdmvSearchDepth)
    if ($bdmv) { return "BDMV directory '$bdmv'" }

    foreach ($p in $cfg.discRipPatterns) {
        $m = [regex]::Match($T.name, "(?i)$p")
        if ($m.Success) { return "disc-rip tag '$($m.Value)'" }
    }

    return $null
}

function Test-AlreadyGone {
    param([object]$T)
    return $script:gone.ContainsKey($T.hash)
}

function Get-StalledWatch {
    <#
        Rule 2b: an unfinished torrent that is not gaining any data.

        "Not able to download more" is measured as "completed has not gone up",
        which is the honest definition. qBittorrent's own `state` field is not
        used for this, because `stalledDL` only means "no peers right now" and
        flips back the moment a tracker reannounces or a leecher reconnects. A
        swarm that is genuinely dead reports `stalledDL` forever; one that is
        merely between peers does not, and neither should be deleted.

        State lives in a table on $Stalled, keyed by hash, holding the moment we
        last saw bytes arrive and the value at that moment. It is updated in
        place so the caller can persist it. Callers that must not write anything
        (status.ps1) pass a throwaway copy - this function touches neither disk
        nor the API.

        First sighting has no history to compare against, so the clock is seeded
        from qBittorrent's `last_activity`: the last moment the client saw
        anything happen at all. That is what makes a torrent that died before
        the manager was ever installed catchable on the first run rather than
        after a full week of watching.

        Two groups are deliberately excluded:

        - paused and stopped torrents. A torrent the user parked by hand is not
          "unable to download"; deleting it would quietly undo their decision,
          and a paused queue fills up precisely when someone is reorganising.
        - magnets with no metadata. Rule 2 owns those, and it removes them on
          evidence - a magnet that reports no size after the timeout - rather than
          on a date. Letting rule 2b near them would delete every magnet in the
          client on day seven whatever their state, which is a different and much
          blunter instrument.

        Transient states (allocating, checking, moving) are skipped because the
        torrent is busy rather than stuck, and a recheck can legitimately take a
        while on a large set on a slow disk.
    #>
    param(
        [object[]]$Torrents,
        [object]$Stalled,
        [datetime]$Now
    )

    $out = New-Object System.Collections.ArrayList

    $deadline = 0.0
    if ($cfg.PSObject.Properties['stalledDeleteDays']) { $deadline = [double]$cfg.stalledDeleteDays }
    if ($deadline -le 0) { return $out }

    $skip = @('metaDL', 'allocating', 'moving', 'checkingDL', 'checkingUP', 'checkingResumeData', 'unknown')
    $seen = @{}

    foreach ($t in $Torrents) {
        if ($null -eq $t) { continue }
        if ($t.progress -ge 1) { continue }
        if ($t.amount_left -le 0) { continue }
        if ($skip -contains $t.state) { continue }
        if ($t.state -like 'paused*' -or $t.state -like 'stopped*') { continue }

        $bytes = [int64]$t.completed
        $prop  = $Stalled.PSObject.Properties[$t.hash]

        if ($null -eq $prop) {
            # The seed is max(last_activity, added_on), capped at now:
            #   - nothing can have happened before the torrent was added, so an
            #     older last_activity is meaningless rather than very stale,
            #   - and a clock skewed into the future must not age a torrent
            #     beyond its true age and get it deleted on first sight.
            $last = $Now
            if ($t.added_on) {
                try {
                    $added = [DateTimeOffset]::FromUnixTimeSeconds([int64]$t.added_on).LocalDateTime
                    if ($added -lt $last) { $last = $added }
                } catch { }
            }
            if ($t.last_activity) {
                try {
                    $cand = [DateTimeOffset]::FromUnixTimeSeconds([int64]$t.last_activity).LocalDateTime
                    if ($cand -gt $last) { $last = $cand }
                } catch { }
            }
            if ($last -gt $Now) { $last = $Now }
            $seenBytes = $bytes
        }
        else {
            $last      = [datetime]::Parse($prop.Value.lastProgressAt)
            $seenBytes = [int64]$prop.Value.bytes
            if ($bytes -gt $seenBytes) { $last = $Now; $seenBytes = $bytes }
        }

        $Stalled | Add-Member -NotePropertyName $t.hash -NotePropertyValue ([pscustomobject]@{
            lastProgressAt = $last.ToString('o')
            bytes          = $seenBytes
        }) -Force
        $seen[$t.hash] = $true

        $idle = ($Now - $last).TotalDays
        [void]$out.Add([pscustomobject]@{
            Torrent   = $t
            Name      = $t.name
            State     = $t.state
            Completed = [int64]$t.completed
            Total     = [int64]$t.total_size
            IdleDays  = $idle
            Remaining = [Math]::Max(0, $deadline - $idle)
            WillDelete = ($idle -ge $deadline)
        })
    }

    # Forget anything that completed or left, so the table cannot grow without
    # bound over months of runs.
    foreach ($p in @($Stalled.PSObject.Properties)) {
        if (-not $seen.ContainsKey($p.Name)) { $Stalled.PSObject.Properties.Remove($p.Name) }
    }

    return $out
}

# ---------------------------------------------------------------------------
# rule 2, isolated so it can be tested against synthetic torrents and time
# travel instead of against whatever happens to be queued this afternoon
# ---------------------------------------------------------------------------

function Get-NoAvailabilityVerdict {
    <#
        Rule 2: a magnet that cannot report a size is deleted once it has been
        really trying for longer than the timeout.

        "Really trying" has a precise meaning on this client, because
        qBittorrent does not work on every torrent at once. Measured here:
        QueueingSystemEnabled=true, and `priority` is the queue position - one
        integer per torrent, measured 0 to 229 across 235 torrents. It is not a
        0..7 "how much do I want this" tier, and treating it as one is what
        caused this rule to be loosened to the point where it deleted 205
        torrents that had never been handed a single peer connection.

        A magnet sitting at position 150 is waiting its turn. It has not tried
        anything. Deleting it for being unavailable is deleting it for not having
        been started yet. So two conditions apply and both are load-bearing:

          1. The magnet must be inside the window, 1 <= priority <= QueueLimit.
             Priority 0 is excluded on purpose. Measured, priority 0 is every
             finished torrent in the client (stalledUP / stoppedUP): it means
             "out of the queue", not "at the top of it", so treating it as
             position 1 would hand the whole window to torrents that are already
             done. A magnet qBittorrent has dropped out of the queue is left
             alone by this rule - rule 2b and the orphan reaper are the
             instruments for a stalled client, not this one.

          2. The clock runs only while the magnet is inside the window. It is
             kept as `windowSince` in $Hashes, and a magnet found outside the
             window has that entry removed. That is the whole difference between
             "has been trying for an hour" and "has existed for an hour": a
             magnet promoted from position 150 gets a full tolerance from the
             moment it reaches the front, instead of being deleted on the spot
             for a queue it had not yet served.

        Entries written before this rule carry `since` and no `windowSince`. A
        missing `windowSince` seeds a fresh full tolerance, so the migration can
        only ever be more patient than the old behaviour, never less.

        $Hashes is updated in place so the caller can persist it. Callers that
        must write nothing pass a throwaway object; this function touches
        neither disk nor the API.

        The result is one row per metadata-less torrent in queue order, each
        carrying the verdict. Nothing here deletes anything.
    #>
    param(
        [object[]]$Torrents,
        [object]$Hashes,
        [datetime]$Now,
        [double]$TimeoutMinutes,
        [int]$QueueLimit,
        [hashtable]$Skip = @{}
    )

    $out = New-Object System.Collections.ArrayList

    # Ascending. This orders the rows only; the verdict is carried by the two
    # conditions below, never by the row's place in this list.
    $rows = @($Torrents | Sort-Object -Property @{Expression = { $_.priority }; Ascending = $true},
                                                @{Expression = { $_.added_on };  Ascending = $true})

    for ($i = 0; $i -lt $rows.Count; $i++) {
        $t = $rows[$i]
        if ($null -eq $t) { continue }
        if ($Skip.ContainsKey($t.hash)) { continue }

        # TRYING, not merely WAITING - the same line the drain uses.
        #
        # 'size 0' on its own admitted a magnet sitting in line that qBittorrent
        # had never given a slot to, so it entered the table and its clock started
        # on arrival. Being at the front of the queue is not the same as having been
        # served: rule 2's own premise is that a magnet at position 150 has never
        # been handed a peer connection, and that reasoning holds at position 5 too.
        #
        # Dropping a queuedDL entry here also clears any windowSince it carried, so
        # it cannot carry a clock it was never served into the window's turn.
        $noMeta = ($t.state -eq 'metaDL')

        # A torrent that resolved has no clock to keep. Dropping the entry here
        # is what stops the table growing without bound.
        if (-not $noMeta) {
            if ($Hashes.PSObject.Properties.Name -contains $t.hash) {
                $Hashes.PSObject.Properties.Remove($t.hash)
            }
            continue
        }

        $pos = [int]$t.priority
        $inWindow = (($QueueLimit -gt 0) -and ($pos -ge 1) -and ($pos -le $QueueLimit))

        $windowSince = $null
        if ($Hashes.PSObject.Properties.Name -contains $t.hash) {
            $raw = $Hashes.PSObject.Properties[$t.hash].Value.windowSince
            if ($raw) {
                try { $windowSince = [datetime]::Parse([string]$raw) } catch { $windowSince = $null }
            }
        }

        $mins = $null

        if (-not $inWindow) {
            # Out of the window: no clock and no verdict, and any clock it had is
            # cleared so its next turn at the front starts from scratch.
            if ($Hashes.PSObject.Properties.Name -contains $t.hash) {
                $Hashes.PSObject.Properties.Remove($t.hash)
            }
        }
        else {
            if ($null -eq $windowSince) { $windowSince = $Now }
            $Hashes | Add-Member -NotePropertyName $t.hash -NotePropertyValue ([pscustomobject]@{
                windowSince = $windowSince.ToString('o')
            }) -Force
            $mins = ($Now - $windowSince).TotalMinutes
            if ($mins -lt 0) { $mins = 0 }
        }

        $seeds  = [int]$t.num_seeds
        $leechs = [int]$t.num_leechs
        $delete = ($inWindow -and ($null -ne $mins) -and ($mins -ge $TimeoutMinutes))

        $reason = ''
        if ($delete) {
            # The reason names the availability, because that is what the rule is
            # about, and the queue position it was judged at. A magnet with no
            # metadata cannot have seeds; if it does, the magnet resolved and
            # size is lying to us, which is worth seeing in the log.
            $reason = ("no availability: queue position {0} for {1:N0} min (tolerance {2:N0}m), no size, {3} seeds {4} peers" -f `
                       $pos, $mins, $TimeoutMinutes, $seeds, $leechs)
        }

        [void]$out.Add([pscustomobject]@{
            Torrent    = $t
            Name       = $t.name
            Rank       = ($i + 1)
            QueuePos   = $pos
            InWindow   = $inWindow
            QueueLimit = $QueueLimit
            Minutes    = $mins
            WillDelete = $delete
            Seeds      = $seeds
            Leechs     = $leechs
            Reason     = $reason
        })
    }

    return $out
}

# ---------------------------------------------------------------------------
# rule 2c: the drain - one magnet an hour, behind the window
# ---------------------------------------------------------------------------

# Is this torrent being downloaded right now? Used as the drain's liveness
# witness, so the bar is deliberately high: the client has to be actively
# working on it, not merely holding it.
#
# An ALLOWLIST of the states that mean "this torrent is being downloaded", not a
# denylist of the ones that do not. That direction is load-bearing. A denylist
# has to enumerate every state the client can be in that is not a download, and
# it will eventually meet one nobody thought of - and the default there is the
# dangerous answer. Measured against qBittorrent 5.2.4's full state set, the
# denylist version passed uploading, stalledUP, error and unknown as witnesses: a
# torrent that is seeding, broken, or in a state this script has never seen would
# have authorised deleting a magnet. With an allowlist, anything unrecognised is
# simply not a witness, and the worst case is that the drain holds a torrent for
# another hour.
#
#   included  downloading, forcedDL, stalledDL, allocating, metaDL, forcedMetaDL
#   excluded  paused*, stopped*, queued*  - the user's decisions, or a torrent
#             that has not been given a slot, so neither says anything about
#             whether the client is alive
#             uploading, stalledUP, queuedUP, forcedUP - seeding, not downloading
#             error, missingFiles, checkingDL, checkingUP, moving,
#             checkingResumeData - transitional or broken, none is proof of life
#
# The size and progress guards are kept as defence in depth, so a state that
# slipped into the allowlist by mistake still cannot witness with no data.
# Is the internet actually working? The stall rule below deletes magnets BECAUSE
# nothing is downloading, so it has to be able to tell "the client is stuck" from
# "the network is down". Without this check a dropped home connection would look
# exactly like a dead client, and the rule would delete a queue that was merely
# waiting for the router to come back.
#
# Deliberately independent of qBittorrent. Asking the client whether it has
# network access is circular - the client is the thing being doubted. So this
# asks something the client does not control.
#
# NO -f, and NO -I. Both looked reasonable and both were wrong, measured here:
#
#   -f  fails on an HTTP error status, exiting 22. The configured URL answers 404
#       to HEAD (it is a trace endpoint, not a page) - so -f reported the internet
#       as unreachable when it was perfectly fine, and the rule would have been
#       permanently dead.
#   -I  is what produced that 404 in the first place. This endpoint wants GET.
#
# So: a plain GET, discarding the body with -o NUL. Exit 0 means a response came
# back; anything else means none did. The status code is deliberately NOT checked
# - 404, 403 and 405 all still prove the network works, which is the only question
# being asked. What is transferred is one small response into the null device.
#
# FAIL-CLOSED BY DESIGN. A DNS failure, a refused connection or a timeout all
# return $false, and $false means "do not delete". Being unable to prove the
# internet works is never treated as permission to delete.
function Test-InternetReachable {
    param(
        [string]$Url = 'https://www.cloudflare.com/cdn-cgi/trace',
        [int]$TimeoutSeconds = 8
    )

    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # No -f, no -I. See the note above for why both were measured to be wrong.
        $null = & curl.exe -s -o NUL `
                    --connect-timeout $TimeoutSeconds --max-time $TimeoutSeconds `
                    $Url 2>&1
        return ($LASTEXITCODE -eq 0)
    }
    catch { return $false }
    finally { $ErrorActionPreference = $prev }
}

# Is the whole client stalled - global download velocity at zero while the
# internet is demonstrably fine?
#
# TWO THINGS MUST HOLD, and the second is the reason this is a separate rule
# rather than a shorter timeout on rule 2:
#
#   1. qBittorrent's own aggregate download rate is zero, read from
#      /transfer/info. Not a sum over torrents, and not a per-torrent dlspeed:
#      dl_info_speed is the client's own figure for what it is pulling, which is
#      the thing that has gone quiet. A per-torrent check would miss the case
#      where several torrents are each trickling below the threshold and the
#      link as a whole is fine.
#
#   2. The internet is up, proven by Test-InternetReachable. This is what stops
#      the rule from firing when the user's connection is down.
#
# $MinSeconds is the "more than 1 minute" requirement. It is enforced by the
# caller, which samples the rate more than once across the run - see
# Get-StallVerdict, where the clock lives. A single sample cannot tell a stall
# from a momentary lull between chunks.
function Get-DownloadRate {
    $r = $null
    try { $r = @(Invoke-ApiGet -Endpoint 'transfer/info')[0] } catch { $r = $null }
    if ($null -eq $r) { return $null }

    $speed = 0
    if ($r.PSObject.Properties['dl_info_speed']) { $speed = [int64]$r.dl_info_speed }

    $status = ''
    if ($r.PSObject.Properties['connection_status']) { $status = [string]$r.connection_status }

    # A client that reports itself disconnected is not downloading because it
    # cannot, whatever dl_info_speed says. Treated as stalled-but-unproven: the
    # internet check decides.
    return [pscustomobject]@{
        Speed       = $speed
        Connection  = $status
        DlRateLimit = $(if ($r.PSObject.Properties['dl_rate_limit']) { [int64]$r.dl_rate_limit } else { 0 })
    }
}

function Get-StallVerdict {
    <#
        Rule 2d: a client that is downloading NOTHING while the internet works is
        stuck, and the magnets at the front of its queue are what it is stuck on.
        They go immediately, without waiting out rule 2's tolerance.

        Measured live, the case that prompted it: 206 torrents, 195 of them
        magnets, dl_info_speed 0, up_info_speed 1,4 MB/s - the client was
        perfectly capable of traffic and was pulling nothing down. Positions 4
        through 20 were all metaDL with dlspeed 0. There was nothing to wait for:
        every one of them was unavailable and the client had already said so with
        its own aggregate figure.

        WHY THIS IS NOT JUST A SHORTER TIMEOUT ON RULE 2. Rule 2 asks "has this
        magnet been trying a long time". That question is unanswerable when the
        whole client is idle, because there is no evidence of trying - only
        evidence of waiting. This rule asks a different and stronger question:
        "is anything at all happening". When the answer is no, and the internet is
        verifiably up, the queue is not slow, it is stalled, and patience buys
        nothing.

        THREE CONDITIONS, ALL LOAD-BEARING:

          1. Global download rate is zero - dl_info_speed from /transfer/info, the
             client's own aggregate figure.

          2. The rate has been zero for LONGER THAN $ConfirmSeconds. One sample
             cannot tell a stall from a lull between chunks, so this is proven
             over time rather than assumed from a single reading. The clock is
             persisted in $Stall, so a stall noticed at the end of one run and
             still present at the start of the next is already past the threshold
             and is acted on immediately.

             When the threshold has not yet been reached, this function WAITS OUT
             the remainder and re-samples, bounded by $MaxWaitSeconds, so the
             deletion happens in the run that noticed the stall rather than the
             one after it. That wait is the whole "more than 1 minute" requirement
             and it is paid only when the rate is genuinely zero.

          3. The internet is up, by Test-InternetReachable, which does not involve
             qBittorrent at all. Without it, a dropped home connection produces
             exactly this picture and the queue would be deleted for the network
             being down. FAIL-CLOSED: an inconclusive check counts as "internet
             not proven up" and blocks the deletion.

        WHAT IT DELETES: up to $MaxDeletions magnets from the queue window,
        in queue order, oldest first. Same window as rule 2 (1..$QueueLimit) -
        these are the torrents the client is supposed to be working on right now.
        Priority 0 is excluded, as everywhere else.

        WHAT IT WILL NOT DO:

          - It does not touch resolved torrents. Only size == 0 or metaDL.
          - It does not delete past the window. That is the drain's job, one per
            run, with its own witness.
          - It does not delete anything when the rate is non-zero, however dead
            the individual magnets look. One working download means the client is
            working, and rule 2's clock is the right instrument for the rest.

        $Stall is updated in place so the caller can persist it. Nothing here
        deletes anything.
    #>
    param(
        [object[]]$Torrents,
        [datetime]$Now,
        [double]$ConfirmSeconds,
        [int]$MaxWaitSeconds,
        [int]$QueueLimit,
        [int]$MaxDeletions,
        [object]$Stall,
        [hashtable]$Skip = @{},
        [scriptblock]$RateReader,
        [scriptblock]$InternetProbe
    )

    $out = New-Object System.Collections.ArrayList

    # Rate sampled twice, with the difference between them as the proof.
    $first = & $RateReader
    if ($null -eq $first) {
        return @([pscustomobject]@{ Action = 'unknown'; Reason = 'the client did not report a transfer rate'; Torrents = @() })
    }

    if ($first.Speed -gt 0) {
        # Working. Forget any stall clock so the next one starts clean.
        $Stall.since = $null
        return @()
    }

    # --- is it a rate limit rather than a stall? --------------------------------
    # A global download limit of 0 is the OFF setting, not a limit. Anything above
    # zero means the user capped the client, and a capped client pulling nothing
    # is obeying the cap, not stuck. Deleting its queue would be deleting the
    # user's own configuration back at them.
    if ($first.DlRateLimit -gt 0) {
        $Stall.since = $null
        return @([pscustomobject]@{
            Action = 'hold'
            Reason = ("global download velocity is 0, but a download rate limit of {0} bytes/s is set - the client is obeying it, not stuck" -f $first.DlRateLimit)
            Torrents = @()
        })
    }

    # --- how long has it been zero? ---------------------------------------------
    $since = $null
    if ($Stall.since) { try { $since = [datetime]::Parse([string]$Stall.since) } catch { $since = $null } }
    if ($null -eq $since) { $since = $Now }

    $waited = 0.0
    $rate = $first
    $elapsed = ($Now - $since).TotalSeconds
    if ($elapsed -lt 0) { $elapsed = 0 }

    if ($elapsed -lt $ConfirmSeconds -and $MaxWaitSeconds -gt 0) {
        # Not proven yet. Wait out the remainder, but never past the ceiling - a
        # run that blocked for minutes would overlap the next scheduled one.
        $need = $ConfirmSeconds - $elapsed
        if ($need -gt $MaxWaitSeconds) { $need = $MaxWaitSeconds }
        if ($need -gt 0) {
            Start-Sleep -Milliseconds ([int]($need * 1000))
            $waited = $need
        }
        $rate = & $RateReader
    }

    if ($null -eq $rate -or $rate.Speed -gt 0) {
        # It started moving while we watched, or the reading failed. Either way
        # there is no stall to act on.
        $Stall.since = $null
        return @()
    }

    $total = $elapsed + $waited
    if ($total -lt $ConfirmSeconds) {
        # Still zero, but not yet for long enough, and the ceiling stopped us.
        # The clock is kept so the next run resumes from here rather than
        # restarting.
        $Stall.since = $since.ToString('o')
        return @([pscustomobject]@{
            Action = 'hold'
            Reason = ("global download velocity has been 0 for {0:N0}s, under the {1:N0}s threshold - watching" -f $total, $ConfirmSeconds)
            Torrents = @()
        })
    }

    # --- proven. Is the internet actually up? ------------------------------------
    $up = $false
    try { $up = [bool](& $InternetProbe) } catch { $up = $false }
    if (-not $up) {
        $Stall.since = $null
        return @([pscustomobject]@{
            Action = 'hold'
            Reason  = ("global download velocity has been 0 for {0:N0}s, but the internet could not be reached - this looks like the network, not the client, so nothing is deleted" -f $total)
            Torrents = @()
            Connection = $rate.Connection
        })
    }

    # --- collect what to remove -------------------------------------------------
    # Same window as rule 2, same exclusion of priority 0, and up to $MaxDeletions
    # of them in queue order. A cap is not optional here: this rule can fire on a
    # queue of 195 magnets, and an uncapped sweep would empty it.
    $ordered = @($Torrents | Sort-Object -Property @{Expression = { $_.priority }; Ascending = $true},
                                                   @{Expression = { $_.added_on };  Ascending = $true})
    $picked = New-Object System.Collections.ArrayList
    foreach ($t in $ordered) {
        if ($null -eq $t) { continue }
        if ($Skip.ContainsKey($t.hash)) { continue }
        $pos = [int]$t.priority
        if ($pos -lt 1) { continue }
        if ($QueueLimit -gt 0 -and $pos -gt $QueueLimit) { continue }
        $noSize = ($t.state -eq 'metaDL')
        if (-not $noSize) { continue }
        [void]$picked.Add($t)
        if ($picked.Count -ge $MaxDeletions) { break }
    }

    if ($picked.Count -eq 0) {
        $Stall.since = $null
        return @([pscustomobject]@{
            Action = 'hold'
            Reason = ("global download velocity has been 0 for {0:N0}s and the internet is up, but there is no unavailable magnet in queue positions 1-{1} to remove" -f $total, $QueueLimit)
            Torrents = @()
        })
    }

    $Stall.since = $null
    return @([pscustomobject]@{
        Action    = 'delete'
        Seconds   = $total
        Torrents  = @($picked)
        Reason    = ("global download velocity has been 0 for {0:N0}s with the internet reachable and nothing downloading anywhere: the client is stalled, not slow, and {1} magnet(s) in queue positions 1-{2} are what it is stalled on" -f `
                     $total, $picked.Count, $QueueLimit)
    })
}

function Test-ActivelyDownloading {
    param([object]$T)
    if ($null -eq $T) { return $false }
    if ([double]$T.size -le 0) { return $false }      # still a magnet
    if ([double]$T.progress -ge 1) { return $false }  # already finished

    $s = [string]$T.state
    if (-not $s) { return $false }
    switch ($s) {
        'downloading'    { return $true }
        'forcedDL'       { return $true }
        'stalledDL'      { return $true }
        'allocating'     { return $true }
        'metaDL'         { return $true }
        'forcedMetaDL'   { return $true }
        default          { return $false }
    }
}

function Get-QueueDrainVerdict {
    <#
        Rule 2c: one magnet an hour, from the back of the queue.

        The window in rule 2 is a fixed slab of the queue - positions 1..10 -
        and it judges every magnet in it at once. Behind that slab sits the rest
        of the queue, which rule 2 deliberately never touches: a magnet at
        position 150 has not tried anything. That is right while the queue is
        healthy, but it also means a magnet at position 11 that has been dead
        for a week is never cleaned up, because nothing ever promotes it into
        the window.

        This rule is the missing half. It takes the single first magnet behind
        the window, gives it its own full tolerance, and deletes it - but only
        when something proves the client is still working:

            1. Candidate. The first magnet ACTIVELY FETCHING METADATA at a position
               greater than the window limit, in ascending position order. Exactly
               one candidate per run, so the rate is bounded by the tolerance no
               matter how long the queue is. Priority 0 is excluded for the same
               reason rule 2 excludes it: it means "out of the queue".
               
               "Actively fetching" is the whole condition, and it is what keeps this
               rule off magnets that have not had their turn. A queuedDL magnet with
               no size has not been STARTED - qBittorrent has not given it a slot -
               so counting minutes against it counts the queue, not its failure.

          2. Its own clock, starting when it first becomes the candidate. A new
             candidate always starts from zero, so a magnet promoted from
             position 300 cannot be deleted on arrival for a queue it never
             served. Only one clock exists at a time and it is replaced whenever
             the candidate changes, so this cannot grow without bound.

          3. A witness. The deletion happens only if some torrent FURTHER DOWN
             the queue - a higher position number, strictly - is actively
             downloading. This is the part that makes the rule safe, and it is
             not decoration:

               - A magnet past the window is unavailable in two very different
                 situations: the torrent is dead, or the client is not getting
                 anywhere. Only the first is this rule's business.
               - A dead client makes every magnet look unavailable at once, all
                 the way down the queue. Without the witness this rule would
                 respond to a broken client by deleting the entire queue in
                 hourly instalments.
               - Requiring the witness to be FURTHER DOWN, not anywhere, is what
                 makes it a proof rather than a coincidence. An unrelated
                 download inside the window would be true just as often on a
                 stalled client as on a healthy one. Something past the dead
                 magnet means the client reached beyond it and found life.

             When there is no witness the clock is deliberately left running.
             The 60 minutes measure how long the candidate has been dead, not
             how long it has waited for a witness; when a witness appears the
             time already served counts.

        $Drain is updated in place so the caller can persist it. Nothing here
        deletes, and this function touches neither disk nor the API.
    #>
    param(
        [object[]]$Torrents,
        [datetime]$Now,
        [double]$TimeoutMinutes,
        [int]$QueueLimit,
        [object]$Drain,
        [hashtable]$Skip = @{}
    )

    # The drain is defined relative to the window, so with no window there is no
    # boundary to drain from.
    if ($QueueLimit -le 0) { return @() }

    $all = @($Torrents)

    # Ascending by position: the candidate is by definition the front of what
    # the window has not reached. added_on only breaks ties so the choice is
    # stable between runs - two torrents cannot share a position, but a synthetic
    # test can, and a rule that picks differently each run cannot be tested.
    $ordered = @($all | Sort-Object -Property @{Expression = { $_.priority }; Ascending = $true},
                                               @{Expression = { $_.added_on };  Ascending = $true})

    $candidate = $null
    $candPos = 0
    foreach ($t in $ordered) {
        if ($null -eq $t) { continue }
        if ($Skip.ContainsKey($t.hash)) { continue }
        $pos = [int]$t.priority
        if ($pos -lt 1) { continue }                 # out of the queue, not the front
        if ($pos -le $QueueLimit) { continue }      # the window's business, not this rule's
        # TRYING, not merely WAITING.
        #
        # The candidate test used to accept any torrent reporting size 0, which
        # includes one sitting in line with qBittorrent having never given it a
        # slot. Measured on a live queue:
        #
        #   pos 11-20   size 8.9 GB, 8.7 GB ...   served: working or stalled
        #   pos 21      size 0, state queuedDL     never had a turn
        #   pos 22-30   size 0, state queuedDL     never had a turn
        #
        # So the first magnet behind the window was position 21 and its clock started
        # on arrival. Thirty minutes later it would have been deleted for failing to
        # fetch metadata - having never been asked to fetch any.
        #
        # Rule 2 already draws this line, for the same reason: "a magnet at position
        # 150 has never been handed a peer connection, so it has not tried anything,
        # and deleting it for being unavailable is really deleting it for not having
        # been started yet." The drain inherited the mistake, and this fixes it.
        #
        # metaDL is the state meaning "fetching metadata right now". A magnet queued
        # behind the window is queuedDL, and one whose metadata resolved has a size.
        # So it is the only state in which "no size" means "trying and failing"
        # rather than "not started yet".
        if ($t.state -ne 'metaDL') { continue }
        $candidate = $t
        $candPos = $pos
        break
    }

    if ($null -eq $candidate) {
        # Nothing behind the window is dead. Forget the clock so a torrent that
        # returns to this position starts from a full tolerance rather than
        # inheriting time served by a different torrent.
        $Drain.hash = $null
        $Drain.since = $null
        return @()
    }

    # A different candidate is a new decision, so it gets a new clock. The
    # existing clock is deliberately not carried across.
    if ([string]$Drain.hash -ne [string]$candidate.hash) {
        $Drain.hash = $candidate.hash
        $Drain.since = $Now.ToString('o')
    }

    $since = $null
    if ($Drain.since) {
        try { $since = [datetime]::Parse([string]$Drain.since) } catch { $since = $null }
    }
    if ($null -eq $since) { $since = $Now }
    $Drain.since = $since.ToString('o')

    $mins = ($Now - $since).TotalMinutes
    if ($mins -lt 0) { $mins = 0 }

    # The witness must be strictly further down than the candidate. Equal
    # positions cannot happen on a real queue, and treating "not before" as
    # "after" would let the candidate witness itself.
    $witness = $null
    foreach ($t in $ordered) {
        if ($null -eq $t) { continue }
        if ($Skip.ContainsKey($t.hash)) { continue }
        if ([string]$t.hash -eq [string]$candidate.hash) { continue }
        $pos = [int]$t.priority
        if ($pos -le $candPos) { continue }
        if (Test-ActivelyDownloading $t) { $witness = $t; break }
    }

    $timedOut = ($mins -ge $TimeoutMinutes)
    $delete = ($timedOut -and ($null -ne $witness))

    $seeds  = [int]$candidate.num_seeds
    $leechs = [int]$candidate.num_leechs

    $reason = ''
    if ($delete) {
        $reason = ("no availability: {0:N0} min at queue position {1} (tolerance {2:N0}m), no size, {3} seeds {4} peers; " +
                   "torrent at position {5} is downloading, so the client is working past it" -f `
                   $mins, $candPos, $TimeoutMinutes, $seeds, $leechs, [int]$witness.priority)
    }
    elseif ($timedOut) {
        # Out of tolerance but unproven. The clock keeps running, so this is a
        # report, not a decision.
        $reason = ("no availability: {0:N0} min at queue position {1} (tolerance {2:N0}m) - held, nothing further down " +
                   "the queue is downloading, so the client may be the problem rather than the torrent" -f `
                   $mins, $candPos, $TimeoutMinutes)
    }

    return @([pscustomobject]@{
        Torrent    = $candidate
        Name       = $candidate.name
        Hash       = [string]$candidate.hash
        QueuePos   = $candPos
        Minutes    = $mins
        TimedOut   = $timedOut
        HasWitness = ($null -ne $witness)
        Witness    = if ($null -ne $witness) { [string]$witness.name } else { '' }
        WitnessPos = if ($null -ne $witness) { [int]$witness.priority } else { 0 }
        WillDelete = $delete
        Seeds      = $seeds
        Leechs     = $leechs
        Reason     = $reason
    })
}
# ---------------------------------------------------------------------------
# orphan reaper: download leftovers that no torrent claims any more
# ---------------------------------------------------------------------------

# A torrent that has actually downloaded bytes must say where they are. If one
# does not, this pass cannot tell an orphan from a download in progress, so it
# declines to run for that pass. Leaking a folder for a day is recoverable;
# deleting a download in progress is not.
#
# The test is deliberately about bytes, not about state: a magnet stuck in
# metaDL holds no data and its empty content_path proves nothing, so it is not
# counted here. Only a torrent with real progress on disk is a risk.
function Test-Unlocatable {
    param([object[]]$Torrents)
    return @($Torrents | Where-Object {
        $_.completed -gt 0 -and [string]::IsNullOrWhiteSpace($_.content_path)
    })
}

# What counts as "still in use" is deliberately narrow, and save_path is NOT
# part of it. Torrents share one save_path, so treating save_path as a claim
# would mark every file in the staging directory as in use and the reaper could
# never fire - measured on the machine this was written on, the majority of
# torrents shared one staging path as their save_path. content_path is the only
# per-torrent statement about where its own bytes live.
#
# Both sides are compared as strings taken from the same UTF-8 API read, so the
# decision never depends on Test-Path resolving a non-ASCII name correctly.
function Test-Claimed {
    param(
        [string]$Path,
        [object[]]$Torrents
    )
    $n = $Path.TrimEnd('\', '/')
    foreach ($t in $Torrents) {
        if ([string]::IsNullOrWhiteSpace($t.content_path)) { continue }
        $c = $t.content_path.TrimEnd('\', '/')
        if ($c.Equals($n, [StringComparison]::OrdinalIgnoreCase))  { return $t }
        # a multi-file torrent's content_path is the file, and sits inside the
        # folder we are judging
        if ($c.StartsWith($n + '\', [StringComparison]::OrdinalIgnoreCase)) { return $t }
        # or the torrent's content_path is a folder that contains the entry
        if ($n.StartsWith($c + '\', [StringComparison]::OrdinalIgnoreCase)) { return $t }
    }
    return $null
}
# Has this torrent's data actually arrived under the library folder? The one
# question the library rule is allowed to believe. A 200 from setLocation says
# the move was QUEUED, not that it happened: on this box setLocation answered
# 200 for a torrent whose files never left temp, while qBittorrent's own log
# said 'storage move failed ... Permission denied'. Asking the API afterwards
# is the only way to tell those two apart, because /torrents/info does not
# expose move_status.
#
# content_path is what is asked, never save_path: the folder a torrent's own
# bytes live in is a per-torrent statement, while save_path is shared by
# everything and would make this answer yes for torrents still in temp.
function Test-MoveSettled {
    param(
        [object]$T,
        [string]$TargetDir
    )

    if (-not $T) { return $false }
    $cp = [string]$T.content_path
    if ([string]::IsNullOrWhiteSpace($cp)) { return $false }

    $parent = if (Test-Path -LiteralPath $cp) { Split-Path -Parent $cp } else { [string]$T.save_path }
    if ([string]::IsNullOrWhiteSpace($parent)) { return $false }

    return ($parent.TrimEnd('\', '/') -ieq $TargetDir.TrimEnd('\', '/'))
}

# The size of ONE episode inside a finished pack, read from the pack's own file
# list rather than derived from its total.
#
# Dividing the pack total by its episode count is not a measurement. Episodes in
# one season pack differ in length, and a pack measured on this client holds
# S18E01 at 1,741,016,868 bytes, S18E03 at 1,812,402,004 and S18E04 at
# 1,479,590,942 - a spread of about 330 MB inside a single pack. A total divided
# by a count invents a number that corresponds to no episode at all, so it can
# make the wrong file look like the winner.
#
# The file is found by its own episode marker in the name, and the season is
# matched with leading zeros allowed so 'S18E01' and 'S04E08' both match. When
# several files match - a sample, or an extra - the largest is taken, because the
# episode itself is always the largest of them.
#
# $null means "not measured", and every caller skips the comparison on that. A
# missing file listing, a name that matches nothing, or an unknown size must
# never turn into a deletion.
# The episode-set key a torrent is judged under, correcting a name that claims a
# whole season when its own files say otherwise.
#
# Only a name-derived S<n>-ALL is corrected, and that limit is deliberate. It is
# the one key that makes a claim the name cannot support - a season pack asserts
# every episode of a season without saying how many there are - and it is the one
# that silently disables dedup, because no range key can equal it. A name that
# already states a range ('S03e01-08') is taken at its word, as it is everywhere
# else; correcting that too would mean listing the files of every series torrent
# in the queue on every run, for a case that does not arise.
#
# $null is never returned: an unknown key is the empty string, which every caller
# already reads as 'take no part'.
function Resolve-TorrentSetKey {
    param(
        [object]$T,
        [hashtable]$Cache
    )

    $nameKey = Get-EpisodeSetKey -Parts $T.parts
    if ($nameKey -notmatch '^S\d+-ALL$') { return $nameKey }
    if ([string]::IsNullOrWhiteSpace($T.hash)) { return $nameKey }

    $key = $T.hash.ToLowerInvariant()
    if ($null -eq $Cache) { $Cache = @{} }
    if (-not $Cache.ContainsKey($key)) {
        try { $Cache[$key] = @(Invoke-ApiGet -Endpoint "torrents/files?hash=$($T.hash)") }
        catch { $Cache[$key] = @() }
    }

    $fromFiles = Get-EpisodeSetFromFiles -Files @($Cache[$key])
    if (-not $fromFiles) { return $nameKey }
    return $fromFiles
}

function Get-PackEpisodeBytes {
    param(
        [string]$Hash,
        [int]$Season,
        [int]$Episode,
        [hashtable]$Cache
    )

    if ([string]::IsNullOrWhiteSpace($Hash)) { return $null }
    if ($null -eq $Season -or $null -eq $Episode) { return $null }

    $key = $Hash.ToLowerInvariant()
    if ($null -eq $Cache) { $Cache = @{} }
    if (-not $Cache.ContainsKey($key)) {
        try { $Cache[$key] = @(Invoke-ApiGet -Endpoint "torrents/files?hash=$Hash") }
        catch { $Cache[$key] = @() }
    }

    $files = @($Cache[$key])
    if ($files.Count -eq 0) { return $null }

    # $Season and $Episode are [int], so interpolating them cannot inject a
    # pattern; the only thing that varies is zero padding in the file name.
    $rx = '(?i)S0*' + $Season + 'E0*' + $Episode + '(?!\d)'

    $best = 0
    foreach ($f in $files) {
        $name = [string]$f.name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($name -notmatch $rx) { continue }
        $sz = [int64]$f.size
        if ($sz -gt $best) { $best = $sz }
    }

    if ($best -le 0) { return $null }
    return $best
}

function ConvertTo-LibraryFolderName {
    <#
        The name a show's library folder should carry: every word capitalised.

        'its always sunny in philadelphia'  ->  'Its Always Sunny In Philadelphia'

        EVERY word is capitalised, not just the significant ones, so 'in' becomes
        'In' and 'the' becomes 'The'. That was asked for explicitly, and it is also
        the simpler rule: an exceptions list for 'of', 'the', 'and' is a list that
        eventually gets one entry wrong.

        Only the FIRST LETTER of each word is touched. The rest is left exactly as
        it was, which matters in two ways:

        - accents survive. 'zátoka' becomes 'Zátoka' and not 'ZATOKA' or 'zátoka',
          because the conversion is culture-aware and only aims at the first
          character.
        - anything already carrying capitals keeps them. The parser lowercases
          titles, so in practice there is nothing to preserve - but a title that
          reached here with 'TV' or 'iPhone' in it is not mangled on the way to
          the filesystem.

        A hyphen starts a new capital: 'vdovina-zátoka' -> 'Vdovina-Zátoka'. A
        trailing dot is left attached, so 'mr.' becomes 'Mr.' and not 'Mr'.

        Note what this cannot do: the parser drops apostrophes from titles on
        purpose, for matching, so 'It's Always Sunny' reaches this function as
        'its always sunny' and the folder is 'Its Always Sunny In Philadelphia'.
        Putting the apostrophe back is not derivable from the title - it is what
        titleAliases is for.
    #>
    param([string]$Title)

    if ([string]::IsNullOrWhiteSpace($Title)) { return $Title }

    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    $pieces = @($Title -split '(\s+)')
    $out = New-Object System.Collections.ArrayList

    foreach ($word in $pieces) {
        # whitespace and punctuation-only tokens pass through untouched
        if ($word -notmatch '[^\W\d_]') { [void]$out.Add($word); continue }

        $built = ''
        foreach ($chunk in @($word -split '(-)' | Where-Object { $_ -ne '' })) {
            if ($chunk -eq '-') { $built += '-'; continue }
            $built += $chunk.Substring(0, 1).ToUpper($culture) + $chunk.Substring(1)
        }
        [void]$out.Add($built)
    }
    return ($out -join '')
}

# Fold an alias into the title it names, if the user has said they are one show.
#
# titleAliases is a flat object of "parsed title" -> "the title to file it under",
# and it is the only mechanism that can join two spellings nothing else can. Both
# families this exists for were measured on a live queue:
#
#   - 'euphoria' and 'euphoria us' are one show. They share a first word, so
#     dedup already compares them, but the LIBRARY FOLDER comes from the parsed
#     title, so the two filed into 'Euphoria' and 'Euphoria Us' and rule 4b could
#     not see across them - it only ever compares inside one show folder. Two
#     copies of S03E08 sat in the library, 10.27 GB and 6.89 GB, with no verdict
#     between them.
#
#   - 'widows bay', 'wdowia zatoka widows bay' and 'o segredo de widows bay' are
#     one show in three languages, and nothing derivable from a title relates
#     them: 'zatoka' means 'bay', and only a person knows that.
#
# Automatic transliteration was considered and rejected. Folding titles by
# similarity trades a known false-negative - a duplicate nobody notices - for a
# false positive that deletes a file, which is the worse of the two by a long way.
#
# Looked up case-insensitively, since the parser lowercases. A chain is followed
# so 'a' -> 'b' -> 'c' lands on 'c', but only within a bounded number of hops and
# only while it keeps changing: a cycle cannot hang the run. An unknown title is
# returned unchanged, which is what makes the list safe to leave incomplete.
function Resolve-ShowAlias {
    param(
        [string]$Title,
        [object]$Aliases
    )

    if ([string]::IsNullOrWhiteSpace($Title)) { return $Title }
    if ($null -eq $Aliases) { return $Title }

    $pairs = @()
    if ($Aliases -is [System.Collections.IDictionary]) {
        foreach ($k in $Aliases.Keys) { $pairs += , @([string]$k, [string]$Aliases[$k]) }
    }
    else {
        foreach ($p in $Aliases.PSObject.Properties) { $pairs += , @($p.Name, [string]$p.Value) }
    }
    if ($pairs.Count -eq 0) { return $Title }

    # Built once per call, keyed lowercase. The list is a handful of entries and
    # this runs once per torrent, so a scan would also do - the map is here so a
    # long list does not turn into a long list of comparisons.
    $map = @{}
    foreach ($p in $pairs) {
        if ([string]::IsNullOrWhiteSpace($p[0])) { continue }
        if ([string]::IsNullOrWhiteSpace($p[1])) { continue }
        $map[$p[0].ToLowerInvariant()] = $p[1]
    }

    $cur = $Title
    for ($hop = 0; $hop -lt 8; $hop++) {
        $k = $cur.ToLowerInvariant()
        if (-not $map.ContainsKey($k)) { break }
        $next = $map[$k]
        if ($next -eq $cur) { break }
        $cur = $next
    }
    return $cur
}

function Resolve-PartsAlias {
<#
    An alias is a statement about IDENTITY, not about file naming.

    'Euforie - Euphoria S03E01 (2026)[1080p]' is not a show called 'Euforie'. The
    parser reads its title as 'euforie euphoria' - the Czech title of Euphoria in
    front of the English one - and because a show family is the FIRST WORD of that
    name, the family came out as 'euforie'. The other 40-odd Euphoria releases
    parse as 'euphoria' or 'euphoria us', so this one sat in a group of its own:

      parsed "euforie euphoria"   family "euforie"    S03E01, 4,65 GB, 100%
      parsed "euphoria"           family "euphoria"   the same episode, 8,44 GB

    Two copies of one episode that never met, and 4,65 GB of data qBittorrent had
    no reason to keep. The family fold could not repair it: it merges on a shared
    first word, and folding 'euforie' into 'euphoria' by resemblance is exactly
    the guess this project refuses to make. 'euforia', 'euforie' and 'euphoria'
    are one show to a person and three different strings to a parser.

    So the knowledge comes from the user, in config, and it is applied HERE - where
    a release's identity is established - rather than at folder-naming time. That
    is the whole difference: Resolve-ShowAlias was called from exactly one place,
    Resolve-LibraryShowDir, so an alias filed the show correctly and still left
    dedup blind to it. The two disagreed about what the show was, which is the
    same shape as the two bugs this session already turned up - a duplicated rule
    where one copy was fixed and the other kept saying the old thing.

    Applying it at the parser changes Title AND Tokens together, because the show
    family is computed from the leading run of Tokens, not from Title. Rewriting
    only Title would leave every grouping key still reading 'euforie'.

    Nothing is inferred here. A title with no alias entry comes back untouched,
    byte for byte.
#>
    param(
        $Parts,
        [object]$Aliases
    )

    if ($null -eq $Parts) { return $Parts }
    if ($null -eq $Aliases) { return $Parts }
    if ([string]::IsNullOrWhiteSpace([string]$Parts.Title)) { return $Parts }

    $canon = Resolve-ShowAlias -Title ([string]$Parts.Title) -Aliases $Aliases
    if ([string]::IsNullOrWhiteSpace($canon)) { return $Parts }

    $canon = $canon.ToLowerInvariant().Trim()
    if ($canon -eq [string]$Parts.Title) { return $Parts }

    # Retokenised by the same rule Get-TitleParts uses, so the canonical title is
    # held to the same standard as a parsed one: bare numbers inside a title are
    # sequel markers and are kept out of Tokens, and the ignorable words are
    # dropped. Rebuilding rather than slicing the old list is what stops a stale
    # 'euforie' surviving in the family computation.
    $tokens = @()
    $numericTitle = @(($canon -split ' ') | Where-Object { $_.Length -gt 0 }).Count -eq 1 -and
                    ($canon -split ' ') -match '^\d+$'
    $numbers = @()
    foreach ($w in @($canon -split ' ' | Where-Object { $_.Length -gt 0 })) {
        if ($w -match '^\d+$' -and -not $numericTitle) { $numbers += $w; continue }
        if ($script:ignorable -contains $w) { continue }
        $tokens += $w
    }

    # An alias that resolves to nothing usable is ignored rather than applied. A
    # title that cannot be retokenised has no grouping key, and a group with no
    # key is skipped everywhere - so honouring it would silence the rule for
    # every OTHER release of the show too.
    if ($tokens.Count -eq 0) { return $Parts }

    $out = [ordered]@{}
    foreach ($p in $Parts.PSObject.Properties) { $out[$p.Name] = $p.Value }
    $out['Title'] = $canon
    $out['Tokens'] = $tokens
    $out['Numbers'] = $numbers
    return [pscustomobject]$out
}

function Resolve-LibraryShowDir {
    <#
        The show folder on disk for a parsed title, as a FULL path - and it is
        always a folder that already exists if one does.

        This exists because of a real hazard, not tidiness. Show folder names are
        title-cased, but the folders already on disk are not:
        'its always sunny in philadelphia'. Computing a target from the title
        alone would therefore aim at 'Its Always Sunny In Philadelphia' - a
        DIFFERENT path - and every subsequent torrent of that show would land in a
        second folder, splitting one season across two trees. The library would
        quietly become the duplicate problem this project exists to prevent.

        So the lookup is case-insensitive and returns the name that is actually
        there. Renaming an existing folder to match the new style is a separate,
        deliberate act - see the note in ConvertTo-LibraryFolderName - and not
        something a path computation should do on its own.

        The title is folded through titleAliases FIRST, so that two spellings of
        one show resolve to ONE folder. Without that, dedup compares them (they
        share a first word) while the library files them apart, and rule 4b - which
        only ever compares inside a single show folder - can then never see the
        duplicate that results. Two folders for one show is not a cosmetic split:
        it is the duplicate problem this project exists to prevent, arriving
        through the back door.

        The alias target is what the folder is NAMED, but an existing folder
        matching either spelling is still preferred, so adding an alias does not
        orphan a folder that is already on disk with files in it. Folding the two
        existing folders together is a separate, deliberate act - see
        Merge-LibraryShowFolders.

        Cached per run: this is called once per torrent, and the series folder does
        not change mid-run.
    #>
    param(
        [string]$SeriesDir,
        [string]$Title,
        [object]$Aliases
    )

    if ([string]::IsNullOrWhiteSpace($Title)) { return $null }
    if (-not $SeriesDir -or -not (Test-Path -LiteralPath $SeriesDir)) { return $null }

    if (-not $script:showDirCache) { $script:showDirCache = @{} }
    $ck = $Title.ToLowerInvariant()
    if ($script:showDirCache.ContainsKey($ck)) { return $script:showDirCache[$ck] }

    $alias = Resolve-ShowAlias -Title $Title -Aliases $Aliases
    $want = ConvertTo-LibraryFolderName -Title $alias
    # The un-aliased spelling, so a folder that predates the alias is still
    # found rather than duplicated. Compared second, so the aliased name wins
    # when both exist.
    $wantPlain = ConvertTo-LibraryFolderName -Title $Title
    $found = $null

    foreach ($d in @(Get-ChildItem -LiteralPath $SeriesDir -Directory -ErrorAction SilentlyContinue)) {
        if ($d.Name.Equals($want, [StringComparison]::OrdinalIgnoreCase)) { $found = $d.FullName; break }
    }
    if ($null -eq $found -and $wantPlain -ne $want) {
        foreach ($d in @(Get-ChildItem -LiteralPath $SeriesDir -Directory -ErrorAction SilentlyContinue)) {
            if ($d.Name.Equals($wantPlain, [StringComparison]::OrdinalIgnoreCase)) { $found = $d.FullName; break }
        }
    }

    # Nothing there yet: the case-corrected name is what gets created.
    if ($null -eq $found) { $found = Join-Path $SeriesDir $want }

    $script:showDirCache[$ck] = $found
    return $found
}

# Where a completed torrent belongs. Series go into a per-show folder with a
# per-season subfolder; movies go straight into the movies dir. The show name
# comes from the parsed title, the season from the parsed parts. A season of 0
# or $null means the season is unknown, so no season subfolder is created.
#
# The show FOLDER is resolved through Resolve-LibraryShowDir, so it is always the
# one already on disk rather than a freshly spelled, differently-cased path.
function Get-LibraryTargetDir {
    param(
        [object]$T,
        [string]$MoviesDir,
        [string]$SeriesDir,
        [object]$Aliases
    )

    if (-not $T -or -not $T.parts) { return $MoviesDir }
    if (-not $T.parts.IsSeries) { return $MoviesDir }

    $base = Resolve-LibraryShowDir -SeriesDir $SeriesDir -Title $T.parts.Title -Aliases $Aliases
    if (-not $base) {
        # Unidentified show: fall back to the series root rather than inventing a
        # folder name from an empty title.
        return $SeriesDir
    }

    $season = $T.parts.Season
    if ($null -ne $season -and $season -gt 0) {
        $base = Join-Path $base ("Season {0}" -f $season)
    }
    return $base
}

# What should happen to this torrent's files right now, and why. A decision, not
# an action: no API call, nothing moved. Move-ToLibrary acts on the answer and
# then verifies, so a rule that cannot be answered here cannot be trusted
# anywhere.
#
#   skip   the files are already where they belong
#   block  something still wanted is holding the folder, and no retry clears it
#   move   go ahead, then VERIFY rather than assume
#
# 'block' exists because a shared content_path is a real, reproducible failure
# and not a transient one. qBittorrent moves a folder by renaming it, and
# Windows refuses a rename while another file inside it is open. Two torrents
# pointing at one folder therefore deadlock each other: asking again every 15
# minutes cannot help, and before this rule the ask was made anyway and logged
# as a success each time.
function Get-MovePlan {
    param(
        [object]$T,
        [object[]]$Torrents = @(),
        [string]$TargetDir,
        [hashtable]$Gone = @{}
    )

    if (-not $T) { return [pscustomobject]@{ Action = 'block'; Reason = 'there is no torrent to move' } }

    $cp = [string]$T.content_path
    if ([string]::IsNullOrWhiteSpace($cp)) {
        return [pscustomobject]@{
            Action = 'block'
            Reason = 'it reports no content_path, so there is nothing that could be moved'
        }
    }

    if (Test-MoveSettled -T $T -TargetDir $TargetDir) {
        return [pscustomobject]@{ Action = 'skip'; Reason = 'already in the library' }
    }

    # $Gone holds what this run has already deleted. Without it a torrent removed
    # earlier in the run would still read as a holder of its own old folder and
    # block the move of whatever shared it.
    $others = @($Torrents | Where-Object { $_ -and $_.hash -ne $T.hash -and -not $Gone.ContainsKey($_.hash) })
    $holders = @($others | Where-Object { $null -ne (Test-Claimed -Path $cp -Torrents @($_)) })

    if ($holders.Count -gt 0) {
        if ($holders.Count -eq 1) {
            $who = "one live torrent ('{0}')" -f $holders[0].name
        }
        else {
            $who = '{0} live torrents (e.g. ''{1}'')' -f $holders.Count, $holders[0].name
        }
        return [pscustomobject]@{
            Action = 'block'
            # The -f is applied to the JOINED string, not to the second half of
            # it: -f binds tighter than +, so "...; " + 'x' -f $who would
            # substitute nothing and leave a literal {0} in the message.
            Reason = ("{0} still point at that folder, so moving it would fail with 'Permission denied'; " +
                      'the folder belongs to one of them and not to this one') -f $who
        }
    }

    return [pscustomobject]@{ Action = 'move'; Reason = '' }
}

# Read-only. Enumerates one level under each root and reports what could be
# reaped, plus why each thing that was kept was kept - a reaper that deletes
# silently is impossible to trust, and impossible to debug after the fact.
function Get-LibraryDuplicateVerdicts {
    <#
        Rule 4b: the same episode, twice, inside one show's own season folder.

        Why this exists, from a measured loss. The library layout puts a series at
        seriesDir\<show>\Season N\, and the show name comes from Get-LibraryTargetDir
        - the torrent's own parsed title. Three releases of the same show therefore
        land in DIFFERENT season folders while being the same show:

            ...\its always sunny in philadelphia\Season 18\C'è Sempre il Sole a Philadelphia S18\
            ...\its always sunny in philadelphia\Season 18\Its Always Sunny In Philadelphia s18 WEB-DL 1080p\
            ...\its always sunny in philadelphia\Season 18\www.UIndex.org - ...REPACK...Kitsune\

        Rule 4 could not see them. It compares inside a CLUSTER, and a cluster's
        family is the first word of the show name - 'its', 'c'è', 'www' - so three
        releases of one show are three clusters that never meet. The result was 7
        duplicated episodes and 10,5 GB, all of it finished and all of it in the
        library, because the two rules that would have noticed (dedup and the
        family merge) are both title-based and neither can see past a translated
        or re-labelled release.

        The library folder is what fixes it, and it is not a heuristic. The manager
        put those files in that folder itself: Get-LibraryTargetDir decided they were
        one show, so the folder is a grouping already proven, arrived at by a
        different route than the family guard. Two files in the same season folder
        claiming the same episode are the same episode of the same show by
        construction - which is exactly what the family guard could not establish.

        What it will NOT do:

        - It only ever looks inside seriesDir. Two different shows never share a
          folder, so it cannot merge across shows.
        - It requires BOTH files to name the SAME episode. A file whose name yields
          no episode is skipped, never treated as a wildcard - the same refusal
          Get-EpisodeSetKey documents.
        - It compares SIZE, exactly as rule 4 does, and only among files that are
          both complete. An incomplete file is never a deletion candidate and never
          a keeper.
        - A PACK is never deleted as a whole just because one of its files is a
          duplicate. See WHAT HAPPENS TO A PACK below.
        - The season comes from the FOLDER and the episode from the FILE NAME, and
          the two are never cross-checked. This is the only way the rule can see
          the files it exists for: 'e01 - Frank Marries a Corpse.mkv' states no
          season at all and parses as season 1, so requiring the filename's season
          to match the folder's would reject every EZTV-style file - precisely the
          half of the pair that must be recognised. Get-LibraryTargetDir is what
          filed it under Season 18, so the folder is the better evidence anyway.
          Verified by building the real folder names in a temp tree: with the
          cross-check in place the rule found 0 duplicates in 16 files; without
          it, 7.
        - A file holding a RANGE of episodes, or a whole season, is skipped. It is
          not a single episode and has nothing to be a duplicate of - the same
          refusal rule 4 makes when it separates packs from singles.

        FILM files are not handled here. A film folder holds one work, and two
        different cuts of the same film are a judgement call, not a duplicate.

        WHAT HAPPENS TO A PACK. A duplicate file may belong to a PACK, and then
        deleting the file is not the same thing as deleting the torrent. The
        torrent is the only record of the pack's OTHER episodes, several of which
        are usually wanted and have no other copy. So:

          - Pack owner, and the pack still has episodes the library does not
            otherwise hold  ->  the FILE is the duplicate, but the torrent must
            survive. Returned as Action 'delete-file-only': the caller removes
            the one file by path and leaves the entry alone.
          - Pack owner, and every remaining episode of the pack is either already
            in the library or is this duplicate  ->  the whole entry is now
            worthless, so it goes with its data: Action 'delete'.
          - No torrent, or a SINGLE-episode torrent  ->  'delete' with its data.

        The pack's remaining episodes are counted against the LIBRARY, not against
        its own file list. A pack listing ten episodes of which the library holds
        nine is one episode short of deletable, no matter what the pack claims to
        contain - and that is the direction the check has to err in. Deleting an
        entry whose episodes exist nowhere else is unrecoverable; leaving one
        duplicate file behind is merely untidy.

        A pack is required to be STOPPED before it is deleted, and is never
        restarted. That is the same discipline every other deletion here follows,
        and it matters most here: a running pack re-fetches the file just deleted,
        so the duplicate returns on the next run.

        Returns one row per duplicate, naming the file and the torrent that owns it.
        Deletes nothing; the caller acts on the answer.
    #>
    param(
        [string]$SeriesDir,
        [object[]]$Torrents,
        [hashtable]$Gone = @{}
    )

    $out = New-Object System.Collections.ArrayList
    if (-not $SeriesDir -or -not (Test-Path -LiteralPath $SeriesDir)) { return $out }

    # One file listing per owning entry for the whole pass. Deciding whether an
    # entry is a pack means asking what episodes it holds, and a season full of
    # duplicates would otherwise re-read the same listing once per duplicate.
    $ownerSetKeyCache = @{}

    foreach ($showDir in @(Get-ChildItem -LiteralPath $SeriesDir -Directory -ErrorAction SilentlyContinue)) {
        foreach ($seasonDir in @(Get-ChildItem -LiteralPath $showDir.FullName -Directory -ErrorAction SilentlyContinue |
                                Where-Object { $_.Name -match '^Season\s+(?<n>\d+)$' })) {
            $season = [int]$Matches['n']

            # Which episode each file in this season claims, read by the ONE helper
            # that both this rule and the phantom rule use, so the two can never
            # disagree about what a season folder contains.
            #
            # The season comes from the FOLDER and the episode from the FILE NAME,
            # never cross-checked. That is deliberate and it is the only way this
            # rule can see the files it exists for: a release named
            # 'e01 - Frank Marries a Corpse.mkv' states no season whatsoever and
            # parses as season 1, so requiring the filename's season to match the
            # folder's would reject every such file - precisely the half of the
            # duplicate pair that has to be recognised. Get-LibraryTargetDir filed
            # it under Season 18, so the folder is the better evidence anyway.
            $fileEpisodes = Get-LibraryEpisodeFiles -SeasonDir $seasonDir.FullName -Season $season

            # Grouped by episode, so two copies of one episode meet. EVERY copy is
            # carried through: keeping only the largest here would hide the
            # duplicates this rule exists to find.
            $byEpisode = @{}
            foreach ($ep in $fileEpisodes.Keys) {
                $key = "$season-E$ep"
                if (-not $byEpisode.ContainsKey($key)) { $byEpisode[$key] = New-Object System.Collections.ArrayList }
                foreach ($f in @($fileEpisodes[$ep])) {
                    [void]$byEpisode[$key].Add([pscustomobject]@{
                        File  = $f
                        Owner = (Test-Claimed -Path $f.FullName -Torrents $Torrents)
                    })
                }
            }

            foreach ($key in ($byEpisode.Keys | Sort-Object)) {
                $group = @($byEpisode[$key])
                if ($group.Count -lt 2) { continue }

                # A preallocated downloading file is not a finished keeper.
                # Check every claimant, not merely the first matching torrent.
                $eligible = @($group | Where-Object {
                    $file = $_.File
                    $claims = @($Torrents | Where-Object { Test-Claimed -Path $file.FullName -Torrents @($_) })
                    @($claims | Where-Object { $_.progress -lt 1 -or $Gone.ContainsKey($_.hash) }).Count -eq 0
                })
                if ($eligible.Count -lt 2) { continue }
                # Stable tie-break: one finished file survives, even on a tie.
                $sorted = @($eligible | Sort-Object -Property @{ Expression = { $_.File.Length }; Descending = $true }, @{ Expression = { $_.File.FullName } })
                $biggest = $sorted[0].File.Length

                # The torrent(s) behind the largest copy. They are stopped but
                # never deleted, and never restarted.
                $keeperHashes = @($Torrents | Where-Object {
                    Test-Claimed -Path $sorted[0].File.FullName -Torrents @($_)
                } | ForEach-Object { [string]$_.hash })

                for ($i = 1; $i -lt $sorted.Count; $i++) {
                    $c = $sorted[$i]
                    $f = $c.File

                    if ($c.Owner -and $keeperHashes -contains [string]$c.Owner.hash) {
                        [void]$out.Add([pscustomobject]@{
                            Action   = 'hold'
                            Reason   = 'the keeper and duplicate belong to the same torrent; entry deletion would remove the keeper'
                            File     = $f.FullName
                            Bytes    = $f.Length
                            Episode  = $key
                            Show     = $showDir.Name
                            Owner        = $c.Owner
                            OwnerHash    = ''
                            KeeperHashes = @()
                        })
                        continue
                    }

                    $ownerName = if ($c.Owner) { $c.Owner.name } else { '(no torrent claims this file)' }
                    $reason = ("duplicate episode inside {0}\Season {1}: {2:N2} GB beside the retained finished {3:N2} GB copy of the same episode ({4}); owned by '{5}'" -f `
                               $showDir.Name, $season, ($f.Length / 1GB), ($biggest / 1GB), $key, $ownerName)

                    # A PACK owner changes what may be deleted. The file is the
                    # duplicate, but the ENTRY is the only record of the pack's
                    # other episodes - usually wanted, and often the only copy.
                    #
                    # So the question is not "is this file a duplicate" but "is
                    # anything left that only this entry holds". Measured against
                    # the LIBRARY rather than the pack's own file list: an episode
                    # the pack lists but the library already has elsewhere is not
                    # lost by deleting the entry.
                    $action = 'delete'
                    $packNote = ''

                    # WHICH episodes the owning entry holds. This must never be
                    # narrower than the truth, because the whole question is
                    # whether anything would be lost with the entry.
                    #
                    # It was, and it cost a season. The guard used to be
                    # `-and $Owner.parts.IsMultiEpisode -and $Owner.parts.EpisodeLast`,
                    # which reads an explicit range out of the NAME. A whole-season
                    # pack states no range - 'Euphoria.S03.COMPLETE' parses to
                    # Episode 0, IsMultiEpisode false, EpisodeLast null - so the
                    # guard was false, the branch was skipped, and the verdict fell
                    # through to a plain `delete` with the pack's hash.
                    #
                    #   2026-10-05 22:28:13 [DELETE] "Euphoria.S03.COMPLETE..." [c7fc56a6]
                    #     - duplicate episode inside Euphoria\Season 3: 5,61 GB beside
                    #       the larger 8,16 GB copy of the same episode (3-E7)
                    #
                    # One file of eight was the duplicate. The entry went anyway, and
                    # S03E01-E06 and S03E08 - about 31 GB with no other copy anywhere
                    # - went with it. A 40 GB pack was destroyed on the strength of a
                    # 5,61 GB file.
                    #
                    # Read from the episode numbers FIRST, because that is what a
                    # single and a named range both state outright. Episode 0 means
                    # the name claims a whole season without saying how many episodes
                    # that is, so only then is the file list consulted - the same
                    # resolver rule 4 uses, and the only way to tell eight episodes
                    # from ten.
                    #
                    # Deliberately NOT gated on parts.IsSeries. That flag describes how
                    # the name parsed, not what the entry holds, and requiring it
                    # reclassified every owner that lacked it as 'unknown' - the safe
                    # direction, and still wrong: it turned ordinary single-episode
                    # deletions into file-only ones and broke thirteen checks.
                    $pf = $null
                    $pl = $null
                    $ownerParts = $null
                    if ($c.Owner -and $c.Owner.parts) { $ownerParts = $c.Owner.parts }

                    if ($ownerParts) {
                        $pe0 = $ownerParts.Episode
                        $pe1 = $ownerParts.EpisodeLast
                        if ($null -ne $pe0 -and [int]$pe0 -gt 0) {
                            if ($null -ne $pe1 -and [int]$pe1 -gt [int]$pe0) {
                                $pf = [int]$pe0
                                $pl = [int]$pe1
                            }
                            else {
                                # One episode. A single-episode entry holds nothing
                                # that deleting it could lose beyond the file already
                                # removed.
                                $pf = [int]$pe0
                                $pl = [int]$pe0
                            }
                        }
                    }

                    # Still nothing: the name claims a season without saying how many
                    # episodes are in it. Ask the entry's own file list.
                    if ($null -eq $pf -and $ownerParts) {
                        $ownerKey = Resolve-TorrentSetKey -T $c.Owner -Cache $ownerSetKeyCache
                        if ($ownerKey -match '^S\d+-E(\d+)-E(\d+)$') {
                            $pf = [int]$Matches[1]
                            $pl = [int]$Matches[2]
                        }
                    }

                    # NO OWNER is a different case from an owner of unknown range, and
                    # conflating them was the second half of this regression.
                    #
                    # With no torrent claiming the file there is no entry to protect:
                    # nothing else can be holding the pack's remaining episodes,
                    # because there is no pack. The file is simply removed, which is
                    # what this rule did for unowned duplicates from the start.
                    #
                    # Gating on `$null -ne $pf` alone sent those to 'delete-file-only'
                    # instead, so seven real duplicates stopped being removable and the
                    # library could only ever be cleaned by hand. An absent owner is
                    # evidence of nothing at risk; an owner whose range cannot be read
                    # is evidence of a possible pack.
                    if ($null -eq $c.Owner) {
                        $packNote = ' No torrent claims this file, so there is no entry to protect.'
                    }
                    elseif ($null -ne $pf) {
                        $orphaned = New-Object System.Collections.ArrayList

                        # The episode being duplicated, taken from the GROUP KEY
                        # rather than from $ep. $ep is the loop variable of the
                        # per-episode sweep that built $byEpisode and has long since
                        # finished, so it holds whatever episode that sweep ended on
                        # - episode 8 here, not episode 7. Comparing against it made
                        # the duplicate itself count as "still held by this entry",
                        # which is the one episode it must never count as.
                        $dupEpisode = 0
                        if ($key -match '-E(\d+)$') { $dupEpisode = [int]$Matches[1] }

                        for ($pe = $pf; $pe -le $pl; $pe++) {
                            # This very episode is the duplicate being removed, so
                            # it does not count as something the entry still holds.
                            if ($pe -eq $dupEpisode) { continue }

                            if (-not $fileEpisodes.ContainsKey($pe)) {
                                [void]$orphaned.Add("S$season" + "E$pe")
                                continue
                            }
                            # Present in the library - but is the only copy of it
                            # owned by THIS pack? If some other release holds it,
                            # deleting this entry still costs nothing.
                            $heldElsewhere = $false
                            foreach ($other in @($fileEpisodes[$pe])) {
                                if ($other.FullName -ieq $f.FullName) { continue }
                                $o = Test-Claimed -Path $other.FullName -Torrents $Torrents
                                if ($o -and ([string]$o.hash -eq [string]$c.Owner.hash -or $o.progress -lt 1 -or $Gone.ContainsKey($o.hash))) { continue }
                                $heldElsewhere = $true
                                break
                            }
                            if (-not $heldElsewhere) { [void]$orphaned.Add("S$season" + "E$pe") }
                        }

                        if ($orphaned.Count -gt 0) {
                            $action = 'delete-file-only'
                            $packNote = (" The owning pack still holds {0}, which the library does not have elsewhere, so the entry is kept and only this file is removed." -f `
                                         (@($orphaned) -join ', '))
                        }
                        else {
                            $packNote = (" Every remaining episode of the owning pack is already in the library, so the entry goes with its data.")
                        }
                    }
                    else {
                        # The owning entry's episodes could not be established, so it
                        # is not known to be a single. Deleting it would be a guess,
                        # and the guess is 'everything it holds'. So only the
                        # duplicate FILE goes.
                        #
                        # Refusing here is never the wrong direction: an entry left
                        # behind costs one stale row and disk, while an entry deleted
                        # on a guess costs the episodes nothing else holds, which is
                        # not recoverable.
                        $action = 'delete-file-only'
                        $packNote = (" Which episodes the owning entry holds could not be established, so it is kept and only this file is removed - deleting it would be a guess, and the guess is everything it holds.")
                    }

                    [void]$out.Add([pscustomobject]@{
                        Action   = $action
                        Reason   = ($reason + $packNote)
                        File     = $f.FullName
                        Bytes    = $f.Length
                        Episode  = $key
                        Show     = $showDir.Name
                        Owner       = $(if ($action -eq 'delete-file-only') { $null } else { $c.Owner })
                        # Deleting the file alone would leave the owning SINGLE
                        # re-downloading it, which is the duplicate all over
                        # again. A PACK is different: the entry has to survive,
                        # so OwnerHash is left empty and the caller removes the
                        # file by path.
                        OwnerHash   = if ($action -eq 'delete-file-only') { '' }
                                      elseif ($c.Owner) { [string]$c.Owner.hash }
                                      else { '' }
                        KeeperHashes = $keeperHashes
                        StopHashes = @($keeperHashes) + @($Torrents | Where-Object {
                            Test-Claimed -Path $f.FullName -Torrents @($_)
                        } | ForEach-Object { [string]$_.hash })
                    })
                }
            }
        }
    }

    return $out
}

function Get-LibraryEpisodeFiles {
    <#
        The video files a season folder holds, keyed by the episode each one
        claims. EVERY copy is kept, in a list per episode - this is the shared
        fact both library rules need, and the two need different things from it:

        - the phantom rule asks "is there ANY file for episode N?", to decide
          whether a vanished entry has been replaced.
        - the duplicate rule asks "how many files claim episode N?", to find the
          copies. It needs all of them.

        An earlier version returned only the largest file per episode. That was
        wrong for the duplicate rule and failed silently: with two copies of one
        episode the smaller was dropped before the comparison, so the rule found
        nothing and reported the season as clean. test-library-dedupe.ps1 caught
        it - 7 duplicates down to 0 - which is what a shared helper is for.

        Keyed by episode number, with the season taken from the FOLDER and never
        cross-checked against the file name: 'e01 - Frank Marries a Corpse.mkv'
        states no season at all and parses as season 1, so requiring the name's
        season to match the folder's would discard half of every release.

        A file holding a RANGE, or a whole season, is left out. It is not a single
        episode and cannot stand in for one.
    #>
    param(
        [string]$SeasonDir,
        [int]$Season
    )

    $map = @{}
    if (-not $SeasonDir -or -not (Test-Path -LiteralPath $SeasonDir)) { return $map }

    $videoExt = @('.mkv', '.mp4', '.avi', '.m4v', '.ts')
    foreach ($f in @(Get-ChildItem -LiteralPath $SeasonDir -Recurse -File -ErrorAction SilentlyContinue |
                     Where-Object { $videoExt -contains $_.Extension.ToLowerInvariant() })) {
        $parts = $null
        try { $parts = Get-TitleParts -Name $f.Name } catch { $parts = $null }
        if (-not $parts) { continue }
        if (-not $parts.IsSeries) { continue }
        if ($null -eq $parts.Episode) { continue }
        if ($parts.IsMultiEpisode) { continue }
        if ($parts.Episode -le 0) { continue }

        $ep = $parts.Episode
        if (-not $map.ContainsKey($ep)) { $map[$ep] = New-Object System.Collections.ArrayList }
        [void]$map[$ep].Add($f)
    }
    return $map
}

function Get-PhantomVerdicts {
    <#
        Rule 4c: a torrent that says it is finished, over data that is not there.

        The case, from this box: 'Its.Always.Sunny.In.Philadelphia.S18E01-E07.400p.Ru.Ultradox'
        sat at 100% while the folder it claimed had long since been removed. The
        entry was pure fiction - it advertised seven episodes to qBittorrent and
        to anything reading its status, and held nothing. It also made the queue
        lie: every count of "finished" included it.

        A phantom is deleted, but only when its content has demonstrably been
        REPLACED. That condition is the whole rule, and it is what separates this
        from simply deleting any completed torrent whose folder happens to be
        missing - which would destroy the only record of a season whose data was
        merely unreachable (a detached drive, a permissions problem, a folder
        someone moved by hand).

        So all of these must hold:

        - progress is 1. A download in progress is not a phantom; its folder is
          being written to.
        - content_path is inside seriesDir or moviesDir. A missing path under the
          staging area is the orphan reaper's business, and is far more likely to
          be a torrent that has not started yet.
        - the torrent is identified, so what episodes it held can be derived.
        - EVERY episode it claimed has a file in the library season folder. One
          missing episode and the entry is HELD, because the remaining episodes
          have no other record and the data may be recoverable.
        - no other live torrent claims the same content_path. Two torrents can
          share a folder name, and deleting one must never disturb the other.

        The entry is removed WITHOUT files. The path it claims does not exist, so
        there is nothing there to delete - and a stray copy of the same data may
        well sit under the staging area, owned by a different torrent. Deleting
        files here would be deleting something this rule never looked at.

        Returns one row per candidate. Deletes nothing.
    #>
    param(
        [object[]]$Torrents,
        [string]$MoviesDir,
        [string]$SeriesDir,
        [hashtable]$Gone = @{},
        # titleAliases, forwarded to the folder resolver. Omitting it makes this
        # rule look for the library in a folder the entry's own episodes were never
        # filed under - see the note at the resolver call.
        [object]$Aliases = $null
    )

    $out = New-Object System.Collections.ArrayList
    $all = @($Torrents)

    # The set of content_paths some OTHER live torrent claims, so a shared folder
    # is never touched.
    $claimedBy = @{}
    foreach ($t in $all) {
        if ($null -eq $t) { continue }
        $cp = [string]$t.content_path
        if ([string]::IsNullOrWhiteSpace($cp)) { continue }
        $k = $cp.TrimEnd('\', '/').ToLowerInvariant()
        if (-not $claimedBy.ContainsKey($k)) { $claimedBy[$k] = New-Object System.Collections.ArrayList }
        [void]$claimedBy[$k].Add([string]$t.hash)
    }

    foreach ($t in $all) {
        if ($null -eq $t) { continue }
        if ($Gone.ContainsKey($t.hash)) { continue }
        if ([double]$t.progress -lt 1) { continue }

        $cp = [string]$t.content_path
        if ([string]::IsNullOrWhiteSpace($cp)) { continue }
        if (Test-Path -LiteralPath $cp) { continue }

        # Only inside the library. See the notes above.
        $inLibrary = $false
        foreach ($root in @($SeriesDir, $MoviesDir)) {
            if (-not $root) { continue }
            $r = $root.TrimEnd('\', '/')
            if ($cp.Equals($r, [StringComparison]::OrdinalIgnoreCase) -or
                $cp.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) { $inLibrary = $true; break }
        }
        if (-not $inLibrary) { continue }

        if (-not $t.parts) { continue }

        # Another live torrent claiming the same path: not ours to remove.
        $ck = $cp.TrimEnd('\', '/').ToLowerInvariant()
        $others = @($claimedBy[$ck] | Where-Object { $_ -ne [string]$t.hash })
        if ($others.Count -gt 0) {
            [void]$out.Add([pscustomobject]@{
                Action = 'hold'
                Torrent = $t
                Reason = ("its folder is gone, but {0} other torrent(s) claim the same path, so this entry is not the only record" -f $others.Count)
            })
            continue
        }

        # A film is replaced by a file of the same name in the movies folder.
        if (-not $t.parts.IsSeries) {
            $replaced = $false
            foreach ($ext in @('mkv', 'mp4', 'avi', 'm4v')) {
                $c = Join-Path $MoviesDir ($t.parts.Title + '.' + $ext)
                if (Test-Path -LiteralPath $c) { $replaced = $true; break }
            }
            if ($replaced) {
                [void]$out.Add([pscustomobject]@{
                    Action  = 'delete'
                    Torrent = $t
                    Reason  = ("phantom: it reports {0:N0}% complete but its data is gone, and '{1}' is in the library in its place" -f `
                               ($t.progress * 100), $t.parts.Title)
                })
            }
            else {
                [void]$out.Add([pscustomobject]@{
                    Action  = 'hold'
                    Torrent = $t
                    Reason  = ("phantom, but no file for '{0}' is in the library, so nothing has replaced it" -f $t.parts.Title)
                })
            }
            continue
        }

        # A series: every episode it claimed must be present in the library.
        $season = $t.parts.Season
        if ($null -eq $season -or $season -le 0) { continue }
        if ($null -eq $t.parts.Episode) { continue }

        $show = $t.parts.Title
        if ([string]::IsNullOrWhiteSpace($show)) { continue }
        # Through the resolver, so this finds the folder that is actually on disk
        # rather than a freshly spelled path that differs only in case.
        #
        # -Aliases, and it is load-bearing here. This rule asks "does the library
        # hold a replacement for every episode this entry claimed", and it can only
        # answer by looking in the folder the entry's OWN episodes were filed
        # under. Without the alias it asks about 'Euphoria Us' while the pack was
        # moved to 'Euphoria' - so it finds nothing, concludes there is no
        # replacement, and holds a phantom it should have deleted.
        $showDir = Resolve-LibraryShowDir -SeriesDir $SeriesDir -Title $show -Aliases $Aliases
        if (-not $showDir) { continue }
        $seasonDir = Join-Path $showDir ("Season {0}" -f $season)
        $have = Get-LibraryEpisodeFiles -SeasonDir $seasonDir -Season $season

        $first = [int]$t.parts.Episode
        $last = $first
        if ($t.parts.IsMultiEpisode -and $null -ne $t.parts.EpisodeLast) { $last = [int]$t.parts.EpisodeLast }

        $missing = New-Object System.Collections.ArrayList
        $covered = New-Object System.Collections.ArrayList
        for ($ep = $first; $ep -le $last; $ep++) {
            if ($have.ContainsKey($ep)) { [void]$covered.Add($ep) }
            else { [void]$missing.Add($ep) }
        }

        $range = if ($first -eq $last) { "S{0}E{1}" -f $season, $first } else { "S{0}E{1}-E{2}" -f $season, $first, $last }

        if ($missing.Count -gt 0) {
            # The one case that must never delete. The entry is the only record
            # these episodes have; removing it would make them unrecoverable.
            [void]$out.Add([pscustomobject]@{
                Action  = 'hold'
                Torrent = $t
                Reason  = ("phantom: {0} is gone from disk, but the library holds no S{1}E{2}, so the entry is the only record of it - held" -f `
                           $range, $season, (@($missing) -join ', S' + $season + 'E'))
            })
            continue
        }

        $covDesc = if ($covered.Count -eq 1) { ("S{0}E{1}" -f $season, $covered[0]) }
                   else { ("S{0}E{1}-E{2}" -f $season, $covered[0], $covered[$covered.Count - 1]) }
        [void]$out.Add([pscustomobject]@{
            Action  = 'delete'
            Torrent = $t
            Reason  = ("phantom: it reports {0:N0}% complete but its data is gone, and the library holds {1} ({2}) in its place" -f `
                       ($t.progress * 100), $covDesc, $show)
        })
    }

    return $out
}

function Get-LibraryRedundantVerdicts {
    <#
        Rule 4d: stop downloading an episode the library already has.

        The rule as the user stated it:

            "when I already have a version of the episode with download completed,
             smaller, equal or bigger for less than 10% of the total size of
             complete episodes should be deleted and discarded on ongoing
             downloads... I'm talking about the size when the download WILL be
             finished, as soon as I know the size of the download, I should
             delete smaller versions of episodes I already have"

        Two things in that are load-bearing, and both are easy to get wrong:

        - It is the TOTAL size, not the downloaded bytes. qBittorrent knows a
          torrent's final size the moment its metadata resolves, so this fires at
          0% as well as at 80%. Progress is never consulted. That is the whole
          point of the rule: it saves the download, not the disk space after it.

        - It is measured against the LIBRARY, not against a cluster. Rule 4 can
          only compare releases whose show names share a first word, which is why
          115 Always Sunny torrents sat in four families that never met. The
          library folder is a grouping the manager already proved.

        The tolerance is what makes this safe rather than reckless. Two encodes of
        one episode differ by a few percent for reasons that have nothing to do
        with quality - different subtitle tracks, a different container, a
        different cut of the same source. Rule 4 deleted a 12,54 GB eight-episode
        pack over a 46 MB difference, so a plain "smaller" test is not enough.
        Inside the tolerance the two are the same episode and one is redundant;
        outside it, the download may genuinely be the better copy and is kept.

        For a PACK, nothing. A pack is not judged here at all.

        That is a correction, and it is the same principle already written into
        Get-PackEpisodeBytes: a pack's TOTAL is not a per-episode quantity and must
        never be compared with one. Summing the library's individual episode files
        and holding the result against a pack's total looks like a comparison but
        is not one - it is the total against the total, dressed up as an
        episode-level measurement. Two encodes of the same six episodes can differ
        by far more than 10% in total for reasons that have nothing to do with the
        episodes being redundant, and a pack whose total happens to land under the
        sum is not thereby a spare copy of anything.

        Pack against pack is decided in rule 4, by the episode SET key, which
        requires the two ranges to be identical: S18E01-E06 only ever competes with
        S18E01-E06, never with S18E01-E04. That is the only sound pack-to-pack
        comparison available, and it already exists.

        So this rule is single-episode only. A pack is left for rule 4.

        Also never touched:

        - a COMPLETE torrent. Rule 4b compares finished files in the library
          folder; this rule is only about downloads still in progress.
        - a torrent whose declared size is 0. That is a magnet that has not
          fetched metadata, and its size is unknown, not small.
        - a torrent compared against a library file that IT owns. That is its
          own data, and it is the normal case for a completed-then-moved torrent.

        Returns one row per redundant download. Deletes nothing.
    #>
    param(
        [object[]]$Torrents,
        [string]$MoviesDir,
        [string]$SeriesDir,
        [double]$TolerancePercent = 10,
        [hashtable]$Gone = @{},
        # titleAliases, forwarded to the folder resolver - see the note there.
        [object]$Aliases = $null
    )

    $out = New-Object System.Collections.ArrayList
    if ($TolerancePercent -lt 0) { $TolerancePercent = 0 }
    # "no more than N% bigger" - the user's "less than 10%" is applied as <=, so a
    # download exactly on the limit counts as within it.
    $limit = 1.0 + ($TolerancePercent / 100.0)

    foreach ($t in @($Torrents)) {
        if ($null -eq $t) { continue }
        if ($Gone.ContainsKey($t.hash)) { continue }

        # Only a download in progress, and only once its final size is known.
        if ([double]$t.progress -ge 1) { continue }
        if ([double]$t.size -le 0) { continue }
        if (-not $t.parts) { continue }

        $mine = [int64]$t.size

        if (-not $t.parts.IsSeries) {
            # A film: replaced by a file of the same name in the movies folder.
            $libFile = $null
            foreach ($ext in @('mkv', 'mp4', 'avi', 'm4v')) {
                $c = Join-Path $MoviesDir ($t.parts.Title + '.' + $ext)
                if (Test-Path -LiteralPath $c) { $libFile = Get-Item -LiteralPath $c; break }
            }
            if ($null -eq $libFile) { continue }
            # Its own file is not a rival.
            if ($null -ne (Test-Claimed -Path $libFile.FullName -Torrents @($t))) { continue }

            if ([int64]$libFile.Length -le 0) { continue }
            if ($mine -le ([int64]$libFile.Length * $limit)) {
                [void]$out.Add([pscustomobject]@{
                    Torrent  = $t
                    LibBytes = [int64]$libFile.Length
                    LibLabel = $libFile.Name
                    Scope    = "film '$($t.parts.Title)'"
                    Reason   = ("the library already has '{0}' at {1:N2} GB and this download will finish at {2:N2} GB, within the {3:N0}% tolerance" -f `
                                $libFile.Name, ($libFile.Length / 1GB), ($mine / 1GB), $TolerancePercent)
                })
            }
            continue
        }

        $season = $t.parts.Season
        if ($null -eq $season -or $season -le 0) { continue }
        if ($null -eq $t.parts.Episode) { continue }
        $show = $t.parts.Title
        if ([string]::IsNullOrWhiteSpace($show)) { continue }

        $first = [int]$t.parts.Episode

        # A PACK IS NOT JUDGED HERE. See the note at the top of this function: a
        # pack's total is not a per-episode quantity, and holding it against the
        # sum of individual library episodes is not a comparison. Rule 4 compares
        # packs with packs by exact episode range instead.
        if ($t.parts.IsMultiEpisode) { continue }

        # -Aliases, and load-bearing here for the same reason as in the phantom
        # rule: this one asks "does the library already hold this episode", and it
        # can only answer by looking where the library copy actually is. Without
        # the alias it looks in 'Euphoria Us' while the copy sits in 'Euphoria',
        # finds nothing, and the download is judged against a copy that is not
        # there - or missed, when one is.
        $showDir = Resolve-LibraryShowDir -SeriesDir $SeriesDir -Title $show -Aliases $Aliases
        if (-not $showDir) { continue }
        $seasonDir = Join-Path $showDir ("Season {0}" -f $season)
        $have = Get-LibraryEpisodeFiles -SeasonDir $seasonDir -Season $season

        if (-not $have.ContainsKey($first)) { continue }

        # The largest copy is the best one already held, so it is the fair thing to
        # measure against.
        $best = @(@($have[$first]) | Sort-Object -Property Length -Descending)[0]
        if ($null -eq $best -or $best.Length -le 0) { continue }

        # If this torrent owns that file, it is comparing against its own data.
        if ($null -ne (Test-Claimed -Path $best.FullName -Torrents @($t))) { continue }

        $sum = [int64]$best.Length
        $range = "S{0}E{1}" -f $season, $first

        # BIGGER THAN THE COPY IT WOULD REPLACE. Held, not deleted.
        #
        # The tolerance decides whether two encodes are the same episode. It does
        # NOT decide which one to keep - that is rule 4's job, and rule 4 says the
        # biggest finished copy wins. Deleting a download that would finish BIGGER
        # than the library copy takes away the very copy the next rule would have
        # kept, and leaves the smaller one in its place.
        #
        # Measured on a live queue, and it did exactly that:
        #
        #   2026-10-06 00:13:13 [DELETE] "Euphoria US S03E07 Rain or Shine 2160p"
        #     [4094aa89] - the library already has S3E7 at 8,16 GB and this download
        #     will finish at 8,43 GB, within the 10% tolerance
        #
        # 8,43 GB against 8,16 GB is 3,4% - inside the tolerance, so this rule
        # fired. The torrent was at 0%. Had it finished, rule 4 would have kept it
        # and deleted the 8,16 GB copy, which is the opposite of what happened.
        #
        # So the comparison is made in the direction that matters: this download is
        # redundant only if it is NOT the better copy. Larger than the library copy
        # means rule 4 would keep it and drop that one instead, so removing it now
        # is removing the winner.
        #
        # The 10% tolerance is untouched. It still governs everything below - a
        # download equal to or smaller than the library copy is redundant whatever
        # the gap, and is deleted as before.
        if ($mine -gt $sum) {
            [void]$out.Add([pscustomobject]@{
                Torrent  = $t
                LibBytes = $sum
                LibLabel = $best.Name
                Scope    = "$show $range"
                Action   = 'hold'
                Reason   = ("this download will finish at {0:N2} GB against the library's {1:N2} GB of {2}, so it is the BIGGER copy - held. Rule 4 keeps the largest finished version, and that would be this one; the library copy is what would go." -f `
                            ($mine / 1GB), ($sum / 1GB), $range)
            })
            continue
        }

        if ($mine -le ($sum * $limit)) {
            [void]$out.Add([pscustomobject]@{
                Torrent  = $t
                LibBytes = $sum
                LibLabel = $best.Name
                Scope    = "$show $range"
                Action   = 'delete'
                Reason   = ("the library already has {0} at {1:N2} GB and this download will finish at {2:N2} GB, within the {3:N0}% tolerance" -f `
                            $range, ($sum / 1GB), ($mine / 1GB), $TolerancePercent)
            })
        }
    }

    return $out
}

function Get-ReapCandidates {
    param(
        [string[]]$Roots,
        [object[]]$Torrents,
        [double]$MinAgeHours,
        [string[]]$ExcludeDirs = @(),
        [datetime]$Now
    )

    # @() is load-bearing, not decoration: Test-Unlocatable unrolls a
    # single-element array on output, and a lone PSCustomObject has no .Count
    # in PowerShell 5.1, so an unwrapped result makes the guard below silently
    # evaluate false exactly when one torrent is unlocatable.
    $stray = @(Test-Unlocatable -Torrents $Torrents)
    if ($stray.Count -gt 0) {
        $why = "$($stray.Count) torrent(s) hold downloaded bytes but report no content_path " +
               "(e.g. '$($stray[0].name)'), so an unclaimed folder cannot be told apart from " +
               'an active download; reaping skipped for this run'
        return [pscustomobject]@{ Candidates = @(); Skipped = @(); Blocked = $why }
    }

    $excl = @($ExcludeDirs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
              ForEach-Object { $_.TrimEnd('\', '/') })

    $cand = New-Object System.Collections.ArrayList
    $skip = New-Object System.Collections.ArrayList

    foreach ($root in ($Roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $r = $root.TrimEnd('\', '/')

        if (@($excl | Where-Object { $r.Equals($_, [StringComparison]::OrdinalIgnoreCase) -or
                                     $r.StartsWith($_.ToString() + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
            [void]$skip.Add([pscustomobject]@{ Path = $r; Reason = 'reap root is an excluded directory' })
            continue
        }
        if (-not (Test-Path -LiteralPath $r -PathType Container)) {
            [void]$skip.Add([pscustomobject]@{ Path = $r; Reason = 'reap root does not exist' })
            continue
        }

        foreach ($it in @(Get-ChildItem -LiteralPath $r -Force -ErrorAction SilentlyContinue)) {
            $full = $it.FullName

            if (@($excl | Where-Object { $full.Equals($_.ToString(), [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
                [void]$skip.Add([pscustomobject]@{ Path = $full; Reason = 'excluded directory' })
                continue
            }

            # A junction would send the recursive delete outside the root, and
            # nothing in the name says where it points.
            if ($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                [void]$skip.Add([pscustomobject]@{ Path = $full; Reason = 'reparse point / link, not followed' })
                continue
            }

            $owner = Test-Claimed -Path $full -Torrents $Torrents
            if ($null -ne $owner) {
                [void]$skip.Add([pscustomobject]@{ Path = $full; Reason = "claimed by '$($owner.name)'" })
                continue
            }

            $idleH = ($Now - $it.LastWriteTime).TotalHours
            if ($idleH -lt $MinAgeHours) {
                [void]$skip.Add([pscustomobject]@{ Path = $full; Reason = ('touched {0:N1}h ago, need {1:N0}h' -f $idleH, $MinAgeHours) })
                continue
            }

            $bytes = [int64]0
            if ($it.PSIsContainer) {
                $sum = Get-ChildItem -LiteralPath $full -Recurse -Force -File -ErrorAction SilentlyContinue |
                       Measure-Object -Property Length -Sum
                if ($sum.Sum) { $bytes = [int64]$sum.Sum }
            }
            else {
                $bytes = [int64]$it.Length
            }

            [void]$cand.Add([pscustomobject]@{
                Path      = $full
                IsDir     = [bool]$it.PSIsContainer
                Bytes     = $bytes
                IdleHours = $idleH
                LastWrite = $it.LastWriteTime
            })
        }
    }

    return [pscustomobject]@{ Candidates = @($cand); Skipped = @($skip); Blocked = $null }
}

function Get-SetKeySpan {
<#
    The episodes a set key stands for, as a span.

        S3-E7      season 3, one episode
        S3-E1-E10  season 3, episodes 1 to 10
        S3-ALL     a whole season - first 1, last 999
        film       not a series
        ""         unknown, and unknown means take no part

    The empty key is the important one. It is what a release whose episodes cannot
    be established returns, and this function reports it as unknown rather than
    guessing a range - because a guessed range here would BLOCK every settle it
    touched, and an unblocked settle is the dangerous direction.
#>
    param([string]$Key)

    if ([string]::IsNullOrWhiteSpace($Key)) {
        return [pscustomobject]@{ Known = $false; IsFilm = $false; Season = $null; First = $null; Last = $null }
    }
    if ($Key -eq 'film') {
        return [pscustomobject]@{ Known = $true; IsFilm = $true; Season = $null; First = $null; Last = $null }
    }
    if ($Key -match '^S(\d+)-ALL$') {
        return [pscustomobject]@{ Known = $true; IsFilm = $false; Season = [int]$Matches[1]; First = 1; Last = 999 }
    }
    if ($Key -match '^S(\d+)-E(\d+)-E(\d+)$') {
        return [pscustomobject]@{ Known = $true; IsFilm = $false; Season = [int]$Matches[1]; First = [int]$Matches[2]; Last = [int]$Matches[3] }
    }
    if ($Key -match '^S(\d+)-E(\d+)$') {
        return [pscustomobject]@{ Known = $true; IsFilm = $false; Season = [int]$Matches[1]; First = [int]$Matches[2]; Last = [int]$Matches[2] }
    }
    return [pscustomobject]@{ Known = $false; IsFilm = $false; Season = $null; First = $null; Last = $null }
}

function Test-SetKeyCovers {
<#
    Does one set key cover a given episode?

    Used to ask the settle question: "is there anything unfinished that still
    holds this episode". A pack that spans 1 to 10 covers episode 7; a single
    episode 7 does not cover episode 8.

    Unknown keys cover NOTHING. A release whose episodes cannot be established
    does not get to hold up everything else on the strength of a guess - and it
    does not get to be settled either, which is the other half of the same
    refusal and is enforced by the caller.
#>
    param(
        [string]$Key,
        [int]$Season,
        [int]$Episode
    )

    $span = Get-SetKeySpan -Key $Key
    if (-not $span.Known) { return $false }
    if ($span.IsFilm) { return $false }
    if ($span.Season -ne $Season) { return $false }
    return ($Episode -ge $span.First -and $Episode -le $span.Last)
}

function Test-SpanOverlap {
<#
    Do two set keys hold anything in common?

    This is the question the settle rule actually asks of a rival release, and
    asking it per episode instead is both slower and wrong at the edges: a whole-
    season key spans 1 to 999, so the per-episode form asks 991 questions about
    episodes a pack of eight does not have.

    Unknown never overlaps. A release whose episodes cannot be established holds
    nothing that can be shown to be in common - see Get-SettleVerdicts for why
    that asymmetry is safe here and would not be safe in a deleting rule.
#>
    param($A, $B)

    if ($null -eq $A -or $null -eq $B) { return $false }
    if (-not $A.Known -or -not $B.Known) { return $false }
    if ($A.IsFilm -or $B.IsFilm) { return $false }
    if ($A.Season -ne $B.Season) { return $false }
    return ($A.First -le $B.Last -and $B.First -le $A.Last)
}

function Get-SettleVerdicts {
<#
        Rule 3b: a finished media file that nothing unfinished can improve is cut
        out of its download folder into the flat library, and the torrent entry is
        removed with its data left alone.

        WHY IT IS SEPARATE FROM RULE 3. Rule 3 moves a completed torrent into the
        library as soon as it completes, which is right - the bytes belong in the
        library either way. But it is not the last word on those bytes. A pack
        that landed as Season 3\Euphoria S03 2160p\*.mkv has put eight episodes in
        a folder the library rules then have to unpick, and a season folder is
        meant to hold episodes, not packs.

        This rule runs after rule 3, on what is already in the library, and asks
        the question rule 3 has no reason to ask: is this file the best version
        that will ever arrive?

        THE CONDITION, and it is deliberately stricter than "could be bigger".
        Nothing unfinished may hold any of this torrent's episodes - not a bigger
        download, not a smaller one, not a stopped entry, not a magnet with no
        size at all. The user's rule is that the move happens when there is no
        longer any possibility of a better version, and a magnet is the one thing
        whose size is unknown: treating it as harmless would mean settling on the
        strength of not knowing. So:

            settled  <=>  no unfinished torrent covers any episode it holds

        ALL OR NOTHING, PER TORRENT. This is the part that is not a preference.
        Moving one file out from under a LIVE torrent entry means qBittorrent
        rechecks, finds that file missing, and fetches it again - so the entry has
        to go in the same breath, and it can only go once every one of its media
        files has landed. A pack whose episode 1 is settled but whose episode 2 is
        still beatable therefore waits in full, and that is the cost of not
        re-downloading episode 1. Partial relocation is never attempted.

        WHAT MOVES. Only the media file: mkv, mp4, avi, m4v. .nfo, .txt, samples
        and subtitles stay where they are, which is what the user does by hand -
        the Euphoria season folder holds eight .mkv files and nothing else.

        UNKNOWN IS THE REASON TO WAIT. A torrent with no media file in its listing
        is not settled, because there is nothing to say it holds one. An
        unidentifiable episode is not settled either. Refusing here costs a
        postponement; acting on a guess costs the file.
#>
    param(
        [object[]]$Torrents,
        [hashtable]$Gone = @{},
        [scriptblock]$FileLister,
        [string]$MoviesDir,
        [string]$SeriesDir,
        [object]$Aliases = $null
    )

    $out = @{}

    $live = @($Torrents | Where-Object { $null -ne $_ })
    $fileCache = @{}

    # Every set key in the run, resolved once. The blocking question is asked
    # against this list rather than against the API, so it costs nothing.
    $keys = @{}
    $spanCache = @{}
    foreach ($t in $live) {
        if ($Gone.ContainsKey($t.hash)) { continue }
        $k = ''
        try { $k = Resolve-TorrentSetKey -T $t -Cache $fileCache } catch { $k = '' }
        $keys[$t.hash] = $k
    }

    foreach ($t in $live) {
        if ($Gone.ContainsKey($t.hash)) { continue }

        # Only a finished torrent has media worth settling.
        if ([double]$t.progress -lt 1) { continue }
        if (-not $t.parts) { continue }

        $key = [string]$keys[$t.hash]
        $span = Get-SetKeySpan -Key $key
        if (-not $span.Known) {
            # The episodes could not be established, so nothing can be said about
            # what else might hold them. Wait.
            continue
        }

        $files = @()
        try { $files = @(& $FileLister $t.hash) } catch { $files = @() }
        if ($files.Count -eq 0) { continue }

        $media = @($files | Where-Object { [string]$_.name -match '(?i)\.(mkv|mp4|avi|m4v)$' })
        if ($media.Count -eq 0) { continue }

        # What is still out there that holds the same thing?
        #
        # Asked as a SPAN OVERLAP rather than episode by episode. A whole-season key
        # spans 1 to 999, so the per-episode form tested every episode in the season
        # against every torrent in the run - which is both slow and, for a season
        # pack that really holds eight episodes, 991 questions about episodes it
        # does not have. The overlap asks the question that is actually being asked:
        # do these two releases hold anything in common?
        #
        # An UNIDENTIFIABLE torrent does not block, and that asymmetry is
        # deliberate. It cannot be placed, so there is no evidence it holds this
        # episode - and blocking on it would let one unparseable release freeze
        # every settle in the run indefinitely. It is safe to let it pass because
        # this rule MOVES files and never deletes them: settling while a better
        # version is still coming leaves a valid copy in the library, and the better
        # version simply downloads afterwards. The rules that delete cannot afford
        # that; this one can.
        $blockers = @()
        $myTitle = [string]$t.parts.Title
        foreach ($u in $live) {
            if ($u.hash -eq $t.hash) { continue }
            if ($Gone.ContainsKey($u.hash)) { continue }
            if ([double]$u.progress -ge 1) { continue }
            $us = Get-SetKeySpan -Key ([string]$keys[$u.hash])
            if (-not $us.Known) { continue }
            if ($span.IsFilm) {
                if (-not $us.IsFilm) { continue }
                if (-not $u.parts) { continue }
                if ([string]$u.parts.Title -ne $myTitle) { continue }
            }
            else {
                if ($us.IsFilm) { continue }
                if (-not (Test-SpanOverlap -A $span -B $us)) { continue }
            }
            $blockers += $u
        }

        $blockers = @($blockers | Sort-Object -Property hash -Unique)
        if ($blockers.Count -gt 0) {
            $names = @($blockers | ForEach-Object { $_.name })
            if ($names.Count -gt 2) { $names = @($names[0..1]) + @("... and " + ($blockers.Count - 2) + " more") }
            $out[$t.hash] = [pscustomobject]@{
                Verdict = 'WAIT'
                Torrent = $t
                Files   = @()
                Reason  = ("held back: {0} unfinished torrent(s) still hold {1} - {2}" -f `
                           $blockers.Count, $(if ($span.IsFilm) { "'" + $myTitle + "'" } else { "S$($span.Season)E$($span.First)-E$($span.Last)" }), ($names -join '; '))
            }
            continue
        }

        # Settled. The destination is the library folder rule 3 already chose,
        # with the file at the top of it rather than inside a pack's subfolder.
        $dir = ''
        try { $dir = Get-LibraryTargetDir -T $t -MoviesDir $MoviesDir -SeriesDir $SeriesDir -Aliases $Aliases }
        catch { $dir = '' }

        # A series file must land under <series>/<show>/Season N. Get-LibraryTargetDir
        # returns the series ROOT when the show folder cannot be resolved - which it
        # does whenever the series directory itself is missing - and a file dropped in
        # that root is not filed anywhere, it is simply loose, and every later rule
        # that works per show folder would never see it again. An empty destination is
        # caught by the obvious test; this one is not empty, so it needs its own.
        $badDir = [string]::IsNullOrWhiteSpace($dir)
        if (-not $badDir -and -not $span.IsFilm -and $SeriesDir) {
            if ($dir.TrimEnd('\') -ieq $SeriesDir.TrimEnd('\')) { $badDir = $true }
        }
        if ($badDir) {
            $out[$t.hash] = [pscustomobject]@{
                Verdict = 'WAIT'
                Torrent = $t
                Files   = @()
                Reason  = ("no show folder could be resolved under '{0}' - the file stays put rather than landing loose in the series root" -f $SeriesDir)
            }
            continue
        }

        $plan = @()
        foreach ($f in $media) {
            $name = [string]$f.name
            $leaf = Split-Path -Leaf $name
            $plan += [pscustomobject]@{
                Name  = $name
                Leaf  = $leaf
                Bytes = [int64]$f.size
                Path  = (Join-Path $t.content_path $name)
                Target = (Join-Path $dir $leaf)
            }
        }

        $out[$t.hash] = [pscustomobject]@{
            Verdict = 'SETTLE'
            Torrent = $t
            Dir     = $dir
            Files   = $plan
            Reason  = ("finished, and nothing unfinished holds {0} - {1} media file(s) settled into {2}" -f `
                       $(if ($span.IsFilm) { "the film '" + $t.parts.Title + "'" } else { "S$($span.Season)E$($span.First)-E$($span.Last)" }), $plan.Count, $dir)
        }
    }

    return $out
}

# ---------------------------------------------------------------------------
# actions
# ---------------------------------------------------------------------------

# Is this torrent in qBittorrent's ERROR state?
#
# An errored torrent is NOT a deletion candidate, by instruction. The reason is
# the partial data: with deleteDataFiles on, removing an errored entry destroys
# whatever it managed to fetch, and an error is usually a transient or external
# fault - a disk that filled, a path that moved, a tracker that went away - not a
# verdict on the torrent. Deleting the entry throws away the only record that it
# existed and of how far it got.
#
# THE EXCEPTIONS, where -AllowErrored is passed and an errored torrent IS deleted:
#
#   - DoVi and disc rip. Both are unconditional by specification - "in any state" -
#     and both decide from the torrent's NAME and on-disk structure, never from
#     how it is progressing. There is no judgement for an error to have corrupted,
#     so protecting these was an over-reach.
#
#   - Dedup's set-level comparison. An errored torrent is deleted there when a
#     FINISHED torrent of the IDENTICAL episode set is bigger: pack against pack of
#     the same range, or one episode against itself, never a pack against a
#     different pack and never against a single. The keeper is complete and holds
#     the same episodes, so the errored one is a spare copy that failed rather
#     than data held only once.
#
# WHAT STAYS PROTECTED, and why the distinction matters: pack-vs-single. There the
# comparison is between a pack's own file for ONE episode and a single's file for
# that episode - and the pack's other episodes have nothing to say about it. That
# is the comparison that deleted a 12,54 GB E01-E08 pack over a 46 MB difference
# in one episode, stranding seven files that existed nowhere else. Deleting an
# errored single there could strand a pack the same way, so an errored single is
# left alone. Everything else - no-availability, stalled, redundant download,
# phantom - also keeps the protection, because each of those judges a torrent on
# its progress or its availability, which is exactly what an error corrupts.
#
# The guard lives at this single chokepoint every rule passes through, rather than
# being repeated at eleven call sites where it would drift.
#
# 'error' is the API spelling; the Web UI shows it as "Error" / "Errored". Only
# that exact state is protected - 'stalledDL', 'missingFiles' and friends are
# NOT errors and remain subject to every rule as before.
function Test-Errored {
    param([object]$T)
    if ($null -eq $T) { return $false }
    return ([string]$T.state -eq 'error')
}

# Stop a torrent and CONFIRM it stopped.
#
# `torrents/stop` returning HTTP 200 says the request was accepted, not that the
# torrent has stopped. qBittorrent tears down connections first, so there is a
# window where the entry still reads 'uploading' or 'downloading'. That window is
# not academic: a finished torrent was stopped and deleted in the same breath
# once, and the state read immediately afterwards still said 'queuedUP'.
#
# A delete issued inside that window races the running torrent, and a running
# torrent re-fetches whatever is deleted underneath it - so the duplicate returns
# on the next run and the delete looks as though it did nothing.
#
# Returns $true only when the torrent is stopped, already stopped, or gone.
# Is a bigger copy of this content still on its way?
#
# Returns a sentence naming it, or '' when nothing incoming threatens this entry.
# This is a different question from -Knows, and neither replaces the other:
#
#   -Knows      did a rule SEE a keeper?
#   this        is something BIGGER still arriving?
#
# A rule can pass the first honestly and still be wrong, because the thing that
# would beat the keeper does not exist yet. Measured on a live queue:
#
#   S3E7  unfinished 8,43 GB @  0%   beats  finished 8,16 GB
#   S4E8  unfinished 9,03 GB @ 63%   beats  finished 7,72 GB
#
# Deleting a finished copy because a bigger one is coming is losing data on credit.
# The credit is never called in: the replacement can fail, stall, be removed by
# another rule, or turn out to be unseeded. By then the smaller copy is gone and the
# episode is not on disk.
#
# COMPARED ON DECLARED SIZE, and a magnet is never a threat. A magnet has no size,
# so it could be anything. Treating "unknown" as "bigger" would mean no finished
# copy could ever be judged redundant by any rule that consults this, which is not
# a safety property - it is the rule switched off.
#
# Only single episodes are matched. A pack's total says nothing about any one
# episode, and the same rule-4 reasoning applies: comparing totals across kinds is
# how a pack gets deleted for being smaller than something that covers none of its
# episodes.
function Get-IncomingBetterVerdict {
    param(
        [object]$T,
        [object[]]$Torrents
    )

    if (-not $T -or -not $T.parts -or -not $T.parts.IsSeries) { return '' }
    if ($null -eq $T.parts.Season -or $null -eq $T.parts.Episode) { return '' }
    if ($T.parts.Episode -lt 1) { return '' }
    if ($T.parts.IsMultiEpisode) { return '' }

    $mine = [double]$T.size
    if ($mine -le 0) { return '' }

    $season = [int]$T.parts.Season
    $episode = [int]$T.parts.Episode
    $show = [string]$T.parts.Title

    $best = $null
    foreach ($o in @($Torrents)) {
        if ($null -eq $o -or [string]::IsNullOrWhiteSpace([string]$o.hash)) { continue }
        if ([string]$o.hash -eq [string]$T.hash) { continue }
        if (-not $o.parts -or -not $o.parts.IsSeries) { continue }
        if ($o.parts.IsMultiEpisode) { continue }
        if ($null -eq $o.parts.Season -or $null -eq $o.parts.Episode) { continue }
        if ([int]$o.parts.Episode -ne $episode) { continue }

        # A different show entirely is a different episode. Compared on the
        # leading run of the title, the same way the dedup pass groups them, so
        # 'the office' and 'the bear' can never meet here.
        if (-not (Test-SameTitle -A $T.parts -B $o.parts)) { continue }

        $size = [double]$o.size
        if ($size -le 0) { continue }
        if ($size -le $mine) { continue }
        # Already finished: that is a keeper a rule can SEE, which is -Knows's
        # business, not this one's.
        if ([double]$o.progress -ge 1) { continue }

        if ($null -eq $best -or $size -gt [double]$best.size) { $best = $o }
    }

    if ($null -eq $best) { return '' }

    $pct = [double]$best.progress * 100
    return ("'{0}' [{1}] is still downloading S{2}E{3} and will finish at {4:N2} GB against this entry's {5:N2} GB - it is {6:N1}% done" -f `
            $best.name, $best.hash.Substring(0, 8), $season, $episode, ([double]$best.size / 1GB), ($mine / 1GB), $pct)
}

function Stop-TorrentAndConfirm {
    param(
        [object]$T,
        [int]$Attempts = 5,
        [int]$WaitMs = 400
    )

    if (-not $T -or [string]::IsNullOrWhiteSpace($T.hash)) { return $true }

    $last = [string]$T.state
    # 'error' joins the settled states. An errored torrent is not running and
    # cannot start writing, so there is no writer to race - and stopping it would
    # change its state, which is precisely the record that says why it must not be
    # deleted. A rule that legitimately deletes an errored torrent would otherwise
    # alter the evidence on its way past.
    if ($last -match '^(stopped|paused|error)') { return $true }

    Invoke-ApiPost -Endpoint 'torrents/stop' -Fields @{ hashes = $T.hash } | Out-Null

    for ($i = 0; $i -lt $Attempts; $i++) {
        Start-Sleep -Milliseconds $WaitMs
        $now = $null
        try { $now = Invoke-ApiGet -Endpoint 'torrents/info' } catch { $now = $null }
        if ($null -eq $now) { continue }

        foreach ($x in @($now)) {
            if ([string]$x.hash -ne [string]$T.hash) { continue }
            $last = [string]$x.state
            if ($last -match '^(stopped|paused|error|moving|missingFiles)') { return $true }
        }
        # Not in the listing at all: it is gone, which is what we wanted.
        return $true
    }

    Write-Log 'WARN' ("'{0}' did not confirm stopped (last state '{1}') after {2} attempt(s)" -f $T.name, $last, $Attempts)
    return $false
}

function Remove-Torrent {
    param(
        [object]$T,
        [string]$Reason,
        # Per-call override for the data-file question. $null means "follow
        # config". Typed as [object] rather than [Nullable[bool]] because a
        # nullable value type parameter is easy to coerce into $false by
        # accident, and the failure would be silent data left on disk.
        [object]$DeleteFiles = $null,
        # Escape hatch, used by exactly ONE rule: dedup's set-level comparison.
        # An errored torrent is deleted there only when a FINISHED torrent of the
        # IDENTICAL episode set is bigger - pack against pack of the same range, or
        # the same episode against itself - so nothing unique is lost. See the
        # comment at that call site. It exists so that "protected" stays a decision
        # someone makes on purpose rather than a wall.
        [switch]$AllowErrored,
        # The rule has ESTABLISHED that a better copy of this content exists -
        # a finished torrent it compared against, or a file in the library - rather
        # than merely failing to find one. Required to delete a FINISHED entry.
        #
        # This is the burden of proof, inverted. Every verdict here is reached from
        # a partial view: a snapshot of the queue, a library that may be mid-move,
        # an owning entry that may not be loaded. A rule that did not find another
        # copy has not established that this is the only one.
        #
        # Deleting a 40 GB season pack on the strength of one 5,61 GB duplicate file
        # is what that costs. The pack was found to be the smaller version of one
        # episode, and six other episodes went with it.
        [switch]$Knows,
        # Escape hatch for the incoming-better-copy guard, for the rules whose
        # verdict cannot be about a copy at all.
        #
        # DoVi and disc rip: their evidence is the release's own NAME or the
        # on-disk disc structure. There is no comparison between copies to be
        # pre-empted by a better one - if the best copy of an episode anywhere
        # carries a DV marker, it still goes, because the rule is about the format
        # the library does not hold and was specified "in any state".
        #
        # Duplicate comparisons also pass it after establishing a finished keeper.
        # An unfinished incoming copy alone is never grounds to remove that keeper.
        [switch]$AllowIncomingBetter
    )
    if ($script:gone.ContainsKey($T.hash)) { return }

    # THE PROTECTION. Placed BEFORE $script:gone is marked, so a refused torrent is
    # not recorded as dealt with and a later rule in the same run can still report
    # on it.
    if (-not $AllowErrored -and (Test-Errored $T)) {
        $label = '"{0}" [{1}]' -f $T.name, $T.hash.Substring(0, 8)
        [void]$script:notes.Add("KEPT (errored)  $label - $Reason")
        Write-Log 'WARN' "$label left alone: qBittorrent reports it as errored, and an errored entry is not a deletion candidate"
        return
    }

    # THE BURDEN OF PROOF. Not knowing is the reason to keep something.
    #
    # Every rule here reaches its verdict from a view that is necessarily partial:
    # the torrent list is a snapshot, the library may be mid-move, a file's owning
    # entry may not be loaded, a file listing may be unreadable. A rule that cannot
    # establish what else exists has not established that this is the only copy -
    # it has established that it did not find another one.
    #
    # Those are different, and only the second one is evidence. Deleting on it is
    # how a 40 GB pack was destroyed: the library held one copy of an episode, the
    # rule found it was smaller than another, and removing the entry took six other
    # episodes that existed nowhere else.
    #
    # So a rule that deletes a FINISHED torrent must say what it knows, by passing
    # -Knows. "Finished" is the trigger because a finished entry is a statement
    # about data that exists: its content is on disk, and removing the entry cannot
    # be undone by re-downloading. An unfinished entry is deleted with its partial
    # data, which is small, already unwanted, and what the rule was written for.
    #
    # A rule passing -Knows is claiming its comparison is against a keeper it has
    # actually SEEN - a finished torrent, or a file in the library - not against the
    # absence of one. DoVi and disc rip pass it because their verdict comes from the
    # release's own name and on-disk structure, so there is nothing further to know.
    #
    # Without -Knows, the entry stays and says why. It costs a row and some disk. The
    # alternative costs the data.
    if (-not $Knows -and [double]$T.progress -ge 1) {
        $label = '"{0}" [{1}]' -f $T.name, $T.hash.Substring(0, 8)
        [void]$script:notes.Add("KEPT (nothing established it is a copy)  $label - $Reason")
        Write-Log 'WARN' ("$label left in the list: it is finished, and no rule established that another copy of it exists. Not knowing is the reason to keep it - the queue and the library are both only a partial view.")
        return
    }

    # A BETTER COPY THAT HAS NOT ARRIVED YET.
    #
    # -Knows asks whether a rule saw a keeper. It cannot ask whether something
    # bigger is on its way, because that thing does not exist yet: it is at 0%, or
    # it is a magnet, or it has not been added. Deleting a finished copy on the
    # promise of a bigger one is losing data on credit, and the credit is never
    # called in - the replacement may fail, stall, or be removed by another rule,
    # and by then the smaller copy is gone and the episode is not on disk.
    #
    # Measured on a live queue, six pairs where an unfinished download would beat a
    # finished one, including one at 0%:
    #
    #   S3E7  unfinished 8,43 GB @  0%   beats  finished 8,16 GB
    #   S4E8  unfinished 9,03 GB @ 63%   beats  finished 7,72 GB
    #   S3E1  unfinished 8,44 GB @ 11%   beats  finished 8,44 GB
    #
    # The comparison is on DECLARED size, which a magnet does not have. A magnet is
    # therefore never treated as a threat - it could be anything, and treating
    # "unknown" as "bigger" would mean no finished copy could ever be judged
    # redundant by any rule that consults this.
    if (-not $AllowIncomingBetter -and [double]$T.progress -ge 1) {
        $better = Get-IncomingBetterVerdict -T $T -Torrents @($script:liveTorrents)
        if ($better) {
            $label = '"{0}" [{1}]' -f $T.name, $T.hash.Substring(0, 8)
                # The incoming torrent goes in the NOTE as well as the log. The log is
            # where a human looks afterwards, but the notes are what the run's own
            # summary prints - and "kept" with no reason given is the kind of line
            # that gets read as a bug.
            [void]$script:notes.Add("KEPT (a bigger copy is still downloading)  $label - $Reason - $better")
            Write-Log 'WARN' ("$label left in the list: $better")
            return

        }
    }

    $label = '"{0}" [{1}] - {2}' -f $T.name, $T.hash.Substring(0, 8), $Reason
    $script:gone[$T.hash] = $true

    if ($DryRun) {
        [void]$script:actions.Add("WOULD DELETE  $label")
        Write-Log 'DELETE' "[DRY-RUN] $label"
        return
    }

    $wantFiles = if ($null -ne $DeleteFiles) { [bool]$DeleteFiles } else { [bool]$cfg.deleteDataFiles }
    $deleteFiles = 'false'
    if ($wantFiles) { $deleteFiles = 'true' }

    # Stop first, and do not go on unless the stop is CONFIRMED. There used to be
    # no stop here at all, which meant a running torrent could be deleted from
    # under itself - and a running torrent re-fetches whatever is taken away, so
    # the file came back and the delete read as a no-op.
    #
    # A torrent that will not confirm stopped is NOT deleted. Leaving a duplicate
    # on disk costs space; deleting under a live writer costs the write.
    #
    # $script:gone is UNSET here, not just the delete skipped. It is set further up,
    # before the dry-run branch, so that everything past this point is final. A
    # refusal that left it set would mark the torrent as dealt with while it is
    # still in the list - and every later rule would skip it as already handled, so
    # a torrent kept for being mid-write would silently never be reconsidered.
    if (-not (Stop-TorrentAndConfirm -T $T)) {
        $script:gone.Remove($T.hash)
        [void]$script:notes.Add(('KEPT (still running)  "{0}" [{1}] - {2}' -f $T.name, $T.hash.Substring(0, 8), $Reason))
        return
    }

    Invoke-ApiPost -Endpoint 'torrents/delete' -Fields @{
        hashes      = $T.hash
        deleteFiles = $deleteFiles
    }
    [void]$script:actions.Add("DELETED  $label")
    Write-Log 'DELETE' $label
}

# Polls qBittorrent until the move either shows up or the ceiling is reached.
# The first check happens before any sleep so a move that already succeeded -
# a rename on the same volume - costs one API call and no waiting at all.
function Wait-MoveVerified {
    param(
        [string]$Hash,
        [string]$TargetDir,
        [int]$TimeoutSeconds = 30,
        [int]$PollMs = 500
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $tries = 0
    $last = ''

    while ($true) {
        $tries++
        $fresh = @(Invoke-ApiGet -Endpoint ("torrents/info?hashes=$Hash"))

        if ($fresh.Count -eq 0) {
            return [pscustomobject]@{
                Ok    = $false
                Tries = $tries
                Path  = ''
                Why   = 'the torrent vanished from qBittorrent while the move was in flight'
            }
        }

        $last = [string]$fresh[0].content_path
        if (Test-MoveSettled -T $fresh[0] -TargetDir $TargetDir) {
            return [pscustomobject]@{ Ok = $true; Tries = $tries; Path = $last; Why = '' }
        }

        if ((Get-Date) -ge $deadline) { break }
        if ($PollMs -gt 0) { Start-Sleep -Milliseconds $PollMs }
    }

    return [pscustomobject]@{
        Ok    = $false
        Tries = $tries
        Path  = ''
        Why   = ("qBittorrent still reports content_path '{0}' after {1}s and {2} check(s), " +
                 'so the move did not happen') -f $last, $TimeoutSeconds, $tries
    }
}

function Move-ToLibrary {
    param(
        [object]$T,
        [string]$TargetDir,
        # The run's torrent list, used only to ask whether somebody else is
        # holding this folder. $Gone removes what this run already deleted.
        [object[]]$Live = @(),
        [hashtable]$Gone = @{},
        [int]$VerifySeconds = 30,
        [int]$PollMs = 500
    )

    $plan = Get-MovePlan -T $T -Torrents $Live -TargetDir $TargetDir -Gone $Gone

    if ($plan.Action -eq 'skip') {
        [void]$script:notes.Add("already in library: $($T.name)")
        return
    }

    $label = '"{0}" -> {1}' -f $T.name, $TargetDir

    if ($plan.Action -eq 'block') {
        # Not asked, because asking cannot work: the folder is held by a torrent
        # that is still wanted, and the request would be queued, fail, and be
        # reported as a success - which is what happened on every 15 minute run
        # before this rule existed.
        Write-Host ("  BLOCKED  {0}" -f $label)
        [void]$script:notes.Add(("blocked: {0} - {1}" -f $label, $plan.Reason))
        Write-Log 'WARN' ("move blocked: {0} - {1}" -f $label, $plan.Reason)
        return
    }

    if ($DryRun) {
        [void]$script:actions.Add("WOULD MOVE  $label")
        Write-Log 'MOVE' "[DRY-RUN] $label"
        return
    }

    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }
    Invoke-ApiPost -Endpoint 'torrents/setLocation' -Fields @{
        hashes   = $T.hash
        location = $TargetDir
    }

    # A 200 here means the move was QUEUED. Whether the bytes arrived is a
    # separate question and is asked separately, because a queue that never
    # drains is indistinguishable from a queue that did unless you look.
    $check = Wait-MoveVerified -Hash $T.hash -TargetDir $TargetDir `
                               -TimeoutSeconds $VerifySeconds -PollMs $PollMs

    if ($check.Ok) {
        # Keep the in-memory copy truthful: later rules in this same run read
        # these fields and must not be told the files are still in temp.
        $T.content_path = $check.Path
        $T.save_path = $TargetDir
        [void]$script:actions.Add("MOVED  $label")
        Write-Log 'MOVE' $label
    }
    else {
        Write-Host ("  FAILED   {0}" -f $label)
        [void]$script:notes.Add(("move failed: {0} - {1}" -f $label, $check.Why))
        Write-Log 'WARN' ("move failed: {0} - {1}" -f $label, $check.Why)
    }
}

# Reap totals are usually tens of GB, but a small leftover should not be logged
# as "0 GB".
function Format-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [int64]$Bytes)
}

# Deletes one reaper candidate. The containment check is repeated here on
# purpose: the candidate list was built earlier in the run, and a path that is
# no longer strictly inside a reap root is not ours to delete. Nothing here
# consults the candidate list, so a caller cannot smuggle a path through.
function Remove-OrphanPath {
    param(
        [string]$Path,
        [string[]]$Roots
    )

    $inside = $false
    foreach ($r in @($Roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $rn = $r.TrimEnd('\', '/')
        # strictly inside, so a root can never delete itself
        if ($Path.StartsWith($rn + '\', [StringComparison]::OrdinalIgnoreCase)) { $inside = $true; break }
    }
    if (-not $inside) {
        Write-Log 'WARN' "refusing to delete '$Path': not inside a reap root"
        return $false
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log 'INFO' "reap target '$Path' is already gone"
        return $true
    }

    if ($DryRun) {
        Write-Log 'ACTION' "[DRY-RUN] would reap orphan '$Path'"
        $script:notes += "would reap $(Split-Path -Leaf $Path)"
        return $true
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        $script:actions += "REAP $(Split-Path -Leaf $Path)"
        Write-Log 'DELETE' "reaped orphan '$Path'"
        return $true
    }
    catch {
        Write-Log 'WARN' "could not reap '$Path': $($_.Exception.Message)"
        return $false
    }
}

function Ensure-Category {
    param(
        [string]$Name, [string]$SavePath)
    $existing = Invoke-ApiGet -Endpoint 'torrents/categories'
    if ($existing.PSObject.Properties.Name -contains $Name) { return }
    if ($DryRun) {
        Write-Log 'ACTION' "[DRY-RUN] would create category '$Name' (savePath: $SavePath)"
        return
    }
    Invoke-ApiPost -Endpoint 'torrents/createCategory' -Fields @{
        category = $Name
        savePath = $SavePath
    }
    Write-Log 'ACTION' "created category '$Name' (savePath: $SavePath)"
}

function Set-Category {
    param([object]$T, [string]$Category)
    if ($T.category -eq $Category) { return }
    if ($DryRun) {
        Write-Log 'ACTION' "[DRY-RUN] category '$($T.name)' -> '$Category'"
        return
    }
    Invoke-ApiPost -Endpoint 'torrents/setCategory' -Fields @{
        hashes    = $T.hash
        category  = $Category
    }
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

# Taken before anything is read, so two runs can never both be looking at the
# same list and both deciding to delete the same torrent.
Enter-RunLock | Out-Null

Write-Host ''
Write-Host "qbt-manager  $(if ($DryRun) { '[DRY RUN - nothing will be deleted]' } else { '[LIVE]' })  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "movies : $($cfg.moviesDir)"
Write-Host "series : $($cfg.seriesDir)"
if ($Only) { Write-Host "scope  : only titles matching '$Only' (dedup pass restricted)" }
Write-Host ''

# Invoke-ApiGet does not throw on an unreachable API: it classifies the failure
# and ends the run itself, so that "qBittorrent is closed" exits quietly with 0
# and a real API fault exits with its own code. This catch is only the net for
# anything unforeseen.
try {
    $all = @(Invoke-ApiGet -Endpoint 'torrents/info')
} catch {
    Write-Log 'ERROR' "unexpected failure reading torrents: $($_.Exception.Message)"
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Exit-Run -Code 1
}

Write-Log 'INFO' "run start; $($all.Count) torrent(s) seen; dryRun=$([bool]$DryRun)"
Write-Host "fetched $($all.Count) torrent(s)"

# -- annotate every torrent with its key ------------------------------------

foreach ($t in $all) {
    $parts = $null
try   { $parts = Get-TitleParts -Name $t.name }
      catch { Write-Log 'WARN' "title parse failed for '$($t.name)': $($_.Exception.Message)" }

      # Identity, settled here rather than at folder-naming time. An alias says
      # "this release IS that show", and a group key still reading the raw
      # spelling would put the release in a show of its own - see
      # Resolve-PartsAlias for the live queue this came from.
      if ($parts) {
          $aliased = Resolve-PartsAlias -Parts $parts -Aliases $cfg.titleAliases
          if ($aliased.Title -ne $parts.Title) {
              Write-Log 'INFO' ("titleAliases: '{0}' is '{1}'; grouping and filing it as '{1}'" -f $parts.Title, $aliased.Title)
              $parts = $aliased
          }
      }

      Add-Member -InputObject $t -NotePropertyName parts -NotePropertyValue $parts -Force

    if (-not $parts) {
        Write-Log 'WARN' "could not identify the title of '$($t.name)' - excluded from dedup, left untouched"
    } else {
        Write-Log 'INFO' "parsed '$($t.name)' -> title='$($parts.Title)' year='$($parts.Year)' series=$($parts.IsSeries) S$($parts.Season)E$($parts.Episode)"
    }
}

$live = New-Object System.Collections.ArrayList
foreach ($t in $all) { [void]$live.Add($t) }

# Kept for rules that must ask about ownership by path. $live shrinks as rules
# remove torrents; a path question needs to know what was there when the run
# started, not what is left after the deletions.
$script:liveTorrents = @($all)

Write-Host ""
Write-Host "Conflicting content paths"
# Two torrents that still claim the SAME folder are not a collision of names, they are
# a collision of ownership. Measured today:
#
#   Lanterns.2026.S01E08.1080p.WEB.h264-ETHEL [ext.to]   92d5ef0f
#   Lanterns.2026.S01E08.1080p.WEB.h264-ETHEL [ext.to]   6b4e163a
#
# two entries, identical titles, both 100% complete, both pointing into the same
# folder under C:\Downloads\Séries. No setLocation can ever succeed for either of
# them, because each one claims the folder the other sits in, and every run goes
# round on it as a "move blocked" line that looks like a transient fault when it
# is a data conflict.
#
# The identity of a torrent is its HASH, not its name. Two entries with one
# name are two torrents, and every rule that compares them already keys on the
# hash. What this does is say the second part out loud: where overlap is found
# it is REPORTED, with each side named, instead of surfacing sideways as a
# refusal somebody has to triangulate.

$overlap = 0
$telegram = @()
foreach ($a in $live) {
    if (-not $a.content_path) { continue }
    $ca = ([string]$a.content_path).TrimEnd("\","/")
    foreach ($b in $live) {
        if ($b.hash -eq $a.hash -or -not $b.content_path) { continue }
        $cb = ([string]$b.content_path).TrimEnd("\","/")
        $hit = ($ca -eq $cb) -or
               $cb.TrimEnd("\","/").StartsWith($ca + "\", [StringComparison]::OrdinalIgnoreCase) -or
               $ca.StartsWith($cb + "\", [StringComparison]::OrdinalIgnoreCase)
        if ($hit) { $overlap++ }
    }
}
if ($overlap -gt 0) {
    # counted once per ordered pair, so divide
    $overlap = [int]($overlap / 2)
}
if ($overlap -gt 0) {
    foreach ($a in $live) {
        if (-not $a.content_path) { continue }
        $ca = ([string]$a.content_path).TrimEnd("\","/")
        foreach ($b in $live) {
            if ($b.hash -eq $a.hash -or -not $b.content_path) { continue }
            $cb = ([string]$b.content_path).TrimEnd("\","/")
            $hit = ($ca -eq $cb) -or
                   $cb.StartsWith($ca + "\", [StringComparison]::OrdinalIgnoreCase) -or
                   $ca.StartsWith($cb + "\", [StringComparison]::OrdinalIgnoreCase)
            if ($hit) {
                Write-Host ("  overlap: [{0}] and [{1}] both claim" -f $a.hash.Substring(0,8), $b.hash.Substring(0,8))
                Write-Host ("           {0}" -f (Split-Path -Leaf $ca))
                Write-Host ("           " + $a.name.Substring(0,[Math]::Min(70,$a.name.Length)))
                Write-Host ("           " + $b.name.Substring(0,[Math]::Min(70,$b.name.Length)))
                [void]$false
            }
        }
    }
} else {
    Write-Host "  nothing two torrents claim the same folder" -ForegroundColor DarkGray
}

# -- rule 1: Dolby Vision ---------------------------------------------------

Write-Host ''
Write-Host 'Dolby Vision check'
$doviHits = 0
foreach ($t in $live) {
    if (Test-AlreadyGone $t) { continue }
    $hit = Get-DoviHit -Name $t.name
    if ($hit) {
        $doviHits++
        # -AllowErrored. This rule was specified as unconditional - "any state" -
        # and an errored DoVi entry is still a DoVi entry. It reads the NAME and
        # acts on the name alone, so there is nothing an error can change.
        #
        # -Knows. The verdict comes from the release's own NAME, which is all the
        # evidence there is to have: the marker is either in the name or it is not,
        # and there is no further copy to go and find. If the best copy of an
        # episode happens to carry a DV marker, this rule still removes it - that
        # is what "in any state" was asked to mean. DoVi is a statement about the
        # format, not a comparison between copies. So this rule knows what it
        # knows without consulting anything else.
        Remove-Torrent -T $t -AllowErrored -Knows -AllowIncomingBetter -Reason "Dolby Vision marker '$hit'"
    }
}
if ($doviHits -eq 0) { Write-Host '  none found' }

# -- rule 1b: full Blu-ray disc rips -----------------------------------------
# runs before clustering, so a disc rip can never win a group and delete a
# non-disc version of the same title

if ($cfg.excludeBluRayDiscRips) {
    Write-Host ''
    Write-Host 'Blu-ray disc-rip check'
    $discHits = 0
    foreach ($t in $live) {
        if (Test-AlreadyGone $t) { continue }
        $hit = Get-DiscRipHit -T $t
        if ($hit) {
            $discHits++
            # -Knows, for the same reason as Dolby Vision above: the verdict is
            # read off the on-disk structure, which is the whole of the evidence.
            Remove-Torrent -T $t -AllowErrored -Knows -AllowIncomingBetter -Reason "full Blu-ray disc structure - $hit"
        }
    }
    if ($discHits -eq 0) { Write-Host '  none found' }
}

# -- state ------------------------------------------------------------------

$state = @{ hashes = @{} }
if (Test-Path -LiteralPath $statePath) {
    try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-Log 'WARN' "state file unreadable, starting fresh" }
}
$now = Get-Date

# -- rule 2: a magnet that found nothing to download from --------------------

Write-Host ''
Write-Host ''
Write-Host 'No-availability check'
# THE RULE, and the reasoning behind both halves of it, lives with
# Get-NoAvailabilityVerdict above. The short version:
#
#   qBittorrent works the queue in order, so a magnet at position 150 has not
#   tried anything - it is waiting its turn. "Unavailable after trying" is only
#   true of a magnet the client is actually giving a slot. So the rule is judged
#   only inside the first $limit positions, and only for the time spent inside
#   them. A magnet that has never had a turn is never this rule's business.
$timeout = [double]$cfg.metadataTimeoutMinutes
$limit = 10
if ($cfg.PSObject.Properties['metadataPriorityRankLimit']) { $limit = [int]$cfg.metadataPriorityRankLimit }

$skip = @{}
foreach ($h in $script:gone.Keys) { $skip[$h] = $true }
$noAvailability = @(Get-NoAvailabilityVerdict -Torrents $live -Hashes $state.hashes -Now $now `
                    -TimeoutMinutes $timeout -QueueLimit $limit -Skip $skip)

if ($limit -gt 0) {
    Write-Host ("  judged only inside queue positions 1-{0}; priority 0 is out of the queue, not the front of it" -f $limit) -ForegroundColor DarkGray
}

for ($i = 0; $i -lt $noAvailability.Count; $i++) {
    $row = $noAvailability[$i]
    $short = $row.Name.Substring(0, [Math]::Min(46, $row.Name.Length))

    if ($row.WillDelete) {
        Remove-Torrent -T $row.Torrent -Reason $row.Reason
        continue
    }
    if ($row.InWindow) {
        Write-Host ("  {0,4}  {1,-46} no metadata at queue {2}, {3:N0}m in the window (tolerance {4:N0}m - waiting)" -f @((($i + 1)), $short, $row.QueuePos, $row.Minutes, $timeout))
    }
    elseif ($row.QueuePos -lt 1) {
        Write-Host ("  {0,4}  {1,-46} no metadata, out of the queue (priority 0) - not judged" -f @((($i + 1)), $short))
    }
    else {
        Write-Host ("  {0,4}  {1,-46} no metadata, queued at {2} of {3} - has not had a turn" -f @((($i + 1)), $short, $row.QueuePos, $limit))
    }
}

# -- rule 2c: one magnet an hour, from behind the window ---------------------

# Runs after rule 2 so the window's deletions have already been applied and are
# already in $script:gone: when the window frees a position, the magnet that was
# behind it should be seen at its new position, not its old one.
#
# THE RULE and the reasoning behind the witness live with Get-QueueDrainVerdict
# above. The short version: rule 2's window is a fixed slab and never reaches
# past position 10, so a magnet at position 11 that has been dead for a week is
# never cleaned up. This rule takes the first such magnet, gives it its own
# tolerance, and deletes it - but only when a torrent further down the queue is
# actually downloading, which is what distinguishes "this torrent is dead" from
# "the client is stuck".
$drainOn = $true
if ($cfg.PSObject.Properties['queueDrainEnabled']) { $drainOn = [bool]$cfg.queueDrainEnabled }

if (-not $drainOn) {
    Write-Host ''
    Write-Host 'No-availability drain' -ForegroundColor DarkGray
    Write-Host '  queueDrainEnabled is false, so nothing behind the window is ever judged' -ForegroundColor DarkGray
}
elseif ($limit -le 0) {
    Write-Host ''
    Write-Host 'No-availability drain' -ForegroundColor DarkGray
    Write-Host '  the queue window is disabled, so there is no boundary to drain from' -ForegroundColor DarkGray
}
else {
    Write-Host ''
    Write-Host 'No-availability drain (one per hour, from behind the window)'

    # The clock lives beside the window's timers in the same state file. It is
    # created on first use so an existing state.json keeps working.
    if (-not $state.PSObject.Properties['drain']) {
        $state | Add-Member -NotePropertyName 'drain' -NotePropertyValue ([pscustomobject]@{ hash = $null; since = $null })
    }
    if (-not $state.drain.PSObject.Properties['hash']) {
        $state.drain | Add-Member -NotePropertyName 'hash' -NotePropertyValue $null
    }
    if (-not $state.drain.PSObject.Properties['since']) {
        $state.drain | Add-Member -NotePropertyName 'since' -NotePropertyValue $null
    }

    # Rebuilt rather than reused: rule 2 may have deleted something above.
    $skip2 = @{}
    foreach ($h in $script:gone.Keys) { $skip2[$h] = $true }

    $drain = @(Get-QueueDrainVerdict -Torrents $live -Now $now -TimeoutMinutes $timeout `
                           -QueueLimit $limit -Drain $state.drain -Skip $skip2)

    if ($drain.Count -eq 0) {
        Write-Host ("  nothing behind position {0} is missing metadata - nothing to drain" -f $limit) -ForegroundColor DarkGray
    }
    else {
        $d = $drain[0]
        $shortD = $d.Name.Substring(0, [Math]::Min(46, $d.Name.Length))

        if ($d.WillDelete) {
            Write-Host ("  candidate at position {0}: {1,-46} dead for {2:N0} min, witness at position {3} - deleting" -f `
                @($d.QueuePos, $shortD, $d.Minutes, $d.WitnessPos)) -ForegroundColor Red
            Remove-Torrent -T $d.Torrent -Reason $d.Reason
        }
        elseif ($d.TimedOut) {
            # The distinction this rule exists to make, stated rather than
            # buried: past tolerance, but with nothing working past it to prove
            # the client is alive. Held, and the clock keeps running.
            Write-Host ("  candidate at position {0}: {1,-46} dead for {2:N0} min - HELD, nothing further down is downloading" -f `
                @($d.QueuePos, $shortD, $d.Minutes)) -ForegroundColor Yellow
        }
        else {
            $left = $timeout - $d.Minutes
              # "no witness yet", not "witness at position 0".
              #
              # $d.WitnessPos is 0 when there is no witness, and it was printed
              # unconditionally - so a candidate with NO witness printed as though one
              # existed, at position 0, which is in FRONT of it. That is the precise
              # thing this rule must never do: require the witness to be further down
              # the queue, then report a witness in front of it.
              #
              # The rule was never wrong - it holds the torrent - but the panel made it
              # look broken, and a reader cannot tell a real position 0 from a
              # missing one.
              $witnessText = if ($d.HasWitness) { "witness at position $($d.WitnessPos)" } else { 'no witness yet' }
              # The argument list is built in a variable, not concatenated at the
              # call site: -f binds tighter than +, so
              #   "..." -f @($a,$b,$c,$d) + @($e)
              # formats with the FIRST array and then appends the rest to the
              # resulting STRING. It throws FormatException at run time, which is
              # how a one-line display fix took the whole run down.
              $drainRow = @($d.QueuePos, $shortD, $d.Minutes, $left, $witnessText)
              Write-Host ("  candidate at position {0}: {1,-46} dead for {2:N0} min ({3:N0}m left), {4}" -f $drainRow) -ForegroundColor DarkGray
        }
    }
}

# -- rule 2d: a client downloading nothing at all, with the internet up --------

# Runs AFTER the drain, deliberately. The drain's witness is "something further
# down the queue is downloading", and this rule deletes the very torrents that
# would be that witness. Running the drain first lets it use a witness that still
# exists, and lets its one-per-run bound apply before this rule's larger sweep.
#
# THE RULE lives with Get-StallVerdict above. The short version: rule 2 asks how
# long a magnet has been trying, and that question has no answer while the client
# is idle - there is no evidence of trying, only of waiting. This rule asks
# whether ANYTHING is happening. When the answer is no and the internet is
# verifiably up, the queue is stalled rather than slow and patience buys nothing.
#
# Measured live when this was written: 206 torrents, 195 magnets, dl_info_speed 0,
# up_info_speed 1,4 MB/s, positions 4-20 all metaDL at dlspeed 0.

$stallOn = $true
if ($cfg.PSObject.Properties['stallCleanupEnabled']) { $stallOn = [bool]$cfg.stallCleanupEnabled }

$stallConfirm = 60.0
if ($cfg.PSObject.Properties['stallConfirmSeconds']) { $stallConfirm = [double]$cfg.stallConfirmSeconds }
$stallWait = 75.0
if ($cfg.PSObject.Properties['stallMaxWaitSeconds']) { $stallWait = [double]$cfg.stallMaxWaitSeconds }
$stallMax = 10
if ($cfg.PSObject.Properties['stallMaxDeletions']) { $stallMax = [int]$cfg.stallMaxDeletions }
$stallUrl = 'https://www.cloudflare.com/cdn-cgi/trace'
if ($cfg.PSObject.Properties['stallInternetProbeUrl']) { $stallUrl = [string]$cfg.stallInternetProbeUrl }

Write-Host ''
if (-not $stallOn) {
    Write-Host 'Stalled-client check' -ForegroundColor DarkGray
    Write-Host '  stallCleanupEnabled is false, so a client pulling nothing down is left alone' -ForegroundColor DarkGray
}
elseif ($stallConfirm -le 0) {
    Write-Host 'Stalled-client check' -ForegroundColor DarkGray
    Write-Host '  stallConfirmSeconds is 0 or less, so there is no way to tell a stall from a lull - rule disabled' -ForegroundColor DarkGray
}
else {
    Write-Host ("Stalled-client check (velocity 0 for {0:N0}s, internet up)" -f $stallConfirm)

    # The clock, alongside the other timers in the same state file.
    if (-not $state.PSObject.Properties['stall']) {
        $state | Add-Member -NotePropertyName 'stall' -NotePropertyValue ([pscustomobject]@{ since = $null })
    }
    if (-not $state.stall.PSObject.Properties['since']) {
        $state.stall | Add-Member -NotePropertyName 'since' -NotePropertyValue $null
    }

    # Rebuilt again: rules 2, 2c and 2b may all have deleted something.
    $skip3 = @{}
    foreach ($h in $script:gone.Keys) { $skip3[$h] = $true }

    $probeUrl = $stallUrl
    $stallVerdict = @(Get-StallVerdict -Torrents $live -Now $now `
                            -ConfirmSeconds $stallConfirm -MaxWaitSeconds $stallWait `
                            -QueueLimit $limit -MaxDeletions $stallMax `
                            -Stall $state.stall -Skip $skip3 `
                            -RateReader { Get-DownloadRate } `
                            -InternetProbe { Test-InternetReachable -Url $probeUrl })[0]

    if ($null -ne $stallVerdict -and $stallVerdict.Action -eq 'delete') {
        Write-Host ("  global download velocity 0 for {0:N0}s, internet reachable, nothing downloading anywhere" -f $stallVerdict.Seconds) -ForegroundColor Red
        Write-Host ("  removing up to {0} magnet(s) from queue positions 1-{1}, in queue order:" -f $stallMax, $limit) -ForegroundColor Red
        foreach ($t in @($stallVerdict.Torrents)) {
            Write-Host ("    position {0,3}  {1}" -f $t.priority, $t.name.Substring(0, [Math]::Min(56, $t.name.Length)))
        }
        foreach ($t in @($stallVerdict.Torrents)) {
            Remove-Torrent -T $t -Reason $stallVerdict.Reason
        }
    }
    elseif ($null -ne $stallVerdict -and $stallVerdict.Action -eq 'hold') {
        Write-Host ("  {0}" -f $stallVerdict.Reason) -ForegroundColor Yellow
    }
    elseif ($null -ne $stallVerdict -and $stallVerdict.Action -eq 'unknown') {
        Write-Host ("  {0} - cannot judge a stall without it" -f $stallVerdict.Reason) -ForegroundColor Yellow
    }
    else {
        Write-Host '  downloading normally, or not stalled long enough - nothing to do' -ForegroundColor DarkGray
    }
}

# -- rule 2b: an unfinished torrent that has not gained a byte in N days ----

# Runs after the metadata rule so magnets are already gone, and before the
# dedup pass so a dead torrent cannot take part in choosing which version of a
# title to keep.
if ($cfg.PSObject.Properties['stalledDeleteDays'] -and [double]$cfg.stalledDeleteDays -gt 0) {

    # The stalled table lives alongside the metadata timers in the same state
    # file. It is created on first use so an existing state.json keeps working.
    if (-not $state.PSObject.Properties['stalled']) {
        $state | Add-Member -NotePropertyName 'stalled' -NotePropertyValue ([pscustomobject]@{})
    }

    Write-Host ''
    Write-Host "Stalled check (no new data for $([int]$cfg.stalledDeleteDays) day(s))"
    $stalledRows = @(Get-StalledWatch -Torrents $live -Stalled $state.stalled -Now $now)

    if ($stalledRows.Count -eq 0) {
        Write-Host '  nothing incomplete to judge'
    }

    foreach ($r in $stalledRows) {
        $short = $r.Name.Substring(0, [Math]::Min(46, $r.Name.Length))
        if ($r.WillDelete) {
            # Partial data from a torrent that has not moved in a week is dead
            # weight on the disk, so this rule removes the files too. That is the
            # same orphan growth that filled Downloads\temp before, and leaving
            # the bytes behind would recreate it.
            Remove-Torrent -T $r.Torrent -DeleteFiles $true -Reason (
                "no data received for {0:N1} day(s), stuck at {1:N2} GB of {2:N2} GB (state {3})" -f
                $r.IdleDays, ($r.Completed / 1GB), ($r.Total / 1GB), $r.State)
        }
        else {
            Write-Host ("  {0,5:N1}d left  {1,-46} {2,6:N2}/{3,6:N2} GB  {4}" -f `
                $r.Remaining, $short, ($r.Completed / 1GB), ($r.Total / 1GB), $r.State)
        }
    }
}

# -- categories + cluster the dedup groups ----------------------------------

$clusters = New-Object System.Collections.ArrayList
$anyCompleted = @()

foreach ($t in $live) {
    if (Test-AlreadyGone $t) { continue }

    if ($t.progress -ge 1) { $anyCompleted += $t }
    if (-not $t.parts) { continue }

    # optional scope for a staged first run
    if ($Only -and ($t.parts.Title -notlike "*$Only*")) { continue }

    $placed = $false
    foreach ($c in $clusters) {
        if (Test-SameTitle -A $t.parts -B $c[0].parts) { [void]$c.Add($t); $placed = $true; break }
    }
    if (-not $placed) {
        $nc = New-Object System.Collections.ArrayList
        [void]$nc.Add($t)
        [void]$clusters.Add($nc)
    }
}

# Series releases of one episode often reach that loop under different titles,
# which is enough to leave them in different groups. Fold those back together.
$clusters = Merge-SeriesClusters -Clusters $clusters

if ($cfg.assignCategories) {
    Write-Host ''
    Write-Host 'Categories'
    Ensure-Category -Name $cfg.moviesCategory -SavePath $cfg.moviesDir
    Ensure-Category -Name $cfg.seriesCategory -SavePath $cfg.seriesDir
    foreach ($c in $clusters) {
        $cat = if ($c[0].parts.IsSeries) { $cfg.seriesCategory } else { $cfg.moviesCategory }
        foreach ($m in $c) { Set-Category -T $m -Category $cat }
    }
}

# -- whether a bigger copy still downloading protects a smaller finished copy ---
#
# THE GUARD, and why duplicate-comparison rules now bypass it by default.
#
# Remove-Torrent carries -AllowIncomingBetter. Without it, a FINISHED entry is kept
# whenever a bigger copy of the same episode is still downloading, because
# deleting a finished copy on the promise of a bigger one is losing data on credit:
# the replacement may fail, and by then the smaller copy is gone.
#
# That reasoning is sound for a rule deciding on ONE copy. It does not hold for a
# rule that has just PROVED a better copy already exists, because the credit is not
# being issued - it has already been cashed. Measured on a live queue, Lanterns
# S01E08, ten copies of one episode in the library:
#
#     6,19 GB  2160p AMZN FLUX          <- the biggest, the keeper, not a candidate
#     2,10 GB  4K HMAX TURG
#     1,79 GB  x4  various 1080p
#     1,64 GB  MULTi K83
#     1,63 GB  x2  ETHEL
#
# plus a 10,87 GB 4320p downloading at 17%. Every one of the nine smaller copies
# was held on the strength of that 4320p, so the library kept ten copies of one
# episode. The user's rule is the opposite: one copy, the better one, and the nine go.
#
# WHY IT IS SAFE TO BYPASS THE GUARD, and this is the whole argument. In every rule
# wired to it below, the entry being deleted is smaller than a copy that is ALREADY
# FINISHED and already present:
#
#   rule 4   - $keeper is the largest FINISHED member of the episode set, and the
#              loser is strictly smaller than it. The keeper is not a candidate.
#   rule 4/2 - pack-vs-single: both sides complete, the single is the smaller copy
#              of the one episode they share.
#   rule 4b  - the file is a duplicate of a LARGER file in the same season folder,
#              and the largest file in that folder is never the one deleted.
#
# So the episode is already covered by bytes on disk that this rule is not
# touching. Whether something even better is on its way is a question about which
# copy to KEEP, and it is answered later - when the better copy finishes, rule 4
# weighs it against the current keeper and the current keeper becomes the
# duplicate. The end state is the same either way; the difference is whether the
# library holds one copy now or ten until a download that may never finish.
#
# This is set in config.json as guardDuplicatesAgainstIncomingBetter: false (the
# live default). Set it to true to restore the old behaviour. DoVi and disc-rip
# still pass -AllowIncomingBetter unconditionally: they name the release from its
# own structure and establish no keeper at all.
#
# The call sites use a hash-splat such as
#   $rt = @{ T = $m; Knows = $true; Reason = ... }
#   if (-not $guardDuplicates) { $rt.AllowIncomingBetter = $true }
#   Remove-Torrent @rt
# because splatting a one-element ARRAY, @('-AllowIncomingBetter'), does NOT bind
# a [switch] parameter - proven by direct test. Passing the switch must be
# explicit.
$guardDuplicates = $false
if ($cfg.PSObject.Properties['guardDuplicatesAgainstIncomingBetter']) {
    $guardDuplicates = [bool]$cfg.guardDuplicatesAgainstIncomingBetter
}

# -- rule 4: dedup (runs before any move, so we never relocate files we are
#             about to delete) -----------------------------------------------

Write-Host ''
Write-Host 'Dedup (keep the largest finished version, drop anything smaller)'

# The user's 10%: two encodes of one episode that differ by less than this are the
# same episode, and one of them is redundant. Rule 4d already applies it against the
# library; this pass applies the SAME number to the other side of the comparison -
# an unfinished copy of an episode that is already FINISHED in the queue.
#
# One key, one meaning, read from one place. Two separate tolerance settings would
# be two chances to drift apart, and the failure mode is silent: a keeper 9% larger
# deleted by one rule and kept by the other, with nothing in the log to say why.
$dedupTol = 10
if ($cfg.PSObject.Properties['libraryRedundantTolerancePercent']) { $dedupTol = [double]$cfg.libraryRedundantTolerancePercent }
$tolerance = $dedupTol

# Rule 4 weighs releases that hold the IDENTICAL set of episodes. It used to look
# for those inside one cluster, and a cluster is built from the release TITLE, so
# two packs of one show whose names differ never met. Measured on a live queue:
# 'Euphoria US S03e01-08 [720p Ita Eng Spa SubS] byMe7alh' and
# 'Euphoria.S03.COMPLETE.1080p.AMZN.WEB-DL.H.264-EniaHD' are the same eight
# episodes, the second finished at 40.37 GB against the first's 15.69 GB at 96.5%,
# and they were never compared - the titles put them in different clusters and
# the packs' different names stopped the merge pass joining those clusters.
#
# So clusters are folded by show family before the sets are taken. Folding cannot
# widen the comparison past a set key: a single episode keys S3-E1 and a pack keys
# S3-E1-E8, so a pack still never meets a single; a pack of 1 to 8 still never
# meets a pack of 1 to 10; and one pack's other episodes still have nothing to say
# about another's. What changes is only that a set key is now found across title
# variants instead of only within one spelling of the title.
#
# Films keep one cluster per group, exactly as before. Test-SameTitle is the only
# thing that has ever decided whether two films are the same film, and a family
# key is a series concept.
$setGroups = @()
$famInfo = Get-ClusterFamilies -Clusters $clusters
$fams = @($famInfo.Family)
$byFamily = @{}
$familyOrder = New-Object System.Collections.ArrayList
for ($i = 0; $i -lt $clusters.Count; $i++) {
    $f = if ($i -lt $fams.Count) { $fams[$i] } else { '' }
    if (-not $f) { $setGroups += , @($clusters[$i]); continue }
    if (-not $byFamily.ContainsKey($f)) {
        $byFamily[$f] = New-Object System.Collections.ArrayList
        [void]$familyOrder.Add($f)
    }
    [void]$byFamily[$f].Add($i)
}
foreach ($f in $familyOrder) {
    $g = New-Object System.Collections.ArrayList
    foreach ($i in $byFamily[$f]) { foreach ($m in $clusters[$i]) { [void]$g.Add($m) } }
    $setGroups += , @($g)
}

# One file listing per torrent for the whole run. The set pass walks every live
# torrent, so an uncached lookup here would be one HTTP call per torrent per run.
$script:setKeyCache = @{}

foreach ($c in $setGroups) {
    $members = @($c | Where-Object { -not (Test-AlreadyGone $_) })
    if ($members.Count -lt 2) { continue }

    # The SHOW name only. The season and episode part of the header is built
    # per episode set below, so a header reading S18E1-E8 can only ever sit
    # above releases that really do hold episodes 1 to 8.
    $show = Get-ShowLabel -Parts @($members | ForEach-Object { $_.parts })

    # Rule 4 runs per SET OF EPISODES, not per cluster. A cluster only ever
    # holds releases whose first episode agrees, so one cluster can contain a
    # 10-episode pack, a 6-episode pack and a single episode 1 at the same
    # time. Comparing those three totals would delete whichever is smallest
    # while it still holds episodes nothing else in the room does.
    #
    # So the members are split by the set of episodes they carry first, and
    # the rule is applied inside each set. That leaves the common cases exactly
    # as they were - two versions of one episode share a set and deduplicate
    # against each other - and makes packs comparable on the one condition that
    # is genuinely safe: two packs of the SAME range hold the same episodes,
    # so the smaller one beside the finished bigger one really is a spare copy.
    # A pack against a single episode is now weighed separately below - see
    # the pack-vs-single pass after the set loop.
    $sets = @{}
    foreach ($m in $members) {
        $k = Resolve-TorrentSetKey -T $m -Cache $script:setKeyCache
        if (-not $k) {
            [void]$script:notes.Add("cannot tell which episodes '$($m.name)' holds - left out of dedup")
            continue
        }
        if (-not $sets.ContainsKey($k)) { $sets[$k] = New-Object System.Collections.ArrayList }
        [void]$sets[$k].Add($m)
    }

    # Sets are walked in episode order rather than as text, because
    # 'S1-E1-E10' sorts before 'S1-E1-E2' and that would print a ten-episode
    # pack above a two-episode one.
    $setOrder = @($sets.Keys | Sort-Object -Property `
        @{ Expression = { if ($_ -match '^S(\d+)-') { [int]$Matches[1] } else { 0 } } }, `
        @{ Expression = { if ($_ -match '-E(\d+)') { [int]$Matches[1] } else { 0 } } }, `
        @{ Expression = { if ($_ -match '-E\d+-E(\d+)$') { [int]$Matches[1] } else { 0 } } })

    # ONE GROUP PER EPISODE SET, not per cluster. A cluster is keyed on the
    # first episode alone, so it holds single episodes and packs of every
    # range that starts there. Printing those as one block under a header
    # reading S18E1-E8 claims that two dozen releases cover episodes 1 to 8
    # when most of them do not, and a header has to describe its own rows and
    # nothing else. Judging and printing are the same loop, so a release is
    # only ever weighed against others holding the same episodes, under a
    # header built from the key it was weighed under.
    foreach ($k in $setOrder) {
        $set = @($sets[$k])
        $label = ("{0} {1}" -f $show, (Get-EpisodeSetLabel -Key $k)).Trim()

        if ($set.Count -ge 2) {
            $complete = @($set | Where-Object { $_.progress -ge 1 })

            # 4. one keeper per episode set: the largest version that is 100%
            # downloaded.
            #
            # Every other version SMALLER than or EQUAL to that keeper is removed, whether
            # or not it is itself finished. Once a bigger copy is complete there is
            # no reason to go on fetching a smaller one, and no size ratio changes
            # that: a 3.87 GB 1080p is exactly as redundant next to a finished 7.72
            # GB 2160p as a copy half a percent away from it in size.
            #
            # A version BIGGER than the keeper is left alone. Finishing the small
            # copy is not a reason to throw away the large one that is still
            # downloading.
            #
            # 'size' is qBittorrent's TOTAL size - the size the download would end
            # up at, not the bytes fetched so far. The comparison is on totals
            # throughout, so an unfinished 38.40 GB REMUX at 11% is bigger than, and
            # survives, a finished 17.06 GB encode. Comparing downloaded bytes
            # instead would invert exactly that case.
            if ($complete.Count -ge 1) {
                # Only versions this run has not already removed may be the keeper.
                # Otherwise a DoVi or stalled deletion above can leave the set
                # nominating something that is on its way out.
                $alive = @($complete | Where-Object { -not (Test-AlreadyGone $_) })
                if ($alive.Count -ge 1) {
                    $keeper = @($alive | Sort-Object -Property @{ Expression = { $_.size }; Descending = $true }, hash)[0]

                    foreach ($m in $set) {
                        if (Test-AlreadyGone $m) { continue }
                        if ($m.hash -eq $keeper.hash) { continue }

                        # A total of 0 means the size is UNKNOWN - a magnet that has
                        # not fetched its metadata yet - not that it is the smallest
                        # release in the room. Deleting on that basis would sidestep
                        # rule 2b's priority ranking and its 60 minute grace period,
                        # so a torrent this rule is not entitled to touch is left
                        # alone here.
                        if ($m.size -le 0) { continue }

                        if ($m.size -gt $keeper.size -or ($m.size -eq $keeper.size -and [double]$m.progress -lt 1)) {
                            # Finished ties go through the duplicate branch instead.
                            # A finished copy larger than the selected largest
                            # keeper cannot normally occur. Keep it defensively. So
                            # the tolerance below is deliberately one-sided: it can
                            # only ever reach an UNFINISHED copy.
                            if ([double]$m.progress -ge 1) { continue }

                            # BIGGER IS NOT ACTUALLY BIGGER.
                            #
                            # A download that would finish larger is the better
                            # version, and throwing it away throws away the better
                            # version. But 61 KB out of 9 GB is not a better version,
                            # it is the difference between two releases of the same
                            # encode: a padded track, a container detail, a slightly
                            # different tag. Measured on a live queue, one episode:
                            #
                            #    9.057.610.150 B    0,6%   +0,00067%   kept
                            #    9.057.552.150 B   12,8%   +0,00003%   kept
                            #    9.057.550.486 B    6,1%   +0,00001%   kept
                            #    9.057.549.336 B  100,0%              finished keeper
                            #
                            # Three downloads of one episode, each a rounding error
                            # larger than the copy ALREADY FINISHED, all kept by a
                            # strict ">=" and all fetching the same thing. On a size
                            # ratio they are indistinguishable, and the finished copy
                            # is the one that is done.
                            #
                            # The tolerance is the same 10% rule 4d applies against
                            # the library, read the same way: "no more than 10%
                            # bigger" counts as within it, so a download exactly on
                            # the limit is redundant. Anything past it is a different
                            # encode and stays - a 2160p next to a finished 1080p is
                            # a genuine better copy and is not touched.
                            $over = ([double]$m.size - [double]$keeper.size) / [double]$keeper.size
                            if ($over -gt ($tolerance / 100.0)) { continue }

                            $why = 'incomplete, and not meaningfully bigger than a finished version'
                        }
                        else {
                            # Spelled out for the errored case so the log says WHY an
                            # errored entry was removed, rather than leaving it to be
                            # inferred from the fact that it happened at all.
                            $why = if ($m.progress -ge 1 -and $m.size -eq $keeper.size) { 'equal-size completed duplicate' }
                                   elseif ($m.progress -ge 1) { 'smaller completed version' }
                                   elseif (Test-Errored $m) { 'errored, and the same episodes are already finished elsewhere' }
                                   else { 'incomplete, and a bigger version is already finished' }
                        }

                        # The ONE place an errored torrent may be deleted.
                        #
                        # Everywhere else an error is protected, because deleting it
                        # destroys whatever it fetched and throws away the record of
                        # how far it got. Here that reasoning does not apply, because
                        # the comparison has already established that this content
                        # exists, complete, somewhere else:
                        #
                        #   - the keeper is progress >= 1, so it is FINISHED. An
                        #     errored torrent is never the keeper; it can only lose.
                        #   - $k is Get-EpisodeSetKey, so the two hold the IDENTICAL
                        #     episodes - pack against pack of the same range, or the
                        #     same single episode against itself. Nothing in this
                        #     group is unique, which is what makes removing the
                        #     entry safe rather than merely convenient.
                        #   - $m.size > 0 was checked above, so this is not a magnet
                        #     being judged on an unknown size.
                        #
                        # In short: an errored copy of something already held in
                        # full is not lost data, it is a spare copy that failed.
                        #
                        # -Knows. This is the one rule that genuinely SEES its
                        # keeper: $keeper is a real torrent in this snapshot, it is
                        # progress >= 1, and the set key proves the two hold the
                        # identical episodes. That is a keeper found, not a keeper
                        # missing - which is the difference -Knows asks about. The
                        # snapshot is still only a snapshot, so the claim is scoped
                        # to what it can be: the content exists, finished, in the
                        # entry named in this very message.
                        # The percentage is in the message when it decided anything.
                        # "Incomplete, and not meaningfully bigger" is a claim about
                        # a number; a reader checking it later needs the number, not
                        # an adjective.
                        $gap = ''
                        if ($m.size -ge $keeper.size -and [double]$m.progress -lt 1) {
                            $gap = (" - only {0:N2}% bigger, inside the {1:N0}% tolerance" -f `
                                (([double]$m.size - [double]$keeper.size) / [double]$keeper.size * 100), $tolerance)
                        }
                        $rt = @{ T = $m; AllowErrored = $true; Knows = $true; Reason = ("{0}{1} of '{2}' ({3}); '{4}' is finished at {5:N2} GB against {6:N2} GB" -f `
                            $why, $gap, $label, $k, $keeper.name, ($keeper.size / 1GB), ($m.size / 1GB)) }
                        if (-not $guardDuplicates) { $rt.AllowIncomingBetter = $true }
                        if (-not $DryRun -and -not (Stop-TorrentAndConfirm -T $keeper)) { continue }
                        # Equal names are not identity. If payloads really overlap,
                        # remove only the redundant entry, never the keeper's bytes.
                        if ($m.content_path -and $keeper.content_path -and
                            (Test-Claimed -Path $m.content_path -Torrents @($keeper))) {
                            $rt.DeleteFiles = $false
                        }
                        Remove-Torrent @rt
                    }
                }
            }
        }

        Write-Host ("  {0}" -f $label)
        foreach ($m in @($set | Sort-Object -Property size -Descending)) {
            $mark = if (Test-AlreadyGone $m) { 'REMOVE' } else { 'keep  ' }
            Write-Host ("    {0}  {1,7:N2} GB  {2,6:N2}%  {3}" -f $mark,
                ($m.size / 1GB), ($m.progress * 100), $m.name)
        }
    }

    # Pack vs single contained in it. Two releases that hold the SAME episodes
    # in one place: S18E01-E05 6.4 GB beside S18E01 8.1 GB is the same content
    # twice, whatever the set key says. The single-episode version and the pack
    # sit in different sets because their exact ranges differ, so without this
    # pass they are never weighed against each other and the smaller one stays.
    #
    # Both must be COMPLETE for the comparison to be honest, and DoVi was
    # already deleted by rule 1, so Test-AlreadyGone closes that door.
    #
    # WHAT IS WEIGHED is the ONE episode they share, measured on both sides: the
    # pack's own file for that episode, against the single's own file. The pack's
    # TOTAL is irrelevant here and is never used - it covers other episodes that
    # have nothing to say about this one, and dividing that total by the episode
    # count is worse than using nothing, because it produces a plausible number
    # that matches no real file.
    #
    # ONLY THE SINGLE IS EVER DELETED, and that is the load-bearing part.
    #
    # It was otherwise, and it cost real data on this box:
    #
    #   2026-10-05 15:43   Its.Always.Sunny.in.Philadelphia S18E01-E08 [0f5b83fb]
    #   deleted by the scheduled run, because one single's copy of S18E01 was
    #   46 MB bigger than the pack's own S18E01 file. The pack held E01-E08, and
    #   E02-E08 had no other copy anywhere on the machine.
    #
    # A 46 MB difference between two encodes of one episode is not evidence that
    # seven other episodes are redundant, and removing the pack's entry left those
    # seven files on disk belonging to no torrent at all. A pack is the ONLY
    # record qBittorrent has of the episodes it holds; deleting one to settle a
    # disagreement about a single episode destroys the rest with it.
    #
    # Rule 4's set-level comparison above already removes a pack that is a genuine
    # spare copy of another pack of the SAME range, weighing whole packs against
    # whole packs. That is the only safe way to delete one, and it is why this
    # pass can be narrowed to singles without losing anything.
    #
    # $fileSizeCache holds one file listing per pack for the whole run. Measuring
    # the shared episode means reading the pack's file list, and a season with
    # many packs would otherwise re-read the same listing once per single it
    # contains.
    $fileSizeCache = @{}
    foreach ($pack in $members) {
        if (Test-AlreadyGone $pack) { continue }
        if (-not $pack.parts) { continue }
        if (-not $pack.parts.IsMultiEpisode) { continue }
        if (-not $pack.parts.EpisodeLast) { continue }
        if ($pack.progress -lt 1) { continue }

        foreach ($single in $members) {
            if (Test-AlreadyGone $single) { continue }
            if ($single.hash -eq $pack.hash) { continue }
            if (-not $single.parts) { continue }
            if ($single.parts.IsMultiEpisode) { continue }
            if ($single.parts.Title -ne $pack.parts.Title) { continue }
            if ($single.parts.Season -ne $pack.parts.Season) { continue }
            if ($null -eq $single.parts.Episode) { continue }
            if ($single.parts.Episode -lt $pack.parts.Episode) { continue }
            if ($single.parts.Episode -gt $pack.parts.EpisodeLast) { continue }
            if ($single.progress -lt 1) { continue }

            # The two are compared on the ONE episode they share: that episode's
            # real file inside the pack, against the single's own file. Neither
            # the pack's total nor an average of it is involved - the pack holds
            # other episodes that say nothing about this one.
            $epFileBytes = Get-PackEpisodeBytes -Hash $pack.hash -Season $pack.parts.Season `
                                                -Episode $single.parts.Episode -Cache $fileSizeCache

            # An unmeasured episode is not a licence to delete. Skip it and say so.
            if ($null -eq $epFileBytes) {
                [void]$script:notes.Add(("cannot measure S{0}E{1} inside '{2}', so it is not weighed against '{3}'" -f `
                    $pack.parts.Season, $single.parts.Episode, $pack.name, $single.name))
                continue
            }
            if ($single.size -le 0) { continue }

            # The PACK IS NEVER THE ONE DELETED. Only the single can be, and only
            # when the pack's own copy of this episode is the larger one.
            #
            # It was otherwise, and it cost a 12,54 GB pack of E01-E08 on
            # 2026-10-05: the single's S18E01 was 46 MB bigger than the pack's
            # S18E01, so the whole pack was removed and E02-E08 - which had no
            # other copy anywhere - were left on disk belonging to no torrent.
            # A 46 MB difference between two encodes of one episode says nothing
            # about the seven other episodes.
            if ($epFileBytes -lt $single.size) {
                # The pack's copy is smaller, so the pack's episode is the spare
                # and the single survives. The pack is left completely alone -
                # which is the whole point: the pack holds episodes the single
                # cannot replace.
                continue
            }

            # Stopping both first so qBittorrent releases its file handles on the
            # pack, and the survivor is never restarted afterwards.
            if (-not $DryRun) {
                if (-not (Stop-TorrentAndConfirm -T $pack)) { continue }
            }

            $reason = ("duplicate of '{0}': both are complete, and the single's own copy of S{1}E{2} is smaller or equal ({3:N2} GB) to the pack's file for that episode ({4:N2} GB); the pack holds other episodes this single cannot replace, so the single goes" `
                -f $pack.name, $pack.parts.Season, $single.parts.Episode,
                   ($single.size / 1GB), ($epFileBytes / 1GB))
            # -Knows. It SEES its keeper: $pack is a real torrent, both are
            # complete, and $epFileBytes is that pack's own file for this episode -
            # measured, not inferred. The single is one episode and the pack holds
            # it, so nothing unique goes with it.
            $rt = @{ T = $single; Knows = $true; Reason = $reason; DeleteFiles = $true }
            if (-not $guardDuplicates) { $rt.AllowIncomingBetter = $true }
            if ($single.content_path -and $pack.content_path -and
                (Test-Claimed -Path $single.content_path -Torrents @($pack))) { $rt.DeleteFiles = $false }
            Remove-Torrent @rt

            # The pack stays STOPPED. It was stopped above to release its file
            # handles for the delete, and nothing here starts it again.
            break
        }
    }
}

# -- rule 4b: the same episode twice inside one show's own season folder -------
#
# THE RULE lives with Get-LibraryDuplicateVerdicts. The short version: rule 4
# compares inside a cluster, and a cluster's family is the FIRST WORD of the show
# name, so 'its always sunny in philadelphia', 'c'e sempre il sole a philadelphia'
# and 'www.uindex.org - ...' are three clusters of one show and never meet. The
# library folder does not have that problem, because the manager put those files
# there itself - Get-LibraryTargetDir already decided they are one show.
#
# Measured cost of leaving it out: 7 duplicated episodes of one season and 10,5 GB,
# every copy finished, every copy in the library.
#
# It runs AFTER dedup (so anything rule 4 could see is already gone) and BEFORE the
# move (so a duplicate is not moved, and cannot become a duplicate somewhere else).
$libraryDupOn = $true
if ($cfg.PSObject.Properties['libraryDedupeEnabled']) { $libraryDupOn = [bool]$cfg.libraryDedupeEnabled }

if (-not $libraryDupOn) {
    Write-Host ''
    Write-Host 'Library duplicate check' -ForegroundColor DarkGray
    Write-Host '  libraryDedupeEnabled is false, so a repeated episode inside a season folder is left alone' -ForegroundColor DarkGray
}
else {
    Write-Host ''
    Write-Host 'Library duplicate check (same episode twice in one season folder)'
    $libDupes = @(Get-LibraryDuplicateVerdicts -SeriesDir $cfg.seriesDir -Torrents $all -Gone $script:gone)

    if ($libDupes.Count -eq 0) {
        Write-Host '  no episode appears twice in a season folder' -ForegroundColor DarkGray
    }
    foreach ($d in $libDupes) {
        $short = Split-Path -Leaf $d.File
        if ($d.Action -eq 'hold') {
            Write-Host ("  hold    {0,-9} {1}" -f $d.Episode, $short) -ForegroundColor Yellow
            Write-Host ("          {0}" -f $d.Reason) -ForegroundColor DarkGray
            continue
        }

        # A pack whose entry must survive is shown distinctly, because the file is
        # being removed and the entry deliberately is not.
        #
        # It does NOT continue here. It used to, and that meant a real
        # 'delete-file-only' verdict printed "file" and then fell out of the loop
        # before the removal below - so the duplicate was announced and never
        # deleted, every run, silently. The verdict is carried, not consumed: the
        # branch further down handles both the panel and the removal.
        if ($d.Action -eq 'delete-file-only') {
            Write-Host ("  file    {0,-9} {1}" -f $d.Episode, $short) -ForegroundColor Magenta
            Write-Host ("          {0}" -f $d.Reason) -ForegroundColor DarkGray
        }

        # Both sides are stopped before anything is removed: the duplicate, and the
        # larger copy it loses to. The survivor is left STOPPED and never
        # restarted - same discipline as the pack-vs-single pass in rule 4, and
        # for the same reason. A running torrent re-fetches the file it just lost,
        # so the duplicate is back on the next run; and a stopped survivor cannot
        # quietly become a file handle the next delete has to fight.
        if (-not $DryRun) {
            $stopped = $true
            foreach ($hash in @($d.StopHashes | Select-Object -Unique)) {
                $entry = @($all | Where-Object { $_.hash -eq $hash })
                if ($entry.Count -ne 1 -or -not (Stop-TorrentAndConfirm -T $entry[0])) { $stopped = $false; break }
            }
            if (-not $stopped) { continue }
        }
        if ($DryRun -and -not $d.Owner) {
            [void]$script:actions.Add("WOULD DELETE FILE  $($d.File) - $($d.Reason)")
            Write-Log 'DELETE' "[DRY-RUN] $($d.File) - $($d.Reason)"
            continue
        }

        # A PACK owner, where the entry still holds episodes the library lacks.
        # The file is the duplicate; the ENTRY is not, and removing it would take
        # the pack's other - usually wanted, sometimes unique - episodes with it.
        # So only the file goes, by path, and the entry is left stopped as it was.
        if ($d.Action -eq 'delete-file-only') {
            try {
                Remove-Item -LiteralPath $d.File -Force -ErrorAction Stop
                [void]$script:actions.Add("DELETED FILE  $($d.File) - $($d.Reason)")
                Write-Log 'DELETE' "$($d.File) - $($d.Reason) (pack entry kept: it still holds other episodes)"
            }
            catch {
                Write-Log 'WARN' "could not delete duplicate file $($d.File): $($_.Exception.Message)"
            }
            continue
        }

        # The torrent goes with the file. Deleting only the file would leave the
        # owner re-downloading it, which is the same duplicate on the next run.
        #
        # -Knows. The verdict function already established the whole of it, and
        # established it against something it can name: it walked this very season
        # folder, found a second file for the same episode, measured both, and
        # recorded the larger one as the keeper. Every episode the owning entry
        # still holds was counted against the library before this call was reached.
        # A keeper found in the folder on disk, not the absence of one.
        if ($d.Owner) {
            $rt = @{ T = $d.Owner; Knows = $true; Reason = $d.Reason }
            if (-not $guardDuplicates) { $rt.AllowIncomingBetter = $true }
            Remove-Torrent @rt
        }
        else {
            # No torrent claims it, so there is nothing to ask qBittorrent to
            # remove. The file is deleted directly, and says so in the log.
            try {
                Remove-Item -LiteralPath $d.File -Force -ErrorAction Stop
                [void]$script:actions.Add("DELETED FILE  $($d.File) - $($d.Reason)")
                Write-Log 'DELETE' "$($d.File) - $($d.Reason) (no owning torrent; file removed directly)"
            }
            catch {
                Write-Log 'WARN' "could not delete duplicate file $($d.File): $($_.Exception.Message)"
            }
        }
    }
}

# -- rule 4d: stop downloading an episode the library already has ------------
#
# THE RULE lives with Get-LibraryRedundantVerdicts. The short version: an
# in-progress download whose FINAL size is within the tolerance of a finished
# copy already in the library is redundant, and is removed with its partial data.
#
# It reads `size`, never `completed`. That is the point of the rule - it fires the
# moment metadata resolves, at 0% as much as at 80%, so the download never
# happens rather than being cleaned up afterwards.
#
# Measured against the LIBRARY, because rule 4 can only compare inside a cluster
# and the clusters of one show do not meet when the release names differ.
$redundantTol = 10.0
if ($cfg.PSObject.Properties['libraryRedundantTolerancePercent']) { $redundantTol = [double]$cfg.libraryRedundantTolerancePercent }
$redundantOn = $true
if ($cfg.PSObject.Properties['libraryRedundantEnabled']) { $redundantOn = [bool]$cfg.libraryRedundantEnabled }

if (-not $redundantOn) {
    Write-Host ''
    Write-Host 'Redundant download check' -ForegroundColor DarkGray
    Write-Host '  libraryRedundantEnabled is false, so a download matching a library episode is left running' -ForegroundColor DarkGray
}
else {
    Write-Host ''
    Write-Host ("Redundant download check (within {0:N0}% of an episode already in the library)" -f $redundantTol)
    $redundant = @(Get-LibraryRedundantVerdicts -Torrents $all -MoviesDir $cfg.moviesDir `
                                                -SeriesDir $cfg.seriesDir -TolerancePercent $redundantTol `
                                                -Aliases $cfg.titleAliases)

    if ($redundant.Count -eq 0) {
        Write-Host ("  no download is within {0:N0}% of an episode already in the library" -f $redundantTol) -ForegroundColor DarkGray
    }
    foreach ($r in $redundant) {
        $shortR = $r.Torrent.name.Substring(0, [Math]::Min(52, $r.Torrent.name.Length))
        # HELD, and shown distinctly. This download would finish BIGGER than the
        # library copy, so rule 4 would keep IT and delete that one. Printing it as
        # REDUNDANT claims the opposite of what the next rule would do, and the two
        # would have to be read together to see the contradiction.
        if ([string]$r.Action -eq 'hold') {
            Write-Host ("  hold    {0,-9} download {1,7:N2} GB   library {2,7:N2} GB   ({3,5:N1}% done)" -f `
                $r.Scope, ([double]$r.Torrent.size / 1GB), ($r.LibBytes / 1GB), ([double]$r.Torrent.progress * 100)) -ForegroundColor Yellow
            Write-Host ("            {0}" -f $shortR) -ForegroundColor DarkGray
            Write-Host ("            {0}" -f $r.Reason) -ForegroundColor DarkGray
            [void]$script:notes.Add("held: this download would be the bigger copy - $($r.Torrent.name) - $($r.Reason)")
            continue
        }

        Write-Host ("  REDUNDANT {0,-9} download {1,7:N2} GB   library {2,7:N2} GB   ({3,5:N1}% done)" -f `
            $r.Scope, ([double]$r.Torrent.size / 1GB), ($r.LibBytes / 1GB), ([double]$r.Torrent.progress * 100)) -ForegroundColor Red
        Write-Host ("            {0}" -f $shortR) -ForegroundColor DarkGray
        Write-Host ("            {0}" -f $r.Reason) -ForegroundColor DarkGray

        # Stopped first, then the torrent AND its partial data: this download is
        # one nobody wanted, so the bytes already fetched for it are waste too.
        if (-not $DryRun) {
            Invoke-ApiPost -Endpoint 'torrents/stop' -Fields @{ hashes = $r.Torrent.hash } | Out-Null
        }
        # -Knows. It SEES its keeper: Get-LibraryRedundantVerdicts opened this
        # torrent's own season folder and measured a file that is already there,
        # within the tolerance. That is the library copy found on disk, named in
        # the reason, not the absence of one.
        #
        # This rule only ever judges a download in progress - a completed torrent
        # is explicitly not its business - so the -Knows guard would not fire here
        # anyway. It is passed because the claim is true, not because it is needed,
        # and a rule that later widens to finished torrents should already be
        # making the claim.
        Remove-Torrent -T $r.Torrent -Knows -Reason $r.Reason -DeleteFiles $true
    }
}

# -- rule 4c: a finished entry whose data is gone ---------------------------
#
# THE RULE lives with Get-PhantomVerdicts. The short version: a torrent can report
# 100% over a folder that no longer exists, and such an entry advertises episodes
# to qBittorrent and to anything reading its status while holding nothing. It is
# removed only when every episode it claimed is verifiably present in the library
# - otherwise the entry is the only record of that data and is held.
#
# It runs last of the deletion rules, after every move, so a folder that is merely
# about to arrive is not mistaken for one that has gone.
$phantomOn = $true
if ($cfg.PSObject.Properties['phantomCleanupEnabled']) { $phantomOn = [bool]$cfg.phantomCleanupEnabled }

if (-not $phantomOn) {
    Write-Host ''
    Write-Host 'Phantom check' -ForegroundColor DarkGray
    Write-Host '  phantomCleanupEnabled is false, so a finished entry with no data is left alone' -ForegroundColor DarkGray
}
else {
    Write-Host ''
    Write-Host 'Phantom check (finished, but its data is gone)'
    $phantoms = @(Get-PhantomVerdicts -Torrents $all -MoviesDir $cfg.moviesDir -SeriesDir $cfg.seriesDir `
                                              -Aliases $cfg.titleAliases)

    if ($phantoms.Count -eq 0) {
        Write-Host '  every finished entry has its data where it says it does' -ForegroundColor DarkGray
    }
    foreach ($p in $phantoms) {
        $shortP = $p.Torrent.name.Substring(0, [Math]::Min(52, $p.Torrent.name.Length))
        if ($p.Action -eq 'hold') {
            Write-Host ("  hold    {0}" -f $shortP) -ForegroundColor Yellow
            Write-Host ("          {0}" -f $p.Reason) -ForegroundColor DarkGray
            continue
        }

        # Stopped first, then the ENTRY only. DeleteFiles is false and must stay
        # false: the folder it claims is already gone, and a stray copy of the
        # same data may sit under staging owned by a different torrent.
        if (-not $DryRun) {
            Invoke-ApiPost -Endpoint 'torrents/stop' -Fields @{ hashes = $p.Torrent.hash } | Out-Null
        }
        Write-Host ("  PHANTOM {0}" -f $shortP) -ForegroundColor Red
        Write-Host ("          {0}" -f $p.Reason) -ForegroundColor DarkGray
        # -Knows, and this is the rule that most needs it - a phantom is finished
        # by definition, so the guard fires on every single one of them.
        #
        # It SEES its replacement. Get-PhantomVerdicts requires that EVERY episode
        # the entry claimed has a file present in the library season folder, and it
        # refuses the entry outright when one is missing. Those files were opened
        # and found. The data is already gone; what the entry is asserting is
        # false, and the replacement is on disk.
        Remove-Torrent -T $p.Torrent -Knows -Reason $p.Reason -DeleteFiles $false
    }
}

# -- rule 3: completed torrents into the library ---------------------------
# only the survivors from the dedup step are moved

Write-Host ''
Write-Host 'Completed -> library'
if ($cfg.moveCompletedToLibrary) {

    $verifySeconds = 30
    if ($cfg.PSObject.Properties['moveVerifySeconds']) { $verifySeconds = [int]$cfg.moveVerifySeconds }
    $verifyPollMs = 500
    if ($cfg.PSObject.Properties['moveVerifyPollMs']) { $verifyPollMs = [int]$cfg.moveVerifyPollMs }

    # $all is the list this run started from. It is the right list to ask who
    # holds a folder: anything added since is a torrent the run has not seen,
    # and anything this run deleted is removed again through $script:gone.
    foreach ($t in $anyCompleted) {
        if (Test-AlreadyGone $t) { continue }
        if (-not $t.parts) {
            Write-Log 'WARN' "completed but unidentified, not moving: $($t.name)"
            continue
        }
        # -Aliases, so a show the parser spells two ways is filed in ONE folder.
        # Without it the two spellings land in different show folders, and rule
        # 4b only ever compares inside a single one - so the alias stops the split
        # that would otherwise hide the duplicates from the rule meant to find
        # them. See Resolve-LibraryShowDir.
        $dir = Get-LibraryTargetDir -T $t -MoviesDir $cfg.moviesDir -SeriesDir $cfg.seriesDir -Aliases $cfg.titleAliases
        Move-ToLibrary -T $t -TargetDir $dir -Live $all -Gone $script:gone `
                       -VerifySeconds $verifySeconds -PollMs $verifyPollMs
    }
}

# -- rule 3b: settle the settled ------------------------------------------
#
# Runs AFTER rule 3, on bytes that are already in the library, and asks the
# question rule 3 has no reason to ask: is this file the best version that will
# ever arrive?
#
#     settled  <=>  no unfinished torrent holds any episode this one holds
#
# The condition is stricter than "could be bigger" on purpose. A stopped entry, a
# 2 KB 480p rip and a magnet with no size at all all block, because the rule is
# about there being no further POSSIBILITY of a better version - and a magnet is
# precisely the one whose size is unknown. Treating unknown as harmless would
# settle on the strength of not knowing, which is the inversion of the whole
# project's premise.
#
# The move is a CUT of the media file, not a setLocation. Rule 3 has already put
# the torrent in the library, possibly inside a pack's folder; this lifts the file
# to the top of the season folder, which is where a library is supposed to be,
# and leaves the sidecars behind for the reaper.
#
# ORDER IS THE SAFETY. Stop, then move, then verify, then only remove the entry -
# and only if every file verified. If a move fails the entry stays and the data
# stays, and the next run tries again. Removing the entry first would make a
# failed move an orphan the reaper eventually destroys, which is losing the file
# to recover a folder.

Write-Host ''
Write-Host 'Settled (finished, and nothing unfinished could improve it)'
if ($cfg.PSObject.Properties['settleEnabled'] -and -not $cfg.settleEnabled) {
    Write-Host '  settleEnabled is false, so finished files are left where rule 3 put them' -ForegroundColor DarkGray
}
else {
    $settleList = Get-SettleVerdicts -Torrents $live -Gone $script:gone `
                                    -MoviesDir $cfg.moviesDir -SeriesDir $cfg.seriesDir `
                                    -Aliases $cfg.titleAliases `
                                    -FileLister {
        param($h)
        try { return @(Invoke-ApiGet -Endpoint "torrents/files?hash=$h") } catch { return @() }
    }

    $settleCount = 0
    $settleWait = 0

    foreach ($hash in @($settleList.Keys | Sort-Object)) {
        $sv = $settleList[$hash]
        $t = $sv.Torrent

        if ($sv.Verdict -ne 'SETTLE') {
            $settleWait++
            $short = $t.name
            if ($short.Length -gt 46) { $short = $short.Substring(0, 46) }
            Write-Host ("  hold  {0,-46} {1}" -f $short, $sv.Reason) -ForegroundColor DarkGray
            continue
        }

        if (Test-AlreadyGone $t) { continue }

        # A live entry over a file we are about to move is a recheck waiting to
        # happen. Stopped first, and the stop is confirmed rather than assumed.
        $stoppedOk = Stop-TorrentAndConfirm -T $t

        $moved = @()
        $failed = @()
        foreach ($f in @($sv.Files)) {
            $src = [string]$f.Path
            $dst = [string]$f.Target

            if (-not (Test-Path -LiteralPath $src)) {
                $failed += $f
                continue
            }

            # The destination is the library folder. Refuse to overwrite: if a file
            # for this episode is already there, rule 4b owns that decision - it
            # keeps the larger and deletes the smaller - and this rule must not
            # quietly replace one with another.
            if (Test-Path -LiteralPath $dst) {
                $existing = Get-Item -LiteralPath $dst
                if ([int64]$existing.Length -ge [int64]$f.Bytes) {
                    Write-Log 'WARN' ("not settling '{0}': '{1}' is already in the library at {2:N2} GB" -f `
                        $t.name, $f.Leaf, ([int64]$existing.Length / 1GB))
                    $failed += $f
                    continue
                }
            }

            if ($DryRun) {
                $moved += $f
                continue
            }

            try {
                $parent = Split-Path -Parent $dst
                if (-not (Test-Path -LiteralPath $parent)) {
                    New-Item -ItemType Directory -Path $parent -Force | Out-Null
                }
                Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop

                # Verified by SIZE, not by the move command's exit status. A move
                # that reports success and leaves a short file is the failure worth
                # catching, and it is the one that would take the entry with it.
                if (Test-Path -LiteralPath $dst) {
                    $after = Get-Item -LiteralPath $dst
                    if ([int64]$after.Length -eq [int64]$f.Bytes) {
                        $moved += $f
                        Write-Log 'MOVE' ("{0} -> {1} ({2:N2} GB, verified)" -f $src, $dst, ([int64]$f.Bytes / 1GB))
                    }
                    else {
                        Write-Log 'WARN' ("settle size mismatch for '{0}': wrote {1} bytes, expected {2} - entry kept" -f `
                            $f.Leaf, [int64]$after.Length, [int64]$f.Bytes)
                        $failed += $f
                    }
                }
                else {
                    Write-Log 'WARN' ("settle could not verify '{0}' at {1} - entry kept" -f $f.Leaf, $dst)
                    $failed += $f
                }
            }
            catch {
                Write-Log 'WARN' ("settle failed for '{0}': {1} - entry kept" -f $f.Leaf, $_.Exception.Message)
                $failed += $f
            }
        }

        if ($DryRun) {
            foreach ($f in $moved) {
                $short = $t.name
                if ($short.Length -gt 40) { $short = $short.Substring(0, 40) }
                [void]$script:actions.Add(("WOULD SETTLE  {0}  ->  {1}" -f $short, $f.Target))
            }
            Write-Log 'MOVE' ("[DRY-RUN] would settle {0} media file(s) from '{1}' into {2}" -f $moved.Count, $t.name, $sv.Dir)
            $settleCount++
            continue
        }

        if ($failed.Count -gt 0) {
            # Partial success is still partial. The entry stays, because it is the
            # only record of what the files that did not land were.
            Write-Log 'WARN' ("'{0}' not settled: {1} of {2} file(s) did not verify - entry left in place" -f `
                $t.name, $failed.Count, @($sv.Files).Count)
            [void]$script:notes.Add(("settle incomplete: {0} - {1} file(s) did not verify" -f $t.name, $failed.Count))
            continue
        }

        if (-not $stoppedOk) {
            Write-Log 'WARN' ("'{0}' moved but not confirmed stopped - entry left in place" -f $t.name)
            [void]$script:notes.Add("settle withheld: the stop could not be confirmed")
            continue
        }

        # Every file is in the library and verified. The entry is now the only
        # thing left of the torrent, and the data is not its to delete.
        #
        # -Knows. The entry is finished, so the burden of proof applies - and it is
        # met: the files this rule just moved are named in its own log lines, and
        # they were verified by size. This is a keeper that was SEEN, not one that
        # was merely absent.
        #
        # -DeleteFiles $false. The bytes are the library's now. Deleting them would
        # be the whole loss this rule exists to avoid.
        $leafNames = @($moved | ForEach-Object { $_.Leaf }) -join ', '
        Remove-Torrent -T $t -Knows -DeleteFiles $false -Reason `
            ("finished, and nothing unfinished held {0}; {1} settled into {2} and verified, so the entry is left with nothing to own" -f `
             $(if ($sv.Reason -match 'nothing unfinished holds (.+?) -') { $Matches[1] } else { 'these episodes' }), $leafNames, $sv.Dir)

        # The folder the pack left behind. Only when it holds no media file at all,
        # because anything that still carries an episode is the library's problem
        # and not this rule's to reason about.
        if ($t.content_path) {
            $left = @(Get-ChildItem -LiteralPath $t.content_path -Recurse -File -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match '(?i)\.(mkv|mp4|avi|m4v)$' })
            if ($left.Count -eq 0) {
                try {
                    Remove-Item -LiteralPath $t.content_path -Recurse -Force -ErrorAction Stop
                    Write-Log 'INFO' ("removed the emptied folder '{0}'" -f $t.content_path)
                }
                catch {
                    Write-Log 'WARN' ("could not remove the emptied folder '{0}': {1}" -f $t.content_path, $_.Exception.Message)
                }
            }
        }

        $settleCount++
    }

    Write-Host ("  {0} settled, {1} held back" -f $settleCount, $settleWait)
}

# -- rule 6: orphan reaper ---------------------------------------------------
#
# Runs last, after every deletion and every move, so the claim check sees the
# state this run actually left behind rather than the snapshot taken before it.
# This is the only rule that acts on the filesystem instead of on qBittorrent's
# torrent list, so it is the one fenced in hardest: explicit roots, the library
# excluded regardless of config, an age gate, a fresh claim check, and a
# containment re-check inside the delete itself.

if ($cfg.PSObject.Properties['reapOrphans'] -and $cfg.reapOrphans) {

    $reapRoots = @()
    if ($cfg.PSObject.Properties['reapRoots']) { $reapRoots = @($cfg.reapRoots) }

    $reapMinAge = 24.0
    if ($cfg.PSObject.Properties['reapMinAgeHours']) { $reapMinAge = [double]$cfg.reapMinAgeHours }

    # The library is never reaped, whatever the config happens to say.
    $reapExclude = @($cfg.moviesDir, $cfg.seriesDir)

    Write-Host ''
    Write-Host "Orphan reaper (untouched for $([int]$reapMinAge)h)"

    if ($reapRoots.Count -eq 0) {
        Write-Host '  no reapRoots configured; nothing scanned'
        Write-Log 'WARN' 'reaper is enabled but reapRoots is empty, so nothing was scanned'
    }
    else {
        # Re-read the torrent list so the claim check reflects what qBittorrent
        # holds now. A single failing call here stops the run through the usual
        # API-failure path, which is the right outcome: an unknown torrent list
        # is exactly the state in which deleting files would be reckless.
        $reapTorrents = @(Invoke-ApiGet -Endpoint 'torrents/info')

        $reap = Get-ReapCandidates -Roots $reapRoots -Torrents $reapTorrents `
                                    -MinAgeHours $reapMinAge -ExcludeDirs $reapExclude -Now $now

        if ($reap.Blocked) {
            Write-Host "  SKIPPED: $($reap.Blocked)"
            Write-Log 'WARN' "reaper skipped: $($reap.Blocked)"
        }
        elseif ($reap.Candidates.Count -eq 0) {
            Write-Host ("  nothing to reap; {0} item(s) kept under {1} root(s)" -f $reap.Skipped.Count, $reapRoots.Count)
        }
        else {
            $reapBytes = [int64]0
            foreach ($c in $reap.Candidates) {
                $kind = if ($c.IsDir) { 'dir ' } else { 'file' }
                Write-Host ("  {0} {1,8:N2} GB  idle {2,6:N1}h  {3}" -f $kind, ($c.Bytes / 1GB), $c.IdleHours, $c.Path)
                $reapBytes += $c.Bytes
            }

            $reaped = 0
            $reapedBytes = [int64]0
            foreach ($c in $reap.Candidates) {
                # Last claim check, as close to the delete as the rule order
                # allows. Cheap, and it narrows the window in which a torrent
                # added after the snapshot could claim the folder.
                $late = Test-Claimed -Path $c.Path -Torrents $reapTorrents
                if ($null -ne $late) {
                    Write-Log 'INFO' "'$($c.Path)' is claimed by '$($late.name)'; left in place"
                    continue
                }
                if (-not $DryRun -and (Remove-OrphanPath -Path $c.Path -Roots $reapRoots)) {
                    $reaped++
                    $reapedBytes += $c.Bytes
                }
                elseif ($DryRun) {
                    [void](Remove-OrphanPath -Path $c.Path -Roots $reapRoots)
                }
            }

            $nDirs = @($reap.Candidates | Where-Object { $_.IsDir }).Count
            Write-Host ("  {0} candidate(s): {1} dir, {2} file, {3} total" -f `
                $reap.Candidates.Count, $nDirs, ($reap.Candidates.Count - $nDirs), (Format-Bytes $reapBytes))
            if ($DryRun) {
                $script:notes += "would reap $($reap.Candidates.Count) orphan(s), $(Format-Bytes $reapBytes)"
            }
            elseif ($reaped -gt 0) {
                $script:notes += "reaped $reaped orphan(s), $(Format-Bytes $reapedBytes) freed"
            }
            else {
                $script:notes += 'no orphan was actually removed'
            }
        }
    }
}

# -- rule 7: backup reaper -----------------------------------------------------
#
# The manager writes a .bak next to each file it rewrites, kept as an undo
# corridor. Without a cap those pile up: at one edit per run they would outnumber
# the real files within a week. Four days is long enough to undo a bad edit and
# short enough that last week's copies never linger.

$backupDays = 4.0
if ($cfg.PSObject.Properties['backupMaxAgeDays']) { $backupDays = [double]$cfg.backupMaxAgeDays }

if ($backupDays -gt 0) {
    Write-Host ''
    Write-Host "Backup reaper (older than $([int]$backupDays)d)"
    $cutoff = (Get-Date).AddDays(-$backupDays)
    $stale = @(Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File -Filter '*.bak*' -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTime -lt $cutoff })
    if ($stale.Count -eq 0) {
        Write-Host "  no backup older than $([int]$backupDays) days"
    } else {
        $gb = [int64]0
        foreach ($s in $stale) {
            Write-Host ("  old backup  {0}  ({1} days)" -f $s.FullName, [math]::Round(((Get-Date) - $s.LastWriteTime).TotalDays, 1))
            if (-not $DryRun) {
                try { Remove-Item -LiteralPath $s.FullName -Force } catch { Write-Log 'WARN' "could not remove old backup $($s.FullName): $($_.Exception.Message)" }
            }
            $script:actions += "DELETE-BACKUP $($s.FullName)"
            $gb += $s.Length
        }
        $script:notes += "old backups pruned: $($stale.Count) file(s), $(Format-Bytes $gb) freed"
    }
}

# -- rule 8: log reaper --------------------------------------------------------
#
# Without this the logs only ever grew. The manager writes ONE FILE PER DAY
# (manager-yyyy-MM-dd.log), so nothing ever overwrites or rotates them and the
# total climbs forever. It looked harmless at first - one day was 3,9 KB - but a
# single busy run logs a line per torrent, and 258 of them is tens of kilobytes
# per pass, several passes a day. Small and unbounded is still unbounded, and
# this is a directory on the same volume as the media.
#
# EVERYTHING IN logs\ PASSES THE CUTOFF, and that includes the deleted-*.csv
# worksheets. An earlier version filtered to 'manager-*.log' and spared the CSV,
# on the claim that it was the only record of the 205 torrents deleted on
# 2026-10-05. That claim did not survive checking: the file records
# Name,HashFirst8,Reason, and 8 hex characters is not the 40-character infohash,
# so it cannot re-add a torrent by hash or by magnet. It is a diagnostic list of
# what was deleted and why - useful, but not a restore path, and worth 33 KB
# against 208 GB free. So it goes on the same clock as everything else.
#
# Non-recursive on purpose. logs\ holds flat files the manager wrote; nothing
# here should descend into a subfolder, and a recursive delete in a directory
# that also receives writes is a bad shape to leave lying around.
#
# Today's own log is skipped by name. That is not a retention opinion: the run
# doing the deleting is appending to that file as it goes, and deleting it
# mid-run would take the current run's own record with it.

$logDays = 4.0
if ($cfg.PSObject.Properties['logRetentionDays']) { $logDays = [double]$cfg.logRetentionDays }

if ($logDays -gt 0) {
    Write-Host ''
    Write-Host "Log reaper (everything in logs\ older than $([int]$logDays)d)"
    $logCutoff = (Get-Date).AddDays(-$logDays)
    $todayName = Split-Path -Leaf $logPath
    $oldLogs = @(Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.LastWriteTime -lt $logCutoff -and $_.Name -ne $todayName })
    if ($oldLogs.Count -eq 0) {
        Write-Host "  nothing in logs\ older than $([int]$logDays) days"
    } else {
        $lb = [int64]0
        foreach ($l in $oldLogs) {
            Write-Host ("  old  {0}  ({1} days, {2})" -f $l.Name, [math]::Round(((Get-Date) - $l.LastWriteTime).TotalDays, 1), (Format-Bytes $l.Length))
            if (-not $DryRun) {
                try { Remove-Item -LiteralPath $l.FullName -Force }
                catch { Write-Log 'WARN' "could not remove old log file $($l.FullName): $($_.Exception.Message)" }
            }
            $script:actions += "DELETE-LOG $($l.Name)"
            $lb += $l.Length
        }
        $script:notes += "old logs pruned: $($oldLogs.Count) file(s), $(Format-Bytes $lb) freed"
    }
}

# -- persist state ----------------------------------------------------------

if (-not $DryRun) {
    $state | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

# -- summary ----------------------------------------------------------------

Write-Host ''
Write-Host 'Summary'
if ($script:actions.Count -eq 0) {
    Write-Host '  nothing to do'
} else {
    foreach ($a in $script:actions) { Write-Host "  $a" }
}
foreach ($n in $script:notes) { Write-Host "  $n" }

$delCount = @($script:actions | Where-Object { $_ -match '^(DELETE|WOULD DELETE)' }).Count
Write-Host ''
Write-Log 'INFO' "run end; $($script:actions.Count) action(s), $delCount deletion(s), dryRun=$([bool]$DryRun)"

# Release the lock. Exit-Run does the same for every early exit, so this only
# covers the ordinary finish.
if ($script:lockTaken) {
    Remove-Item -LiteralPath $script:lockPath -Force -ErrorAction SilentlyContinue
}
