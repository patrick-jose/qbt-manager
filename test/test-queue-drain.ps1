<#
    Exercises Get-QueueDrainVerdict (rule 2c), lifted out of qbt-manager.ps1
    with synthetic torrents and a clock the test controls.

    The rule as the user stated it, in their words:

        "if a torrent is being downloaded on position 18 and the torrents 11,
         12, 13, 14, 15, 16, 17 are unavailable, after 60 minutes delete the
         torrent 11, after that count another 60 minutes to delete the 12 (now 11
         with the removal of the previous 11) if it's unavailable too"

    and then, on the case where position 11 is itself alive:

        "if torrent 11 is being downloaded, delete the hypothetical 12 if it's
         unavailable for 60 minutes and if torrent(s) >=13 is being downloaded"

    Four conditions fall out of those two sentences, and all four are tested
    here:

      1. Only the FIRST magnet behind the window is ever the candidate. The
         rate is one per tolerance no matter how many are dead.
      2. Each candidate gets its own full clock, starting when it becomes the
         candidate. Time served by the previous candidate is never inherited.
      3. A deletion additionally needs a witness: a torrent FURTHER DOWN the
         queue that is actively downloading. This is the safety half, and the
         "if torrent >=13 is downloading" clause of the user's second sentence
         is exactly it.
      4. Priority 0 is out of the queue, not the front of it, so it is neither
         a candidate nor a witness.

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-queue-drain.ps1
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
# lift the rule out of the manager and run it
# ---------------------------------------------------------------------------
$src = [System.IO.File]::ReadAllText((Get-ProjectFile 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)
$s = $src.IndexOf('# rule 2c: the drain')
$e = $src.IndexOf('# orphan reaper: download leftovers that no torrent claims any more')
if ($s -lt 0 -or $e -le $s) { throw 'could not locate Get-QueueDrainVerdict in qbt-manager.ps1' }
Invoke-Expression $src.Substring($s, $e - $s)

$script:fails = 0
function Check {
    param([string]$Label, [bool]$Ok)
    if ($Ok) { "  [PASS] $Label" } else { $script:fails++; "  [FAIL] $Label" }
}

$Limit = [int]$cfg.metadataPriorityRankLimit
$Timeout = [double]$cfg.metadataTimeoutMinutes

$NOW = [datetime]'2026-10-05 09:00:00'

# A magnet: no size, waiting for metadata. Size 0 is what makes it unavailable
# under this rule - the same test rule 2 uses.
function M {
    param(
        [string]$Hash,
        [int]$Priority,
        [string]$State = 'metaDL',
        [int]$Seeds = 0,
        [int]$Leechs = 0,
        [double]$AddedOn = 0
    )
    return [pscustomobject][ordered]@{
        hash       = $Hash
        name       = "Magnet $Hash at queue $Priority"
        priority   = $Priority
        size       = 0
        total_size = 0
        progress   = 0
        state      = $State
        num_seeds  = $Seeds
        num_leechs = $Leechs
        added_on   = $AddedOn
    }
}

# A live download: it has a size, is incomplete, and is not paused, stopped or
# queued. This is the witness shape the rule requires.
function D {
    param(
        [string]$Hash,
        [int]$Priority,
        [double]$Progress = 0.4,
        [string]$State = 'downloading',
        [double]$Size = 1500000000
    )
    return [pscustomobject][ordered]@{
        hash       = $Hash
        name       = "Download $Hash at queue $Priority"
        priority   = $Priority
        size       = [int64]$Size
        total_size = [int64]$Size
        progress   = $Progress
        state      = $State
        num_seeds  = 3
        num_leechs = 1
        added_on   = 0
    }
}

function New-Clock {
    return [pscustomobject]@{ hash = $null; since = $null }
}

# Age the single clock the way the manager would have aged it after earlier
# runs, so the test controls "how long has this candidate been dead" exactly.
function Age {
    param($Clock, [string]$Hash, [double]$Minutes, [datetime]$Now = $NOW)
    $Clock.hash = $Hash
    $Clock.since = $Now.AddMinutes(-$Minutes).ToString('o')
}

function Judge {
    param(
        [object[]]$Torrents,
        [object]$Clock,
        [datetime]$Now = $NOW,
        [double]$Tol = 60,
        [int]$Win = 10
    )
    return @(Get-QueueDrainVerdict -Torrents $Torrents -Now $Now -TimeoutMinutes $Tol -QueueLimit $Win -Drain $Clock)
}

# One row, or $null when there is no candidate.
function Row {
    param($Rows)
    $r = @($Rows)
    if ($r.Count -eq 0) { return $null }
    return $r[0]
}

Write-Host ''
Write-Host '== the shipped config =='
Check 'the drain is enabled'                ($cfg.queueDrainEnabled -eq $true)
Check 'the window it sits behind is 10'     ($Limit -eq 10)
Check 'so the drain starts at position 11'  (($Limit + 1) -eq 11)

Write-Host ''
Write-Host '== the user''s first example: 11-17 dead, 18 downloading =='
# Positions 11..17 unavailable, 18 downloading. After 60 minutes, delete 11.
$q = @(M 'm11' 11; M 'm12' 12; M 'm13' 13; M 'm14' 14; M 'm15' 15; M 'm16' 16; M 'm17' 17; D 'd18' 18)

$c = New-Clock; Age $c 'm11' 59
$r = Row (Judge $q $c)
Check 'the candidate is position 11, not some later magnet' ($r.Hash -eq 'm11')
Check 'under the tolerance nothing is deleted'            (-not $r.WillDelete)
Check 'the witness at 18 is found'                        ($r.HasWitness -and $r.WitnessPos -eq 18)

$c = New-Clock; Age $c 'm11' 60
$r = Row (Judge $q $c)
Check 'at exactly 60 minutes position 11 is deleted'      ($r.WillDelete)
Check 'and the log names the witness position'            ($r.Reason -match 'position 18 is downloading')
$one = @(Judge $q $c)
Check 'exactly one row comes back - one per hour'         ($one.Count -eq 1)
Check 'and it is m11'                                      ($one[0].Hash -eq 'm11')

$c = New-Clock; Age $c 'm11' 61
$one = @(Judge $q $c)
Check '61 minutes is still just the one deletion'         ($one.Count -eq 1 -and $one[0].WillDelete -and $one[0].Hash -eq 'm11')
# 12..17 are all dead and all witnessed, and none of them is judged. This is the
# rate limit: an hour passes, one torrent goes, and the rest keep waiting.
$c = New-Clock; Age $c 'm12' 61
$one = @(Judge @($q[1..6] + $q[7]) $c)
Check 'removing m11 makes m12 the candidate, and only it' ($one.Count -eq 1 -and $one[0].Hash -eq 'm12')
$c = New-Clock; Age $c 'm13' 61
Check 'a clock on m13 cannot promote it past m12'         ((@(Judge @($q[1..6] + $q[7]) $c)[0].Hash) -eq 'm12')

Write-Host ''
Write-Host '== the user''s second example: 11 alive, 12 dead, 13 downloading =='
$q2 = @(D 'd11' 11; M 'm12' 12; D 'd13' 13)
$c = New-Clock; Age $c 'm12' 60
$r = Row (Judge $q2 $c)
Check 'with 11 alive the candidate is 12'                 ($r.Hash -eq 'm12')
Check '13 downloading witnesses it'                       ($r.HasWitness -and $r.WitnessPos -eq 13)
Check '12 is deleted after its own 60 minutes'            ($r.WillDelete)

$c = New-Clock; Age $c 'm12' 59
Check 'at 59 minutes 12 is still kept'                    (-not (Row (Judge $q2 $c)).WillDelete)

Write-Host ''
Write-Host '== the witness is the safety half =='
# No witness: nothing past the magnet is being worked on. Past tolerance, held.
$qNoW = @(M 'm11' 11; M 'm12' 12; D 'd9' 9)
$c = New-Clock; Age $c 'm11' 600
$r = Row (Judge $qNoW $c)
Check 'a dead client does not get the queue deleted'      (-not $r.WillDelete)
Check 'it reports itself past tolerance'                  ($r.TimedOut)
Check 'and says no witness was found'                     ($r.Reason -match 'nothing further down')

# A torrent ABOVE the candidate is not a witness. This is what makes the witness
# a proof rather than a coincidence: position 9 being busy would be just as
# likely on a stalled client as on a healthy one.
Check 'a download above the candidate does not witness it' (-not $r.HasWitness)

# Position 0 is out of the queue, so it cannot witness either.
$qP0 = @(M 'm11' 11; (D 'd0' 0))
$c = New-Clock; Age $c 'm11' 600
$r = Row (Judge $qP0 $c)
Check 'a priority-0 torrent is not a witness'             (-not $r.HasWitness)
Check 'so a magnet is held rather than deleted'            (-not $r.WillDelete)

# The candidate cannot witness itself.
$c = New-Clock; Age $c 'm11' 600
$r = Row (Judge @(M 'm11' 11) $c)
Check 'the candidate cannot witness itself'                (-not $r.HasWitness)

Write-Host ''
Write-Host '== what counts as actively downloading =='
$cases = @(
    @{ Label = 'downloading';      State = 'downloading';      Want = $true  }
    @{ Label = 'stalledDL';        State = 'stalledDL';        Want = $true  }
    @{ Label = 'allocating';       State = 'allocating';       Want = $true  }
    @{ Label = 'forcedDL';         State = 'forcedDL';         Want = $true  }
    @{ Label = 'queuedDL';         State = 'queuedDL';         Want = $false }
    @{ Label = 'pausedDL';         State = 'pausedDL';         Want = $false }
    @{ Label = 'stoppedDL';        State = 'stoppedDL';        Want = $false }
    @{ Label = 'uploading';        State = 'uploading';        Want = $false }
    @{ Label = 'stalledUP';        State = 'stalledUP';        Want = $false }
    @{ Label = 'queuedUP';         State = 'queuedUP';         Want = $false }
    @{ Label = 'error';            State = 'error';            Want = $false }
    @{ Label = 'missingFiles';     State = 'missingFiles';     Want = $false }
    @{ Label = 'checkingDL';       State = 'checkingDL';       Want = $false }
    @{ Label = 'moving';           State = 'moving';           Want = $false }
    @{ Label = 'unknown';          State = 'unknown';          Want = $false }
)
foreach ($case in $cases) {
    $qq = @(M 'm11' 11; D 'w20' 20 -State $case.State)
    $cc = New-Clock; Age $cc 'm11' 60
    $rr = Row (Judge $qq $cc)
    # The verdict is computed first: -f binds tighter than the comma here, so
    # passing this expression straight into Check would hand it ONE argument and
    # the check would fail no matter what the rule did.
    $want = ($rr.HasWitness -eq $case.Want)
    Check ("state {0} counts as a witness: {1}" -f $case.Label, $case.Want) $want
}
# A finished torrent is not "being downloaded", however healthy its state looks.
$qq = @(M 'm11' 11; D 'w20' 20 -Progress 1.0 -State 'stalledUP')
$cc = New-Clock; Age $cc 'm11' 60
Check 'a completed torrent is not a witness'                (-not (Row (Judge $qq $cc)).HasWitness)
# A magnet is not a witness, which is the whole point of the size test.
$qq = @(M 'm11' 11; M 'm20' 20)
$cc = New-Clock; Age $cc 'm11' 60
Check 'another magnet further down is not a witness'        (-not (Row (Judge $qq $cc)).HasWitness)

Write-Host ''
Write-Host '== each candidate gets its own clock =='
# The user's "after that count another 60 minutes": m11 is deleted, m12 becomes
# position 11, and it starts from zero rather than inheriting m11's time.
$c = New-Clock
$q2 = @(M 'm11' 11; M 'm12' 12; D 'd18' 18)
# A brand-new clock cannot delete anything, even when asked to judge a moment an
# hour later: the rule has never seen m11 before, so it has not served any time
# yet. Two passes are what a real run does - one to start the clock, one to act.
$seed = Row (Judge $q2 $c)
Check 'the first sighting only starts the clock'            (-not $seed.WillDelete -and $seed.Minutes -eq 0)
$first = Row (Judge $q2 $c ($NOW.AddMinutes(60)))
Check 'an hour later m11 is deleted'                        ($first.WillDelete -and $first.Hash -eq 'm11')

# m11 is gone, so m12 slides to 11. The clock the manager persisted points at
# m11, which is a different torrent, so m12 starts fresh.
$q3 = @(M 'm12' 11; D 'd18' 18)
$second = Row (Judge $q3 $c ($NOW.AddMinutes(61)))
Check 'm12 becomes the candidate'                           ($second.Hash -eq 'm12')
Check 'and its 60 minutes start now, not at zero'           ($second.Minutes -eq 0)
Check ('so it is not deleted on arrival ({0:N0} min)' -f $second.Minutes) (-not $second.WillDelete)

$third = Row (Judge $q3 $c ($NOW.AddMinutes(121)))
Check 'a minute later it still has 60 to serve'             ($third.Minutes -eq 60)
Check 'so it is deleted 60 min after taking the front'      ($third.WillDelete)

Write-Host ''
Write-Host '== the clock follows the candidate =='
# If the front magnet changes for any reason, the new one starts over.
$c = New-Clock; Age $c 'm11' 600
$q4 = @(M 'm12' 11; D 'd18' 18)
$r = Row (Judge $q4 $c)
Check 'a different front magnet does not inherit the clock' ($r.Minutes -eq 0)
Check 'so 600 minutes on another torrent deletes nothing'   (-not $r.WillDelete)
Check 'and the clock is repointed at the new candidate'     ($c.hash -eq 'm12')

# The clock is not reset while the same candidate is still in front: it keeps
# running so that time already served counts when a witness appears.
$c = New-Clock; Age $c 'm11' 600
$noWitness = Row (Judge @(M 'm11' 11) $c)
Check 'the clock keeps running for the same candidate'      ($noWitness.Minutes -eq 600)
Check 'held rather than deleted while unwitnessed'          (-not $noWitness.WillDelete -and $noWitness.TimedOut)
# The 60 minutes measure how long the magnet has been dead, not how long it has
# waited for a witness - so the moment a witness appears the time already served
# counts and it is deleted on that same run.
$withWitness = Row (Judge @(M 'm11' 11; D 'w40' 40) $c)
Check 'and the moment a witness appears it is deleted'      ($withWitness.WillDelete)
Check 'without the dead time being served twice'            ($withWitness.Minutes -eq 600)
Check 'and the clock has been repointed'                    ($c.hash -eq 'm11')

Write-Host ''
Write-Host '== no candidate behind the window =='
$c = New-Clock; Age $c 'm11' 600
Check 'a healthy queue drains nothing'                      ($null -eq (Row (Judge @(D 'a' 1; D 'b' 2; D 'c' 3) $c)))
Check 'and the stale clock is forgotten'                    ($null -eq $c.hash)
# A magnet at position 2 is the window's business, so the drain must find nothing
# behind it at all - not fall back to it.
$c = New-Clock; Age $c 'm2' 600
Check 'a magnet inside the window is never the candidate'   ($null -eq (Row (Judge @(D 'a' 1; M 'm2' 2; D 'c' 3) $c)))
Check 'and its stale clock is not what is consulted'        ($c.hash -eq $null)
$edge = @(M 'in1' 10; M 'in2' 9; D 'w11' 11)
Check 'position 10 is still the window''s, not the drain''s' ($null -eq (Row (Judge $edge $c)))
$justOver = @(M 'm11' 11)
Check 'position 11 is exactly where the drain starts'       ((Row (Judge $justOver $c)).Hash -eq 'm11')

Write-Host ''
Write-Host '== the switch and the window =='
$c = New-Clock; Age $c 'm11' 600
Check 'no window means nothing to drain from'               (@(Get-QueueDrainVerdict -Torrents @(M 'm11' 11) -Now $NOW -TimeoutMinutes 60 -QueueLimit 0 -Drain $c).Count -eq 0)
$c2 = New-Clock; Age $c2 'm11' 600
Check 'a window of 10 makes position 11 the candidate'      ((Row (Judge @(M 'm11' 11) $c2 $NOW 60 10)).Hash -eq 'm11')

Write-Host ''
Write-Host '== skipping what an earlier rule removed =='
$c = New-Clock; Age $c 'm11' 600
$q5 = @(M 'm11' 11; M 'm12' 12; D 'd18' 18)
$r = Row (Get-QueueDrainVerdict -Torrents $q5 -Now $NOW -TimeoutMinutes 60 -QueueLimit 10 `
                                -Drain $c -Skip @{ m11 = $true })
Check 'a magnet deleted earlier this run is skipped'         ($r.Hash -eq 'm12')
Check 'and the next one starts its own clock'               ($r.Minutes -eq 0)

Write-Host ''
Write-Host '== priority 0 is out of the queue, not the front =='
$c = New-Clock
Check 'a priority-0 magnet is never the candidate'          ($null -eq (Row (Judge @(M 'm0' 0; D 'w11' 11) $c)))
$c = New-Clock
Check 'the drain looks past priority 0 to real positions'   ((Row (Judge @(M 'm0' 0; M 'm11' 11) $c)).Hash -eq 'm11')

Write-Host ''
Write-Host '== a magnet that has not had its turn is not a candidate =='
# The candidate test used to accept any torrent with size 0, which includes one
# sitting in line that qBittorrent has never given a slot to. Measured on a live
# queue:
#
#   pos 11-20   size 8.9 GB, 8.7 GB ...   served: working or stalled
#   pos 21      size 0, state queuedDL     never had a turn
#   pos 22-30   size 0, state queuedDL     never had a turn
#
# Position 21 was the first magnet behind the window, so its clock started on
# arrival and 30 minutes later it would have been deleted for failing to fetch
# metadata - having never been asked to fetch any.
#
# This is rule 2's own distinction, inherited: "a magnet at position 150 has never
# been handed a peer connection, so it has not tried anything, and deleting it for
# being unavailable is really deleting it for not having been started yet."
#
# Only metaDL means "fetching metadata right now". A magnet queued behind the
# window is queuedDL, and one whose metadata resolved has a size.

$c = New-Clock; Age $c 'q21' 600
$queuedOnly = @(M 'q21' 21 'queuedDL'; D 'w30' 30)
$none = Row (Judge $queuedOnly $c)
Check 'a queuedDL magnet behind the window is NOT a candidate' ($null -eq $none)

$c = New-Clock; Age $c 'q21' 600
$stillNone = Row (Judge @(M 'q21' 21 'queuedDL'; D 'w30' 30) $c)
Check 'not even after a long wait'                          ($null -eq $stillNone)

$c = New-Clock; Age $c 'q21' 600
$both = @(M 'q21' 21 'queuedDL'; M 'm22' 22 'metaDL'; D 'w30' 30)
$past = Row (Judge $both $c)
Check 'the drain reaches PAST it to one that is trying'     ($null -ne $past -and $past.Hash -eq 'm22')

$c = New-Clock; Age $c 'm11' 600
$still = Row (Judge @(M 'm11' 11 'metaDL'; D 'w30' 30) $c)
Check 'a metaDL magnet is still the candidate'              ($null -ne $still -and $still.Hash -eq 'm11')

# Read off the source, so the state cannot be loosened back to "any torrent with
# no size" without this failing.
$drainSrc = ''
$ds = $src.IndexOf('function Get-QueueDrainVerdict')
$de = $src.IndexOf('function Resolve-ShowAlias')
if ($ds -ge 0 -and $de -gt $ds) { $drainSrc = $src.Substring($ds, $de - $ds) }
Check 'the candidate test names metaDL explicitly'         ($drainSrc -cmatch "if \(\`$t\.state -ne 'metaDL'\) \{ continue \}")
Check 'and does not accept a bare size 0'                 (-not ($drainSrc -cmatch '\$noSize = \(\(\$t\.size -eq 0\)'))

Write-Host ''

Write-Host ''
Write-Host '== NO copy anywhere may accept a bare size 0 =='
# This is the second time a duplicated rule has drifted, and the same shape both
# times: the logic lives in more than one place, one copy is fixed, and the other
# keeps saying the old thing.
#
#   rule 4 tolerance - the manager inline, and Get-DedupVerdicts in status.ps1.
#                      The manager was fixed; the preview would have gone on
#                      reporting an episode as clean an hour before the run
#                      deleted it.
#   candidate gate   - this rule and rule 2, in BOTH files. Four gates between
#                      them, and fixing the drain alone left status.ps1 still
#                      counting down against position 21 - the exact torrent the
#                      user had already said must not have a timer.
#
# Nothing keeps these in step except a check that reads every gate, so this reads
# both files whole and asserts the permissive form is gone from all of them. A new
# copy added later with the old logic fails here instead of silently resurrecting a
# timer against torrents that were never given a turn.

$mgrSrc = [System.IO.File]::ReadAllText((Get-ProjectFile 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)
$preSrc = [System.IO.File]::ReadAllText((Get-ProjectFile 'status.ps1'), [System.Text.Encoding]::UTF8)

$gates = @(
    @{ n = 'manager  rule 2 window';   s = $mgrSrc; p = '\$noMeta = \(\$t\.state -eq ''metaDL''\)' }
    @{ n = 'manager  rule 2 delete';   s = $mgrSrc; p = '\$noSize = \(\$t\.state -eq ''metaDL''\)' }
    @{ n = 'manager  rule 2c drain';   s = $mgrSrc; p = "if \(\`$t\.state -ne 'metaDL'\) \{ continue \}" }
    @{ n = 'preview  rule 2 window';   s = $preSrc; p = "\`$noMeta = \(\(Get-Prop \`$t 'state'\) -eq 'metaDL'\)" }
    @{ n = 'preview  rule 2c drain';   s = $preSrc; p = "if \(\`$t\.state -ne 'metaDL'\) \{ continue \}" }
)
foreach ($g in $gates) {
    Check ("the '{0}' gate names metaDL" -f $g.n) ($g.s -cmatch $g.p)
}

# The permissive form, gone from both files outright rather than gate by gate, so
# a sixth gate added with the old logic fails here too.
Check 'no gate anywhere still accepts a bare size 0' (
    (-not ($mgrSrc -cmatch '\(\(\$t\.size -eq 0\) -or \(')) -and
    (-not ($preSrc -cmatch "\(\(Get-Prop \`$t 'size' 0\) -eq 0\) -or")))

# The count is pinned so that DELETING a gate fails here. Deleting one would
# silently disable a rule rather than break it, and that is the harder failure to
# notice: no torrent would ever be judged and nothing would say why.
$gateCount = ([regex]::Matches($mgrSrc, '(?m)^\s*\$(noMeta|noSize) = .*metaDL')).Count +
             ([regex]::Matches($mgrSrc, "(?m)^\s*if \(\`$t\.state -ne 'metaDL'\) \{ continue \}")).Count +
             ([regex]::Matches($preSrc, '(?m)^\s*\$noMeta = .*metaDL')).Count +
             ([regex]::Matches($preSrc, "(?m)^\s*if \(\`$t\.state -ne 'metaDL'\) \{ continue \}")).Count
Check 'all five gates are still there' ($gateCount -eq 5)
if ($script:fails -eq 0) {
    Write-Host "all queue-drain tests passed"
}
else {
    Write-Host ("{0} queue-drain test(s) FAILED" -f $script:fails)
    exit 1
}