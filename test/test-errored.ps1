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

# The detection block, for Get-TitleParts and Test-SameTitle. Remove-Torrent now
# asks whether a bigger copy is still downloading, which means parsing release
# names and comparing titles - and neither is in the actions region. Without this
# the guard's own tests cannot build a release name to point at it, and the first
# version of them died on 'Get-TitleParams is not recognized'.
$ds = $src.IndexOf('$script:boundaryPattern')
$de = $src.IndexOf('function Get-DoviHit')
if ($ds -lt 0 -or $de -le $ds) { throw 'could not locate the detection block' }
Invoke-Expression $src.Substring($ds, $de - $ds)

# Get-IncomingBetterVerdict, the guard that keeps a finished entry when a bigger
# copy is still downloading. It lives in the actions region but BEFORE
# Remove-Torrent, so the slice above misses it - and the first version of these
# tests failed on 'Get-IncomingBetterVerdict is not recognized' with no other
# symptom, which reads as a broken guard rather than an unloaded one.
$hs = $src.IndexOf('# Is a bigger copy of this content still on its way?')
$he = $src.IndexOf('function Stop-TorrentAndConfirm')
if ($hs -lt 0 -or $he -le $hs) { throw 'could not locate Get-IncomingBetterVerdict' }
Invoke-Expression $src.Substring($hs, $he - $hs)

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
# Remove-Torrent now stops a torrent and RE-READS it to confirm the stop landed,
# so it calls torrents/info as well as torrents/stop and torrents/delete. Without
# this stub the confirmation has nothing to read, the stop never confirms, and
# every deletion in this suite silently stops happening - which is exactly what
# the five "still deleted as normal" checks caught.
#
# $script:stopState is the state the re-read reports. 'stoppedUP' is the settled
# state of a stopped finished torrent, so a stop always confirms by default. Set it
# to something active to exercise the refusal.
$script:stopState = 'stoppedUP'
function Invoke-ApiGet {
    param([string]$Endpoint)
    if ($Endpoint -eq 'torrents/info') { return @() }
    return @()
}

Invoke-Expression $src.Substring($rs, $re - $rs)

# Stop-TorrentAndConfirm is stood in for AFTER the source is loaded, because
# defining it before means the source's own definition simply replaces it - which
# is what happened first time, and it left the real helper calling an API this
# suite does not stub. Every deletion then failed to confirm its stop and quietly
# stopped happening.
#
# The real helper is exercised against the real source by test-pack-safety.ps1.
# Here it only needs to record that a stop was issued, so the ORDER of stop and
# delete can be asserted.
$script:refuseStop = $false
function Stop-TorrentAndConfirm {
    param([object]$T, [int]$Attempts = 5, [int]$WaitMs = 400)
    if ($script:refuseStop) { return $false }
    # The settled states, mirroring the real helper: stopped, paused, and error.
    # An errored entry is not running and cannot start writing, so there is no
    # writer to race, and stopping it would overwrite the very state that says it
    # must not be deleted.
    if ($T -and [string]$T.state -notmatch '^(stopped|paused|error)') {
        [void]$script:posted.Add("torrents/stop $($T.hash)")
    }
    return $true
}

function T {
    param(
        [string]$Hash = ('a' * 40),
        [string]$State = 'error',
        [string]$Name = 'A Torrent',
        [double]$Progress = 0.3
    )
    # progress 1: the data is on disk and the entry is the record of it.
    [pscustomobject]@{ hash = $Hash; name = $Name; state = $State; progress = $Progress; size = 1000 }
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
# The count is now 2, not 1: Remove-Torrent stops the torrent before deleting it,
# so an active state produces a torrents/stop AND a torrents/delete. Asserting the
# delete specifically rather than the total, because a total of 1 would also pass
# if the stop happened and the delete did not - which is the failure that matters.
foreach ($s in 'downloading','stalledDL','missingFiles','unknown','uploading') {
    Reset
    Remove-Torrent -T (T -State $s) -Reason 'rule fired'
    $posted = @($script:posted)
    $stops   = @($posted | Where-Object { $_ -like 'torrents/stop*' })
    $deletes = @($posted | Where-Object { $_ -like 'torrents/delete*' })
    Check ("state '$s' is still deleted as normal") `
        (($deletes.Count -eq 1) -and ((@($script:actions) -join ' ') -match 'DELETED'))
    # Order matters as much as presence: a delete issued before the stop races the
    # writer. [array]::IndexOf on the raw list, not on the filtered subsets.
    $stopAt   = if ($stops.Count)   { [array]::IndexOf($posted, $stops[0]) }   else { -1 }
    $deleteAt = if ($deletes.Count) { [array]::IndexOf($posted, $deletes[0]) } else { -1 }
    Check ("  and it is stopped first") (($stops.Count -eq 1) -and ($deletes.Count -eq 1) -and ($stopAt -lt $deleteAt))
}

Write-Host ''
Write-Host '== a torrent that will not confirm stopped is NOT deleted =='
# HTTP 200 from torrents/stop means the request was accepted, not that the torrent
# has stopped. Deleting inside that window races a live writer, and a live torrent
# re-fetches whatever is taken away - so the file returns and the delete looks like
# a no-op. Leaving a duplicate costs disk; deleting under a writer costs the write.
Reset
$script:refuseStop = $true
Remove-Torrent -T (T -State 'downloading') -Reason 'rule fired'
# Each condition parenthesised on its own. Written as one expression with -and
# binding looser than the pipeline, the array leaked out as the argument and the
# call failed on a type conversion rather than reporting a failed check.
$noDelete = @(@($script:posted | Where-Object { $_ -like 'torrents/delete*' })).Count -eq 0
Check 'no delete is issued'                   ($noDelete)
Check 'and nothing is claimed as dealt with'   (-not $script:gone.ContainsKey(('a' * 40)))
Check 'the refusal is recorded as a note'      ((@($script:notes) -join ' ') -match 'KEPT \(still running\)')
Check 'and no DELETED action is recorded'      (-not ((@($script:actions) -join ' ') -match 'DELETED'))
$script:refuseStop = $false

Write-Host ''
Write-Host '== the ONE exception: dedup''s set-level comparison =='
# An errored torrent IS deleted when a FINISHED torrent of the IDENTICAL episode
# set is bigger. The user's wording: "smaller than another finished torrent with
# the same content (pack with x episodes -> pack with x episodes, or show y
# episode x -> show y episode x)".
Reset
Remove-Torrent -T (T -State 'error') -Reason 'errored, and the same episodes are already finished elsewhere' -AllowErrored
# Counted as the DELETE specifically, not the total. An errored torrent is not
# stopped before it is deleted - there is nothing running to stop - so the total is
# 1 here and 2 everywhere else. Asserting the total made this check fail the moment
# the stop-before-delete was added, which reads as "the exception stopped working"
# when nothing of the sort had happened.
$forcedDeletes = @(@($script:posted | Where-Object { $_ -like 'torrents/delete*' }))
Check '-AllowErrored deletes it'                      ($forcedDeletes.Count -eq 1)
Check 'and an errored entry is not stopped first'     (@(@($script:posted | Where-Object { $_ -like 'torrents/stop*' })).Count -eq 0)
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
#
# 'set dedup' pins the GUARDS, not the reason text. It used to match
# '-Reason ("{0} of ', which asserted the wording of a log message rather than
# anything about errored handling - so rewording the reason (the dedup pass gained
# a percentage in it) failed a test about -AllowErrored. What matters here is which
# call site passes the switch, and 'Remove-Torrent -T $m -AllowErrored -Knows
# -Reason' is unique to the set-level delete: the DoVi and disc-rip sites pass -T
# something else and carry -AllowIncomingBetter.
$allowAt = @(
    @{ n = 'Dolby Vision'; p = '-AllowErrored -Knows -AllowIncomingBetter -Reason "Dolby Vision marker' }
    @{ n = 'disc rip';     p = '-AllowErrored -Knows -AllowIncomingBetter -Reason "full Blu-ray disc structure' }
    @{ n = 'set dedup';    p = 'Remove-Torrent -T $m -AllowErrored -Knows -Reason' }
)
foreach ($c in $allowAt) {
    $i = $bodyAll.IndexOf($c.p)
    if ($i -lt 0) { Check ("$($c.n) passes -AllowErrored") $false; continue }
    Check ("$($c.n) passes -AllowErrored") $true
}
# Exactly three, so a fourth cannot appear. Anchored to a line start so the
# comment above Test-Errored, which also contains the words, is not counted.
Check 'and no other rule passes it'   ($allowCalls -eq 3)

# ...and the passes that must NOT reach it. Matched on the argument list alone,
# not the whole call: several of these gained a -Knows later, and a full-call
# pattern stopped matching the moment they did - which reads as "the rule moved"
# when nothing of the sort had happened.
$noAllow = @(
    @{ n = 'the stalled rule';    p = '$r.Torrent -DeleteFiles $true -Reason (' }
    @{ n = 'pack-vs-single';      p = '$single -Knows -Reason $reason' }
    @{ n = 'the phantom rule';    p = '$p.Torrent -Knows -Reason $p.Reason -DeleteFiles $false' }
    @{ n = 'no availability';     p = '$row.Torrent -Reason $row.Reason' }
    @{ n = 'library duplicates';  p = '$d.Owner -Knows -Reason $d.Reason' }
    @{ n = 'redundant download';  p = '$r.Torrent -Knows -Reason $r.Reason -DeleteFiles $true' }
)
foreach ($c in $noAllow) {
    $i = $bodyAll.IndexOf($c.p)
    if ($i -lt 0) { Check ("$($c.n): call site located") $false; continue }
    # Argument list only, never the whole call. Each of these has now gained a
    # flag -Knows, then -AllowIncomingBetter - and a full-call pattern stops
    # matching every time one is added, which reads as "the rule moved" when
    # nothing about the rule's behaviour changed.
    # Named by the flag that follows -T, so a later flag on a different concern
    # cannot stop it matching. Each of these has gained a flag while this file
    # existed, and a full-call pattern stopped matching every time.
    $seg = $bodyAll.Substring($i, [Math]::Min(120, $bodyAll.Length - $i))
    Check ("$($c.n) does NOT pass -AllowErrored")   (-not ($seg -cmatch '-AllowErrored'))
}

Write-Host ''
Write-Host '== only DoVi and disc rip may ignore a bigger copy arriving =='
# Every other rule that deletes a FINISHED entry has to live with the possibility
# that something bigger has not downloaded yet. Measured on a live queue, six pairs
# where that was true - one of them at 0%, so the 'better' copy did not exist yet
# at all.
$incomingOk = @(
    @{ n = 'Dolby Vision'; p = '-Knows -AllowIncomingBetter -Reason "Dolby Vision marker' }
    @{ n = 'disc rip';     p = '-Knows -AllowIncomingBetter -Reason "full Blu-ray disc structure' }
)
foreach ($c in $incomingOk) {
    Check ("$($c.n) may ignore an incoming better copy") ($bodyAll.IndexOf($c.p) -ge 0)
}
$incomingCalls = @($bodyAll -split "`n" | Where-Object { $_ -cmatch '^\s*Remove-Torrent\b' -and $_ -cmatch '-AllowIncomingBetter' })
Check 'and exactly two rules do'                    ($incomingCalls.Count -eq 2)
Write-Output '  they are:'
foreach ($c in $incomingCalls) { Write-Output ("    " + ($c.Trim() -replace '\s+', ' ')) }

Write-Host ''
Write-Host '== an errored torrent can never be the keeper =='
# The keeper is chosen from progress >= 1 only. An errored torrent is unfinished,
# so it cannot win - it can only be deleted as a loser.
$progressClause = ($bodyAll -cmatch '\$complete\s*=\s*@\(\$set\s*\|\s*Where-Object\s*\{\s*\$_\.progress\s*-ge\s*1\s*\}')
Check 'the keeper is chosen from COMPLETE members only' $progressClause

Write-Host ''
Write-Host '== not knowing is the reason to KEEP a finished entry =='
# The burden of proof, inverted. Every rule here reaches its verdict from a
# partial view: a snapshot of the queue, a library that may be mid-move, an owning
# entry that may not be loaded. A rule that did not find another copy has not
# established that this is the only one.
#
# Deleting a 40 GB season pack on the strength of one 5,61 GB duplicate file is
# what that costs, so a FINISHED entry cannot be deleted unless the rule says it
# established a keeper it actually SAW.
Reset
Remove-Torrent -T (T -State 'stoppedUP' -Progress 1) -Reason 'a rule decided this'
Check 'a finished entry with no -Knows is kept'       (@($script:posted).Count -eq 0)
Check 'the note says why'                             ((@($script:notes) -join ' ') -match 'nothing established it is a copy')
Check 'and it is not marked gone'                     (-not $script:gone.ContainsKey(('a' * 40)))
Reset
Remove-Torrent -T (T -State 'stoppedUP' -Progress 1) -Reason 'a rule decided this' -Knows
$knowsDeletes = @(@($script:posted | Where-Object { $_ -like 'torrents/delete*' }))
Check '-Knows does delete it'                         ($knowsDeletes.Count -eq 1)

Write-Host ''
Write-Host '== an UNFINISHED entry needs no such claim =='
# Not a loophole. A finished entry is a statement that data exists on disk, and
# removing the entry cannot be undone by re-downloading. An unfinished one is
# deleted with its partial data, which is small and already unwanted - that is
# what rules 2, 2b, 2c and 2d are for, and they pass no -Knows.
Reset
Remove-Torrent -T (T -State 'downloading') -Reason 'magnet with nothing to download from'
$partialDeletes = @(@($script:posted | Where-Object { $_ -like 'torrents/delete*' }))
Check 'an unfinished entry is deleted as before'      ($partialDeletes.Count -eq 1)
Check 'without needing to prove anything'             ($partialDeletes.Count -eq 1 -and @($script:notes).Count -eq 0)

Write-Host ''
Write-Host '== the finished test is on progress, not on state =='
# 'stoppedUP' and 'queuedUP' are both finished; 'stalledDL' is not. Asserted on
# the thing the rule actually reads, so a state-name change cannot silently
# widen or narrow the guard.
Reset
Remove-Torrent -T (T -State 'queuedUP' -Progress 1) -Reason 'finished and seeding'
Check 'a finished seeding entry is kept too'          (@($script:posted).Count -eq 0)
Reset
Remove-Torrent -T (T -State 'stalledDL') -Reason 'unfinished and idle'
Check 'a stalled but unfinished entry still goes'     (@(@($script:posted | Where-Object { $_ -like 'torrents/delete*' })).Count -eq 1)

Write-Host ''
Write-Host '== every rule that deletes a FINISHED entry must pass -Knows =='
# The property that keeps this from decaying: a new rule added later, or an
# existing one widened, cannot delete finished data without saying what it knows.
# Read off the source rather than trusted.
$src2 = [System.IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)
$callLines = @($src2 -split "`n" | Where-Object { $_ -cmatch '^\s*Remove-Torrent\b' })
$noKnows = @()
foreach ($cl in $callLines) {
    if ($cl -notmatch '-Knows') { $noKnows += $cl.Trim() }
}
Check 'the rules that pass no -Knows are the magnet/partial ones' ($noKnows.Count -eq 4)
Write-Output '  they are:'
foreach ($n in $noKnows) { Write-Output ("    " + ($n -replace '\s+', ' ')) }
Check 'and none of them can be handed a finished torrent by a verdict function' (
    # Each of those four rules judges a magnet or an unfinished download by
    # construction, so the guard never has to save them - but the guard is there
    # in case that ever stops being true.
    ($src2 -cmatch '\[double\]\$T\.progress -ge 1'))

Write-Host ''
Write-Host '== a bigger copy still DOWNLOADING means keep it =='
# -Knows asks whether a rule SAW a keeper. It cannot ask whether something bigger
# is on its way, because that thing does not exist yet: at 0%, or a magnet, or not
# yet added. Deleting a finished copy on the promise of a bigger one is losing data
# on credit, and the credit is never called in.
#
# Measured on a live queue, six pairs - the sharpest being one at 0%.
Reset
$DryRun = $false
$script:liveTorrents = @(
    [pscustomobject]@{ hash = ('a' * 40); name = 'Some.Show.S03E07.1080p.WEB-DL.x264-GRP'; progress = 1.0; size = 8GB
                      parts = (Get-TitleParts -Name 'Some.Show.S03E07.1080p.WEB-DL.x264-GRP') }
    [pscustomobject]@{ hash = ('c' * 40); name = 'Some.Show.S03E07.2160p.WEB-DL.h265-GRP'; progress = 0.0; size = 9GB
                      parts = (Get-TitleParts -Name 'Some.Show.S03E07.2160p.WEB-DL.h265-GRP') }
)
# The torrent under judgement is a DIFFERENT object from the one in the snapshot.
# That is how the real run works - the rule iterates $live, while the guard reads
# $script:liveTorrents, the snapshot taken at the start. Passing the snapshot's own
# member made the guard skip it as 'the same torrent' and find nothing, which is
# how these checks failed while the guard was working perfectly.
$underJudge = [pscustomobject]@{ hash = ('a' * 40); name = 'finished 1080p'; state = 'stoppedUP'; progress = 1.0; size = 1000
                                 parts = (Get-TitleParts -Name 'Some.Show.S03E07.1080p.WEB-DL.x264-GRP') }
Remove-Torrent -T $underJudge -Knows -Reason 'a rule saw a keeper'
$heldForIncoming = @($script:posted).Count -eq 0
# The notes list holds ONE string, and the whole of it is worth reading before any
# assertion is written against it - a check that cannot see what it is matching
# produces a confusing type error rather than a false answer.
$noteText = [string](@($script:notes) -join ' ')
Write-Output ('  the note reads: ' + $noteText)
$heldOk = [bool]$heldForIncoming
$noteSaysComing = [bool]($noteText -match 'still downloading')
$noteNamesIt = [bool]($noteText -match '2160p')
Check 'a finished copy is kept when a bigger one is at 0%' $heldOk
Check 'the note says a bigger copy is coming'          $noteSaysComing
Check 'and it names the incoming torrent'             $noteNamesIt
Check 'and it is not marked gone'                     (-not $script:gone.ContainsKey(('a' * 40)))

Write-Host ''
Write-Host '== ...and once that copy is FINISHED, it is no longer "incoming" =='
# The same pair, with the bigger one at 100%. It is now a keeper a rule can SEE,
# so -Knows covers it and the finished smaller copy may go.
Reset
$script:liveTorrents = @(
    [pscustomobject]@{ hash = ('a' * 40); name = 'Some.Show.S03E07.1080p.WEB-DL.x264-GRP'; progress = 1.0; size = 8GB
                      parts = (Get-TitleParts -Name 'Some.Show.S03E07.1080p.WEB-DL.x264-GRP') }
    [pscustomobject]@{ hash = ('c' * 40); name = 'Some.Show.S03E07.2160p.WEB-DL.h265-GRP'; progress = 1.0; size = 9GB
                      parts = (Get-TitleParts -Name 'Some.Show.S03E07.2160p.WEB-DL.h265-GRP') }
)
$underJudge2 = [pscustomobject]@{ hash = ('a' * 40); name = 'finished 1080p'; state = 'stoppedUP'; progress = 1.0; size = 1000
                                  parts = (Get-TitleParts -Name 'Some.Show.S03E07.1080p.WEB-DL.x264-GRP') }
Remove-Torrent -T $underJudge2 -Knows -Reason 'a rule saw a keeper'
$goneWhenFinished = @(@($script:posted | Where-Object { $_ -like 'torrents/delete*' })).Count -eq 1
Check 'the smaller finished copy is deleted once the bigger is finished' ($goneWhenFinished)

Write-Host ''
Write-Host '== an unfinished entry is unaffected by this guard =='
# It is deleted with its partial data, which is the whole point of rules 2, 2b, 2c
# and 2d. The guard is about losing something already on disk.
Reset
$script:liveTorrents = @(
    [pscustomobject]@{ hash = ('c' * 40); name = 'Some.Show.S03E07.2160p.WEB-DL.h265-GRP'; progress = 0.0; size = 9GB
                      parts = (Get-TitleParts -Name 'Some.Show.S03E07.2160p.WEB-DL.h265-GRP') }
)
Remove-Torrent -T (T -State 'downloading' -Name 'partial' -Progress 0.3) -Knows -Reason 'magnet with nothing to download from'
$partialUnaffected = [bool](@(@($script:posted | Where-Object { $_ -like 'torrents/delete*' })).Count -eq 1)
Check 'an unfinished entry is still deleted as before' ($partialUnaffected)
$script:liveTorrents = @()

Write-Host ''
Write-Host '== a refused torrent is not consumed by the refusal =='
# If the guard marked it gone, a later rule in the same run could not report on
# it and the user would see nothing at all about the torrent.
Reset
Remove-Torrent -T (T) -Reason 'first rule' -AllowErrored
Remove-Torrent -T (T) -Reason 'second rule'
$afterForced = @(@($script:posted | Where-Object { $_ -like 'torrents/delete*' }))
Check 'a normal delete after a forced one is refused' ($afterForced.Count -eq 1)

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