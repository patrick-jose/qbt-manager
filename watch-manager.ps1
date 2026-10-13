<# Lightweight qBittorrent companion. -Watchdog also waits for future launches. #>
[CmdletBinding()]
param(
    [switch]$Watchdog,
    [switch]$DryRun,
    [ValidateRange(1,60)][int]$PollSeconds = 5,
    [ValidateRange(10,3600)][int]$TimerSeconds = 60,
    [ValidateRange(10,3600)][int]$PendingSeconds = 30,
    [ValidateRange(60,86400)][int]$MaintenanceSeconds = 900
)
$ErrorActionPreference = 'Stop'

function Convert-WatchQueueJson {
    param([string]$Text)
    if (-not $Text.TrimStart().StartsWith('[')) { throw 'unexpected torrent-list response' }
    $parsed = $Text | ConvertFrom-Json
    foreach ($torrent in $parsed) { $torrent }
}

function Get-QueueFingerprint {
    param([object[]]$Torrents)
    # Ordinary byte/speed/peer updates do not warrant another filesystem scan.
    # Identity, metadata, completion and meaningful state/location changes do.
    $rows = foreach ($t in @($Torrents | Sort-Object hash)) {
        [ordered]@{ hash = $t.hash; name = $t.name; size = $t.size; total = $t.total_size
            finished = ([double]$t.progress -ge 1); state = $t.state; priority = $t.priority
            category = $t.category; save = $t.save_path; content = $t.content_path }
    }
    return (ConvertTo-Json -InputObject @($rows) -Compress -Depth 4)
}

function Get-WatchDecision {
    param([string]$Fingerprint, [string]$Previous, [datetime]$Now,
        [datetime]$LastPass, [datetime]$LastFull, [bool]$Pending,
        [int]$TimerSeconds, [int]$PendingSeconds, [int]$MaintenanceSeconds)
    if ($Fingerprint -cne $Previous -or ($Now - $LastFull).TotalSeconds -ge $MaintenanceSeconds) { return 'Full' }
    if (($Now - $LastPass).TotalSeconds -ge $TimerSeconds -or
        ($Pending -and ($Now - $LastPass).TotalSeconds -ge $PendingSeconds)) { return 'Quick' }
    return 'Wait'
}

function Invoke-QueueWatch {
    param([scriptblock]$Running, [scriptblock]$ReadQueue, [scriptblock]$RunPass,
        [scriptblock]$HasPending, [scriptblock]$Sleep, [scriptblock]$Clock,
        [scriptblock]$Report, [bool]$Watchdog, [int]$PollSeconds,
        [int]$TimerSeconds, [int]$PendingSeconds, [int]$MaintenanceSeconds,
        [scriptblock]$ShouldStop = { $false })
    $previous = $null; $lastPass = [datetime]::MinValue; $lastFull = [datetime]::MinValue
    while ($true) {
        if (& $ShouldStop) { return }
        if (-not (& $Running)) {
            if (-not $Watchdog) { return }
            # No API calls or manager activity while qBittorrent is closed.
            $previous = $null; $lastPass = [datetime]::MinValue; $lastFull = [datetime]::MinValue
        }
        else {
            try {
                $fingerprint = Get-QueueFingerprint -Torrents @(& $ReadQueue)
                $now = & $Clock
                $decision = Get-WatchDecision -Fingerprint $fingerprint -Previous $previous -Now $now `
                    -LastPass $lastPass -LastFull $lastFull -Pending ([bool](& $HasPending)) `
                    -TimerSeconds $TimerSeconds -PendingSeconds $PendingSeconds -MaintenanceSeconds $MaintenanceSeconds
                if ($decision -ne 'Wait') {
                    # Synchronous child: never overlap passes. The next poll reads
                    # again, including changes that occurred during this pass.
                    $code = & $RunPass $decision
                    $lastPass = & $Clock
                    if ($code -eq 0) {
                        $previous = $fingerprint
                        if ($decision -eq 'Full') { $lastFull = $lastPass }
                    }
                    else {
                        & $Report "manager exited $code; retrying after a bounded delay"
                        & $Sleep ([Math]::Max(30, $PollSeconds))
                    }
                }
            }
            catch {
                & $Report "watch check failed: $($_.Exception.Message)"
                & $Sleep ([Math]::Max(30, $PollSeconds))
            }
        }
        & $Sleep $PollSeconds
    }
}

# runtime (tests load only the functions above)
$manager = Join-Path $PSScriptRoot 'qbt-manager.ps1'
$source = [IO.File]::ReadAllText($manager)
$start = $source.IndexOf('function Get-MergedConfig'); $end = $source.IndexOf('$cfg = Get-MergedConfig', $start)
Invoke-Expression $source.Substring($start, $end - $start)
$cfg = Get-MergedConfig -ConfigPath (Join-Path $PSScriptRoot 'config.json') -Root $PSScriptRoot
$base = ([string]$cfg.baseUrl).TrimEnd('/')
$referer = $base -replace '/api/v2$', ''
$logDir = Join-Path $PSScriptRoot 'logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$mutexName = 'Local\qbt-manager-watch-' + ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($PSScriptRoot.ToLowerInvariant())) -replace '[^a-zA-Z0-9]', '')
$mutex = New-Object Threading.Mutex($false, $mutexName)
$taken = $false
try {
    try { $taken = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $taken = $true }
    if (-not $taken) { exit 0 }
    $report = {
        param($Message)
        $log = Join-Path $logDir ('watcher-{0}.log' -f (Get-Date -Format 'yyyy-MM-dd'))
        Add-Content -LiteralPath $log -Encoding UTF8 -Value ("{0:HH:mm:ss} {1}" -f (Get-Date), $Message)
    }
    & $report 'watcher started'
    Invoke-QueueWatch -Watchdog ([bool]$Watchdog) -PollSeconds $PollSeconds -TimerSeconds $TimerSeconds `
        -PendingSeconds $PendingSeconds -MaintenanceSeconds $MaintenanceSeconds `
        -ShouldStop { Test-Path -LiteralPath (Join-Path $PSScriptRoot 'watch-stop') } `
        -Running { $null -ne (Get-Process -Name qbittorrent -ErrorAction SilentlyContinue) } `
        -Clock { Get-Date } -Sleep { param($Seconds) Start-Sleep -Seconds $Seconds } -Report $report `
        -HasPending { @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'pending-settle') -Filter '*.json' -ErrorAction SilentlyContinue).Count -gt 0 } `
        -ReadQueue {
            $temp = [IO.Path]::GetTempFileName()
            try {
                & curl.exe --fail -s --connect-timeout 3 --max-time 10 -H "Referer: $referer" -o $temp "$base/torrents/info"
                if ($LASTEXITCODE -ne 0) { throw "qBittorrent API unavailable (curl $LASTEXITCODE)" }
                $text = [IO.File]::ReadAllText($temp, [Text.Encoding]::UTF8)
                Convert-WatchQueueJson -Text $text
            }
            finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        } `
        -RunPass {
            param($Kind)
            & $report "starting $Kind manager pass"
            $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $manager)
            if ($Kind -eq 'Quick') { $arguments += '-SkipLibraryScan' }
            if ($DryRun) { $arguments += '-DryRun' }
            & powershell.exe @arguments | Out-Null
            return $LASTEXITCODE
        }
}
finally {
    if ($taken) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
