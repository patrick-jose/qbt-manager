$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $root 'watch-manager.ps1'))
$start = $source.IndexOf('function Convert-WatchQueueJson'); $end = $source.IndexOf('# runtime', $start)
Invoke-Expression $source.Substring($start, $end - $start)
$script:fails = 0
function Check { param($Name,$Ok) if ($Ok) { "[PASS] $Name" } else { $script:fails++; "[FAIL] $Name" } }
function Torrent { param($Hash = 'a') [pscustomobject]@{ hash = $Hash; name = 'Example.Show.S01E01'; size = 100; total_size = 100; progress = 0.5; state = 'downloading'; priority = 1; category = 'Series'; save_path = 'C:\Downloads'; content_path = 'C:\Downloads\release'; downloaded = 50; dlspeed = 10 } }
$a = Torrent; $b = Torrent 'b'
$json = ConvertTo-Json -InputObject @($a,$b) -Depth 4
$parsed = @(Convert-WatchQueueJson -Text $json)
Check 'real JSON queue enumerates rows rather than returning a nested array' ($parsed.Count -eq 2 -and (Get-QueueFingerprint $parsed) -ceq (Get-QueueFingerprint @($a,$b)))
Check 'empty JSON queue remains empty' (@(Convert-WatchQueueJson -Text '[]').Count -eq 0)
$refused = $false
try { Convert-WatchQueueJson -Text '<html>Login required</html>' } catch { $refused = $true }
Check 'non-JSON API response is rejected safely' $refused
$original = Get-QueueFingerprint @($a)
$a.progress = 0.9; $a.downloaded = 90; $a.dlspeed = 20
Check 'ordinary transfer updates do not trigger filesystem scans' ((Get-QueueFingerprint @($a)) -ceq $original)
$a.progress = 1
Check 'completion triggers immediate comparison and settle evaluation' ((Get-QueueFingerprint @($a)) -cne $original)
Check 'torrent order does not produce false changes' ((Get-QueueFingerprint @($a,$b)) -ceq (Get-QueueFingerprint @($b,$a)))
Check 'adding or removing a related alternative triggers evaluation' ((Get-QueueFingerprint @($a,$b)) -cne (Get-QueueFingerprint @($a)))
foreach ($property in @('state','size','priority','category','save_path','name')) {
    $t = Torrent; $before = Get-QueueFingerprint @($t)
    if ($property -in @('size','priority')) { $t.$property = 123 } else { $t.$property = 'changed' }
    Check "$property changes trigger evaluation" ((Get-QueueFingerprint @($t)) -cne $before)
}
$now = [datetime]'2026-01-01T12:00:00'
function Decision { param($Age,$FullAge,$Pending = $false,$Previous = 'same') Get-WatchDecision -Fingerprint 'same' -Previous $Previous -Now $now -LastPass $now.AddSeconds(-$Age) -LastFull $now.AddSeconds(-$FullAge) -Pending $Pending -TimerSeconds 60 -PendingSeconds 30 -MaintenanceSeconds 900 }
Check 'unchanged queue stays idle between checks' ((Decision 5 5) -eq 'Wait')
Check 'timer rules are evaluated without broad scans every minute' ((Decision 60 60) -eq 'Quick')
Check 'pending locked moves receive bounded retries' ((Decision 30 30 $true) -eq 'Quick')
Check 'pending moves are not retried on every five-second poll' ((Decision 5 5 $true) -eq 'Wait')
Check 'maintenance scans run even without queue changes' ((Decision 900 900) -eq 'Full')
Check 'queue changes override idle timers' ((Decision 1 1 $false 'old') -eq 'Full')

# Deterministic production loop with injected process/API/clock callbacks.
$script:tick = 0; $script:passes = @(); $script:reads = 0; $script:reports = 0
$script:epoch = $now
try { Invoke-QueueWatch -Watchdog $true -PollSeconds 5 -TimerSeconds 60 -PendingSeconds 30 -MaintenanceSeconds 900 `
    -Running { $script:tick -in @(1,2,4) } `
    -ReadQueue { $script:reads++; @(Torrent) } `
    -RunPass { param($Kind) $script:passes += $Kind; 0 } `
    -HasPending { $false } -Clock { $script:epoch.AddSeconds($script:tick * 5) } `
    -Sleep { param($Seconds) $script:tick++; if ($script:tick -gt 4) { throw 'test finished' } } `
    -Report { param($Message) $script:reports++ }
} catch { if ($_.Exception.Message -ne 'test finished') { throw } }
Check 'watchdog makes no API calls while qBittorrent is closed' ($script:reads -eq 3)
Check 'watchdog runs on launch and again on relaunch, not idle polls' ($script:passes.Count -eq 2 -and $script:passes[0] -eq 'Full' -and $script:passes[1] -eq 'Full')
$script:reads = 0
Invoke-QueueWatch -Watchdog $false -PollSeconds 5 -TimerSeconds 60 -PendingSeconds 30 -MaintenanceSeconds 900 `
    -Running { $false } -ReadQueue { $script:reads++; throw 'unexpected read' } `
    -RunPass { throw 'unexpected pass' } -HasPending { $false } -Clock { $now } `
    -Sleep { throw 'unexpected sleep' } -Report { throw 'unexpected report' }
Check 'companion exits immediately when qBittorrent is closed' ($script:reads -eq 0)
$script:closed = $false; $script:passFinished = $false; $script:reads = 0
Invoke-QueueWatch -Watchdog $false -PollSeconds 5 -TimerSeconds 60 -PendingSeconds 30 -MaintenanceSeconds 900 `
    -Running { -not $script:closed } -ReadQueue { $script:reads++; @(Torrent) } `
    -RunPass { param($Kind) $script:closed = $true; $script:passFinished = $true; 0 } `
    -HasPending { $false } -Clock { $now } -Sleep { param($Seconds) } -Report { param($Message) }
Check 'closing qBittorrent ends companion after active pass finishes safely' ($script:passFinished -and $script:reads -eq 1)
Invoke-QueueWatch -Watchdog $true -PollSeconds 5 -TimerSeconds 60 -PendingSeconds 30 -MaintenanceSeconds 900 `
    -Running { throw 'unexpected process check' } -ReadQueue { throw 'unexpected API call' } `
    -RunPass { throw 'unexpected manager pass' } -HasPending { $false } -Clock { $now } `
    -Sleep { throw 'unexpected sleep' } -Report { param($Message) } -ShouldStop { $true }
Check 'graceful stop request exits without starting another pass' $true

$script:tick = 0; $script:passes = @(); $script:reports = 0; $script:sleeps = @()
try { Invoke-QueueWatch -Watchdog $false -PollSeconds 5 -TimerSeconds 60 -PendingSeconds 30 -MaintenanceSeconds 900 `
    -Running { $script:tick -lt 3 } -ReadQueue { if ($script:tick -eq 0) { throw 'API not ready' }; @(Torrent) } `
    -RunPass { param($Kind) $script:passes += $Kind; if ($script:passes.Count -eq 1) { 2 } else { 0 } } `
    -HasPending { $false } -Clock { $script:epoch.AddSeconds($script:tick * 5) } `
    -Sleep { param($Seconds) $script:sleeps += $Seconds; $script:tick++ } `
    -Report { param($Message) $script:reports++ }
} catch { throw }
Check 'API startup failure is caught rather than terminating watchdog' ($script:reports -ge 1)
Check 'failed manager pass backs off instead of spinning' ($script:sleeps -contains 30)

$script:tick = 0; $script:reads = 0; $script:passes = @()
Invoke-QueueWatch -Watchdog $false -PollSeconds 5 -TimerSeconds 60 -PendingSeconds 30 -MaintenanceSeconds 900 `
    -Running { $script:tick -lt 2 } -ReadQueue { $script:reads++; $t = Torrent; if ($script:tick -eq 1) { $t.progress = 1 }; @($t) } `
    -RunPass { param($Kind) $script:passes += $Kind; 0 } `
    -HasPending { $false } -Clock { $script:epoch.AddSeconds($script:tick * 5) } `
    -Sleep { param($Seconds) $script:tick++ } -Report { param($Message) }
Check 'next poll catches completion occurring after the previous pass' ($script:passes.Count -eq 2 -and $script:reads -eq 2)

$manager = [IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'))
Check 'timer passes defer broad library dedup scans' ($manager.Contains('if ($SkipLibraryScan -or -not $libraryDupOn)'))
Check 'timer passes defer broad library redundancy scans' ($manager.Contains('if ($SkipLibraryScan -or -not $redundantOn)'))
Check 'timer passes retain pending settle execution' ($manager.Contains('$resumedSettles = Invoke-PendingSettles'))
$installer = [IO.File]::ReadAllText((Join-Path $root 'install-watch-task.ps1'))
Check 'installation uses logon trigger without periodic manager trigger' ($installer.Contains('-AtLogOn') -and -not $installer.Contains('-RepetitionInterval'))
Check 'installation prevents overlapping watchdogs and removes execution limit' ($installer.Contains('-MultipleInstances IgnoreNew') -and $installer.Contains('-ExecutionTimeLimit ([timespan]::Zero)'))
Check 'installation saves previous task and refuses an active file operation' ($installer.Contains('Export-ScheduledTask') -and $installer.Contains("if (`$existing.State -eq 'Running')"))
$launcher = [IO.File]::ReadAllText((Join-Path $root 'launch-qbittorrent.ps1'))
Check 'launcher starts qBittorrent before starting its companion' ($launcher.IndexOf('[Diagnostics.Process]::Start') -lt $launcher.IndexOf("& (Join-Path `$PSScriptRoot 'watch-manager.ps1')"))
Check 'launcher invokes app-bound companion without watchdog switch' (($launcher.TrimEnd() -split '\r?\n')[-1] -eq "& (Join-Path `$PSScriptRoot 'watch-manager.ps1')")
Check 'launcher accepts a magnet or torrent URI and appends it to qBittorrent arguments' ($launcher.Contains('[string]$Uri =') -and $launcher.Contains('$arguments = ($arguments.Trim()'))
$installer = [IO.File]::ReadAllText((Join-Path $root 'install-launcher.ps1'))
Check 'launcher installation disables old watchdog task' ($installer.Contains('Disable-ScheduledTask'))
Check 'startup installation preserves qBittorrent original arguments' ($installer.Contains('-Arguments $settings.StartupArguments'))
Check 'user shortcut installation keeps qBittorrent icon and arguments' ($installer.Contains('-Arguments $target.Arguments') -and $installer.Contains('$link.IconLocation ='))
Check 'launcher terminal opens normally instead of hidden or minimized' ($installer.Contains('-NoProfile -ExecutionPolicy Bypass -EncodedCommand') -and $installer.Contains('$link.WindowStyle = 1'))
Check 'magnet protocol handler is routed through the companion launcher' ($installer.Contains('magnetCommandKey') -and $installer.Contains('-Uri "%1"'))
Check 'a logon watchdog covers qBittorrent launches that skip the launcher' ($installer.Contains("'watch-manager.ps1'") -and $installer.Contains('-Watchdog'))
$startupBlock = [regex]::Match($installer, '(?s)if \(\$startup\) \{.*?\r?\n\}\r?\nif \(\$existingCompanionStartup\)').Value
Check 'the logon watchdog is registered even when qBittorrent does not start with Windows' ($startupBlock -and -not $startupBlock.Contains('$companionRunName') -and $installer.Contains('Set-ItemProperty -LiteralPath $runKey -Name $companionRunName'))
if ($script:fails) { exit 1 }
exit 0
