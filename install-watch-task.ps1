<# Optional legacy watchdog installer. Prefer install-launcher.ps1 for app-bound lifetime. #>
[CmdletBinding()]
param([string]$TaskName = 'qbt-manager')
$ErrorActionPreference = 'Stop'
$watcher = Join-Path $PSScriptRoot 'watch-manager.ps1'
if (-not (Test-Path -LiteralPath $watcher)) { throw 'watch-manager.ps1 is missing' }
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    $backup = Join-Path $PSScriptRoot 'backup'
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    Export-ScheduledTask -TaskName $TaskName | Set-Content -LiteralPath (Join-Path $backup ('task-before-watch-{0}.xml' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))) -Encoding UTF8
    # Do not kill a manager pass in the middle of a file operation.
    if ($existing.State -eq 'Running') { throw 'Task is running. Wait for its manager pass to finish before installing.' }
}
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$watcher`" -Watchdog") -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::Zero) -MultipleInstances IgnoreNew `
    -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description 'qBittorrent companion: 5-second change detection, bounded settle retries, logon watchdog.' -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName,State
