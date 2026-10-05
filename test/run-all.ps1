<#
.SYNOPSIS
    Runs every qbt-manager self-test and summarises the result.

.DESCRIPTION
    Each test-*.ps1 in this folder is a standalone script that exits non-zero on
    failure, so this runs them the same way a human would - one child process
    each - rather than dot-sourcing them into one session where a thrown error
    would take the runner down with it and hide the later suites.

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\run-all.ps1

.EXAMPLE
    .\test\run-all.ps1
    Runs everything, printing each suite's output.

.EXAMPLE
    .\test\run-all.ps1 -Quiet
    One line per suite. Useful before a change you expect to be quiet.
#>
[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'

if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

$tests = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'test-*.ps1' | Sort-Object Name)
if ($tests.Count -eq 0) {
    Write-Host "no test-*.ps1 found in $PSScriptRoot" -ForegroundColor Red
    exit 1
}

$totalPass = 0
$totalFail = 0
$failedSuites = @()
$overall = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($t in $tests) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $t.FullName 2>&1 | Out-String
    $code = $LASTEXITCODE
    $sw.Stop()

    $pass = ([regex]::Matches($out, '\[PASS\]')).Count
    $fail = ([regex]::Matches($out, '\[FAIL\]')).Count
    $totalPass += $pass
    $totalFail += $fail

    if ($code -ne 0 -or $fail -gt 0) { $failedSuites += $t.Name }

    $colour = if ($code -eq 0 -and $fail -eq 0) { 'Green' } else { 'Red' }
    $label = '{0,-22} {1,3} passed  {2,2} failed  {3,6:N1}s' -f $t.Name, $pass, $fail, $sw.Elapsed.TotalSeconds

    if ($Quiet) {
        Write-Host $label -ForegroundColor $colour
    }
    else {
        Write-Host ''
        Write-Host ('=' * 78) -ForegroundColor DarkGray
        Write-Host "  $($t.Name)" -ForegroundColor Cyan
        Write-Host ('=' * 78) -ForegroundColor DarkGray
        # Each suite already colours its own PASS/FAIL lines; passing the text
        # through untouched preserves that.
        Write-Host $out.TrimEnd()
        Write-Host ''
        Write-Host $label -ForegroundColor $colour
    }

    # A suite that died before printing anything is itself a failure, even
    # though it managed to report zero failed checks.
    if ($code -ne 0 -and $pass -eq 0 -and $fail -eq 0) {
        Write-Host "  (this suite exited $code without reporting any checks - it probably crashed)" -ForegroundColor Red
    }
}

$overall.Stop()

Write-Host ''
Write-Host ('=' * 78) -ForegroundColor DarkGray
if ($failedSuites.Count -eq 0) {
    Write-Host ("  {0} suites, {1} checks, all passed, {2:N1}s total" -f $tests.Count, $totalPass, $overall.Elapsed.TotalSeconds) -ForegroundColor Green
    exit 0
}
else {
    Write-Host ("  {0} of {1} suites FAILED ({2} failing checks), {3:N1}s total" -f `
        $failedSuites.Count, $tests.Count, $totalFail, $overall.Elapsed.TotalSeconds) -ForegroundColor Red
    foreach ($f in $failedSuites) { Write-Host "    - $f" -ForegroundColor Red }
    exit 1
}