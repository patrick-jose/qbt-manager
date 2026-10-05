<#
.SYNOPSIS
    Runs every qbt-manager self-test.

.DESCRIPTION
    One command to answer "is this working?". Each suite lives in .\test\test-*.ps1,
    is standalone, and exits non-zero on failure - so each is run in its own child
    process, exactly as a person would run it, rather than dot-sourced into one
    session where a single thrown error would take the runner down and hide every
    suite after it.

    Exit codes
        0  every suite passed
        1  one or more suites failed
        2  the test folder is missing or empty

    Nothing here touches qBittorrent's queue, your state.json, or your library.
    The one suite that reaches the network (test-stall-cleanup.ps1) makes a single
    live HTTP call to confirm the internet probe really answers; see its header.

.EXAMPLE
    .\test-all.ps1
    Everything, full output.

.EXAMPLE
    .\test-all.ps1 -Quiet
    One line per suite. The right choice before a change you expect to be quiet.

.EXAMPLE
    .\test-all.ps1 -Suite dedup,queue-window
    Only the named suites. The 'test-' prefix is optional, and a comma-separated
    list works even under -File, where every argument arrives as one string.

.EXAMPLE
    .\test-all.ps1 -List
    What is available, and nothing else. Useful in a fresh clone.
#>
[CmdletBinding()]
param(
    # One line per suite instead of full output.
    [switch]$Quiet,

    # Comma-separated suite names to run, e.g. 'dedup,phantom'. Default: all.
    [string[]]$Suite,

    # List the suites and exit without running anything.
    [switch]$List,

    # Print each suite's whole output even in -Quiet.
    [switch]$ShowFailures,

    # Seconds to allow one suite before calling it hung. 0 disables the ceiling.
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Continue'

if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$testDir = Join-Path $PSScriptRoot 'test'

if (-not (Test-Path -LiteralPath $testDir)) {
    Write-Host "No test folder at $testDir" -ForegroundColor Red
    exit 2
}

$all = @(Get-ChildItem -LiteralPath $testDir -Filter 'test-*.ps1' -File -ErrorAction SilentlyContinue |
         Sort-Object Name)

if ($all.Count -eq 0) {
    Write-Host "No test-*.ps1 files in $testDir" -ForegroundColor Red
    exit 2
}

# --- -List -------------------------------------------------------------------
if ($List) {
    Write-Host ''
    Write-Host ("{0,3} suite(s) in {1}" -f $all.Count, $testDir)
    Write-Host ''
    # Names only. A per-suite check count is NOT listed, because it cannot be
    # known without running the suite: the [PASS] markers are printed at run time
    # by a Check helper, so counting them in the source finds the one place that
    # formats the string, not the checks themselves. An earlier version of this
    # listing did count them and cheerfully reported "~1 checks" for every suite.
    foreach ($t in $all) { Write-Host ("  {0}" -f $t.Name) }
    Write-Host ''
    Write-Host 'Run one with:  .\test-all.ps1 -Suite <name>'
    Write-Host ''
    exit 0
}

# --- selection ---------------------------------------------------------------
#
# The parameter is [string[]], but under -File EVERY argument arrives as a string,
# so -Suite dedup,phantom is ONE element containing a comma rather than two
# elements. Splitting on the comma is therefore not an optimisation here, it is
# the difference between the documented invocation working and reporting
# "No suite matches: dedup,phantom".
$names = @()
foreach ($s in @($Suite)) {
    if ([string]::IsNullOrWhiteSpace($s)) { continue }
    foreach ($part in ($s -split ',')) {
        $p = $part.Trim()
        if ($p) { $names += $p }
    }
}

$selected = $all
if ($names.Count -gt 0) {
    $wanted = @{}
    foreach ($n in $names) { $wanted[($n -replace '\.ps1$', '').ToLowerInvariant()] = $true }

    $selected = @($all | Where-Object {
        $short = ($_.BaseName -replace '^test-', '').ToLowerInvariant()
        $wanted.ContainsKey($short) -or $wanted.ContainsKey($_.BaseName.ToLowerInvariant())
    })

    $missing = @($names | Where-Object {
        $n = ($_ -replace '\.ps1$', '').ToLowerInvariant()
        $short = ($n -replace '^test-', '')
        -not ($wanted.ContainsKey($n)) -or -not (@($selected | Where-Object {
              (($_.BaseName -replace '^test-', '').ToLowerInvariant()) -eq $short
          }).Count -gt 0)
    } | Select-Object -Unique)

    if ($missing.Count -gt 0) {
        Write-Host ("No suite matches: {0}" -f ($missing -join ', ')) -ForegroundColor Yellow
        Write-Host 'Use -List to see what is available.' -ForegroundColor DarkGray
        exit 2
    }
}

if ($selected.Count -eq 0) {
    Write-Host 'Nothing selected.' -ForegroundColor Yellow
    exit 2
}

Write-Host ''
if (-not $Quiet) {
    Write-Host ('=' * 78) -ForegroundColor DarkGray
    Write-Host ("  qbt-manager test run  -  {0} suite(s)" -f $selected.Count)
    Write-Host ('=' * 78) -ForegroundColor DarkGray
}

$totalPass = 0
$totalFail = 0
$failed = New-Object System.Collections.ArrayList
$overall = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($t in $selected) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    if ($TimeoutSeconds -gt 0) {
        # A child process, so a suite that hangs cannot wedge the runner. The
        # ceiling is generous: test-api.ps1 deliberately drives real connection
        # timeouts and takes well over a minute on a slow day.
        #
        # The job returns the child's EXIT CODE as well as its output, and that
        # matters more than it looks. An earlier version discarded it and hardcoded
        # 0 on completion, so a suite that threw before printing anything came
        # back as "0 passed, 0 failed" and the runner reported the whole run green.
        # The "crashed without reporting any checks" guard below could not fire,
        # because the code it tests was always 0. Caught by planting a suite that
        # throws on line one.
        $job = Start-Job -ScriptBlock {
            param($script)
            $text = & powershell -NoProfile -ExecutionPolicy Bypass -File $script 2>&1 | Out-String
            # $LASTEXITCODE here is the CHILD's, which is what matters. The job
            # itself always exits 0.
            [pscustomobject]@{ Out = $text; Code = $LASTEXITCODE }
        } -ArgumentList $t.FullName

        if (Wait-Job $job -Timeout $TimeoutSeconds) {
            $got = Receive-Job $job
            $out = [string]$got.Out
            $code = [int]$got.Code
            # A job that failed in a way that produced no object at all - Start-Job
            # itself broke, the scriptblock was killed - must not read as a pass.
            if ($null -eq $got) { $out = 'the job returned nothing'; $code = 125 }
        }
        else {
            Stop-Job $job
            $out = "TIMED OUT after $TimeoutSeconds seconds"
            $code = 124
        }
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
    else {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $t.FullName 2>&1 | Out-String
        $code = $LASTEXITCODE
    }

    $sw.Stop()

    $pass = ([regex]::Matches($out, '\[PASS\]')).Count
    $fail = ([regex]::Matches($out, '\[FAIL\]')).Count
    $totalPass += $pass
    $totalFail += $fail

    if ($code -ne 0 -or $fail -gt 0) { [void]$failed.Add($t.Name) }

    $colour = if ($code -eq 0 -and $fail -eq 0) { 'Green' } else { 'Red' }
    $label = '{0,-24} {1,4} passed {2,3} failed {3,7:N1}s' -f $t.Name, $pass, $fail, $sw.Elapsed.TotalSeconds

    if ($Quiet) {
        Write-Host $label -ForegroundColor $colour
    }
    else {
        Write-Host ''
        Write-Host ('-' * 78) -ForegroundColor DarkGray
        Write-Host "  $($t.Name)" -ForegroundColor Cyan
        Write-Host ('-' * 78) -ForegroundColor DarkGray
        # Each suite colours its own PASS/FAIL lines; passing the text through
        # untouched is what preserves that.
        Write-Host $out.TrimEnd()
        Write-Host ''
        Write-Host $label -ForegroundColor $colour
    }

    # A suite that died before printing anything is itself a failure, even though
    # it managed to report zero failed checks. Silence is not a pass.
    if ($code -ne 0 -and $pass -eq 0 -and $fail -eq 0) {
        $why = if ($code -eq 124) { 'timed out' } else { "exited $code" }
        Write-Host "  (this suite $why without reporting any checks - it probably crashed)" -ForegroundColor Red
        if ($ShowFailures -or -not $Quiet) { Write-Host $out.TrimEnd() -ForegroundColor DarkGray }
    }
    elseif ($fail -gt 0 -and $ShowFailures) {
        Write-Host '  failing checks:' -ForegroundColor Red
        foreach ($line in ($out -split "`r?`n" | Where-Object { $_ -match '\[FAIL\]' })) {
            Write-Host ("    " + $line.Trim()) -ForegroundColor Red
        }
    }
}

$overall.Stop()

Write-Host ''
Write-Host ('=' * 78) -ForegroundColor DarkGray
if ($failed.Count -eq 0) {
    Write-Host ("  {0} suites, {1} checks, all passed, {2:N1}s total" -f `
        $selected.Count, $totalPass, $overall.Elapsed.TotalSeconds) -ForegroundColor Green
    Write-Host ('=' * 78) -ForegroundColor DarkGray
    exit 0
}

Write-Host ("  {0} of {1} suites FAILED ({2} failing checks), {3:N1}s total" -f `
    $failed.Count, $selected.Count, $totalFail, $overall.Elapsed.TotalSeconds) -ForegroundColor Red
foreach ($f in $failed) { Write-Host "    - $f" -ForegroundColor Red }
Write-Host ('=' * 78) -ForegroundColor DarkGray
exit 1