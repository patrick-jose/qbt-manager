<# Wire the per-user Start menu, existing user shortcuts and startup entry to the companion launcher. #>
[CmdletBinding()]
param([string]$Executable, [string]$TaskName = 'qbt-manager')
$ErrorActionPreference = 'Stop'
$launcher = Join-Path $PSScriptRoot 'launch-qbittorrent.ps1'
$localPath = Join-Path $PSScriptRoot 'launcher.local.json'
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startup = (Get-ItemProperty -LiteralPath $runKey -ErrorAction SilentlyContinue).qBittorrent
if (-not $Executable) {
    if (Test-Path -LiteralPath $localPath) { $Executable = ([IO.File]::ReadAllText($localPath) | ConvertFrom-Json).Executable }
    else {
        $process = Get-CimInstance Win32_Process -Filter "Name = 'qbittorrent.exe'" | Select-Object -First 1
        $Executable = $process.ExecutablePath
        if (-not $Executable) { $Executable = Join-Path $env:ProgramFiles 'qBittorrent\qbittorrent.exe' }
    }
}
if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw 'Specify the installed qBittorrent executable with -Executable' }
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task -and $task.State -eq 'Running') { throw 'Stop the old watcher safely between manager passes before installing the launcher.' }
$backup = Join-Path $PSScriptRoot ('backup\launcher-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backup -Force | Out-Null
if ($task) {
    Export-ScheduledTask -TaskName $TaskName | Set-Content -LiteralPath (Join-Path $backup 'task.xml') -Encoding UTF8
    Disable-ScheduledTask -TaskName $TaskName | Out-Null
}
if (Test-Path -LiteralPath $localPath) {
    $settings = [IO.File]::ReadAllText($localPath) | ConvertFrom-Json
    Copy-Item -LiteralPath $localPath -Destination (Join-Path $backup 'launcher.local.json')
}
else {
    $settings = [pscustomobject]@{ Executable = $Executable; OriginalStartup = $startup; StartupArguments = '' }
    if ($startup -and $startup -match '^"[^"]*qbittorrent\.exe"\s*(.*)$') { $settings.StartupArguments = $Matches[1] }
    elseif ($startup) { throw 'Unrecognised qBittorrent startup command; refusing to replace it' }
}
$settings.Executable = $Executable
$settings | ConvertTo-Json | Set-Content -LiteralPath $localPath -Encoding UTF8
function Get-LauncherArguments {
    param([string]$Arguments = '')
    $command = "& '$($launcher.Replace("'", "''"))' -QbtArguments '$($Arguments.Replace("'", "''"))'"
    '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
}
$powershell = Join-Path $PSHOME 'powershell.exe'
$shell = New-Object -ComObject WScript.Shell
$roots = @([Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('StartMenu'),
    (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned'))
$links = foreach ($root in $roots) {
    if (Test-Path -LiteralPath $root) {
        Get-ChildItem -LiteralPath $root -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            $link = $shell.CreateShortcut($_.FullName)
            if ($link.TargetPath -ieq $Executable) { [pscustomobject]@{ Path = $_.FullName; Arguments = $link.Arguments } }
        }
    }
}
# Per-user Start menu entry shadows the system entry; do not edit uninstall links
# or require administrator access to ProgramData.
$menu = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\qBittorrent\qBittorrent.lnk'
New-Item -ItemType Directory -Path (Split-Path -Parent $menu) -Force | Out-Null
$targets = @($links)
if (@($targets | Where-Object { $_.Path -ieq $menu }).Count -eq 0) { $targets += [pscustomobject]@{ Path = $menu; Arguments = '' } }
$index = 0
foreach ($target in $targets) {
    $index++
    if (Test-Path -LiteralPath $target.Path) { Copy-Item -LiteralPath $target.Path -Destination (Join-Path $backup ("shortcut-$index.lnk")) }
    $link = $shell.CreateShortcut($target.Path)
    $link.TargetPath = $powershell
    $link.Arguments = Get-LauncherArguments -Arguments $target.Arguments
    $link.WorkingDirectory = $PSScriptRoot
    $link.IconLocation = "$Executable,0"
    $link.WindowStyle = 7
    $link.Description = 'qBittorrent with its manager companion'
    $link.Save()
    Write-Output "Launcher shortcut: $($target.Path)"
}
# Preserve whether qBittorrent was configured to start with Windows and its args.
if ($startup) {
    [pscustomobject]@{ Command = $startup } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backup 'startup.json') -Encoding UTF8
    Set-ItemProperty -LiteralPath $runKey -Name qBittorrent -Value ('"' + $powershell + '" ' + (Get-LauncherArguments -Arguments $settings.StartupArguments))
    Write-Output 'qBittorrent startup entry now starts its companion too.'
}
Write-Output 'Old watchdog task disabled. The companion now runs only with qBittorrent.'
