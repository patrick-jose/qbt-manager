<#
    Exercises rule 2d, the stalled-client cleanup: Get-StallVerdict and
    Test-InternetReachable.

    THE CASE. Measured live on 2026-10-05: 206 torrents, 195 of them magnets,
    dl_info_speed 0, up_info_speed 1,4 MB/s, and queue positions 4 through 20 all
    metaDL at dlspeed 0. The client was plainly capable of traffic and was pulling
    nothing down, so every one of those magnets was unavailable and the client had
    already said so itself. Rule 2 could not act on that: it asks how long a magnet
    has been TRYING, and while the client is idle there is no evidence of trying,
    only of waiting.

    So this asks a different question - is anything happening at all - and only
    deletes when the answer is no AND the internet is verifiably up. That second
    half is the reason the rule is safe: without it, a dropped home connection
    produces exactly the same picture and the queue would be deleted for the
    network being down.

    Two things measured here rather than assumed, both of which had been wrong
    first:

      - curl -f was wrong. It fails on an HTTP error status, and the configured
        endpoint answers 404 to a HEAD request, so -f reported the internet as
        down while it was fine. The rule would have been permanently dead and
        quietly so.
      - A rate limit is not a stall. dl_rate_limit above zero is the user capping
        the client, and a capped client pulling nothing is obeying, not stuck.

    The rate reader and the internet probe are injected as scriptblocks, so the
    rule is tested against a controlled 0-or-not reading with no API call and no
    real 60-second wait. The one live call in this file is the final check that the
    configured probe really does answer True, because a probe that always returns
    False would pass every other test here and block the rule forever.

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-stall-cleanup.ps1
#>

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# The project root, found from this file's own location rather than written out.
# This suite used to carry a hardcoded absolute path, which meant it could only
# ever run on the machine it was written on - no way to publish a test.
if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = Split-Path -Parent $PSScriptRoot
$src = [System.IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)

# Both functions are self-contained apart from Invoke-ApiGet, which the rate-limit
# case stubs. Sliced by their own markers so this runs without the API.
$fs = $src.IndexOf('function Test-InternetReachable {')
$fe = $src.IndexOf('# Is the whole client stalled')
$g1 = $src.IndexOf('function Get-StallVerdict {')
$g2 = $src.IndexOf('function Test-ActivelyDownloading {')
if ($fs -lt 0 -or $fe -le $fs) { throw 'cannot find Test-InternetReachable' }
if ($g1 -lt 0 -or $g2 -le $g1) { throw 'cannot find Get-StallVerdict' }
Invoke-Expression $src.Substring($fs, $fe - $fs)
Invoke-Expression $src.Substring($g1, $g2 - $g1)

$NOW = [datetime]'2026-10-05 18:00:00'
$fails = 0
function Check { param([string]$L, [bool]$Ok) if ($Ok) { "  [PASS] $L" } else { $script:f = $true; "  [FAIL] $L" } }

function M {
    param([string]$Hash, [int]$Priority, [double]$Size = 0, [string]$State = 'metaDL', [double]$AddedOn = 0, [double]$Speed = 0)
    [pscustomobject]@{
        hash=$Hash; name="T-$Hash p$Priority"; priority=$Priority
        size=[int64]$Size; total_size=[int64]$Size; state=$State
        dlspeed=$Speed; num_seeds=0; num_leechs=0; added_on=$AddedOn
    }
}

$script:rate = [pscustomobject]@{ Speed = 0; Connection = 'connected'; DlRateLimit = 0 }
$script:net = $true

function Verdict {
    param($Stall, [object[]]$Tors, [double]$Confirm = 60, [int]$Max = 10, [int]$Wait = 0, [int]$Limit = 10)
    @(Get-StallVerdict -Torrents $Tors -Now $NOW -ConfirmSeconds $Confirm -MaxWaitSeconds $Wait `
        -QueueLimit $Limit -MaxDeletions $Max -Stall $Stall -Skip @{} `
        -RateReader { $script:rate } -InternetProbe { $script:net })[0]
}
function New-Clock { param([double]$AgeMinutes = 5) [pscustomobject]@{ since = $NOW.AddMinutes(-$AgeMinutes).ToString('o') } }

$mag = @(); foreach ($i in 1..12) { $mag += M ("h$i") $i }

Write-Host ''
Write-Host '== the case that prompted the rule =='
$script:rate = [pscustomobject]@{ Speed = 0; Connection = 'connected'; DlRateLimit = 0 }
$script:net = $true
$v = Verdict -Stall (New-Clock) -Tors $mag
Check 'a proven stall with the internet up deletes'   ($v.Action -eq 'delete')
Check 'and it names the seconds it was zero'          ($v.Seconds -ge 300)
Check 'and it says stalled, not slow'                 ($v.Reason -match 'stalled, not slow')

Write-Host ''
Write-Host '== the internet check is what makes it safe =='
$script:net = $false
$v = Verdict -Stall (New-Clock) -Tors $mag
Check 'the internet being down BLOCKS the deletion'   ($v.Action -eq 'hold')
Check 'and says so'                                   ($v.Reason -match 'could not be reached')
Check 'and picks nothing'                             (@($v.Torrents).Count -eq 0)

# Fail-closed on an inconclusive probe: a throwing probe must not read as "up".
$script:net = $false
$throwing = @(Get-StallVerdict -Torrents $mag -Now $NOW -ConfirmSeconds 60 -MaxWaitSeconds 0 `
    -QueueLimit 10 -MaxDeletions 10 -Stall (New-Clock) -Skip @{} `
    -RateReader { $script:rate } `
    -InternetProbe { throw 'probe exploded' })[0]
Check 'a probe that THROWS blocks the deletion'       ($throwing.Action -eq 'hold')

Write-Host ''
Write-Host '== any movement at all means there is no stall =='
$script:net = $true
$script:rate = [pscustomobject]@{ Speed = 1; Connection = 'connected'; DlRateLimit = 0 }
Check '1 byte/s is not a stall'                       ($null -eq (Verdict -Stall (New-Clock) -Tors $mag))
$script:rate = [pscustomobject]@{ Speed = 50000; Connection = 'connected'; DlRateLimit = 0 }
Check '50 kB/s is not a stall'                        ($null -eq (Verdict -Stall (New-Clock) -Tors $mag))
$script:rate = [pscustomobject]@{ Speed = 0; Connection = 'connected'; DlRateLimit = 0 }

Write-Host ''
Write-Host '== a rate limit is the user''s choice, not a fault =='
$limited = @()
$limited += Get-StallVerdict -Torrents $mag -Now $NOW -ConfirmSeconds 60 -MaxWaitSeconds 0 `
    -QueueLimit 10 -MaxDeletions 10 -Stall (New-Clock) -Skip @{} `
    -RateReader { [pscustomobject]@{ Speed = 0; Connection = 'connected'; DlRateLimit = 524288 } } `
    -InternetProbe { $true }
Check 'a non-zero download limit blocks the deletion'  ($limited[0].Action -eq 'hold')
Check 'and names the limit'                            ($limited[0].Reason -match 'obeying it')

Write-Host ''
Write-Host '== the window, and never past it =='
# 8 magnets in the window, one at 11 (past it), one resolved at 2.
$widened = @()
foreach ($i in 1..8) { $widened += M ("w$i") $i }
$widened += M 'past' 11
$widened += M 'done' 2 5000000000 'stalledUP'
$v = Verdict -Stall (New-Clock) -Tors $widened
$pos = @($v.Torrents | ForEach-Object { $_.priority })
Check 'position 11 is NOT picked'                     ($pos -notcontains 11)
Check 'a resolved torrent is NOT picked'              ((@($v.Torrents) | Where-Object { $_.hash -eq 'done' }).Count -eq 0)
Check 'everything picked is a magnet'                 ((@($v.Torrents) | Where-Object { $_.size -ne 0 }).Count -eq 0)
Check 'picked in queue order'                         ((($pos | Sort-Object) -join ',') -eq ($pos -join ','))

# Priority 0 is out of the queue, never the front of it.
$zero = @(); $zero += M 'z0' 0; foreach ($i in 1..3) { $zero += M ("z$i") $i }
$v = Verdict -Stall (New-Clock) -Tors $zero
Check 'priority 0 is never picked'                    ((@($v.Torrents) | Where-Object { $_.hash -eq 'z0' }).Count -eq 0)

Write-Host ''
Write-Host '== the cap is real and is not the window size by accident =='
$v = Verdict -Stall (New-Clock) -Tors $mag -Max 10
Check '12 available, cap 10 -> exactly 10'            (@($v.Torrents).Count -eq 10)
$v = Verdict -Stall (New-Clock) -Tors $mag -Max 3
Check 'cap 3 -> exactly 3'                            (@($v.Torrents).Count -eq 3)
Check 'and the reason reports the real count'          ($v.Reason -match '3 magnet\(s\)')

Write-Host ''
Write-Host '== the clock =='
# Proven in a previous run: no waiting, straight to delete.
$old = [pscustomobject]@{ since = $NOW.AddMinutes(-5).ToString('o') }
$v = Verdict -Stall $old -Tors $mag -Max 3
Check 'a clock from a previous run deletes at once'    ($v.Action -eq 'delete')
Check 'with the time already served counted'          ($v.Seconds -ge 300)

# Too young and no wait allowed: held, clock KEPT so the next run resumes.
$new = [pscustomobject]@{ since = $NOW.ToString('o') }
$v = Verdict -Stall $new -Tors $mag -Wait 0
Check 'a fresh clock with no wait is held'             ($v.Action -eq 'hold')
Check 'and says it is under the threshold'            ($v.Reason -match 'under the 60s threshold')
Check 'and the clock is kept for the next run'        ($null -ne $new.since)

# Movement clears the clock, so a stall never inherits an old one.
$stale = [pscustomobject]@{ since = $NOW.AddHours(-9).ToString('o') }
$script:rate = [pscustomobject]@{ Speed = 999; Connection = 'connected'; DlRateLimit = 0 }
$null = Verdict -Stall $stale -Tors $mag
Check 'a working client CLEARS a stale stall clock'    ($null -eq $stale.since)

# Proven stall also clears it, so the next stall is measured fresh.
$stale2 = [pscustomobject]@{ since = $NOW.AddHours(-9).ToString('o') }
$script:rate = [pscustomobject]@{ Speed = 0; Connection = 'connected'; DlRateLimit = 0 }
$null = Verdict -Stall $stale2 -Tors $mag -Max 2
Check 'and a proven stall clears it too'               ($null -eq $stale2.since)

Write-Host ''
Write-Host '== nothing to delete is not a reason to fail =='
$resolved = @(); foreach ($i in 1..5) { $resolved += M ("r$i") $i 5000000000 'stalledUP' }
$script:net = $true
$v = Verdict -Stall (New-Clock) -Tors $resolved
Check 'a stall with no magnets to remove holds'        ($v.Action -eq 'hold')
Check 'and explains why'                               ($v.Reason -match 'no unavailable magnet')

# An unreadable rate cannot establish a stall.
$noRead = @(Get-StallVerdict -Torrents $mag -Now $NOW -ConfirmSeconds 60 -MaxWaitSeconds 0 `
    -QueueLimit 10 -MaxDeletions 10 -Stall (New-Clock) -Skip @{} `
    -RateReader { $null } -InternetProbe { $true })[0]
Check 'an unreadable transfer rate blocks everything'  ($noRead.Action -eq 'unknown')

Write-Host ''
Write-Host '== skipped torrents are not touched twice =='
$skip = @{}; $skip['h1'] = $true
$v = @(Get-StallVerdict -Torrents $mag -Now $NOW -ConfirmSeconds 60 -MaxWaitSeconds 0 `
    -QueueLimit 10 -MaxDeletions 10 -Stall (New-Clock) -Skip $skip `
    -RateReader { $script:rate } -InternetProbe { $true })[0]
Check 'a hash in Skip is left alone'                   ((@($v.Torrents) | Where-Object { $_.hash -eq 'h1' }).Count -eq 0)

Write-Host ''
Write-Host '== the window disabled means nothing is in scope =='
$off = [pscustomobject]@{ since = $NOW.ToString('o') }
$v = Verdict -Stall $off -Tors $mag -Wait 0 -Limit 0
Check 'with no window, no magnet qualifies'            (@($v.Torrents).Count -eq 0)

Write-Host ''
Write-Host '== the shipped config =='
$cfg = [System.IO.File]::ReadAllText((Join-Path $root 'config.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
Check 'stallCleanupEnabled is on'                      ($cfg.stallCleanupEnabled -eq $true)
Check 'the confirm window is 60s'                      ([double]$cfg.stallConfirmSeconds -eq 60)
Check 'the wait ceiling is above the window'           ([double]$cfg.stallMaxWaitSeconds -ge [double]$cfg.stallConfirmSeconds)
Check 'the cap is 10'                                  ([int]$cfg.stallMaxDeletions -eq 10)
Check 'a probe url is configured'                      (-not [string]::IsNullOrWhiteSpace([string]$cfg.stallInternetProbeUrl))

Write-Host ''
Write-Host '== the probe really does answer True right now =='
$probeBody = $src.Substring($src.IndexOf('function Test-InternetReachable {'), $src.IndexOf('# Is the whole client stalled') - $src.IndexOf('function Test-InternetReachable {'))
Invoke-Expression $probeBody
Check 'the configured URL is reachable from here'      (Test-InternetReachable -Url ([string]$cfg.stallInternetProbeUrl) -TimeoutSeconds 8)

Write-Host ''
if ($script:f) { Write-Host 'FAILURES' -ForegroundColor Red; exit 1 }
Write-Host 'all stall-cleanup tests passed'