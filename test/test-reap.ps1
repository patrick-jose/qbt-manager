# Exercises the orphan reaper: Test-Unlocatable, Test-Claimed,
# Get-ReapCandidates and Remove-OrphanPath, lifted out of qbt-manager.ps1 and
# pointed at a throwaway directory.
#
# This rule is the only one in the manager that deletes bytes qBittorrent does
# not know about, and with a clean Downloads\temp it correctly finds nothing -
# so "no candidates" is exactly the result that would hide a broken reaper. The
# suite therefore plants known orphans and asserts each one is found, and plants
# known live downloads and asserts each one is left alone.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-reap.ps1

$ErrorActionPreference = 'Stop'
if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

# These tests live in <project>\test\ and exercise the code one level up, so
# every path is resolved from the project root, not from this folder.
$projectRoot = Split-Path -Parent $PSScriptRoot

function Get-ProjectFile {
    param([string]$Name)
    $p = Join-Path $projectRoot $Name
    if (-not (Test-Path -LiteralPath $p)) {
        throw "cannot find $Name (looked in $p). These tests are meant to stay in the project's test folder."
    }
    return $p
}

$src = [System.IO.File]::ReadAllText((Get-ProjectFile 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)

# Detection region, sliced on the same markers status.ps1 uses.
$s = $src.IndexOf('$script:boundaryPattern')
$e = $src.IndexOf('# actions')
if ($s -lt 0 -or $e -le $s) { throw 'could not locate the detection block' }
Invoke-Expression $src.Substring($s, $e - $s)

# The delete helper lives in the actions region, so it is sliced separately and
# evaluated against the stubs below. Bounded by the next function declaration
# rather than by counting braces, because braces also appear inside strings.
$rs = $src.IndexOf('function Remove-OrphanPath {')
$re = $src.IndexOf('function Ensure-Category {')
if ($rs -lt 0 -or $re -le $rs) { throw 'could not locate Remove-OrphanPath' }

# Stubs for what Remove-OrphanPath expects to already exist.
$DryRun = $true
$script:actions = @()
$script:notes = @()
$script:logLines = @()
function Write-Log { param([string]$Level, [string]$Message) $script:logLines += "$Level $Message" }

Invoke-Expression $src.Substring($rs, $re - $rs)

# Wait-MoveVerified is here for the same reason: it is an action, so it cannot be
# reached by the detection slice. Its only dependency is Invoke-ApiGet, which is
# replaced with a fake below - so what is tested is the control flow (how many
# times it asks, when it gives up, what it says when it gives up), not the API.
$ws = $src.IndexOf('function Wait-MoveVerified {')
$we = $src.IndexOf('function Move-ToLibrary {')
if ($ws -lt 0 -or $we -le $ws) { throw 'could not locate Wait-MoveVerified' }
Invoke-Expression $src.Substring($ws, $we - $ws)

$script:apiCalls = 0
$script:apiReplies = @()
function Invoke-ApiGet {
    param([string]$Endpoint)
    $script:apiCalls++
    if ($script:apiReplies.Count -eq 0) { return @() }
    $next = @($script:apiReplies[0])
    if ($script:apiReplies.Count -gt 1) {
        $script:apiReplies = @($script:apiReplies[1..($script:apiReplies.Count - 1)])
    }
    return $next
}

$script:fails = 0
$script:skips = 0
function Check {
    param([string]$label, [bool]$ok)
    if ($ok) { "  [PASS] $label" } else { $script:fails++; "  [FAIL] $label" }
}
function Skip {
    param([string]$label, [string]$why)
    $script:skips++
    "  [SKIP] $label ($why)"
}

$NOW = [datetime]'2026-10-04 12:00:00'
$OLD = $NOW.AddHours(-72)      # well past a 24h gate
$NEW = $NOW.AddHours(-2)       # inside it

# --- sandbox ----------------------------------------------------------------

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('qbt-reap-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$root    = Join-Path $sandbox 'temp'
$library = Join-Path $sandbox 'Filmes'
New-Item -ItemType Directory -Path $root    -Force | Out-Null
New-Item -ItemType Directory -Path $library -Force | Out-Null

function New-Leaf {
    param([string]$Name, [datetime]$When, [int]$Bytes = 0, [switch]$Folder)
    $p = Join-Path $root $Name
    if ($Folder) {
        New-Item -ItemType Directory -Path $p -Force | Out-Null
        if ($Bytes -gt 0) {
            $f = Join-Path $p 'payload.bin'
            [System.IO.File]::WriteAllBytes($f, (New-Object byte[] $Bytes))
            (Get-Item -LiteralPath $f).LastWriteTime = $When
        }
        (Get-Item -LiteralPath $p).LastWriteTime = $When
    }
    else {
        [System.IO.File]::WriteAllBytes($p, (New-Object byte[] $Bytes))
        (Get-Item -LiteralPath $p).LastWriteTime = $When
    }
    return $p
}

try {
    # --- the fixtures -------------------------------------------------------
    # orphans: old and unclaimed
    $orphanDir  = New-Leaf -Name 'orphan-dir'        -When $OLD -Bytes 2048 -Folder
    $orphanFile = New-Leaf -Name 'orphan-file.bin'   -When $OLD -Bytes 1024
    # fresh, so the age gate must keep it
    $freshDir   = New-Leaf -Name 'fresh-dir'         -When $NEW -Bytes 4096 -Folder
    # claimed three different ways
    $byExact    = New-Leaf -Name 'claimed-exact'     -When $OLD -Bytes 512 -Folder
    $byInside   = New-Leaf -Name 'claimed-multi'     -When $OLD -Bytes 512 -Folder
    $byParent   = New-Leaf -Name 'claimed-parent'    -When $OLD -Bytes 512 -Folder
    $fileInMulti = Join-Path $byInside 'video.mkv'
    [System.IO.File]::WriteAllBytes($fileInMulti, (New-Object byte[] 512))
    (Get-Item -LiteralPath $fileInMulti).LastWriteTime = $OLD
    # an orphan with a non-ASCII name, and a claimed one with the same
    $uniOrphan = New-Leaf -Name '已知 测试 òrfan'    -When $OLD -Bytes 256 -Folder
    $uniClaimed = New-Leaf -Name '已知 声称 held'   -When $OLD -Bytes 256 -Folder
    # an excluded directory, even though it is old and unclaimed. Note the
    # exclusion has to name this folder: the real library lives outside the
    # staging root, so "a folder that merely looks like the library" is
    # correctly still a candidate.
    $excluded = New-Leaf -Name 'library-ish'       -When $OLD -Bytes 8192 -Folder

    # Torrents, described the way the real API describes them.
    $torrents = @(
        [pscustomobject]@{ hash = 'aaaa0001'; name = 'ClaimedExact'
            content_path = $byExact; save_path = $sandbox; completed = 1GB; state = 'downloading' }
        # multi-file: content_path is the FILE, inside the folder
        [pscustomobject]@{ hash = 'aaaa0002'; name = 'ClaimedMulti'
            content_path = $fileInMulti; save_path = $sandbox; completed = 1GB; state = 'downloading' }
        # a single-file torrent whose content_path IS a parent folder
        [pscustomobject]@{ hash = 'aaaa0003'; name = 'ClaimedParent'
            content_path = $byParent; save_path = $sandbox; completed = 1GB; state = 'stalledDL' }
        [pscustomobject]@{ hash = 'aaaa0004'; name = 'ClaimedUnicode'
            content_path = $uniClaimed; save_path = $sandbox; completed = 1GB; state = 'downloading' }
    )

    # The library, plus one exclusion deliberately aimed inside the root, to
    # prove a misconfigured exclusion is still obeyed.
    $exclusions = @($library, $excluded)

    $res = Get-ReapCandidates -Roots @($root) -Torrents $torrents -MinAgeHours 24 `
                                -ExcludeDirs $exclusions -Now $NOW
    $found = @($res.Candidates | ForEach-Object { $_.Path })
    $kept  = @($res.Skipped    | ForEach-Object { $_.Path })
    $reasonFor = @{}
    foreach ($k in $res.Skipped) { $reasonFor[$k.Path] = $k.Reason }

    "== candidates found =="
    foreach ($c in $res.Candidates) { "   $(Split-Path -Leaf $c.Path)  $([math]::Round($c.Bytes/1KB,1)) KB  $([math]::Round($c.IdleHours,1))h idle" }
    ""

    "== the two real orphans are found =="
    Check 'old unclaimed folder is a candidate'  ($found -contains $orphanDir)
    Check 'old unclaimed file is a candidate'    ($found -contains $orphanFile)
    Check 'non-ASCII unclaimed folder is a candidate' ($found -contains $uniOrphan)

    "== live downloads are never candidates =="
    Check 'fresh unclaimed folder held by the age gate' ($kept -contains $freshDir)
    Check 'folder claimed by an exact content_path'     ($kept -contains $byExact)
    Check 'folder claimed by a content_path inside it'  ($kept -contains $byInside)
    Check 'folder that is a content_path itself'        ($kept -contains $byParent)
    Check 'non-ASCII claimed folder is kept'            ($kept -contains $uniClaimed)
    Check 'an excluded directory inside the root is kept' ($kept -contains $excluded)

    "== sizes and ages are reported =="
    $od = @($res.Candidates | Where-Object { $_.Path -eq $orphanDir })[0]
    Check 'folder size sums its contents'   ($od -and $od.Bytes -eq 2048)
    Check 'folder flagged as a directory'    ($od -and $od.IsDir -eq $true)
    Check 'idle age computed from last write' ($od -and [math]::Abs($od.IdleHours - 72) -lt 0.1)
    $of = @($res.Candidates | Where-Object { $_.Path -eq $orphanFile })[0]
    Check 'single file size read directly'   ($of -and $of.Bytes -eq 1024)
    Check 'single file not flagged as a directory' ($of -and $of.IsDir -eq $false)

    "== every skip carries a reason a human can read =="
    Check 'a reason is recorded for every skip' (@($reasonFor.Values | Where-Object { -not $_ }).Count -eq 0)
    Check 'the claimed skip names the owner'   ($reasonFor[$byExact] -like '*ClaimedExact*')
    Check 'the age-gate skip states both ages' ($reasonFor[$freshDir] -like '*need 24h*')

    # --- the regression this rule was designed around ------------------------
    # Torrents here all share save_path with each other and with the reap root's
    # parent. If save_path were treated as a claim, every entry would look
    # in-use and the reaper would silently never fire again.
    "== a shared save_path does not mask orphans (the measured bug) =="
    $shared = @(
        [pscustomobject]@{ hash='bbbb0001'; name='A'; content_path = $byExact;  save_path = $sandbox; completed = 1GB; state='downloading' }
        [pscustomobject]@{ hash='bbbb0002'; name='B'; content_path = $byInside; save_path = $sandbox; completed = 1GB; state='downloading' }
        [pscustomobject]@{ hash='bbbb0003'; name='C'; content_path = $byParent; save_path = $sandbox; completed = 1GB; state='downloading' }
        [pscustomobject]@{ hash='bbbb0004'; name='D'; content_path = $uniClaimed; save_path = $sandbox; completed = 1GB; state='downloading' }
    )
    $res2 = Get-ReapCandidates -Roots @($root) -Torrents $shared -MinAgeHours 24 -ExcludeDirs $exclusions -Now $NOW
    $found2 = @($res2.Candidates | ForEach-Object { $_.Path })
    Check 'orphan still found when every save_path is shared'  ($found2 -contains $orphanDir)
    Check 'only the three real orphans survive the age gate' (@($found2).Count -eq 3)

    # save_path equal to the reap root itself must not blanket-claim it either,
    # as long as no torrent's content_path is the root.
    $saveAtRoot = @($shared | ForEach-Object {
        [pscustomobject]@{
            hash = $_.hash; name = $_.name; content_path = $_.content_path
            save_path = $root; completed = $_.completed; state = $_.state
        }
    })
    $res3 = Get-ReapCandidates -Roots @($root) -Torrents $saveAtRoot -MinAgeHours 24 -ExcludeDirs $exclusions -Now $NOW
    Check 'save_path equal to the root does not blanket-claim it' `
        (@($res3.Candidates | Where-Object { $_.Path -eq $orphanDir }).Count -eq 1)

    # --- fail closed --------------------------------------------------------
    "== the pass refuses to run when a torrent's bytes cannot be located =="
    $lost = @($torrents) + @([pscustomobject]@{
        hash='aaaa0005'; name='Nowhere'; content_path=''; save_path=$sandbox
        completed=2GB; state='downloading' })
    $res4 = Get-ReapCandidates -Roots @($root) -Torrents $lost -MinAgeHours 24 -ExcludeDirs $exclusions -Now $NOW
    Check 'blocked when a torrent with data has no content_path' ($null -ne $res4.Blocked)
    Check 'blocked run returns no candidates at all'            (@($res4.Candidates).Count -eq 0)
    Check 'the block explains itself and names a torrent'       ($res4.Blocked -like '*Nowhere*')

    $magnet = @($torrents) + @([pscustomobject]@{
        hash='aaaa0006'; name='Magnet'; content_path=''; save_path=$sandbox
        completed=0; state='metaDL' })
    $res5 = Get-ReapCandidates -Roots @($root) -Torrents $magnet -MinAgeHours 24 -ExcludeDirs $exclusions -Now $NOW
    Check 'a magnet holding no bytes does not block the pass'  ($null -eq $res5.Blocked)
    Check 'and the orphans are still found through it'         (@($res5.Candidates).Count -ge 3)

    # --- awkward roots ------------------------------------------------------
    "== awkward roots are survivable =="
    $missing = Get-ReapCandidates -Roots @((Join-Path $sandbox 'nope')) -Torrents $torrents -MinAgeHours 24 -ExcludeDirs $exclusions -Now $NOW
    Check 'a missing root yields no candidates, not an error'  (@($missing.Candidates).Count -eq 0)
    Check 'a missing root is reported'                         ($missing.Skipped[0].Reason -like '*does not exist*')

    # The root here IS the excluded directory, so the library path must be the
    # exclusion - $exclusions would also work, but naming it directly keeps the
    # intent of this case obvious.
    $asExcluded = Get-ReapCandidates -Roots @($library) -Torrents $torrents -MinAgeHours 24 -ExcludeDirs @($library) -Now $NOW
    Check 'a root that is an excluded dir is refused'           ($asExcluded.Skipped[0].Reason -like '*excluded*')
    Check 'nothing under it is touched'                        (@($asExcluded.Candidates).Count -eq 0)

    $insideLib = Join-Path $library 'sub'
    New-Item -ItemType Directory -Path $insideLib -Force | Out-Null
    $nested = Get-ReapCandidates -Roots @($insideLib) -Torrents $torrents -MinAgeHours 24 -ExcludeDirs @($library) -Now $NOW
    Check 'a root nested inside an excluded dir is refused'     (@($nested.Candidates).Count -eq 0)

    # --- trailing separators and case ---------------------------------------
    "== separators and case are not a way to smuggle a path in =="
    $tricky = @([pscustomobject]@{ hash='cccc0001'; name='TrailingSlash'
        content_path = ($orphanDir + '\'); save_path = $sandbox; completed = 1GB; state='downloading' })
    $res6 = Get-ReapCandidates -Roots @($root + '\') -Torrents $tricky -MinAgeHours 24 -ExcludeDirs $exclusions -Now $NOW
    Check 'a trailing separator on content_path still claims the folder' `
        (@($res6.Candidates | Where-Object { $_.Path -eq $orphanDir }).Count -eq 0)
    $res7 = Get-ReapCandidates -Roots @($root) -Torrents @([pscustomobject]@{
        hash='cccc0002'; name='CaseTest'; content_path = $orphanDir.ToUpperInvariant()
        save_path = $sandbox; completed = 1GB; state='downloading' }) -MinAgeHours 24 -ExcludeDirs $exclusions -Now $NOW
    Check 'matching is case-insensitive' `
        (@($res7.Candidates | Where-Object { $_.Path -eq $orphanDir }).Count -eq 0)

    # --- links --------------------------------------------------------------
    "== links are not followed out of the root =="
    $target = Join-Path $sandbox 'outside'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $target 'precious.txt'), [System.Text.Encoding]::UTF8.GetBytes('do not delete me'))
    $link = Join-Path $root 'shortcut'
    $madeLink = $false
    try {
        New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null
        (Get-Item -LiteralPath $link).LastWriteTime = $OLD
        $madeLink = $true
    }
    catch {
        try {
            New-Item -ItemType SymbolicLink -Path $link -Target $target -ErrorAction Stop | Out-Null
            (Get-Item -LiteralPath $link).LastWriteTime = $OLD
            $madeLink = $true
        }
        catch { }
    }
    if ($madeLink) {
        $res8 = Get-ReapCandidates -Roots @($root) -Torrents $torrents -MinAgeHours 24 -ExcludeDirs $exclusions -Now $NOW
        Check 'a junction to a folder outside the root is never a candidate' `
            (@($res8.Candidates | Where-Object { $_.Path -eq $link }).Count -eq 0)
        Check 'the skip says it was a link' `
            (@($res8.Skipped | Where-Object { $_.Path -eq $link -and $_.Reason -like '*link*' }).Count -eq 1)

        # Remove the link itself and never through it. Directory.Delete on the
        # reparse point is the reliable form; Remove-Item on a junction is a
        # known NullReferenceException in 5.1, and -Recurse here would risk
        # walking into the target.
        try { [System.IO.Directory]::Delete($link, $false) }
        catch { Remove-Item -LiteralPath $link -Force -ErrorAction SilentlyContinue }
    }
    else {
        Skip 'a junction outside the root is never a candidate' 'this account cannot create links'
        Skip 'the skip says it was a link' 'no link could be created'
    }
    # Checked after the link is gone: the whole point is that nothing followed
    # it, so the file behind it has to still be there.
    Check 'the folder behind the link survived detection and cleanup' `
        (Test-Path -LiteralPath (Join-Path $target 'precious.txt'))

    # --- Remove-OrphanPath containment --------------------------------------
    "== the delete itself re-checks containment =="
    $victim = New-Leaf -Name 'to-delete' -When $OLD -Bytes 128 -Folder
    $outside = Join-Path $sandbox 'not-in-root'
    New-Item -ItemType Directory -Path $outside -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $outside 'keep.txt'), [byte[]]@(1, 2, 3))

    Check 'a path outside every root is refused'  ((Remove-OrphanPath -Path $outside -Roots @($root)) -eq $false)
    Check 'and it is still on disk'               (Test-Path -LiteralPath (Join-Path $outside 'keep.txt'))
    Check 'a root cannot delete itself'            ((Remove-OrphanPath -Path $root -Roots @($root)) -eq $false)
    Check 'and the root survives'                 (Test-Path -LiteralPath $root)
    Check 'an empty root list refuses everything' ((Remove-OrphanPath -Path $victim -Roots @()) -eq $false)
    Check 'a dry run reports success without deleting' ((Remove-OrphanPath -Path $victim -Roots @($root)) -eq $true)
    Check 'the dry run left the target alone'     (Test-Path -LiteralPath $victim)

    $DryRun = $false
    Check 'a live run deletes the target'         ((Remove-OrphanPath -Path $victim -Roots @($root)) -eq $true)
    Check 'the target is gone afterwards'         (-not (Test-Path -LiteralPath $victim))
    Check 'a missing target is not an error'      ((Remove-OrphanPath -Path (Join-Path $root 'never-existed') -Roots @($root)) -eq $true)
    Check 'the refusal was logged with a reason'  (@($script:logLines | Where-Object { $_ -like '*not inside a reap root*' }).Count -ge 1)
    $DryRun = $true

    # --- the move rule -------------------------------------------------------
    # Two bugs, one cause. setLocation answers 200 as soon as the move is
    # QUEUED, so the manager logged MOVE for a move that never happened - and
    # the moves never happened because two torrents pointed at one folder, which
    # is the same claim question the reaper asks above, so it is asked the same
    # way here: by content_path, never by save_path.
    "== a move is not assumed, and not asked for while the folder is held =="

    function MT {
        param([string]$Hash, [string]$Name, [string]$ContentPath, [string]$SavePath = $root, [double]$Progress = 1)
        return [pscustomobject]@{
            hash = $Hash; name = $Name; content_path = $ContentPath
            save_path = $SavePath; progress = $Progress; completed = 1
        }
    }

    $shared  = New-Leaf -Name 'move-shared' -When $OLD -Folder
    $lonely  = New-Leaf -Name 'move-lonely' -When $OLD -Folder
    $arrived = New-Item -ItemType Directory -Path (Join-Path $library 'already-there') -Force
    # WriteAllText returns void, so the path has to be kept, not the call result.
    $loosePath = Join-Path $shared 'episode.mkv'
    [System.IO.File]::WriteAllText($loosePath, 'x')
    $noPath  = MT 'h0' 'no content_path' '' $root

    $a = MT 'hA' 'torrent A' $shared
    $b = MT 'hB' 'torrent B' $shared

    # Test-MoveSettled: the one question the rule is allowed to believe.
    Check 'a folder under the library counts as settled' `
        (Test-MoveSettled -T (MT 'h1' 'in place' $arrived.FullName) -TargetDir $library)
    Check 'a folder still in staging does not' `
        (-not (Test-MoveSettled -T $a -TargetDir $library))
    Check 'a torrent with no content_path is never settled' `
        (-not (Test-MoveSettled -T $noPath -TargetDir $library))
    Check 'and neither is nothing at all' `
        (-not (Test-MoveSettled -T $null -TargetDir $library))

    # Get-MovePlan: what to do, and why.
    Check 'a finished torrent already in the library is skipped' `
        ((Get-MovePlan -T (MT 'h2' 'in place' $arrived.FullName) -Torrents @() -TargetDir $library).Action -eq 'skip')

    $blocked = Get-MovePlan -T $a -Torrents @($a, $b) -TargetDir $library
    Check 'two torrents on one folder block the move' ($blocked.Action -eq 'block')
    Check 'the reason names the torrent holding it'     ($blocked.Reason -like "*torrent B*")
    Check 'the reason says retrying will not help'      ($blocked.Reason -like '*Permission denied*')

    Check 'with nobody else on the folder the move goes ahead' `
        ((Get-MovePlan -T $a -Torrents @($a) -TargetDir $library).Action -eq 'move')
    Check 'a torrent never blocks itself' `
        ((Get-MovePlan -T $a -Torrents @($a, $a) -TargetDir $library).Action -eq 'move')

    # The holder was deleted earlier in this same run, so it no longer holds
    # anything. Without $Gone its stale entry would block the move for ever.
    Check 'a holder this run already deleted does not block' `
        ((Get-MovePlan -T $a -Torrents @($a, $b) -TargetDir $library -Gone @{ 'hB' = $true }).Action -eq 'move')

    # The case that actually produced 'Permission denied': the other torrent's
    # content_path is a FILE inside the folder, so a rename of the folder cannot
    # succeed even though the two paths are not equal.
    Check "a file inside the folder blocks it too" `
        ((Get-MovePlan -T $a -Torrents @($a, (MT 'hC' 'multi-file' $loosePath)) -TargetDir $library).Action -eq 'block')

    Check 'a torrent with no content_path is blocked, not moved' `
        ((Get-MovePlan -T $noPath -Torrents @() -TargetDir $library).Action -eq 'block')

    Check 'save_path alone never blocks a move' `
        ((Get-MovePlan -T (MT 'h4' 'staged' $lonely) -Torrents @((MT 'h5' 'neighbour' (Join-Path $root 'something-else'))) -TargetDir $library).Action -eq 'move')

    # $a is the torrent being moved, so it is the other TWO that are holding.
    Check 'both holders are counted, not just the first one' `
        ((Get-MovePlan -T $a -Torrents @($a, $b, (MT 'hD' 'third' $shared)) -TargetDir $library).Reason -like '*2 live torrents*')

    # --- Wait-MoveVerified ---------------------------------------------------
    # The bug this replaces logged MOVE on the strength of a 200 from
    # setLocation, which only means the move was QUEUED. What is tested here is
    # the thing that was missing: it asks, and then reports what it was told.
    "== a queued move is confirmed, not assumed =="

    # Already there. Confirmed on the first ask, with no waiting at all: a move
    # on the same volume is a rename, so there is nothing to wait for.
    $script:apiCalls = 0
    $script:apiReplies = @()
    $script:apiReplies += ,@(MT 'hV1' 'arrived' $arrived.FullName)
    $v = Wait-MoveVerified -Hash 'hV1' -TargetDir $library -TimeoutSeconds 30 -PollMs 0
    Check 'a move that has landed is confirmed'           ($v.Ok)
    Check 'and is confirmed on the very first ask'        ($v.Tries -eq 1)
    Check 'after exactly one API call, and no waiting'     ($script:apiCalls -eq 1)
    Check 'the path reported is the one qBittorrent gave' ($v.Path -eq $arrived.FullName)
    Check 'with no reason attached to a success'           ($v.Why -eq '')

    # In flight: still in staging twice, then it lands.
    $script:apiCalls = 0
    $script:apiReplies = @()
    $script:apiReplies += ,@(MT 'hV2' 'staged' $lonely)
    $script:apiReplies += ,@(MT 'hV2' 'staged' $lonely)
    $script:apiReplies += ,@(MT 'hV2' 'arrived' $arrived.FullName)
    $v = Wait-MoveVerified -Hash 'hV2' -TargetDir $library -TimeoutSeconds 30 -PollMs 0
    Check 'a move in flight is waited for, not called a failure' ($v.Ok)
    Check 'after three asks, not one'                            ($v.Tries -eq 3)
    Check 'and the answer is the path that finally appeared'     ($v.Path -eq $arrived.FullName)

    # Never lands: the case the old code called a success. It has to give up at
    # the ceiling and say which path qBittorrent was still reporting.
    $script:apiCalls = 0
    $script:apiReplies = @()
    $script:apiReplies += ,@(MT 'hV3' 'stuck' $lonely)
    $script:apiReplies += ,@(MT 'hV3' 'stuck' $lonely)
    $v = Wait-MoveVerified -Hash 'hV3' -TargetDir $library -TimeoutSeconds 1 -PollMs 100
    Check 'a move that never lands is not reported as done'   (-not $v.Ok)
    Check 'it kept asking instead of answering once'           ($v.Tries -gt 1)
    Check 'the reason names the path qBittorrent still reports' ($v.Why -like '*move-lonely*')
    Check 'and says the move did not happen'                   ($v.Why -like '*did not happen*')
    Check 'a failed move reports no path as if it had one'     ($v.Path -eq '')

    # The torrent disappears while the move is in flight. An empty reply is not
    # an answer, so this must not be mistaken for success.
    $script:apiCalls = 0
    $script:apiReplies = @()
    $v = Wait-MoveVerified -Hash 'hV4' -TargetDir $library -TimeoutSeconds 5 -PollMs 100
    Check 'a torrent that vanishes mid-move is a failure' (-not $v.Ok)
    Check 'and the reason says it vanished'               ($v.Why -like '*vanished*')
}
finally {
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

''
"checks: $($script:fails) failed, $script:skips skipped"
if ($script:fails -gt 0) { exit 1 }
exit 0
