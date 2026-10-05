<#
    Exercises Get-NoAvailabilityVerdict, lifted out of qbt-manager.ps1 with
    synthetic torrents and a clock the test controls.

    This is the rule that deleted 205 torrents in one run, so it is tested on
    behaviour and not on the shape of the source. The rule as the user stated it
    is:

        delete a magnet that has been trying to find an availability for longer
        than the tolerance - and "trying" means qBittorrent is actually giving
        it a slot, which is the first `metadataPriorityRankLimit` positions of
        the queue.

    So there are two conditions, and both are tested:

      1. only a magnet inside the window is ever judged, and
      2. only time spent inside the window counts.

    The drain (rule 2c) is an ADDITION to this rule, not a replacement for it, and
    both functions are lifted here so the two can be run together in the order the
    manager runs them. That combination is the part worth protecting: the window
    must keep deleting every expired magnet it finds, all at once, however many
    there are, while the drain contributes at most one more. See the section at
    the bottom of this file.

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-queue-window.ps1
#>

$ErrorActionPreference = 'Stop'
if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent $PSScriptRoot

function Get-ProjectFile {
    param([string]$Name)
    $p = Join-Path $projectRoot $Name
    if (-not (Test-Path -LiteralPath $p)) {
        throw "cannot find $Name (looked in $p). These tests are meant to stay in the project's test folder."
    }
    return $p
}

$cfg = [System.IO.File]::ReadAllText((Get-ProjectFile 'config.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json

# ---------------------------------------------------------------------------
# lift the function out of the manager and run it
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# lift BOTH halves of the no-availability rule out of the manager and run them
# ---------------------------------------------------------------------------
# Both are needed here, not just the window. The drain was added as an ADDITION
# to the window rule, and the failure mode that matters is silent: if adding the
# drain had capped the window at one deletion per run, every other test in this
# file would still pass - they each call the window alone - while the rule the
# user actually relies on had quietly stopped working. So the two are exercised
# together at the end of this file, in the order the manager runs them.
$src = [System.IO.File]::ReadAllText((Get-ProjectFile 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)
$s = $src.IndexOf('# rule 2, isolated so it can be tested')
$e = $src.IndexOf('# orphan reaper: download leftovers that no torrent claims any more')
if ($s -lt 0 -or $e -le $s) { throw 'could not locate Get-NoAvailabilityVerdict in qbt-manager.ps1' }
Invoke-Expression $src.Substring($s, $e - $s)

$script:fails = 0
function Check {
    param([string]$Label, [bool]$Ok)
    if ($Ok) { "  [PASS] $Label" } else { $script:fails++; "  [FAIL] $Label" }
}

# The window and the tolerance the shipped config.json actually asks for. The
# tests below are about the rule, not about the numbers, but the numbers should
# be read from the real file so a bad edit cannot pass unnoticed.
$Limit = [int]$cfg.metadataPriorityRankLimit
$Timeout = [double]$cfg.metadataTimeoutMinutes

$NOW = [datetime]'2026-10-05 09:00:00'

function M {
    param(
        [string]$Hash,
        [int]$Priority,
        [double]$Size = 0,
        [string]$State = 'metaDL',
        [int]$Seeds = 0,
        [int]$Leechs = 0,
        [double]$AddedOn = 0
    )
    return [pscustomobject][ordered]@{
        hash       = $Hash
        name       = "Magnet $Hash at queue $Priority"
        priority   = $Priority
        size       = [int64]$Size
        total_size = [int64]$Size
        state      = $State
        num_seeds  = $Seeds
        num_leechs = $Leechs
        added_on   = $AddedOn
    }
}

function Judge {
    param(
        [object[]]$Torrents,
        [object]$Table,
        [datetime]$Now = $NOW,
        [double]$Tol = 60,
        [int]$Win = 10,
        $Skip
    )
    $h = @{}
    if ($Skip) { foreach ($k in $Skip.Keys) { $h[$k] = $true } }
    return @(Get-NoAvailabilityVerdict -Torrents $Torrents -Hashes $Table -Now $Now `
                -TimeoutMinutes $Tol -QueueLimit $Win -Skip $h)
}
function Row  { param($Rows, [string]$Hash) @($Rows | Where-Object { $_.Torrent.hash -eq $Hash })[0] }
function Held { param($Table, [string]$Hash) ($Table.PSObject.Properties.Name -contains $Hash) }
function Age  {
    param($Table, [string]$Hash, [double]$Minutes, [datetime]$Now = $NOW)
    $Table | Add-Member -NotePropertyName $Hash -NotePropertyValue ([pscustomobject]@{
        windowSince = $Now.AddMinutes(-$Minutes).ToString('o')
    }) -Force
}
function Head { param($Rows) if (@($Rows).Count -eq 0) { '' } else { $Rows[0].Name } }

Write-Host ''
Write-Host "== the shipped config =="
Check 'config.json sets a queue window'      ($Limit -gt 0)
Check 'the window is 10 positions'           ($Limit -eq 10)
# 30 minutes, lowered from 60 on request. Read from the real file, so a bad edit
# cannot pass unnoticed - that is the point of reading $Timeout at all rather
# than hardcoding a number here too.
Check 'the tolerance is 30 minutes'          ($Timeout -eq 30)
Check 'and it is a positive span'            ($Timeout -gt 0)

Write-Host ''
Write-Host '== inside the window: the timeout decides =='
$t = [pscustomobject]@{}
Age $t 'aa' 61
$r = Judge @(M 'aa' 3) $t
Check 'a magnet past the tolerance is deleted'          ($r[0].WillDelete)
Check 'and it says which queue position it was judged at' ($r[0].QueuePos -eq 3)

$t = [pscustomobject]@{}; Age $t 'aa' 59
Check 'a magnet under the tolerance is kept'            (-not (Judge @(M 'aa' 3) $t)[0].WillDelete)

$t = [pscustomobject]@{}; Age $t 'aa' 60
Check 'exactly at the tolerance is a deletion'          ((Judge @(M 'aa' 3) $t)[0].WillDelete)

Write-Host ''
Write-Host '== the window edges =='
foreach ($p in 1, 5, 10) {
    $t = [pscustomobject]@{}; Age $t 'aa' 61
    $r = (Judge @(M 'aa' $p) $t)[0]
    Check "queue position $p is inside the window"       ($r.InWindow -and $r.WillDelete)
}
foreach ($p in 11, 12, 150, 229) {
    $t = [pscustomobject]@{}; Age $t 'aa' 61
    $r = (Judge @(M 'aa' $p) $t)[0]
    Check "queue position $p is outside the window"      ((-not $r.InWindow) -and (-not $r.WillDelete))
}

Write-Host ''
Write-Host '== priority 0 is out of the queue, not the front of it =='
$t = [pscustomobject]@{}; Age $t 'aa' 5000
$r = (Judge @(M 'aa' 0) $t)[0]
Check 'priority 0 is never deleted'                     (-not $r.WillDelete)
Check 'and it is reported as out of the queue'          ((-not $r.InWindow) -and ($r.QueuePos -eq 0))
Check 'and it gets no clock at all'                     ($null -eq $r.Minutes)
Check 'its stored clock is thrown away'                 (-not (Held $t 'aa'))

Write-Host ''
Write-Host '== a magnet that has not had a turn is not this rule''s business =='
$t = [pscustomobject]@{}; Age $t 'aa' 435
$r = (Judge @(M 'aa' 150) $t)[0]
Check 'queued at 150 after 435 minutes it is kept'       (-not $r.WillDelete)
Check 'it has no clock, not a zero clock'               ($null -eq $r.Minutes)
Check 'the stale clock is dropped, not kept'             (-not (Held $t 'aa'))
Check 'so its next turn at the front starts from zero'   (-not (Held $t 'aa'))

Write-Host ''
Write-Host '== the clock runs only while the magnet is in the window =='
$t = [pscustomobject]@{}
$r = (Judge @(M 'aa' 4) $t)[0]
Check 'a magnet arriving at the front this run reads 0 minutes' ($r.Minutes -eq 0)
Check 'and is not deleted on arrival'                    (-not $r.WillDelete)
Check 'its clock is now recorded'                        (Held $t 'aa')

# one run later, still in the window: the clock must not restart
$r = Judge @(M 'aa' 4) $t ($NOW.AddMinutes(15))
Check 'a second run 15 minutes later shows 15 minutes'  ($r[0].Minutes -eq 15)
Check 'still not deleted at 15 minutes'                  (-not $r[0].WillDelete)
$r = Judge @(M 'aa' 4) $t ($NOW.AddMinutes(61))
Check 'and is deleted once the 60 minutes are up'        ($r[0].WillDelete)

Write-Host ''
Write-Host '== going out of the window resets the clock =='
$t = [pscustomobject]@{}
Age $t 'aa' 55
$r = Judge @(M 'aa' 40) $t
Check 'dropped back to position 40 it is kept'           (-not $r[0].WillDelete)
Check 'and its 55 minutes are cleared'                   (-not (Held $t 'aa'))
$r = Judge @(M 'aa' 6) $t
Check 'when it comes back it starts at zero again'       ($r[0].Minutes -eq 0)
Check 'so it cannot be deleted by the wait it did while queued' (-not $r[0].WillDelete)

Write-Host ''
Write-Host '== a clock skewed into the future cannot delete anything =='
$t = [pscustomobject]@{}
Age $t 'aa' -600
$r = (Judge @(M 'aa' 2) $t)[0]
Check 'a negative age is clamped to zero'                ($r.Minutes -eq 0)
Check 'and is not a deletion'                            (-not $r.WillDelete)

Write-Host ''
Write-Host '== migration from the old since-based state =='
$t = [pscustomobject]@{}
$t | Add-Member -NotePropertyName 'aa' -NotePropertyValue ([pscustomobject]@{ since = $NOW.AddHours(-9).ToString('o') })
$r = (Judge @(M 'aa' 3) $t)[0]
Check 'an old entry with no windowSince is not trusted'  ($r.Minutes -eq 0)
Check 'and that magnet is kept on the first run after'   (-not $r.WillDelete)
Check 'the new clock is written alongside it'            (Held $t 'aa')

Write-Host ''
Write-Host '== only magnets are candidates =='
# Note: Judge unrolls a single row to a bare object, and a PSCustomObject has no
# .Count in PS 5.1, so every count here goes through @().
$t = [pscustomobject]@{}; Age $t 'aa' 600
$r = Judge @(M 'aa' 3 -Size 4GB -State 'stalledUP') $t
Check 'a resolved torrent produces no row at all'        (@($r).Count -eq 0)
Check 'and its stale entry is dropped'                   (-not (Held $t 'aa'))

$t = [pscustomobject]@{}; Age $t 'aa' 600
$r = Judge @(M 'aa' 3 -Size 4GB -State 'metaDL') $t
Check 'a magnet still counts while it is fetching'       (@($r).Count -eq 1)
Check 'and it is judged for its availability'            ($r[0].WillDelete)

Write-Host ''
Write-Host '== the window size itself =='
$t = [pscustomobject]@{}; Age $t 'aa' 600
$r = Judge @(M 'aa' 3) $t -Win 0
Check 'a window of 0 judges nothing'                     (-not $r[0].WillDelete)
Check 'and writes no clock'                              (-not (Held $t 'aa'))

$t = [pscustomobject]@{}; Age $t 'aa' 600
Check 'a window of 1 judges only position 1'             ((Judge @(M 'aa' 1) $t -Win 1)[0].WillDelete)
Check 'and leaves position 2 alone'                      (-not (Judge @(M 'aa' 2) $t -Win 1)[0].WillDelete)

$t = [pscustomobject]@{}; Age $t 'aa' 600
Check 'a wide window does reach position 150'            ((Judge @(M 'aa' 150) $t -Win 300)[0].WillDelete)

Write-Host ''
Write-Host '== the reason names the availability =='
$t = [pscustomobject]@{}; Age $t 'aa' 75
$r = (Judge @(M 'aa' 7 -Seeds 0 -Leechs 1) $t)[0]
Check 'the reason says what the rule is about'           ($r.Reason -match 'no availability')
Check 'and names the queue position'                     ($r.Reason -match 'queue position 7')
Check 'and the tolerance it broke'                       ($r.Reason -match 'tolerance 60m')
Check 'and the seeds and peers it found'                 ($r.Reason -match '0 seeds 1 peers')
Check 'a kept magnet carries no reason at all'           ((Judge @(M 'aa' 7) $t -Tol 600)[0].Reason -eq '')

Write-Host ''
Write-Host '== ordering and skipping =='
$t = [pscustomobject]@{}
$many = @(M 'p9' 9; M 'p2' 2; M 'p5' 5; M 'p1' 1)
$r = Judge $many $t
Check 'rows come back in queue order'                    ((@($r | ForEach-Object { $_.QueuePos }) -join ',') -eq '1,2,5,9')
Check 'every magnet appears exactly once'                (@($r).Count -eq 4)
Check 'every row carries the torrent it names'           (@($r | Where-Object { $null -eq $_.Torrent }).Count -eq 0)

# A torrent an earlier rule removed this run must be left completely alone: no
# verdict, and no movement of the clock it happens to still have in state.json.
$t = [pscustomobject]@{}; Age $t 'aa' 600; Age $t 'bb' 600
$aaBefore = $t.PSObject.Properties['aa'].Value.windowSince
$r = Judge @(M 'aa' 1; M 'bb' 2) $t -Skip @{ aa = $true }
Check 'a torrent already removed this run is not judged' (@($r | Where-Object { $_.Torrent.hash -eq 'aa' }).Count -eq 0)
Check 'the others still are'                             ((Row $r 'bb').WillDelete)
Check 'and the skipped one keeps the clock it had'       ($t.PSObject.Properties['aa'].Value.windowSince -eq $aaBefore)

Write-Host ''
Write-Host '== the shape of the rule, read off the source =='
Check 'the window is written as 1..limit, so 0 cannot sneak in' ($src -match '\$pos\s*-ge\s*1\)\s*-and\s*\(\$pos\s*-le\s*\$QueueLimit\)')
Check 'the verdict is gated on being inside the window'   ($src -match '\$delete\s*=\s*\(\$inWindow\s+-and')
Check 'the tolerance is never compared for an out-of-window magnet' ($src -notmatch '\$delete\s*=\s*\(\$mins\s*-ge')
Check 'the sort cannot decide a verdict on its own'       ($src -notmatch '\$delete\s*=\s*\(\(\$i\s*\+')

# ---------------------------------------------------------------------------
# the window AND the drain, together, in the order the manager runs them
# ---------------------------------------------------------------------------
#
# The drain is an addition. Everything above tests the window alone, and the drain
# is tested alone in test-queue-drain.ps1, so on paper nothing here would notice
# if one had replaced the other. These run both functions against one queue, the
# way Show-Snapshot and qbt-manager.ps1 do, and assert the two rules' guarantees
# survive side by side:
#
#   - the window still deletes EVERY expired magnet it finds, all at once
#   - the drain still contributes at most one
#   - and neither one's clock is disturbed by the other
#
# The specific regression worth naming: a single shared "one per hour" budget
# across both rules would delete one magnet an hour in total and quietly destroy
# the window behaviour the user depends on - while every isolated test still
# passed.

# A live torrent, which is what the drain needs as its witness.
function Live {
    param([string]$Hash, [int]$Priority, [double]$Progress = 0.5)
    return [pscustomobject][ordered]@{
        hash = $Hash; name = "Live $Hash at queue $Priority"; priority = $Priority
        size = 1500000000; total_size = 1500000000; progress = $Progress
        state = 'downloading'; num_seeds = 3; num_leechs = 1; added_on = 0
    }
}

Write-Host ''
Write-Host '== the window and the drain together: an addition, not a swap =='

# Five magnets inside the window, all long expired, and a drain queue behind them:
# positions 11 and 12 are dead, and 13 is downloading, so the drain has a
# legitimate candidate AND a legitimate witness.
$combo = @(M 'w1' 1; M 'w2' 2; M 'w3' 3; M 'w4' 4; M 'w5' 5;
           M 'd11' 11; M 'd12' 12; (Live 'L13' 13))

$table = [pscustomobject]@{}
foreach ($h in @('w1', 'w2', 'w3', 'w4', 'w5')) { Age $table $h 600 }
$drainClock = [pscustomobject]@{ hash = 'd11'; since = $NOW.AddMinutes(-600).ToString('o') }

# The manager runs the window first, then rebuilds the skip set from what it
# deleted, then runs the drain. Reproduced exactly, because the skip set is the
# only thing coupling the two.
$gone = @{}
$winRows = @(Get-NoAvailabilityVerdict -Torrents $combo -Hashes $table -Now $NOW `
                            -TimeoutMinutes 60 -QueueLimit 10 -Skip $gone)
$winDeletions = @($winRows | Where-Object { $_.WillDelete })
# The window's rows carry no Hash field of their own - the hash lives on the
# torrent it wraps - so read it from there.
$winHashes = @($winDeletions | ForEach-Object { $_.Torrent.hash })
foreach ($h in $winHashes) { $gone[$h] = $true }
$drainRows = @(Get-QueueDrainVerdict -Torrents $combo -Now $NOW -TimeoutMinutes 60 `
                               -QueueLimit 10 -Drain $drainClock -Skip $gone)

Check 'the window still deletes every expired magnet it finds' ($winDeletions.Count -eq 5)
Check 'the five window magnets are the ones it deletes'    (($winHashes -join ',') -eq 'w1,w2,w3,w4,w5')
Check 'and it is not capped at one'                         ($winDeletions.Count -gt 1)
Check 'the drain then adds its own single deletion'         (@($drainRows | Where-Object { $_.WillDelete }).Count -eq 1)
Check 'for a total of 6 in one run, not 1'                  (($winDeletions.Count + @($drainRows | Where-Object { $_.WillDelete }).Count) -eq 6)

# The drain must not reach into the window's half of the queue.
Check 'the drain did not touch a window magnet'             (@($drainRows | Where-Object { $_.QueuePos -le 10 }).Count -eq 0)
Check 'its candidate is position 11, the first behind it'  ($drainRows[0].Hash -eq 'd11')
Check 'and it is the same magnet the window left alone'    ((Row $winRows 'd11') -ne $null -and -not (Row $winRows 'd11').WillDelete)

# A window deletion must be invisible to the drain - both because the skip set
# says so, and because a deleted magnet cannot be a witness.
$goneBoth = @{ w1 = $true; w2 = $true; w3 = $true; w4 = $true; w5 = $true }
$d2 = @(Get-QueueDrainVerdict -Torrents $combo -Now $NOW -TimeoutMinutes 60 `
                           -QueueLimit 10 -Drain $drainClock -Skip $goneBoth)
Check 'the drain ignores what the window already deleted'  ($d2[0].Hash -eq 'd11')

# The two clocks are separate objects and neither writes to the other.
$tableBefore = ($table.PSObject.Properties | ForEach-Object { $_.Value.windowSince }) -join ','
$drainBefore = $drainClock.since
$null = @(Get-NoAvailabilityVerdict -Torrents $combo -Hashes $table -Now $NOW `
                                  -TimeoutMinutes 60 -QueueLimit 10 -Skip @{ d11 = $true })
Check 'running the window leaves the drain clock untouched' ($drainClock.since -eq $drainBefore)
$tableAfter = ($table.PSObject.Properties | ForEach-Object { $_.Value.windowSince }) -join ','
Check 'and running the drain leaves the window clocks alone' ($tableBefore -eq $tableAfter)

# The checks above prove the two RULES compose. They cannot prove the manager
# actually RUNS both in one pass, because they call the two functions directly -
# so a call site that disabled the drain, or a shared budget between them, would
# go unnoticed while every one of them still passed. That was verified by
# breaking the drain's call site and watching this file pass unchanged.
#
# So the wiring itself is asserted here: both rules are invoked, in order, inside
# the one run body, with no early return between them.
$runS = $src.IndexOf("-- rule 2: a magnet that found nothing")
$runE = $src.IndexOf("-- rule 2b: an unfinished torrent")
if ($runS -lt 0 -or $runE -le $runS) { throw 'could not locate the no-availability run body' }
$runBody = $src.Substring($runS, $runE - $runS)

Check 'the run body calls the window rule'          ($runBody -match 'Get-NoAvailabilityVerdict')
Check 'the run body also calls the drain'           ($runBody -match 'Get-QueueDrainVerdict')
Check 'the drain runs after the window, not instead' `
      (($runBody.IndexOf('Get-NoAvailabilityVerdict')) -lt ($runBody.IndexOf('Get-QueueDrainVerdict')))
Check 'and both are inside the one run body'        ($runBody -match 'Get-QueueDrainVerdict')

# Each rule must reach Remove-Torrent on its own account. One delete call wired
# to the other rule's rows is exactly how a substitution would look.
Check 'the window deletes through its own rows'     ($runBody -match '(?s)if \(\$row\.WillDelete\) \{\s*Remove-Torrent -T \$row\.Torrent')
# Bounded rather than exact: the drain logs a line before deleting, and that
# log statement wraps with a backtick continuation, so the two are not adjacent.
# What matters is that the delete is driven by the DRAIN's row variable ($d) and
# not by the window's ($row) - that is precisely how a substitution would look.
Check 'the drain deletes through its own rows'      `
      (($runBody -match 'if \(\$d\.WillDelete\)') -and ($runBody -match '(?s)if \(\$d\.WillDelete\).{0,400}?Remove-Torrent -T \$d\.Torrent'))
Check 'and it never deletes the window''s rows from the drain' ($runBody -notmatch '(?s)if \(\$d\.WillDelete\).{0,400}?Remove-Torrent -T \$row\.Torrent')

# The drain is gated on its own switch, and that gate must not swallow the window:
# the window's call has to sit OUTSIDE any queueDrainEnabled branch. Checked by
# requiring the window call to appear before the drain switch is even read.
$drainGate = $runBody.IndexOf('queueDrainEnabled')
Check 'the window is judged before the drain switch is read' `
      (($runBody.IndexOf('Get-NoAvailabilityVerdict')) -lt $drainGate)
Check 'turning the drain off cannot disable the window' ($runBody -notmatch '(?s)queueDrainEnabled.{0,400}Get-NoAvailabilityVerdict')

# Both calls must be handed the SAME window limit. That is what makes them two
# rules over one boundary rather than two rules over two - and it is the check
# that catches a call site quietly neutralised with a different limit, which the
# two checks above cannot see because they only ask whether the call is present.
# Verified by rewriting the drain's -QueueLimit argument and watching this fail.
Check 'the window is handed the configured limit'      ($runBody -match '(?s)Get-NoAvailabilityVerdict.{0,300}?-QueueLimit \$limit')
Check 'the drain is handed that same limit'            ($runBody -match '(?s)Get-QueueDrainVerdict.{0,300}?-QueueLimit \$limit')
Check 'neither rule is handed a hard-coded limit'      ($runBody -notmatch '(?s)Get-(NoAvailabilityVerdict|QueueDrainVerdict).{0,300}?-QueueLimit \d')
Check 'both are handed the same tolerance'             (($runBody -match '(?s)Get-NoAvailabilityVerdict.{0,300}?-TimeoutMinutes \$timeout') -and `
                                                      ($runBody -match '(?s)Get-QueueDrainVerdict.{0,300}?-TimeoutMinutes \$timeout'))

# ---------------------------------------------------------------------------
# the family label is display-only and cannot affect a deletion
# ---------------------------------------------------------------------------
#
# Set-FamilyLabels stamps showLabel onto every series member so status.ps1 can
# print one name per show family instead of one name per episode. It runs on the
# clusters a merge decided, and it exists because a wrong name reads as several
# different shows - but a label any rule could read would be a rule change
# wearing a display change's clothes. So it is asserted to be unread by every
# decision path, which is the only thing that makes "cosmetic" checkable.
$ls = $src.IndexOf('function Set-FamilyLabels')
$le = $src.IndexOf('function Merge-SeriesClusters {')
Check 'Set-FamilyLabels exists'                  ($ls -gt 0)
if ($ls -gt 0 -and $le -gt $ls) {
    $labelBody = $src.Substring($ls, $le - $ls)
    Check 'showLabel is stamped on members'            ($labelBody -match "NotePropertyName 'showLabel'")
    Check 'it writes no other property'                ($labelBody -notmatch "Add-Member -InputObject \`$m -NotePropertyName (?!'showLabel')")
    Check 'and it never reads the label it just wrote' ($labelBody -notmatch '\.showLabel')
}

# The dedup pass is what deletes, so it must not even mention the label. It is
# inline in the run body rather than a named function, so it is located by its own
# heading - and the heading is searched for as text, so renaming it fails the test
# instead of silently skipping the check.
$ds = $src.IndexOf("Write-Host 'Dedup")
Check 'the dedup pass was found'                    ($ds -gt 0)
if ($ds -gt 0) {
    $dedupBody = $src.Substring($ds, 12000)
    # '.showLabel' and not bare 'showLabel': PowerShell's -match is
    # case-INSENSITIVE, so a bare pattern matches the ShowLabel inside
    # Get-ShowLabel and this check failed against code that never reads the
    # property. A read is always a property access, so that is what is matched.
    Check 'nothing in the dedup pass reads showLabel' ($dedupBody -notmatch '\.showLabel')
    Check 'and the pass does still call Get-ShowLabel'  ($dedupBody -match 'Get-ShowLabel')
}

# The labelling has to be a separate function called from the wrapper, or a
# future fourth return path inside the merge would silently drop the labels.
Check 'the labelling is separate from the merge'     ($src -match '(?s)function Merge-SeriesClustersCore.*?function Merge-SeriesClusters \{.*?Set-FamilyLabels')
Check 'and the wrapper labels on every return path' ($src -match '(?s)\$merged = Merge-SeriesClustersCore -Clusters \$Clusters\s*\r?\n\s*Set-FamilyLabels -Clusters \$merged')

# The reverse direction too: with NO window magnets at all, the window deletes
# nothing and the drain still runs. Neither rule depends on the other existing.
$onlyBehind = @(M 'd11' 11; M 'd12' 12; (Live 'L13' 13))
$t3 = [pscustomobject]@{}
$c3 = [pscustomobject]@{ hash = 'd11'; since = $NOW.AddMinutes(-600).ToString('o') }
$w3 = @(Get-NoAvailabilityVerdict -Torrents $onlyBehind -Hashes $t3 -Now $NOW `
                             -TimeoutMinutes 60 -QueueLimit 10)
$r3 = @(Get-QueueDrainVerdict -Torrents $onlyBehind -Now $NOW -TimeoutMinutes 60 `
                            -QueueLimit 10 -Drain $c3)
Check 'with nothing in the window the window deletes nothing' (@($w3 | Where-Object { $_.WillDelete }).Count -eq 0)
Check 'and the drain still does its job'                    ($r3[0].WillDelete -and $r3[0].Hash -eq 'd11')

# And the window alone, with no drain behind it, is unchanged.
$onlyWindow = @(M 'w1' 1; M 'w2' 2; (Live 'L3' 3))
$t4 = [pscustomobject]@{}
foreach ($h in @('w1', 'w2')) { Age $t4 $h 600 }
$w4 = @(Get-NoAvailabilityVerdict -Torrents $onlyWindow -Hashes $t4 -Now $NOW `
                             -TimeoutMinutes 60 -QueueLimit 10)
Check 'the window is undiminished when there is nothing behind it' (@($w4 | Where-Object { $_.WillDelete }).Count -eq 2)

Write-Host ''
if ($script:fails -eq 0) {
    Write-Host 'ALL CHECKS PASSED'
    exit 0
}
else {
    Write-Host ''
    Write-Host ("{0} CHECK(S) FAILED" -f $script:fails) -ForegroundColor Red
    exit 1
}