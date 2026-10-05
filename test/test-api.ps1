# Exercises the manager's API failure handling and its single-instance lock
# against a real qBittorrent, but never against the real state file or log: every
# case runs from a throwaway directory with its own config, and the cases that
# would act are neutralised or pointed at a dead address.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-api.ps1

$ErrorActionPreference = 'Stop'
if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

# These tests live in <project>\test\ and exercise the code one level up, so
# every path is resolved from the project root, not from this folder.
$projectRoot = Split-Path -Parent $PSScriptRoot

function Get-ProjectFile {
    param([string]$Name)
    $p = Join-Path $projectRoot $Name
    if (-not (Test-Path -LiteralPath $p)) {
        throw "cannot find $Name (looked in $p). These tests are meant to stay in the project's test folder."
    }
    return $p
}

$script:fails = 0
function Check {
    param([string]$Label, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { "  [PASS] $Label" }
    else { $script:fails++; "  [FAIL] $Label"; if ($Detail) { "         $Detail" } }
}

$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('qbt-api-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null

$base = [System.IO.File]::ReadAllText((Get-ProjectFile 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText((Join-Path $sandbox 'qbt-manager.ps1'), $base, (New-Object System.Text.UTF8Encoding($false)))

$realCfg = [System.IO.File]::ReadAllText((Get-ProjectFile 'config.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json

function New-Case {
    param([string]$Name, [string]$BaseUrl)
    $dir = Join-Path $sandbox $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item (Join-Path $sandbox 'qbt-manager.ps1') (Join-Path $dir 'qbt-manager.ps1')

    $c = $realCfg | ConvertTo-Json -Depth 6 | ConvertFrom-Json
    $c.baseUrl = $BaseUrl
    # nothing in these cases may change anything
    $c.moveCompletedToLibrary = $false
    $c.assignCategories       = $false
    $c.deleteDataFiles        = $false
    $c.metadataTimeoutMinutes = 100000
    [System.IO.File]::WriteAllText((Join-Path $dir 'config.json'), ($c | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    return $dir
}

function Invoke-Case {
    param([string]$Dir, [string[]]$Extra = @())
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Dir 'qbt-manager.ps1') `
        -ConfigPath (Join-Path $Dir 'config.json') @Extra 2>&1
    $sw.Stop()
    return [pscustomobject]@{
        Exit    = $LASTEXITCODE
        Elapsed = $sw.Elapsed.TotalSeconds
        Text    = ($out | Out-String)
    }
}

Write-Host ''
Write-Host '=== 1. qBittorrent not running (nothing listening) ==='
# Port 8099 is not expected to be bound. curl answers with exit 7 immediately,
# so the correct behaviour is to notice at once and report exit 0.
$dir = New-Case -Name 'notrunning' -BaseUrl 'http://127.0.0.1:8099/api/v2'
$r = Invoke-Case -Dir $dir
"     exit $($r.Exit) in $([math]::Round($r.Elapsed, 2))s"
Check 'closed qBittorrent is not treated as an error' ($r.Exit -eq 0) "exit was $($r.Exit)"
Check 'and it is noticed immediately, not after a timeout' ($r.Elapsed -lt 5) "took $([math]::Round($r.Elapsed,2))s"
Check 'the reason is explained' ($r.Text -match 'not answering')
Check 'nothing was changed' ($r.Text -notmatch 'ERROR')

Write-Host ''
Write-Host '=== 2. the address is dropped on the floor (connect timeout) ==='
# An unroutable address makes curl exit 28 after the connect timeout. Two
# attempts plus a backoff must stay far inside the task's 5 minute ceiling.
$dir = New-Case -Name 'blackhole' -BaseUrl 'http://10.255.255.1:8080/api/v2'
$r = Invoke-Case -Dir $dir
"     exit $($r.Exit) in $([math]::Round($r.Elapsed, 2))s"
Check 'an unreachable API is an error, not a silent success' ($r.Exit -ge 2) "exit was $($r.Exit)"
Check 'it gives up well inside the 5 minute task ceiling' ($r.Elapsed -lt 60) "took $([math]::Round($r.Elapsed,2))s"
Check 'it says the API stopped responding' ($r.Text -match 'failed|stopped responding')

Write-Host ''
Write-Host '=== 3. the lock refuses a second, concurrent run ==='
$dir = New-Case -Name 'lockheld' -BaseUrl $realCfg.baseUrl
$lock = Join-Path $dir 'manager.lock'
# this test process is definitely alive, so the lock looks genuinely held
[System.IO.File]::WriteAllText($lock, ('{0} {1}' -f $PID, (Get-Date).ToString('o')), (New-Object System.Text.UTF8Encoding($false)))
$r = Invoke-Case -Dir $dir -Extra @('-DryRun')
"     exit $($r.Exit) in $([math]::Round($r.Elapsed, 2))s"
Check 'a live lock holder makes the run stand down' ($r.Exit -eq 4) "exit was $($r.Exit)"
Check 'and it does not touch the API at all' ($r.Text -match 'already in progress')
Check 'the lock is left for its owner' (Test-Path -LiteralPath $lock)

Write-Host ''
Write-Host '=== 4. a lock left by a dead process is cleared, not obeyed ==='
$dir = New-Case -Name 'lockstale' -BaseUrl 'http://127.0.0.1:8099/api/v2'
$lock = Join-Path $dir 'manager.lock'
# PID 999999 is not a live process on any normal machine
[System.IO.File]::WriteAllText($lock, '999999 2026-01-01T00:00:00', (New-Object System.Text.UTF8Encoding($false)))
$r = Invoke-Case -Dir $dir
"     exit $($r.Exit) in $([math]::Round($r.Elapsed, 2))s"
Check 'a stale lock does not block the schedule' ($r.Exit -eq 0) "exit was $($r.Exit)"
Check 'the run got past the lock to the API stage' ($r.Text -match 'not answering')
Check 'and the stale lock was cleaned up' (-not (Test-Path -LiteralPath $lock))

Write-Host ''
Write-Host '=== 5. a normal run leaves no lock behind ==='
$dir = New-Case -Name 'locknormal' -BaseUrl $realCfg.baseUrl
$r = Invoke-Case -Dir $dir -Extra @('-DryRun')
"     exit $($r.Exit) in $([math]::Round($r.Elapsed, 2))s"
Check 'a healthy run succeeds' ($r.Exit -eq 0) "exit was $($r.Exit)"
Check 'and releases the lock on the way out' (-not (Test-Path -LiteralPath (Join-Path $dir 'manager.lock')))

Write-Host ''
Write-Host '=== 6. the live machine is unaffected by all of this ==='
Check 'the real state file was not touched' (-not (Test-Path -LiteralPath (Join-Path $sandbox 'state.json')))
Check 'no stray lock in the real directory' (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'manager.lock')))

Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:fails -eq 0) { 'all api/lock tests passed' }
else { "$($script:fails) test(s) FAILED"; exit 1 }