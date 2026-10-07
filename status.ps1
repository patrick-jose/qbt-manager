<#
.SYNOPSIS
    Live view of what qbt-manager is doing right now.

.DESCRIPTION
    Reads the same files qbt-manager writes, plus the qBittorrent Web API, so
    you can watch an unattended process from a second window without attaching
    to the console it runs in. Nothing here deletes, moves, or pauses anything.

    The important idea is that this script never re-decides anything. It reports
    what the manager recorded, and for anything still pending it reuses the
    manager's own detection functions, lifted straight out of qbt-manager.ps1,
    so a preview can never disagree with the real thing by being a second,
    separately-maintained copy of the rules.

    Sections, roughly in order of how often you will actually want them:

      QUEUE           every torrent, grouped by title, with a verdict per member
      PENDING         what the next run will delete, and why - nothing has run
      METADATA        magnets still inside the no-metadata tolerance, with the
                      countdown to when they would be deleted
      DRIVES          free space, and whether it is enough for what is queued
      SCHEDULED TASK  last run, next run, exit code
      RECENT ACTIVITY the manager's own audit log

    Refreshes itself until you close it or press Ctrl+C.

The panel is deliberately ACTION-FIRST. With a few hundred torrents the
    full listing is thousands of lines, which buries the three or four rows that
    actually matter: what the next run will delete, which magnets are about to
    expire, and whether anything has gone wrong. So the default view leads with
    those and caps everything, with '+N more' where the list was cut. The
    complete queue, and every magnet rather than the ones near expiry, are one
    switch away - see -Full.

.PARAMETER Watch
    Keep refreshing every few seconds. Without it, prints one snapshot.

.PARAMETER Full
    Print the whole queue and every magnet, unbounded. The default is the
    summary; this is the wall of rows.

.PARAMETER Tail
    How many log lines to show. Default 8. The log is mostly 'parsed' lines -
    one per torrent per run - and those are not status, so they are filtered out
    unless -All is given.

.PARAMETER All
    Include the low-value log lines too (INFO / ACTION), not just deletions,
    moves, warnings and errors.

.PARAMETER RefreshSeconds
    Seconds between refreshes under -Watch. Default 30.

.EXAMPLE
    .\status.ps1            # one summary snapshot
    .\status.ps1 -Watch     # live, refreshing
    .\status.ps1 -Full      # every torrent and every magnet
    .\status.ps1 -All -Tail 40   # full log history including parsing noise
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Watch,
    [switch]$Full,
    [switch]$All,
    [int]$Tail = 8,
    [int]$RefreshSeconds = 30
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }

# config.local.json is merged over config.json, exactly as the manager does it -
# see Get-MergedConfig in qbt-manager.ps1 for why there are two files and why the
# merge is shallow. Restated rather than shared because these two scripts are
# deliberately independent: status.ps1 must be runnable without the manager.
function Read-PreviewConfig {
    param([string]$Path, [string]$Root)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "config.json not found at $Path" -ForegroundColor Red
        Write-Host 'It is committed, so restore it with:  git checkout config.json' -ForegroundColor Red
        exit 2
    }

    $base = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $localPath = Join-Path $Root 'config.local.json'
    if (-not (Test-Path -LiteralPath $localPath)) { return $base }

    try {
        $local = [System.IO.File]::ReadAllText($localPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    }
    catch {
        Write-Host 'config.local.json is unreadable, ignoring it.' -ForegroundColor Yellow
        return $base
    }

    # "//" keys are comments, skipped rather than merged - see Get-MergedConfig in
    # qbt-manager.ps1.
    foreach ($p in $local.PSObject.Properties) {
        if ($p.Name.StartsWith('//')) { continue }
        $base | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
    }
    return $base
}

$cfg = Read-PreviewConfig -Path $ConfigPath -Root $PSScriptRoot

$GB = 1GB
$logDir = Join-Path $PSScriptRoot 'logs'
$statePath = Join-Path $PSScriptRoot 'state.json'
$taskName = 'qbt-manager'

# ---------------------------------------------------------------------------
# lift the manager's own detection functions
#
# Get-TitleParts / Test-SameTitle / Get-DoviHit / Get-DiscRipHit are what decide
# whether two torrents are the same film, whether a name advertises Dolby Vision,
# and whether something is a full Blu-ray disc structure. Those are the parts
# most likely to be subtly wrong, so they are not reimplemented here. They are
# extracted from the manager's source and evaluated verbatim, which means a fix
# to the rules shows up in this preview with no work on this side.
#
# The slice runs from the boundary-pattern declaration to the first action
# function, which is exactly the pure-decision region. Everything below that
# point touches the API to delete or move things, and is deliberately excluded.
# ---------------------------------------------------------------------------

$managerPath = Join-Path $PSScriptRoot 'qbt-manager.ps1'
if (-not (Test-Path -LiteralPath $managerPath)) {
    throw "cannot find qbt-manager.ps1 next to this script (looked in $PSScriptRoot)"
}
$src = [System.IO.File]::ReadAllText($managerPath, [System.Text.Encoding]::UTF8)
$sliceStart = $src.IndexOf('$script:boundaryPattern')
$sliceEnd = $src.IndexOf('# actions')
if ($sliceStart -lt 0 -or $sliceEnd -le $sliceStart) {
    throw 'could not locate the detection block in qbt-manager.ps1 - the markers it is sliced by have moved'
}
Invoke-Expression $src.Substring($sliceStart, $sliceEnd - $sliceStart)

# ---- small helpers ---------------------------------------------------------

function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p -or $null -eq $p.Value) { return $Default }
    return $p.Value
}

# The activity table carries a full torrent name and a reason, which needs more
# room than the other sections were laid out for. Follow the console, but never
# drop below what those sections need.
function Get-Width {
    $cw = 0
    try { $cw = [Console]::WindowWidth } catch { $cw = 0 }
    # redirected or headless: assume a normal modern console
    if ($cw -lt 40) { $cw = 140 }
    return [Math]::Min(170, [Math]::Max(95, $cw - 1))
}

# Read the API through a temp file rather than the pipeline. PowerShell 5.1
# decodes native command output using the console code page, which turns the
# UTF-8 bytes of an accented character into two Latin-1 ones. Torrent names here
# really do contain accents, so this is not optional.
#
# This is a status display, not the manager, so the tradeoffs differ: no retries
# (a stale panel is better than a slow one) and much tighter timeouts. Loopback
# answers in milliseconds when it is healthy, so a 2s connect and a 5s ceiling
# are already generous. The important part is that the supplementary calls are
# skipped when the essential one fails - see Show-Snapshot - so a dead API costs
# one timeout rather than three.
function Get-Api {
    param([string]$Endpoint)

    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        $referer = ([uri]$cfg.baseUrl).GetLeftPart([System.UriPartial]::Authority)
        & curl.exe -s --connect-timeout 2 --max-time 5 -H "Referer: $referer" -o $tmp `
            "$($cfg.baseUrl)/$Endpoint" 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        $raw = [System.IO.File]::ReadAllText($tmp, (New-Object System.Text.UTF8Encoding($false)))
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        if ($Endpoint -eq 'app/version') { return $raw.Trim().Trim('"') }
        try { return ($raw | ConvertFrom-Json) } catch { return $raw.Trim() }
    }
    catch { return $null }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

# A name long enough to overflow its column is truncated with a marker rather
# than allowed to push the rest of the row sideways.
function Fit {
    param([string]$Text, [int]$Width)
    if (-not $Text) { return '' }
    if ($Text.Length -le $Width) { return $Text }
    if ($Width -le 3) { return $Text.Substring(0, [Math]::Max(1, $Width)) }
    return $Text.Substring(0, $Width - 3) + '...'
}

# A section heading: title, optional count, and a rule under it.
function Write-Section {
    param(
        [string]$Title,
        [object]$Count,
        [int]$Width,
        [string]$Color = 'Cyan'
    )
    Write-Host ''
    if ($null -ne $Count) {
        Write-Host ("{0} ({1})" -f $Title, $Count) -ForegroundColor $Color
    }
    else {
        Write-Host $Title -ForegroundColor $Color
    }
    Write-Host ('-' * $Width) -ForegroundColor DarkGray
}

# When a list had to be cut, say so - and say how to see the rest. A silently
# truncated panel reads as "that is everything", which is a lie.
function Write-Truncated {
    param([int]$Shown, [int]$Total, [string]$How)
    if ($Shown -ge $Total) { return }
    $hidden = $Total - $Shown
    $more = "  ... and $hidden more ($How)"
    Write-Host $more -ForegroundColor DarkGray
}

# One line of log text, wrapped rather than truncated, so a destination path or
# a reason is never cut off mid-word. Returns nothing; writes directly.
function Write-WrappedLine {
    param(
        [string]$Text,
        [int]$Width,
        [string]$Indent,
        [string]$Color
    )
    $rest = $Text
    $first = $true
    while ($rest.Length -gt 0) {
        $take = [Math]::Min($Width, $rest.Length)
        if ($take -lt $rest.Length) {
            # Break on a space so a path is never split inside a word.
            $sp = $rest.LastIndexOf(' ', $take)
            if ($sp -gt 0) { $take = $sp }
        }
        $line = $rest.Substring(0, $take)
        $rest = $rest.Substring($take).TrimStart()
        if ($first) {
            Write-Host ($Indent + $line) -ForegroundColor $Color
            $first = $false
        }
        else {
            Write-Host ($Indent + '    ' + $line) -ForegroundColor $Color
        }
    }
}

# The manager's log is dominated by 'parsed <name> -> title=... ' lines: one per
# torrent per run, so a couple hundred of them every fifteen minutes. They are
# the manager narrating its own parsing, not status, and they push every
# deletion and warning off the bottom of the panel. So only the levels that
# describe a change or a problem are shown unless -All is passed.
function Select-InterestingLog {
    param($Rows, [bool]$IncludeAll = $false)
    if ($IncludeAll) { return @($Rows) }
    return @($Rows | Where-Object { $_.Level -ne 'INFO' -and $_.Level -ne 'ACTION' })
}

# The single-file / multi-file distinction is worth surfacing: it is why a
# finished film can show as a folder rather than a file, and it is what the
# library move acts on.
function Get-ContentKind {
    param($T)
    $p = Get-Prop $T 'content_path'
    if (-not $p) { return 'unknown' }
    if (-not (Test-Path -LiteralPath $p)) { return 'not created' }
    $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if ($null -eq $i) { return 'unknown' }
    if ($i.PSIsContainer) { return 'folder' }
    return 'file'
}

# ---- the manager's rule set, re-run read-only ------------------------------
#
# Each function below answers one question and returns a verdict per torrent.
# They call the lifted detection functions only. None of them deletes anything.

# Would rule 1 or 1b remove this torrent outright?
# An errored torrent is not a deletion candidate - the manager's Remove-Torrent
# refuses it unless the rule passes -AllowErrored. Restated rather than sliced:
# Test-Errored sits beside Remove-Torrent, in the actions region of the manager,
# and this script only lifts the detection region.
#
# Used in exactly ONE place here - the pack-vs-single pass - because that is the
# only comparison where an errored torrent must still be spared. The DoVi and
# disc-rip exclusions are unconditional in the manager, in any state, and decide
# from the name and the on-disk structure rather than from progress, so they
# report an errored match exactly as they report any other.
function Test-Errored {
    param($T)
    if ($null -eq $T) { return $false }
    return ([string](Get-Prop $T 'state') -eq 'error')
}

function Get-ExclusionVerdict {
    param($T)
    $dovi = Get-DoviHit -Name (Get-Prop $T 'name')
    if ($dovi) {
        return [pscustomobject]@{ Verdict = 'EXCLUDE'; Rule = 'DoVi'; Reason = "Dolby Vision marker '$dovi'" }
    }
    if ((Get-Prop $cfg 'excludeBluRayDiscRips')) {
        $disc = Get-DiscRipHit -T $T
        if ($disc) {
            return [pscustomobject]@{ Verdict = 'EXCLUDE'; Rule = 'disc rip'; Reason = "full Blu-ray disc structure - $disc" }
        }
    }
    return $null
}

# Group the live torrents the way the manager clusters them: by parsed title,
# never by raw name, so two different releases of one film land together.
function Get-Clusters {
    param($Torrents, [string]$Only)

    $clusters = New-Object System.Collections.ArrayList
    foreach ($t in $Torrents) {
        $verdict = Get-ExclusionVerdict -T $t
        Add-Member -InputObject $t -NotePropertyName exclusion -NotePropertyValue $verdict -Force
        if ($verdict) { continue }

        $parts = $null
$parts = $null
        try { $parts = Get-TitleParts -Name (Get-Prop $t 'name') } catch { $parts = $null }

        # Identity resolved through titleAliases, exactly as the manager does it.
        # Resolve-PartsAlias is inside the slice above, so this is the same function
        # and not a second copy that can drift.
        #
        # Without this the preview filed the release under one show and the run
        # under another - or rather, the preview showed it as its own show and the
        # run would never have grouped it with anything. 'Euforie - Euphoria
        # S03E01' parses as 'euforie euphoria', which is Euphoria, and only the
        # user's alias says so.
        if ($parts) { $parts = Resolve-PartsAlias -Parts $parts -Aliases $cfg.titleAliases }

        Add-Member -InputObject $t -NotePropertyName parts -NotePropertyValue $parts -Force
        if (-not $parts) { continue }

        if ($Only -and ($parts.Title -notlike "*$Only*")) { continue }

        $placed = $false
        foreach ($c in $clusters) {
            if (Test-SameTitle -A $parts -B $c[0].parts) { [void]$c.Add($t); $placed = $true; break }
        }
        if (-not $placed) {
            $nc = New-Object System.Collections.ArrayList
            [void]$nc.Add($t)
            [void]$clusters.Add($nc)
        }
    }
    # Same second pass the manager runs, so a group here is a group there.
    return (Merge-SeriesClusters -Clusters $clusters)
}

# Group label, built the same way the manager builds it.
function Get-ClusterLabel {
    # The SHOW name only. The season and episode part of a group header comes
    # from the episode set being printed, so a header reading S18E1-E8 can
    # only ever sit above releases that really hold episodes 1 to 8.
    param($Members)
    return (Get-ShowLabel -Parts @($Members | ForEach-Object { $_.parts }))
}

# The label for a whole show family, for display.
#
# Merge-SeriesClusters already computes one canonical name per family - the
# longest run every member agrees on - and stamps it onto each member as
# showLabel. Using it here is what stops one show printing as several groups:
# Get-ClusterLabel reads the FIRST MEMBER's own title, so which cluster won a
# merge decided the name, and that varies per episode. Measured: one show came
# out as four rows while every cluster already held both of its titles.
#
# Falls back to Get-ClusterLabel when no family label was stamped - films never
# enter that pass, and a family whose members share no leading word has none.
function Get-FamilyLabel {
    param($Members)
    foreach ($m in $Members) {
        if ($m.PSObject.Properties['showLabel'] -and $m.showLabel) { return $m.showLabel }
    }
    return (Get-ClusterLabel -Members $Members)
}

# The episode-set key a torrent is judged under, correcting a name that claims a
# whole season when its own files say otherwise.
#
# Mirrors Resolve-TorrentSetKey in qbt-manager.ps1, against this script's own HTTP
# layer. The shared pure half, Get-EpisodeSetFromFiles, is lifted from the
# manager's detection region like every other helper here - only the fetch has to
# be written twice, because the two scripts talk to qBittorrent differently.
#
# Only a name-derived S<n>-ALL is corrected. It is the one key that makes a claim
# the name cannot support and the one that silently disables dedup, because no
# range key can equal it. A magnet has no file list yet and keeps the name's key.
function Resolve-SetKey {
    param($T, $Cache)

    $parts = Get-Prop $T 'parts'
    $nameKey = Get-EpisodeSetKey -Parts $parts
    if ($nameKey -notmatch '^S\d+-ALL$') { return $nameKey }
    $hash = [string](Get-Prop $T 'hash')
    if (-not $hash) { return $nameKey }

    $key = $hash.ToLowerInvariant()
    if ($null -eq $Cache) { $Cache = @{} }
    if (-not $Cache.ContainsKey($key)) {
        $got = Get-Api -Endpoint ("torrents/files?hash=" + $hash)
        $Cache[$key] = if ($null -eq $got) { @() } else { @($got) }
    }

    $fromFiles = Get-EpisodeSetFromFiles -Files @($Cache[$key])
    if (-not $fromFiles) { return $nameKey }
    return $fromFiles
}

# Rule 4, replayed. Returns a hash of hash -> reason for everything the next run
# would delete inside a cluster. Ordering within the cluster matters and matches
# The manager's rule: the largest finished version in a group is the keeper, and
# everything smaller goes - finished or not. Bigger unfinished versions survive.
function Get-DedupVerdicts {
    # TolerancePercent is the user's 10%: two encodes of one episode closer than
    # this are the same episode, so one of them is redundant. It defaults to 10 and
    # is passed from libraryRedundantTolerancePercent, so the preview and the run
    # cannot disagree about where the line sits. Rule 4d in the manager reads the
    # same key for the same reason.
    param($Clusters, $Gone, [double]$TolerancePercent = 10)

    $verdicts = @{}

    # Clusters are folded by show family first, exactly as the manager now does.
    # A cluster is built from the release TITLE, so two packs of one show whose
    # names differ were never compared - which is how a finished 40 GB
    # 'Euphoria.S03.COMPLETE' sat beside an unfinished 15 GB
    # 'Euphoria US S03e01-08' of the very same eight episodes with the preview
    # silent about it. Folding cannot widen the comparison past a set key, so a
    # pack still never meets a single and two different ranges still never meet.
    # Films keep one cluster per group, as they always have.
    $setGroups = @()
    $famInfo = Get-ClusterFamilies -Clusters $Clusters
    $fams = @($famInfo.Family)
    $byFamily = @{}
    $familyOrder = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Clusters.Count; $i++) {
        $f = if ($i -lt $fams.Count) { $fams[$i] } else { '' }
        if (-not $f) { $setGroups += , @($Clusters[$i]); continue }
        if (-not $byFamily.ContainsKey($f)) {
            $byFamily[$f] = New-Object System.Collections.ArrayList
            [void]$familyOrder.Add($f)
        }
        [void]$byFamily[$f].Add($i)
    }
    foreach ($f in $familyOrder) {
        $g = New-Object System.Collections.ArrayList
        foreach ($i in $byFamily[$f]) { foreach ($m in $Clusters[$i]) { [void]$g.Add($m) } }
        $setGroups += , @($g)
    }

    # One file listing per torrent for the whole pass, so a season full of packs
    # does not re-read the same listing once per group it appears in.
    $setKeyCache = @{}

    foreach ($c in $setGroups) {
        $members = @($c | Where-Object { -not $Gone.ContainsKey($_.hash) })
        if ($members.Count -lt 2) { continue }

        $label = Get-ClusterLabel -Members $members

        # Mirrors qbt-manager.ps1: the rule runs per SET OF EPISODES, not per
        # cluster. A cluster only holds releases whose first episode agrees, so
        # a 10-episode pack, a 6-episode pack and a single episode 1 can all sit
        # in it; comparing those totals would preview the smallest as redundant
        # while it still holds episodes nothing else has. Splitting by the exact
        # set keeps every ordinary case identical and makes packs comparable
        # only when their range matches, which is when they are true rivals.
        $sets = @{}
        foreach ($m in $members) {
            $k = Resolve-SetKey -T $m -Cache $setKeyCache
            if (-not $k) { continue }
            if (-not $sets.ContainsKey($k)) { $sets[$k] = New-Object System.Collections.ArrayList }
            [void]$sets[$k].Add($m)
        }

        foreach ($k in @($sets.Keys | Sort-Object)) {
            $set = @($sets[$k])
            if ($set.Count -lt 2) { continue }

            # The largest finished version is the keeper; other smaller or equal copies
            # goes, finished or not. Bigger unfinished versions are left alone.
            # This mirrors qbt-manager.ps1 exactly - the preview must not become
            # a second, separately-maintained copy of the rule.
            #
            # 'size' is the TOTAL size, not the bytes fetched so far. A total of
            # 0 means the size is unknown - a magnet with no metadata yet - which
            # is not the same as being the smallest release, so it is skipped
            # instead of being reported as a duplicate.
            $complete = @($set | Where-Object { (Get-Prop $_ 'progress') -ge 1 })
            if ($complete.Count -ge 1) {
                $keeper = @($complete | Sort-Object -Property @{ Expression = { $_.size }; Descending = $true }, hash)[0]
                foreach ($m in $set) {
                    if ($m.hash -eq $keeper.hash) { continue }
                    if ((Get-Prop $m 'size') -le 0) { continue }
                    if ((Get-Prop $m 'size') -le 0) { continue }
                    
                    # Bigger than the keeper: left alone, UNLESS it is an unfinished
                    # copy that is not MEANINGFULLY bigger - the same tolerance the
                    # manager applies, read from the same config key.
                    #
                    # A FINISHED copy bigger than the keeper IS the keeper, so the
                    # tolerance can only ever reach an unfinished one.
                    #
                    # Mirrored from qbt-manager.ps1 on purpose. Left at a strict
                    # '>=', this copy previews three downloads of one episode as
                    # clean while the scheduled run deletes them - the panel lying
                    # about the run, which is the same failure as the drain printing
                    # 'witness at position 0' when there was no witness at all.
                    $gap = ''
                    if ((Get-Prop $m 'size') -gt (Get-Prop $keeper 'size') -or
                        ((Get-Prop $m 'size') -eq (Get-Prop $keeper 'size') -and (Get-Prop $m 'progress') -lt 1)) {
                        if ((Get-Prop $m 'progress') -ge 1) { continue }
                        $over = ((Get-Prop $m 'size') - (Get-Prop $keeper 'size')) / (Get-Prop $keeper 'size')
                        if ($over -gt ($TolerancePercent / 100.0)) { continue }
                        $why = 'incomplete, and not meaningfully bigger than a finished version'
                        $gap = (" - only {0:N2}% bigger, inside the {1:N0}% tolerance" -f ($over * 100), $TolerancePercent)
                    }
                    else {
                        # NO errored guard here, and that is deliberate and must stay in
                        # step with the manager.
                        #
                        # Elsewhere an errored torrent is protected. Here it is not,
                        # because $k is Resolve-SetKey - the keeper holds the
                        # IDENTICAL episodes and is FINISHED - so an errored member of
                        # this group is a spare copy that failed, not lost data.
                        #
                        # The guard belongs on the DoVi / disc-rip path (an unconditional
                        # rule that never established anything better existed) and on the
                        # pack-vs-single path (which requires BOTH sides complete, so an
                        # errored single is skipped there anyway). This set-level
                        # comparison is the one place the manager passes -AllowErrored.
                        $why = if ((Get-Prop $m 'progress') -ge 1 -and (Get-Prop $m 'size') -eq (Get-Prop $keeper 'size')) { 'equal-size completed duplicate' }
                               elseif ((Get-Prop $m 'progress') -ge 1) { 'smaller completed version' }
                               elseif (Test-Errored $m) { 'errored, and the same episodes are already finished elsewhere' }
                               else { 'incomplete, and a bigger version is already finished' }
                    }
                    $verdicts[$m.hash] = [pscustomobject]@{
                        Verdict = 'DELETE'; Rule = 'dedup'
                          Reason  = ("{0}{1} of '{2}' ({3}); '{4}' is finished at {5:N2} GB against {6:N2} GB" -f `
                                     $why, $gap, $label, $k, $keeper.name,
                                   ((Get-Prop $keeper 'size') / $GB), ((Get-Prop $m 'size') / $GB))
                    }
                }
            }
        }

        # Pack vs single-episode contained in it, same rule as the manager:
        # a completed pack and a completed single of that pack are two torrents
        # holding the same episode, so the smaller copy of THAT episode goes.
        # $fileSizeCache holds one file listing per pack for the whole preview.
        $fileSizeCache = @{}
        foreach ($pack in $members) {
            if ($Gone.ContainsKey($pack.hash)) { continue }
            if (-not $pack.parts) { continue }
            if (-not $pack.parts.IsMultiEpisode) { continue }
            if (-not $pack.parts.EpisodeLast) { continue }
            if ((Get-Prop $pack 'progress') -lt 1) { continue }
            foreach ($single in $members) {
                if ($Gone.ContainsKey($single.hash)) { continue }
                if ($single.hash -eq $pack.hash) { continue }
                if (-not $single.parts) { continue }
                if ($single.parts.IsMultiEpisode) { continue }
                if ($single.parts.Title -ne $pack.parts.Title) { continue }
                if ($single.parts.Season -ne $pack.parts.Season) { continue }
                if ($null -eq $single.parts.Episode) { continue }
                if ($single.parts.Episode -lt $pack.parts.Episode) { continue }
                if ($single.parts.Episode -gt $pack.parts.EpisodeLast) { continue }
                if ((Get-Prop $single 'progress') -lt 1) { continue }

                # The one episode they share, measured on both sides - the
                # same helper the manager calls, so the preview cannot report a
                # different winner than the run will pick. Dividing the pack
                # total by its episode count is not a measurement; episodes in
                # one pack differ in size, so the pack's own file for that
                # episode is the only honest number.
                $epFileBytes = Get-PackEpisodeBytes -Hash $pack.hash -Season $pack.parts.Season `
                                                    -Episode $single.parts.Episode -Cache $fileSizeCache
                if ($null -eq $epFileBytes) { continue }
                if ((Get-Prop $single 'size') -le 0) { continue }
                if (Test-Errored $single) { continue }

                # ONLY THE SINGLE IS EVER DELETED HERE, and the manager's copy of
                # this pass is narrowed the same way. Both used to pick a winner
                # and delete whichever lost, which deleted a whole PACK over one
                # episode: on 2026-10-05 a single's copy of S18E01 was 46 MB
                # bigger than the pack's own S18E01 file, and the scheduled run
                # removed a 12,54 GB E01-E08 pack whose other seven episodes had
                # no other copy anywhere. A pack is the only record qBittorrent
                # has of what it holds, so it is never the thing this pass
                # removes - only a single is, and only when the pack's own file
                # for that episode is the larger one.
                if ($epFileBytes -lt (Get-Prop $single 'size')) { continue }
                if ($verdicts.ContainsKey($single.hash)) { continue }

                $verdicts[$single.hash] = [pscustomobject]@{
                    Verdict = 'DELETE'; Rule = 'dedup-pack-single'
                    Reason  = ("holds S{0}E{1} that '{2}' already carries inside its pack; the single is {3:N2} GB and the pack's own file for that episode is {4:N2} GB, and the pack holds other episodes this single cannot replace" -f `
                               $pack.parts.Season, $single.parts.Episode, $pack.name,
                               ((Get-Prop $single 'size') / $GB), ($epFileBytes / $GB))
                }
            }
        }
    }
    return $verdicts
}

# Rule 2, replayed against the real state file, so the countdown shown here is
# the same one the manager will act on. Torrents that gained metadata drop out,
# exactly as they do there.
function Get-MetadataWatch {
    param($Torrents)

    $state = @{ hashes = @{} }
    if (Test-Path -LiteralPath $statePath) {
        try {
            $state = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        }
        catch { }
    }

    $timeout = [double](Get-Prop $cfg 'metadataTimeoutMinutes' 60)
    $limit = [int](Get-Prop $cfg 'metadataPriorityRankLimit' 10)
    $now = Get-Date
    $watch = New-Object System.Collections.ArrayList

    # ASCENDING, and it has to match qbt-manager.ps1 exactly. This function is a
    # preview of what that rule will do to the real client, so the moment the two
    # disagree it is worse than useless: it names torrents that will not be
    # touched and stays silent about the ones that will. That is not a
    # hypothetical. It happened while this line still said Descending, after the
    # sort was flipped in the manager and not here: status.ps1 reported ten
    # Euphoria magnets "will delete on next run" while the manager was going to
    # delete none of them.
    #
    # The sort orders the report only. The two conditions below are not
    # cosmetic: they decide which torrents are candidates at all.
    #
    # Both files must agree on both of them, and the tests that guard that are
    # "status.ps1 applies the same queue window as the manager" and
    # "the preview agrees on the in-window gate".
    $byPriority = @($Torrents | Sort-Object -Property @{Expression = { $_.priority }; Ascending = $true},
                                                  @{Expression = { $_.added_on };  Ascending = $true})

    for ($i = 0; $i -lt $byPriority.Count; $i++) {
        $t = $byPriority[$i]
        if ((Get-ExclusionVerdict -T $t)) { continue }

        # TRYING, not merely WAITING - the same line as the manager, and the same line
          # the drain uses a hundred lines below in this file.
          #
          # 'size 0' on its own admitted a magnet sitting in line that qBittorrent
          # had never given a slot to: it entered the table, the panel counted up
          # against it, and 30 minutes later the panel showed it as about to be
          # deleted for failing to fetch metadata it was never asked to fetch.
          $noMeta = ((Get-Prop $t 'state') -eq 'metaDL')
        if (-not $noMeta) { continue }

        # The queue window. Identical arithmetic to the manager's, deliberately.
        $pos = [int](Get-Prop $t 'priority' 0)
        $inWindow = (($limit -gt 0) -and ($pos -ge 1) -and ($pos -le $limit))

        $mins = $null
        $remaining = $null
        if ($inWindow) {
            # The clock is time spent INSIDE the window, not time since the
            # torrent was added. Read-only here: only the manager's own state
            # file can advance windowSince, so a magnet that reaches the front
            # this run shows 0 minutes, which is exactly what the manager will
            # do with it.
            $windowSince = $null
            $prop = $state.hashes.PSObject.Properties[(Get-Prop $t 'hash')]
            if ($null -ne $prop) {
                $raw = Get-Prop $prop.Value 'windowSince'
                if ($raw) {
                    try { $windowSince = [datetime]::Parse([string]$raw, [System.Globalization.CultureInfo]::InvariantCulture) }
                    catch { $windowSince = $null }
                }
            }
            if ($null -eq $windowSince) { $mins = 0.0 } else { $mins = ($now - $windowSince).TotalMinutes }
            if ($mins -lt 0) { $mins = 0.0 }
            $remaining = [Math]::Max(0, $timeout - $mins)
        }

        $seeds  = [int](Get-Prop $t 'num_seeds' 0)
        $leechs = [int](Get-Prop $t 'num_leechs' 0)

        [void]$watch.Add([pscustomobject]@{
            Name      = Get-Prop $t 'name'
            Minutes   = $mins
            Rank      = $i + 1
            QueuePos  = $pos
            InWindow  = $inWindow
            QueueLimit = $limit
            Seeds     = $seeds
            Leechs    = $leechs
            WillDelete = ($inWindow -and ($mins -ge $timeout))
            Remaining = $remaining
            Timeout   = $timeout
        })
    }
    return $watch
}

# ---------------------------------------------------------------------------
# rule 2c: the drain - one magnet an hour, behind the window
# ---------------------------------------------------------------------------

# Mirror of the manager's Test-ActivelyDownloading. Kept identical on purpose:
# this is a preview, and a preview that disagrees about what "the client is
# working" means would report a deletion the live run never performs, or hide one
# it does.
function Test-ActivelyDownloading {
    param([object]$T)
    if ($null -eq $T) { return $false }
    if ([double]$T.size -le 0) { return $false }
    if ([double]$T.progress -ge 1) { return $false }

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

# Reads the same single-clock state the manager keeps, rather than re-deciding.
# $Drain is loaded by the caller; the manager has never run the rule.
function Get-QueueDrainVerdict {
    param(
        [object[]]$Torrents,
        [datetime]$Now,
        [double]$TimeoutMinutes,
        [int]$QueueLimit,
        [object]$Drain,
        [hashtable]$Skip = @{}
    )
    if ($QueueLimit -le 0) { return @() }

    $ordered = @($Torrents | Sort-Object -Property @{Expression = { $_.priority }; Ascending = $true},
                                               @{Expression = { $_.added_on };  Ascending = $true})

    $candidate = $null
    $candPos = 0
    foreach ($t in $ordered) {
        if ($null -eq $t) { continue }
        if ($Skip.ContainsKey($t.hash)) { continue }
        $pos = [int]$t.priority
        if ($pos -lt 1) { continue }
        if ($pos -le $QueueLimit) { continue }

        # TRYING, not merely WAITING. Same line as the manager's copy.
        #
        # This accepted any torrent reporting size 0, which includes one sitting
        # in line that qBittorrent has never given a slot to. Measured on a live
        # queue:
        #
        #   pos 11-20   size 8.9 GB, 8.7 GB ...   served: working or stalled
        #   pos 21      size 0, state queuedDL     never had a turn
        #   pos 22-30   size 0, state queuedDL     never had a turn
        #
        # Position 21 became the candidate, its clock started on arrival, and 30
        # minutes later this panel would have shown it as about to be deleted for
        # failing to fetch metadata - having never been asked to fetch any.
        #
        # metaDL is the state meaning "fetching metadata right now". A magnet
        # queued behind the window is queuedDL; one whose metadata resolved has a
        # size. Rule 2 already draws this line for the same reason: "a magnet at
        # position 150 has never been handed a peer connection, so it has not tried
        # anything, and deleting it for being unavailable is really deleting it for
        # not having been started yet."
        if ($t.state -ne 'metaDL') { continue }
        $candidate = $t
        $candPos = $pos
        break
    }

    if ($null -eq $candidate) { return @() }

    # A different candidate is a new decision, so its clock has not started. The
    # preview must say so rather than borrow the previous torrent's time.
    $same = ($null -ne $Drain -and ([string]$Drain.hash -eq [string]$candidate.hash))
    $since = $null
    if ($same -and $Drain.since) {
        try { $since = [datetime]::Parse([string]$Drain.since) } catch { $since = $null }
    }

    $startedNow = $false
    if ($null -eq $since) {
        $since = $Now
        $startedNow = $true
    }

    $mins = ($Now - $since).TotalMinutes
    if ($mins -lt 0) { $mins = 0 }

    # Written in the same shape as the manager's copy of this loop, on purpose:
    # test-parsing.ps1 matches these lines in both files to prove the two have
    # not drifted apart. `[int]$t.priority` inlined here instead of a local $pos
    # would read identically and drift silently.
    $witness = $null
    foreach ($t in $ordered) {
        if ($null -eq $t) { continue }
        if ($Skip.ContainsKey($t.hash)) { continue }
        if ([string]$t.hash -eq [string]$candidate.hash) { continue }
        $pos = [int]$t.priority
        if ($pos -le $candPos) { continue }
        if (Test-ActivelyDownloading $t) { $witness = $t; break }
    }

    # StartedThisRun means the manager has not yet written a clock for it, so it
    # will be given a full tolerance no matter how old it looks.
    $timedOut = ((-not $startedNow) -and ($mins -ge $TimeoutMinutes))
    $delete = ($timedOut -and ($null -ne $witness))

    $reason = ''
    if ($delete) {
        $reason = ("no availability: {0:N0} min at queue position {1} (tolerance {2:N0}m), no size, {3} seeds {4} peers; " +
                   "torrent at position {5} is downloading, so the client is working past it" -f `
                   $mins, $candPos, $TimeoutMinutes, [int]$candidate.num_seeds, [int]$candidate.num_leechs,
                   [int]$witness.priority)
    }
    elseif ($startedNow) {
        # The tolerance is quoted from the value, never written as 60.
        #
        # It was hardcoded here while the row beside it counted down from
        # metadataTimeoutMinutes - so with that key set to 30 the panel read
        # "30m to go" directly above "its 60 minutes start now". Two numbers, one
        # row, and no way for the reader to tell which one the rule would use.
        # The user's configured tolerance is the only number that belongs here.
        $reason = ("no availability: first candidate behind the window at position {0}; its {1:N0} minutes start now" -f `
                    $candPos, $TimeoutMinutes)
    }
    elseif ($timedOut) {
        $reason = ("no availability: {0:N0} min at queue position {1} (tolerance {2:N0}m) - held, nothing further down " +
                   "the queue is downloading, so the client may be the problem rather than the torrent" -f `
                   $mins, $candPos, $TimeoutMinutes)
    }

    return @([pscustomobject]@{
        Torrent      = $candidate
        Name         = $candidate.name
        QueuePos     = $candPos
        Minutes      = $mins
        StartedNow   = $startedNow
        TimedOut     = $timedOut
        HasWitness   = ($null -ne $witness)
        Witness      = if ($null -ne $witness) { [string]$witness.name } else { '' }
        WitnessPos   = if ($null -ne $witness) { [int]$witness.priority } else { 0 }
        WillDelete   = $delete
        Reason       = $reason
    })
}

# How many days of silence the stalled rule is configured to tolerate.
function Get-StalledDays {
    $p = Get-Prop $cfg 'stalledDeleteDays'
    if ($null -eq $p) { return 0 }
    return [double]$p
}

# The manager's own stalled table, read fresh so the countdowns shown here are
# the same ones it will act on. Get-StalledWatch updates the object it is given
# as it goes, which is how the manager accumulates history between runs; this is
# an in-memory copy that is discarded when the snapshot ends, so watching can
# never advance the manager's clocks.
function Get-StalledTable {
    $table = [pscustomobject]@{}
    if (-not (Test-Path -LiteralPath $statePath)) { return $table }
    try {
        $state = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $p = $state.PSObject.Properties['stalled']
        if ($null -ne $p) { return $p.Value }
    }
    catch { }
    return $table
}

# ---- log parsing -----------------------------------------------------------

# "2026-10-04 12:04:22 [DELETE] text" -> level + text. The level drives colour,
# so an unknown one has to degrade to something neutral rather than blow up.
function Get-LogRow {
    param([string]$Line)
    if ($Line -notmatch '^(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}:\d{2})\s+\[(\w+)\]\s*(.*)$') { return $null }
    return [pscustomobject]@{
        Date = $Matches[1]; Time = $Matches[2]; Level = $Matches[3]; Text = $Matches[4]
    }
}

# Long event names would break the column, so show short labels. The log keeps
# the full names; this is display only.
function Get-LevelLabel {
    param([string]$Level)
    $label = switch ($Level) {
        'DELETE' { 'DELETE' }
        'MOVE'   { 'MOVE' }
        'ACTION' { 'ACTION' }
        'ERROR'  { 'ERROR' }
        'WARN'   { 'WARN' }
        'INFO'   { 'info' }
        default  { $Level }
    }
    if ($label.Length -gt 7) { $label = $label.Substring(0, 7) }
    return $label
}

function Get-LevelColor {
    param([string]$Level)
    switch ($Level) {
        'DELETE' { return 'Red' }
        'ERROR'  { return 'Red' }
        'WARN'   { return 'Yellow' }
        'MOVE'   { return 'Green' }
        'ACTION' { return 'Cyan' }
        default  { return 'DarkGray' }
    }
}

# ---- the snapshot ----------------------------------------------------------
#
# The order below is the order of what the reader wants to know, not the order
# the rules run in. Anything that describes a CHANGE the next run will make comes
# before anything that merely describes the current state, because with a few
# hundred torrents the state is not interesting on its own.

function Show-Snapshot {
    $W = Get-Width
    # Only wipe the screen when actually looping. A one-shot snapshot should
    # leave the scrollback intact so it can be copied out of the window.
    if ($Watch) { Clear-Host }
    Write-Host ("qbt-manager  {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor Cyan
    Write-Host ('=' * $W)

    # ---- reachability, on one line -----------------------------------------
    # torrents/info is the only call this panel cannot do without. The other two
    # are decoration, so they are not attempted once it has failed - otherwise a
    # dead API costs three timeouts in sequence instead of one.
    $torrentsRaw = Get-Api -Endpoint 'torrents/info'
    # Wrapping a null in @() yields a one-element array holding null, which then
    # passes every $null check and crashes strict-mode property access later.
    # Declare-then-assign keeps $torrents a real, possibly-empty array; the
    # if-expression form flattens @() back down to $null.
    $torrents = @()
    if ($null -ne $torrentsRaw) { $torrents = @($torrentsRaw) }
    $transfer = $null
    $version  = $null
    $apiDown  = $false
    if ($null -ne $torrentsRaw) {
        $transfer = Get-Api -Endpoint 'transfer/info'
        $version  = Get-Api -Endpoint 'app/version'
    }
    else {
        $apiDown = $true
    }

    if ($apiDown) {
        Write-Host ''
        Write-Host '  API unreachable - qBittorrent is probably not running' -ForegroundColor Red
        Write-Host '  the manager exits without touching anything; nothing is lost while it cannot connect' -ForegroundColor DarkGray
    }

    # ---- verdict: what the next run will DO --------------------------------
    # Everything the manager would exclude is excluded here too, so this is
    # exactly the set of changes the next run will make.
    $excluded = New-Object System.Collections.ArrayList
    $clusters = $null
    $dedup    = @{}
    $pending  = New-Object System.Collections.ArrayList

    if ($torrents.Count -gt 0) {
        foreach ($t in $torrents) {
            $v = Get-ExclusionVerdict -T $t
            Add-Member -InputObject $t -NotePropertyName exclusion -NotePropertyValue $v -Force
            if ($v) { [void]$excluded.Add($t) }
        }

        $gone = @{}
        foreach ($t in $excluded) { $gone[$t.hash] = $true }
          # The user's 10%, from the same key the manager reads for BOTH this
          # comparison and rule 4d. Read here instead of left at the default so
          # that changing it in config.json moves the preview and the run together -
          # a preview that quietly kept a default the run has moved past would
          # report an episode as clean an hour before it is deleted.
          $dedupTol = [double](Get-Prop $cfg 'libraryRedundantTolerancePercent' 10)
        $clusters = Get-Clusters -Torrents $torrents
        $dedup    = Get-DedupVerdicts -Clusters $clusters -Gone $gone -TolerancePercent $dedupTol

        foreach ($t in $excluded) {
            [void]$pending.Add([pscustomobject]@{
                Verdict = 'EXCLUDE'; Name = (Get-Prop $t 'name')
                Rule = $t.exclusion.Rule; Reason = $t.exclusion.Reason
            })
        }
        foreach ($kv in $dedup.GetEnumerator()) {
            $t = $torrents | Where-Object { $_.hash -eq $kv.Key } | Select-Object -First 1
            if ($null -eq $t) { continue }
            [void]$pending.Add([pscustomobject]@{
                Verdict = 'DELETE'; Name = (Get-Prop $t 'name')
                Rule = $kv.Value.Rule; Reason = $kv.Value.Reason
            })
        }
    }

    Write-Section -Title 'NEXT RUN WILL' -Count $pending.Count -Width $W
    if ($pending.Count -eq 0) {
        Write-Host '  nothing - no deletions queued' -ForegroundColor Green
    }
    else {
        $cap = if ($Full) { $pending.Count } else { [Math]::Min($pending.Count, 12) }
        # Biggest first: a 12 GB delete matters more than a 40 MB one.
        $shown = 0
        foreach ($p in @($pending | Sort-Object -Property @{ Expression = { Get-Prop $_.Name 'size' 0 }; Descending = $true })) {
            if ($shown -ge $cap) { break }
            $shown++
            Write-Host ("  {0,-8} {1}" -f $p.Verdict, (Fit $p.Name ($W - 11))) -ForegroundColor Red
            Write-WrappedLine -Text $p.Reason -Width ($W - 11) -Indent '           ' -Color 'DarkGray'
        }
        Write-Truncated -Shown $shown -Total $pending.Count -How 'run with -Full'
    }

    # ---- the numbers, on two lines -----------------------------------------
    Write-Section -Title 'CLIENT' -Width $W
    if ($apiDown) {
        Write-Host '  unknown - the API is not answering' -ForegroundColor DarkGray
    }
    else {
        $nDone = @($torrents | Where-Object { (Get-Prop $_ 'progress') -ge 1 }).Count
        $nAct  = @($torrents | Where-Object {
                     $s = Get-Prop $_ 'state'
                     $s -and $s -notlike 'stopped*' -and (Get-Prop $_ 'progress') -lt 1
                 }).Count
        $nMag  = @($torrents | Where-Object { (Get-Prop $_ 'size' 0) -eq 0 }).Count
        Write-Host ("  {0} torrents   {1} finished   {2} downloading   {3} awaiting metadata" -f `
            $torrents.Count, $nDone, $nAct, $nMag)
        $line = ''
        if ($null -ne $transfer) {
            $line = ("  down {0:N2} MB/s   up {1:N2} MB/s" -f `
                ((Get-Prop $transfer 'dl_info_speed' 0) / 1MB), ((Get-Prop $transfer 'up_info_speed' 0) / 1MB))
        }
        if ($null -ne $version) { $line += ("   qBittorrent {0}" -f $version) }
        Write-Host $line -ForegroundColor DarkGray
    }

    # ---- the drain: one magnet an hour, from behind the window --------------
    # Deliberately placed right after the window, because that is where it sits
    # in the manager: it takes over exactly where the window stops.
    $drainLimit = [int](Get-Prop $cfg 'metadataPriorityRankLimit' 10)
    $drainOn = $true
    if ($cfg.PSObject.Properties['queueDrainEnabled']) { $drainOn = [bool]$cfg.queueDrainEnabled }
    # The same key the window uses, so the drain cannot disagree with it about how
    # long a magnet is given. The panel title still says "an hour" because that is
    # the RULE - one deletion per run at most - not the tolerance, which is this
    # value. The heading is not rewritten from the number, so lowering the timeout
    # does not silently retitle the panel.
    $drainTimeout = [double](Get-Prop $cfg 'metadataTimeoutMinutes' 60)

    if (-not $drainOn -or $drainLimit -le 0) {
        $why = if (-not $drainOn) { 'queueDrainEnabled is false' } else { 'the queue window is disabled' }
        Write-Section -Title 'DRAIN - one per hour, behind the window' -Width $W
        Write-Host ("  off: {0}" -f $why) -ForegroundColor DarkGray
    }
    elseif ($apiDown) {
        Write-Section -Title 'DRAIN - one per hour, behind the window' -Width $W
        Write-Host '  unknown while the API is down' -ForegroundColor DarkGray
    }
    else {
        # The single clock the manager persists. Read, never written: the preview
        # is not allowed to advance it, or it would reset the manager's own clock
        # just by being looked at.
        $drainState = $null
        if (Test-Path -LiteralPath $statePath) {
            try {
                $st = [System.IO.File]::ReadAllText($statePath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                if ($st.PSObject.Properties['drain']) { $drainState = $st.drain }
            }
            catch { }
        }

        # Same set the manager skips: whatever an earlier rule already removed
        # this run must not be offered up as the drain's candidate.
        $goneForDrain = @{}
        foreach ($t in $excluded) { $goneForDrain[$t.hash] = $true }
        $drainRows = @(Get-QueueDrainVerdict -Torrents $torrents -Now (Get-Date) `
                                        -TimeoutMinutes $drainTimeout -QueueLimit $drainLimit `
                                        -Drain $drainState -Skip $goneForDrain)

        Write-Section -Title ('DRAIN - one per hour, from position {0}' -f ($drainLimit + 1)) -Width $W

        if ($drainRows.Count -eq 0) {
            Write-Host ("  nothing behind position {0} is missing metadata - nothing to drain" -f $drainLimit) -ForegroundColor DarkGray
        }
        else {
            $d = $drainRows[0]
            $nmW = [Math]::Max(20, $W - 46)
            if ($d.WillDelete) {
                Write-Host ("  DELETE next run  pos {0}  {1,4:N0}m dead  witness at {2}  {3}" -f `
                    $d.QueuePos, $d.Minutes, $d.WitnessPos, (Fit $d.Name $nmW)) -ForegroundColor Red
                Write-WrappedLine -Text $d.Reason -Width ($W - 2) -Indent '    ' -Color 'DarkGray'
            }
            elseif ($d.TimedOut) {
                # The distinction the rule exists to make. Held, not deleted.
                Write-Host ("  HELD  pos {0}  {1,4:N0}m dead  nothing further down is downloading" -f `
                    $d.QueuePos, $d.Minutes) -ForegroundColor Yellow
                Write-WrappedLine -Text $d.Reason -Width ($W - 2) -Indent '    ' -Color 'DarkGray'
            }
            else {
                $left = $drainTimeout - $d.Minutes
                  # The witness is printed ONLY when there is one.
                  #
                  # It used to be printed unconditionally, from $d.WitnessPos, which is 0
                  # when no witness exists - so the row read
                  #
                  #   pos 21  0m dead  30m to go  witness at 0  Euphoria US S03E05 ...
                  #
                  # which looks exactly like the thing this rule exists to prevent: a
                  # dead magnet at 21 about to be deleted because something at 0 is
                  # downloading. Nothing was wrong with the RULE - the candidate had no
                  # witness at all, and the panel claimed there was one at position 0.
                  # A panel that invents evidence is worse than no panel: it makes the
                  # rule look broken while it is working.
                  $witnessText = if ($d.HasWitness) { "witness at $($d.WitnessPos)" } else { 'no witness yet' }
                  Write-Host ("  pos {0}  {1,4:N0}m dead  {2,4:N0}m to go  {3}  {4}" -f `
                      $d.QueuePos, $d.Minutes, $left, $witnessText, (Fit $d.Name $nmW)) -ForegroundColor DarkGray
                Write-WrappedLine -Text $d.Reason -Width ($W - 2) -Indent '    ' -Color 'DarkGray'
            }
        }
    }

    # ---- magnets near expiry ----------------------------------------------
    # Only the ones the window is actually judging, and only those close enough
    # to matter. A queue of two hundred magnets at position 150 is not a status
    # item; it is a number in the summary.
    #
    # Named magWatch, not $watch: PowerShell variable names are case-insensitive,
    # so a local $watch here would overwrite the -Watch switch and the panel would
    # claim to be refreshing in a one-shot run.
    $magWatch = @()
    if ($torrents.Count -gt 0) { $magWatch = @(Get-MetadataWatch -Torrents $torrents) }
    $watching = @($magWatch | Where-Object { $_.InWindow })
    $queued   = @($magWatch | Where-Object { -not $_.InWindow })

    Write-Section -Title ('MAGNETS - queue window 1-{0}, tolerance {1}m' -f `
        (Get-Prop $cfg 'metadataPriorityRankLimit' 10), (Get-Prop $cfg 'metadataTimeoutMinutes' 60)) -Width $W

    if ($apiDown) {
        Write-Host '  unknown while the API is down' -ForegroundColor DarkGray
    }
    elseif ($magWatch.Count -eq 0) {
        Write-Host '  no magnet is missing metadata' -ForegroundColor DarkGray
    }
    elseif ($watching.Count -eq 0) {
        # Correct and worth stating plainly: every magnet is waiting its turn,
        # which is exactly what the window is for.
        Write-Host ("  {0} magnet(s) queued outside the window - none is being judged" -f $queued.Count) -ForegroundColor DarkGray
    }
    else {
        $nmW = [Math]::Max(20, $W - 37)
        # Closest to deletion first, since those are the rows that will change.
        $byRisk = @($watching | Sort-Object -Property Remaining)
        $cap = if ($Full) { $byRisk.Count } else { [Math]::Min($byRisk.Count, 8) }
        $shown = 0
        foreach ($m in $byRisk) {
            if ($shown -ge $cap) { break }
            $shown++
            if ($m.WillDelete) {
                Write-Host ("  pos {0,4}  {1,5:N0}m in window  DELETE next run  s{2} p{3}  {4}" -f `
                    $m.QueuePos, $m.Minutes, $m.Seeds, $m.Leechs, (Fit $m.Name $nmW)) -ForegroundColor Red
            }
            else {
                Write-Host ("  pos {0,4}  {1,5:N0}m in window  {2,5:N0}m left   s{3} p{4}  {5}" -f `
                    $m.QueuePos, $m.Minutes, $m.Remaining, $m.Seeds, $m.Leechs, (Fit $m.Name $nmW)) -ForegroundColor Yellow
            }
        }
        Write-Truncated -Shown $shown -Total $byRisk.Count -How 'run with -Full'
        if ($queued.Count -gt 0) {
            Write-Host ("  {0} more magnet(s) queued behind the window, not judged" -f $queued.Count) -ForegroundColor DarkGray
        }
    }

    # ---- stalled, only what is close ---------------------------------------
    $stallDays = Get-StalledDays
    $stallTitle = if ($stallDays -gt 0) { "STALLED - no new data for $([int]$stallDays) day(s)" }
                  else { 'STALLED - disabled' }
    Write-Section -Title $stallTitle -Width $W

    if ($stallDays -le 0) {
        Write-Host '  stalledDeleteDays is 0 - no torrent is ever removed for being stuck' -ForegroundColor DarkGray
    }
    elseif ($apiDown) {
        Write-Host '  unknown while the API is down' -ForegroundColor DarkGray
    }
    else {
        $rows = @(Get-StalledWatch -Torrents $torrents -Stalled (Get-StalledTable) -Now (Get-Date))
        if ($rows.Count -eq 0) {
            Write-Host '  nothing incomplete to judge' -ForegroundColor DarkGray
        }
        else {
            # Soonest first, and only the ones that could plausibly expire today.
            # With everything at 7 days remaining, the list is a wall of rows that
            # says nothing.
            $byRisk = @($rows | Sort-Object -Property Remaining)
            $atRisk = @($byRisk | Where-Object { $_.Remaining -lt 2 })
            $nmW = [Math]::Max(20, $W - 40)
            if ($atRisk.Count -eq 0) {
                Write-Host ("  {0} torrent(s) idle; none expires today (closest is {1:N1} days away)" -f `
                    $rows.Count, $byRisk[0].Remaining) -ForegroundColor DarkGray
            }
            else {
                $shown = 0
                foreach ($r in $atRisk) {
                    if ($shown -ge 8) { break }
                    $shown++
                    $when = if ($r.WillDelete) { 'DELETE next run' } else { '{0,5:N1}d left' -f $r.Remaining }
                    Write-Host ("  {0,-10} {1,5:N1}/{2,5:N1} GB  {3,-14} {4}" -f $r.State,
                        ($r.Completed / $GB), ($r.Total / $GB), $when, (Fit $r.Name $nmW)) -ForegroundColor Red
                }
                Write-Truncated -Shown $shown -Total $atRisk.Count -How 'run with -Full'
                $rest = $rows.Count - $atRisk.Count
                if ($rest -gt 0) {
                    Write-Host ("  {0} more idle, none near expiry" -f $rest) -ForegroundColor DarkGray
                }
            }
        }
    }

    # ---- orphan reaper -----------------------------------------------------
    $reapOn = ($cfg.PSObject.Properties['reapOrphans'] -and $cfg.reapOrphans)
    $reapAge = 24.0
    if ($cfg.PSObject.Properties['reapMinAgeHours']) { $reapAge = [double]$cfg.reapMinAgeHours }
    $reapTitle = if ($reapOn) { "ORPHANS - untouched for $reapAge h" } else { 'ORPHANS - disabled' }
    Write-Section -Title $reapTitle -Width $W

    if (-not $reapOn) {
        Write-Host '  reapOrphans is off, so download leftovers are never touched' -ForegroundColor DarkGray
    }
    elseif ($apiDown) {
        Write-Host '  unknown while the API is down' -ForegroundColor DarkGray
    }
    else {
        $reapRoots = @()
        if ($cfg.PSObject.Properties['reapRoots']) { $reapRoots = @($cfg.reapRoots) }
        if ($reapRoots.Count -eq 0) {
            Write-Host '  reapRoots is empty, so nothing is ever scanned' -ForegroundColor Yellow
        }
        else {
            $reap = Get-ReapCandidates -Roots $reapRoots -Torrents $torrents -MinAgeHours $reapAge `
                                       -ExcludeDirs @($cfg.moviesDir, $cfg.seriesDir) -Now (Get-Date)
            if ($reap.Blocked) {
                Write-Host "  SKIPPED this run: $($reap.Blocked)" -ForegroundColor Yellow
            }
            elseif ($reap.Candidates.Count -eq 0) {
                Write-Host ("  nothing to reap; {0} item(s) kept under {1} root(s)" -f `
                    $reap.Skipped.Count, $reapRoots.Count) -ForegroundColor DarkGray
            }
            else {
                $rb = ($reap.Candidates | Measure-Object -Property Bytes -Sum).Sum
                foreach ($c in @($reap.Candidates | Sort-Object -Property Bytes -Descending)) {
                    Write-Host ("  REAP next run  {0,7:N2} GB  idle {1,6:N1}h  {2}" -f `
                        ($c.Bytes / $GB), $c.IdleHours, (Fit $c.Path ([Math]::Max(20, $W - 40)))) -ForegroundColor Red
                }
                Write-Host ("  {0} candidate(s), {1:N2} GB would be freed" -f $reap.Candidates.Count, ($rb / $GB)) -ForegroundColor Red
            }
        }
    }

    # ---- the groups the manager identified ---------------------------------
    # Split by KIND, which is the distinction the rules actually turn on. A
    # single episode (S18E7) and a pack (S18E1-E8) are never rivals: whichever is
    # larger, the smaller is not covered by it, so a pack beside a single is not
    # redundancy. Counting them in one number would say "18 copies of season 18"
    # when the truth is "18 downloads of season 18", which are different things.
    #
    # The partition is Get-EpisodeSetKey - the very key dedup judges under - so a
    # row here can never imply a comparison the rules would not make.
    Write-Section -Title 'GROUPS' -Width $W

    if ($apiDown) {
        Write-Host '  unknown while the API is down' -ForegroundColor DarkGray
    }
    else {
        # show label -> kind -> tallies
        $byShow = @{}
        $grouped = 0
        $kindsSeen = @{ singles = 0; packs = 0; films = 0 }

        foreach ($c in $clusters) {
            $members = @($c)
            if ($members.Count -eq 0) { continue }
            $grouped += $members.Count

            $label = Get-FamilyLabel -Members $members
            if (-not $label) { $label = '(unnamed)' }

            # One cluster is exactly one episode set, so this key is exact - it is
            # the set the whole cluster was weighed under.
            $setKey = Get-EpisodeSetKey -Parts $members[0].parts

            $kind = 'unknown'
            if ($setKey -eq 'film') { $kind = 'films' }
            elseif ($setKey -match '^S\d+-ALL$') { $kind = 'packs' }
            elseif ($setKey -match '^S\d+-E\d+-E\d+$') { $kind = 'packs' }
            elseif ($setKey -match '^S\d+-E\d+$') { $kind = 'singles' }

            if (-not $byShow.ContainsKey($label)) {
                $byShow[$label] = @{
                    Lower   = $label.ToLowerInvariant()
                    Singles = [pscustomobject]@{ Count = 0; Done = 0; Sets = @{} }
                    Packs   = [pscustomobject]@{ Count = 0; Done = 0; Sets = @{} }
                    Films   = [pscustomobject]@{ Count = 0; Done = 0; Sets = @{} }
                }
            }
            $bucket = $byShow[$label][$kind]
            if ($null -eq $bucket) { continue }

            $bucket.Count += $members.Count
            # One entry per distinct set, not per cluster: a set that appears in
            # three clusters is still one set of episodes, and saying otherwise
            # would overstate the spread.
            $setLabel = Get-EpisodeSetLabel -Key $setKey
            if (-not $bucket.Sets.ContainsKey($setLabel)) { $bucket.Sets[$setLabel] = 0 }
            $bucket.Sets[$setLabel] += $members.Count

            foreach ($m in $members) {
                if ((Get-Prop $m 'progress' 0) -ge 1) { $bucket.Done++ }
            }
            if ($kindsSeen.ContainsKey($kind)) { $kindsSeen[$kind]++ }
        }

        # Torrents that failed to parse are in no cluster at all, and are counted
        # separately rather than dropped: "unidentified" is information, and
        # hiding it would make the totals quietly disagree.
        $ungrouped = 0
        foreach ($t in $torrents) {
            if (-not ($t.PSObject.Properties['parts'] -and $null -ne $t.parts)) { $ungrouped++ }
        }

        if ($byShow.Count -eq 0) {
            Write-Host '  no group was identified' -ForegroundColor DarkGray
        }
        else {
            # Alphabetical, case-insensitively: 'Always Sunny' and 'always sunny'
            # are the same show and must not be split apart by ASCII ordering.
            $shows = @($byShow.Keys | Sort-Object { $byShow[$_].Lower })
            $cap = if ($Full) { $shows.Count } else { [Math]::Min($shows.Count, 12) }
            $shown = 0

            foreach ($label in $shows) {
                if ($shown -ge $cap) { break }
                $shown++
                $b = $byShow[$label]

                Write-Host ("  {0}" -f (Fit $label ([Math]::Max(20, $W - 2)))) -ForegroundColor White

                foreach ($kind in @('singles', 'packs', 'films')) {
                    $k = $b[$kind]
                    if ($k.Count -eq 0) { continue }
                    $nSets = $k.Sets.Count
                    $doneTxt = if ($k.Done -eq $k.Count) { 'all done' }
                               elseif ($k.Done -eq 0) { 'none done' }
                               else { ('{0}/{1} done' -f $k.Done, $k.Count) }
                    $color = if ($k.Done -eq $k.Count) { 'Green' } else { 'DarkGray' }
                    # Pluralised on the set count, so "1 set" never reads as a
                    # typo for "sets".
                    $setTxt = if ($nSets -eq 1) { '1 set' } else { ('{0} sets' -f $nSets) }
                    Write-Host ("      {0,-8} {1,4} in {2,-9} {3}" -f `
                        $kind, $k.Count, $setTxt, $doneTxt) -ForegroundColor $color
                }
            }
            Write-Truncated -Shown $shown -Total $shows.Count -How 'run with -Full'

            $totS = 0; $totP = 0; $totF = 0
            foreach ($label in $shows) {
                $b = $byShow[$label]
                $totS += $b.Singles.Count; $totP += $b.Packs.Count; $totF += $b.Films.Count
            }
            Write-Host ("  {0} group(s): {1} single-episode, {2} in packs, {3} film(s) - {4} torrent(s) total" -f `
                $shows.Count, $totS, $totP, $totF, $grouped) -ForegroundColor DarkGray
        }

        if ($ungrouped -gt 0) {
            # Named, because a torrent the manager could not parse is a torrent
            # no other rule will ever be able to cluster, dedup or file.
            Write-Host ("  {0} torrent(s) identified as no group - not clustered, so never deduplicated" -f `
                $ungrouped) -ForegroundColor Yellow
        }
    }

    # ---- the full queue, only when asked for ------------------------------
    if ($Full) {
        Write-Section -Title 'QUEUE' -Count $torrents.Count -Width $W
        if ($torrents.Count -eq 0) {
            Write-Host '  nothing to show' -ForegroundColor DarkGray
        }
        else {
            $nameW = [Math]::Max(20, $W - 32)

            foreach ($t in $excluded) {
                $v = $t.exclusion
                Write-Host ("  {0,-8} {1,8:N2} GB {2,6:N1}%  {3}" -f 'EXCLUDE', ((Get-Prop $t 'size' 0) / $GB),
                    ((Get-Prop $t 'progress' 0) * 100), (Fit (Get-Prop $t 'name') $nameW)) -ForegroundColor Yellow
                Write-Host ("           {0}" -f (Fit $v.Reason ($W - 11))) -ForegroundColor DarkGray
            }

            # Only groups with more than one member are interesting: a lone
            # torrent has nothing to be a duplicate of, so it gets a flat row.
            foreach ($c in $clusters) {
                $members = @($c)
                if ($members.Count -gt 1) {
                    # A cluster is keyed on the first episode alone, so one
                    # cluster holds single episodes and packs of every range that
                    # starts there. Printed as one block that reads as a claim
                    # about all of them, which is false - so each episode set is
                    # its own group, headed by the set it holds. That is the same
                    # partition Get-DedupVerdicts judges under, so a header and
                    # its rows always describe one set of episodes.
                    $show = Get-ClusterLabel -Members $members
                    $bySet = @{}
                    foreach ($m in $members) {
                        $sk = Get-EpisodeSetKey -Parts $m.parts
                        if (-not $bySet.ContainsKey($sk)) { $bySet[$sk] = New-Object System.Collections.ArrayList }
                        [void]$bySet[$sk].Add($m)
                    }
                    $setOrder = @($bySet.Keys | Sort-Object -Property `
                        @{ Expression = { if ($_ -match '^S(\d+)-') { [int]$Matches[1] } else { 0 } } }, `
                        @{ Expression = { if ($_ -match '-E(\d+)') { [int]$Matches[1] } else { 0 } } }, `
                        @{ Expression = { if ($_ -match '-E\d+-E(\d+)$') { [int]$Matches[1] } else { 0 } } })
                    foreach ($sk in $setOrder) {
                        $header = ("{0} {1}" -f $show, (Get-EpisodeSetLabel -Key $sk)).Trim()
                        Write-Host ("  {0}" -f $header) -ForegroundColor White
                        foreach ($m in @($bySet[$sk] | Sort-Object @{ Expression = { (Get-Prop $_ 'size' 0) }; Descending = $true })) {
                            $mark = if ($dedup.ContainsKey($m.hash)) { 'DELETE' } else { 'keep' }
                            $color = if ($dedup.ContainsKey($m.hash)) { 'Red' } else {
                                if ((Get-Prop $m 'progress' 0) -ge 1) { 'Green' } else { 'White' }
                            }
                            Write-Host ("    {0,-6} {1,7:N2} GB {2,6:N1}%  {3}" -f $mark,
                                ((Get-Prop $m 'size' 0) / $GB), ((Get-Prop $m 'progress' 0) * 100),
                                (Fit (Get-Prop $m 'name') $nameW)) -ForegroundColor $color
                        }
                    }
                }
                else {
                    $m = $members[0]
                    $pct = (Get-Prop $m 'progress' 0) * 100
                    $flag = if ($pct -ge 100) { 'done' } else { 'only' }
                    $color = if ($pct -ge 100) { 'Green' } else { 'White' }
                    Write-Host ("  {0,-6} {1,7:N2} GB {2,6:N1}%  {3}" -f $flag, ((Get-Prop $m 'size' 0) / $GB), $pct,
                        (Fit (Get-Prop $m 'name') $nameW)) -ForegroundColor $color
                }
            }
        }
    }

    # ---- disk, task, log: the quiet facts ----------------------------------
    Write-Section -Title 'DISK' -Width $W

    # Only the drives the manager actually writes to are shown. A full disk is
    # the one thing that makes an unattended run dangerous, so it is worth the
    # two lines it costs.
    #
    # Every configured directory is kept, not one per drive: movies and series
    # nearly always share a drive, and a hashtable keyed by drive root silently
    # keeps only whichever was assigned last.
    $entries = @()
    foreach ($key in @('moviesDir', 'seriesDir')) {
        $p = Get-Prop $cfg $key
        if (-not $p) { continue }
        try {
            $r = [System.IO.Path]::GetPathRoot($p)
            if ($r) { $entries += [pscustomobject]@{ Root = $r.TrimEnd('\'); Path = [string]$p } }
        } catch { }
    }
    foreach ($grp in ($entries | Group-Object -Property Root | Sort-Object -Property Name)) {
        $r = $grp.Name
        # The label says which configured folders put data here - it does not
        # claim they are what fills the drive.
        $why = (@($grp.Group | ForEach-Object { Split-Path -Leaf $_.Path }) -join ', ')
        try {
            $d = New-Object System.IO.DriveInfo($r)
            if (-not $d.IsReady) {
                Write-Host ("  {0} not ready" -f $r) -ForegroundColor Red
                continue
            }
            $free = $d.AvailableFreeSpace
            $pct = if ($d.TotalSize) { [math]::Round(100 * $free / $d.TotalSize, 1) } else { 0 }
            $color = if ($pct -lt 2) { 'Red' } elseif ($pct -lt 10) { 'Yellow' } else { 'DarkGray' }
            Write-Host ("  {0} {1,6:N1} GB free of {2,6:N0} GB ({3,4:N1}%)  {4}" -f `
                $r, ($free / $GB), ($d.TotalSize / $GB), $pct, $why) -ForegroundColor $color
        }
        catch { Write-Host ("  {0} unavailable" -f $r) -ForegroundColor DarkGray }
    }

    try {
        $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
        $info = $task | Get-ScheduledTaskInfo
        $taskColor = if ($task.State -eq 'Ready') { 'DarkGray' } else { 'Yellow' }
        $res = $info.LastTaskResult
        $resColor = if ($res -eq 0) { 'DarkGray' } else { 'Red' }
        Write-Host ("  task {0} [{1}]  last {2} (exit {3})  next {4}" -f `
            $taskName, $task.State, $info.LastRunTime, $res, $info.NextRunTime) -ForegroundColor $taskColor
        if ($res -ne 0) {
            Write-Host ("  the last run exited {0} - see the log below" -f $res) -ForegroundColor $resColor
        }
    }
    catch {
        Write-Host ("  task '{0}' is not registered" -f $taskName) -ForegroundColor Yellow
    }

    # ---- recent activity ---------------------------------------------------
    $log = Join-Path $logDir ("manager-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
    $logTitle = 'ACTIVITY'
    if ($All) { $logTitle += ' (including parsing)' }
    Write-Section -Title $logTitle -Width $W

    if (-not (Test-Path -LiteralPath $log)) {
        Write-Host '  no log yet for today' -ForegroundColor DarkGray
    }
    else {
        # Read generously, then show only what is worth showing. The parsing
        # lines are the bulk of this file and none of them is a status item.
        #
        # Named logRows, not $all: PowerShell ignores case in variable names, so
        # $all would be the same variable as the -All switch and assigning this
        # array to it would silently switch the filter off.
        $logRows = @(Get-Content -LiteralPath $log -Tail ([Math]::Max($Tail * 6, 60)) -ErrorAction SilentlyContinue |
                     ForEach-Object { Get-LogRow $_ } | Where-Object { $_ })
        $rows = @(Select-InterestingLog -Rows $logRows -IncludeAll:([bool]$All))
        $picked = @($rows | Select-Object -Last $Tail)
        if ($picked.Count -eq 0) {
            Write-Host '  nothing to report - the last runs changed nothing' -ForegroundColor Green
        }
        else {
            foreach ($r in $picked) {
                Write-WrappedLine -Text ("{0}  {1}  {2}" -f $r.Time, (Get-LevelLabel $r.Level), $r.Text) `
                                   -Width $W -Indent '  ' -Color (Get-LevelColor $r.Level)
            }
            Write-Truncated -Shown $picked.Count -Total $rows.Count -How 'raise -Tail, or use -All'
        }
    }

    if ($Watch) {
        Write-Host ''
        Write-Host ('refreshing every {0}s - Ctrl+C to stop' -f $RefreshSeconds) -ForegroundColor DarkGray
    }
}

if ($Watch) {
    try {
        while ($true) { Show-Snapshot; Start-Sleep -Seconds $RefreshSeconds }
    }
    finally { Clear-Host }
}
else {
    Show-Snapshot
}
