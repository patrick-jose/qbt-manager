<# Start qBittorrent and its companion together; no resident launcher/watchdog. #>
[CmdletBinding()]
param([string]$QbtArguments = '', [string]$Uri = '')
$ErrorActionPreference = 'Stop'
$settings = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'launcher.local.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
if (-not (Test-Path -LiteralPath $settings.Executable -PathType Leaf)) { throw 'qBittorrent executable is unavailable' }
$arguments = $QbtArguments
if (-not [string]::IsNullOrWhiteSpace($Uri)) {
    if ([string]::IsNullOrWhiteSpace($arguments)) { $arguments = [string]$settings.StartupArguments }
    $arguments = ($arguments.Trim() + ' "' + $Uri.Replace('"', '\"') + '"').Trim()
}
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = $settings.Executable
$start.Arguments = $arguments
$start.UseShellExecute = $true
[void][Diagnostics.Process]::Start($start)
# qBittorrent can hand off to an existing instance. Wait for the real process,
# not the short-lived handoff process, before launching the companion.
$deadline = (Get-Date).AddSeconds(15)
while (-not (Get-Process -Name qbittorrent -ErrorAction SilentlyContinue)) {
    if ((Get-Date) -ge $deadline) { throw 'qBittorrent did not start; companion was not launched' }
    Start-Sleep -Milliseconds 200
}
# No -Watchdog: the companion exits after qBittorrent closes. Its mutex prevents
# repeated shortcut clicks from creating concurrent manager companions.
& (Join-Path $PSScriptRoot 'watch-manager.ps1')
