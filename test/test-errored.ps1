<#
    The ERRORED-torrent protection.

    An errored torrent must never be deleted, by any rule. The instruction was
    explicit, and the reason is on-disk data: with deleteDataFiles on, removing
    an errored entry destroys whatever it fetched, and an error is normally a
    transient or external fault rather than a verdict on the torrent.

    The hazard is that several rules would otherwise catch one torrent at once.
    An errored torrent is unfinished, so it looks like a stalled download, a
    smaller version of its title, AND a redundant copy - at the same time. So the
    guard is asserted at the single chokepoint every rule passes through, plus at
    each rule that has its own local path.

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-errored.ps1
#>

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = Split-Path -Parent $PSScriptRoot

$script:fails = 0
function Check {
    param([string]$Label, [bool]$Ok)
    if ($Ok) { Write-Host "  [PASS] $Label" } else { $script:fails++; Write-Host "  [FAIL] $Label" }
}

# Remove-Torrent and Test-Errored live in the manager's actions region, which is
# sliced separately from the detection block.
$src = [System.IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)

$rs = $src.IndexOf('# Is this torrent in qBittorrent''s ERROR state?')
$re = $src.IndexOf('# Polls qBittorrent until the move either shows up')
if ($rs -lt 0 -or $re -le $rs) { throw 'could not locate Test-Errored / Remove-Torrent in qbt-manager.ps1' }

# Stand-ins for what Remove-Torrent touches.
$DryRun = $true
$cfg = [pscustomobject]@{ deleteDataFiles = $true }
$script:actions = New-Object System.Collections.ArrayList
$script:notes   = New-Object System.Collections.ArrayList
$script:gone    = @{}
$script:posted  = New-Object System.Collections.ArrayList
$script:logged  = New-Object System.Collections.ArrayList
function Write-Log { param([string]$Level, [string]$Message) $script:logged += "$Level $Message" }
function Invoke-ApiPost {
    param([string]$Endpoint, [hashtable]$Fields)
    [void]$script:posted.Add("$Endpoint $($Fields['hash'])")
}

Invoke-Expression $src.Substring($rs, $re - $rs)

function T {
    param([string]$Hash = ('a' * 40), [string]$State = 'error', [string]$Name = 'A Torrent')
    [pscustomobject]@{ hash = $Hash; name = $Name; state = $State; progress = 0.3; size = 1000 }
}
# Reassign, do not .Clear(). The stubs below accumulate with += inside a
# function, and .Clear() on those did not reliably empty them between iterations
# - which showed up as a run of spurious failures where the counts crept 1,2,3,4,5
# and every check after the first looked broken. Reassignment is what $script:gone
# was already doing correctly, so it is used for all of them.
function Reset {
    $script:actions = New-Object System.Collections.ArrayList
    $script:notes   = New-Object System.Collections.ArrayList
    $script:posted  = New-Object System.Collections.ArrayList
    $script:logged  = New-Object System.Collections.ArrayList
    $script:gone    = @{}
}

Write-Host ''
Write-Host '== what counts as errored =='
Check 'state "error" is errored'                    (Test-Errored (T -State 'error'))
Check 'a null torrent is not'                      (-not (Test-Errored $null))
foreach ($s in 'downloading','stalledDL','uploading','pausedDL','stoppedUP','queuedDL',
               'missingFiles','checkingDL','moving','unknown','metaDL','allocating') {
    Check ("state '$s' is NOT errored")            (-not (Test-Errored (T -State $s)))
}
# The distinction that matters: these LOOK broken but are not the error state.
Check '"missingFiles" is not protected'            (-not (Test-Errored (T -State 'missingFiles')))
Check '"stalledDL" is not protected'               (-not (Test-Errored (T -State 'stalledDL')))

Write-Host ''
Write-Host '== the guard holds at the chokepoint =='
Reset
Remove-Torrent -T (T) -Reason 'a rule decided this'
Check 'an errored torrent is NOT posted for delete'  (@($script:posted).Count -eq 0)
Check 'and is not marked as gone in this run'        (-not $script:gone.ContainsKey(('a' * 40)))
Check 'but the refusal is recorded as a note'        ((@($script:notes) -join ' ') -match 'KEPT \(errored\)')
Check 'and logged as a warning, not a deletion'      ((@($script:logged) -join ' ') -match '^WARN')
Check ('  and NOT logged as a DELETE')               (-not ((@($script:logged) -join ' ') -match '^DELETE'))

Write-Host ''
Write-Host '== even in a dry run, nothing is promised =='
Reset
$DryRun = $true
Remove-Torrent -T (T) -Reason 'dry run' -DeleteFiles $true
Check 'a dry run does not print "WOULD DELETE"'      (-not ((@($script:actions) -join ' ') -match 'WOULD DELETE'))
Check 'and posts nothing'                            (@($script:posted).Count -eq 0)
$DryRun = $false

Write-Host ''
Write-Host '== every other state is unaffected =='
foreach ($s in 'downloading','stalledDL','missingFiles','unknown','uploading') {
    Reset
    Remove-Torrent -T (T -State $s) -Reason 'rule fired'
    Check ("state '$s' is still deleted as normal")  ((@($script:posted).Count -eq 1) -and (@($script:actions) -join ' ') -match 'DELETED')
}

Write-Host ''
Write-Host '== the ONE exception: dedup''s set-level comparison =='
# An errored torrent IS deleted when a FINISHED torrent of the IDENTICAL episode
# set is bigger. The user's wording: "smaller than another finished torrent with
# the same content (pack with x episodes -> pack with x episodes, or show y
# episode x -> show y episode x)".
Reset
Remove-Torrent -T (T -State 'error') -Reason 'errored, and the same episodes are already finished elsewhere' -AllowErrored
Check '-AllowErrored deletes it'                      (@($script:posted).Count -eq 1)
# 'DELETE', not 'DELETED' - Write-Log is called with the level DELETE and the
# label as the message. Searching for DELETED found nothing and failed, which is
# the check being wrong rather than the code.
Check 'and it is logged as a deletion, with the reason' (
    ((@($script:logged) -join ' ') -cmatch '\bDELETE\b') -and
    ((@($script:logged) -join ' ') -match 'errored, and the same episodes are already finished elsewhere'))

Write-Host ''
Write-Host '== ...but only dedup''s set pass passes it =='
# The whole safety of the exception is that it is reached from exactly one place,
# and that place compares IDENTICAL episode sets. Asserting the count of call sites
# rather than "it exists somewhere" - a count is what caught the sabotage.
$bodyAll = [System.IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)
# Anchored to the start of a line, so it counts CALL SITES and not the comment
# above Test-Errored that also contains the words "Remove-Torrent's -AllowErrored".
# Unanchored, this counted 2 for 1 call site and the check failed on correct code.
$allowCalls = ([regex]::Matches($bodyAll, '(?m)^\s*Remove-Torrent[^\r\n]*-AllowErrored')).Count
# (?ms), not (?s): with only (?s) the dot matches newlines but ^ still means the
# start of the whole string, so a mid-file "^\s*Remove-Torrent" could never match
# and the check failed on correct code. The window is generous because the two
# are ~110 lines apart inside the set loop.
Check 'and it is the set-level dedup delete'         ($bodyAll -cmatch '(?ms)Get-EpisodeSetKey.{0,20000}?^\s*Remove-Torrent -T \$m -AllowErrored')

# The three call sites that DO reach it, each named rather than counted, so a
# new one cannot slip in unnoticed and a moved one is still found.
$allowAt = @(
    @{ n = 'Dolby Vision'; p = 'Remove-Torrent -T $t -AllowErrored -Reason "Dolby Vision marker' }
    @{ n = 'disc rip';     p = 'Remove-Torrent -T $t -AllowErrored -Reason "full Blu-ray disc structure' }
    @{ n = 'set dedup';    p = 'Remove-Torrent -T $m -AllowErrored -Reason ("{0} of ' }
)
foreach ($c in $allowAt) {
    $i = $bodyAll.IndexOf($c.p)
    if ($i -lt 0) { Check ("$($c.n) passes -AllowErrored") $false; continue }
    Check ("$($c.n) passes -AllowErrored") $true
}
# Exactly three, so a fourth cannot appear. Anchored to a line start so the
# comment above Test-Errored, which also contains the words, is not counted.
Check 'and no other rule passes it'   ($allowCalls -eq 3)

# ...and the passes that must NOT reach it.
$noAllow = @(
    @{ n = 'the stalled rule'; p = 'Remove-Torrent -T $r.Torrent -Reason $r.Reason -DeleteFiles $true' }
    @{ n = 'pack-vs-single';   p = 'Remove-Torrent -T $single -Reason $reason -DeleteFiles $true' }
    @{ n = 'the phantom rule'; p = 'Remove-Torrent -T $p.Torrent -Reason $p.Reason -DeleteFiles $false' }
    @{ n = 'no availability'; p = 'Remove-Torrent -T $row.Torrent -Reason $row.Reason' }
    @{ n = 'library duplicates'; p = 'Remove-Torrent -T $d.Torrent -Reason $d.Reason' }
)
foreach ($c in $noAllow) {
    $i = $bodyAll.IndexOf($c.p)
    if ($i -lt 0) { Check ("$($c.n): call site located") $false; continue }
    $seg = $bodyAll.Substring($i, [Math]::Min(120, $bodyAll.Length - $i))
    Check ("$($c.n) does NOT pass -AllowErrored")   (-not ($seg -cmatch '-AllowErrored'))
}

Write-Host ''
Write-Host '== an errored torrent can never be the keeper =='
# The keeper is chosen from progress >= 1 only. An errored torrent is unfinished,
# so it cannot win - it can only be deleted as a loser.
$progressClause = ($bodyAll -cmatch '\$complete\s*=\s*@\(\$set\s*\|\s*Where-Object\s*\{\s*\$_\.progress\s*-ge\s*1\s*\}')
Check 'the keeper is chosen from COMPLETE members only' $progressClause

Write-Host ''
Write-Host '== a refused torrent is not consumed by the refusal =='
# If the guard marked it gone, a later rule in the same run could not report on
# it and the user would see nothing at all about the torrent.
Reset
Remove-Torrent -T (T) -Reason 'first rule' -AllowErrored
Remove-Torrent -T (T) -Reason 'second rule'
Check 'a normal delete after a forced one is refused' (@($script:posted).Count -eq 1)

Write-Host ''
Write-Host '== the guard is in the source, not only in this copy =='
# $body is assigned first: a statement cannot live inside a Check argument list,
# which is a parse error rather than a failing check.
$body = $src.Substring($rs, $re - $rs)
$guardAt = $body.IndexOf('Test-Errored $T')
$goneAt  = $body.IndexOf('$script:gone[$T.hash] = $true')

# EXACTLY ONE guard, and it precedes the gone-mark.
#
# Counting occurrences rather than just using IndexOf, because IndexOf finds the
# first one: a guard DUPLICATED below the gone-mark still leaves the first in the
# right place, so an ordering-only check reports green on a file that now has two
# guards - the second of which would swallow every torrent after gone was set. That
# is exactly what a sabotage probe did, and this count is what catches it.
$guardCount = ([regex]::Matches($body, [regex]::Escape('Test-Errored $T'))).Count
Check 'Remove-Torrent consults Test-Errored'         ($body -cmatch 'Test-Errored\s+\$T')
Check 'and there is exactly ONE guard'               ($guardCount -eq 1)
Check 'the guard runs BEFORE gone is marked'         ($guardAt -gt 0 -and $guardAt -lt $goneAt)
Check 'only the exact string "error" is protected'   ($src -cmatch "\`$T\.state\s+-eq\s+'error'")

Write-Host ''
Write-Host '== status.ps1 mirrors it, or the preview would lie =='
# Each CALL SITE named exactly, not a count of the bare string. A count was the
# first version and it was useless: deleting the dedup guard left the count at 5
# because a comment, the function definition and the DoVi guard all mention the
# name too. A sabotage probe caught that immediately.
$st = [System.IO.File]::ReadAllText((Join-Path $root 'status.ps1'), [System.Text.Encoding]::UTF8)
Check 'the preview defines Test-Errored'             ($st -cmatch 'function Test-Errored\s*\{')
# The DoVi / disc-rip exclusions are UNCONDITIONAL and the manager lets them
# delete an errored match, so the preview must report one too. Asserted as the
# ABSENCE of the old guard: a presence-check cannot tell "removed on purpose"
# from "never written", and this guard used to be here.
Check 'the DoVi / disc-rip exclusion does NOT skip'  (-not ($st -cmatch '(?s)function Get-ExclusionVerdict.{0,300}?if \(Test-Errored \$T\)'))
Check 'the pack-vs-single pass still respects it'    ($st -cmatch 'if \(Test-Errored \$single\) \{ continue \}')
# The set-level dedup must NOT skip errored members - that is the exception.
# Asserted as the ABSENCE of the old guard, since a presence-check cannot tell
# "removed on purpose" from "never written".
Check 'the set-level dedup does NOT skip errored'     (-not ($st -cmatch 'if \(Test-Errored \$m\) \{ continue \}'))
Check 'and it says why an errored one is deleted'    ($st -cmatch "errored, and the same episodes are already finished elsewhere")
Check 'both scripts use the same wording'            (
    ([regex]::Matches($bodyAll, 'errored, and the same episodes are already finished elsewhere')).Count -eq 1 -and
    ([regex]::Matches($st, 'errored, and the same episodes are already finished elsewhere')).Count -eq 1)

Write-Host ''
if ($script:fails -eq 0) {
    Write-Host 'all errored-torrent tests passed'
}
else {
    Write-Host ("{0} errored-torrent test(s) FAILED" -f $script:fails)
    exit 1
}