<#
    Exercises the log reaper (rule 8): everything in logs\ older than
    logRetentionDays is destroyed.

    It exists because logs were never pruned at all. The manager writes ONE FILE
    PER DAY, so nothing rotates or overwrites them and the total grows forever. The
    only reaper that ran was the backup reaper, whose '*.bak*' filter does not
    match a .log, so nothing ever touched them.

    SCOPE IS EVERYTHING IN logs\, INCLUDING THE deleted-*.csv WORKSHEETS. An
    earlier version of this filter was 'manager-*.log' and it spared the CSV,
    arguing the worksheet was the only record of the 205 torrents deleted on
    2026-10-05. That did not survive checking: the file stores
    Name,HashFirst8,Reason, and 8 hex characters is not the 40-character infohash,
    so it cannot re-add anything by hash or by magnet. It is a diagnostic list of
    what was deleted and why, worth 33 KB, and it goes on the same clock as
    everything else.

    So the sharp edge here points the OTHER way: a reaper that keeps its filter and
    quietly spares the worksheet is NOT what was asked for. The CSV is planted well
    past the cutoff and asserted to be DESTROYED. An unrelated file planted at the
    same age is destroyed too - there is no pattern exception left.

    The one thing that must survive is TODAY'S log: the run doing the deleting is
    appending to it as it goes, and taking the current run's own record with it
    would be a bug rather than a policy. Asserted separately.

    Ages are planted against real file timestamps on a real temp tree, and the
    reaper body is LIFTED FROM THE MANAGER rather than restated here, so a change
    to the shipped logic cannot leave this suite testing something else.

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-log-reap.ps1
#>

$ErrorActionPreference = 'Stop'
if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent $PSScriptRoot

function Get-ProjectFile {
    param([string]$Name)
    $p = Join-Path $projectRoot $Name
    if (-not (Test-Path -LiteralPath $p)) { throw "cannot find $Name (looked in $p)" }
    return $p
}

$cfg = [System.IO.File]::ReadAllText((Get-ProjectFile 'config.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json

$src = [System.IO.File]::ReadAllText((Get-ProjectFile 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)
$rs = $src.IndexOf('# -- rule 8: log reaper')
$re = $src.IndexOf('# -- persist state')
if ($rs -lt 0 -or $re -le $rs) { throw 'could not locate the log reaper in qbt-manager.ps1' }
$reaperBody = $src.Substring($rs, $re - $rs)

$script:fails = 0
function Check {
    param([string]$Label, [bool]$Ok)
    if ($Ok) { "  [PASS] $Label" } else { $script:fails++; "  [FAIL] $Label" }
}

# ---------------------------------------------------------------------------
# a real logs\ tree, with real ages
# ---------------------------------------------------------------------------
$script:roots = @()

function New-LogTree {
    $dir = Join-Path $env:TEMP ('logreap-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $script:roots += $dir
    return $dir
}

# Backdates the file with a real LastWriteTime, because the reaper filters on
# LastWriteTime and a mocked one would test nothing.
function Plant {
    param([string]$Dir, [string]$Name, [double]$AgeDays)
    $p = Join-Path $Dir $Name
    Set-Content -LiteralPath $p -Value ("filler line for $Name") -Encoding UTF8
    (Get-Item -LiteralPath $p).LastWriteTime = (Get-Date).AddDays(-$AgeDays)
    return $p
}

function Run-Reaper {
    param([string]$LogDir, [string]$CurrentLog)
    $DryRun = $false
    # The reaper body reads $logDir and $logPath by name, so they have to exist
    # in THIS scope - Invoke-Expression runs here, not at script scope.
    $logDir = $LogDir
    $logPath = $CurrentLog
    $script:actions = New-Object System.Collections.ArrayList
    $script:notes = New-Object System.Collections.ArrayList
    $script:logLines = @()
    function Write-Log { param([string]$Level, [string]$Message) $script:logLines += "$Level $Message" }
    function Format-Bytes { param($n) "$n B" }
    Invoke-Expression $reaperBody
}

$days = [double]$cfg.logRetentionDays

Write-Host ''
Write-Host '== the shipped config =='
Check 'config.json sets a log retention'      ($cfg.logRetentionDays -ne $null)
Check 'and it is 7 days'                      ($days -eq 7)
Check 'backups are kept 7 days too'           ([double]$cfg.backupMaxAgeDays -eq 7)
Check 'the two retentions agree'              ([double]$cfg.backupMaxAgeDays -eq $days)

# --- the ages that matter, straddling whatever the cutoff is -----------------
# Expressed RELATIVE to $days rather than as fixed numbers. They were written as
# literals (3,2 and 4,1 days, around a 4-day cutoff) and went quietly wrong the
# moment the retention moved to 7: both files landed INSIDE the window, the
# 'past the cutoff' assertions below would have failed for the wrong reason, and
# the suite was one config edit away from testing nothing at all.
$dir = New-LogTree
$today   = Plant $dir 'manager-2026-10-05.log' 0
$fresh   = Plant $dir 'manager-2026-10-02.log' ($days - 3.8)   # inside the window
$edge    = Plant $dir 'manager-2026-10-01.log' ($days + 0.1)   # just past it
$ancient = Plant $dir 'manager-2026-09-20.log' ($days + 23.0)  # long past it
# Past the cutoff on purpose: a deleted-*.csv worksheet goes like anything else.
$csv     = Plant $dir 'deleted-2026-10-05T0813.csv' ($days + 5.0)
# And an unrelated file at the same age, because there is no pattern exception
# left - the filter that used to spare the CSV is exactly what is being removed.
$unrelated = Plant $dir 'notes.txt' ($days + 23.0)

Run-Reaper -LogDir $dir -CurrentLog $today

Write-Host ''
Write-Host '== what the cutoff removes =='
Check 'a log past the cutoff is destroyed'          (-not (Test-Path -LiteralPath $edge))
Check 'a very old log is destroyed too'            (-not (Test-Path -LiteralPath $ancient))
Check 'a deleted-*.csv worksheet is destroyed too'  (-not (Test-Path -LiteralPath $csv))
Check 'an unrelated old file goes as well'          (-not (Test-Path -LiteralPath $unrelated))
Check 'a log inside the window survives'           (Test-Path -LiteralPath $fresh)

Write-Host ''
Write-Host '== the one thing it must never touch =='
# Not a retention opinion: the run doing the deleting is appending to this file as
# it goes, so removing it mid-run would take the current run's own record with it.
Check "today's own log is never removed"            (Test-Path -LiteralPath $today)

# A second pass must find nothing left, not try again and fail.
Run-Reaper -LogDir $dir -CurrentLog $today
Check 'a second pass finds nothing left to do'      (-not (@($script:notes) -match 'pruned'))
Check 'and the survivors are still intact'         (Test-Path -LiteralPath $today)
Check 'and the CSV does not come back'             (-not (Test-Path -LiteralPath $csv))

Write-Host ''
Write-Host '== dry run changes nothing =='
$dir2 = New-LogTree
$today2 = Plant $dir2 'manager-2026-10-05.log' 0
$old2   = Plant $dir2 'manager-2026-08-01.log' ($days + 83.0)
$csv2   = Plant $dir2 'deleted-2026-08-01T0000.csv' ($days + 83.0)

$DryRun = $true
$script:actions = New-Object System.Collections.ArrayList
$script:notes = New-Object System.Collections.ArrayList
$script:logLines = @()
function Write-Log { param([string]$Level, [string]$Message) $script:logLines += "$Level $Message" }
function Format-Bytes { param($n) "$n B" }
$logDir = $dir2
$logPath = $today2
Invoke-Expression $reaperBody

Check 'a dry run leaves the old log in place'      (Test-Path -LiteralPath $old2)
Check 'a dry run leaves the CSV in place too'      (Test-Path -LiteralPath $csv2)
Check 'a dry run reports BOTH as it would do'      ((@($script:actions) | Where-Object { $_ -like 'DELETE-LOG*' }).Count -eq 2)
Check "a dry run still spares today's own log"     (Test-Path -LiteralPath $today2)

Write-Host ''
Write-Host '== the sweep is unfiltered, and non-recursive =='
# Asserted against the source. Every behavioural check above would still pass if
# someone re-added a -Filter, because the planted names all match manager-*.log
# except the two that specifically must NOT be spared - so these three are what
# actually pin the scope down.
Check 'no -Filter narrows the sweep'               ($reaperBody -notmatch '-Filter\s+')
Check 'and it is NOT recursive'                    ($reaperBody -notmatch '-Recurse')
Check 'today is excluded by name, not by pattern'  ($reaperBody -match '\$_\.Name\s+-ne\s+\$todayName')

# ---------------------------------------------------------------------------
# cleanup - see test-library-dedupe.ps1 for why this is not a try/finally
# ---------------------------------------------------------------------------
foreach ($r in $script:roots) {
    if (Test-Path -LiteralPath $r) { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
$mine = 0
foreach ($r in $script:roots) { if (Test-Path -LiteralPath $r) { $mine++ } }
Check 'every tree it created is gone'              ($mine -eq 0)

Write-Host ''
if ($script:fails -eq 0) {
    Write-Host 'all log-reaper tests passed'
}
else {
    Write-Host ("{0} log-reaper test(s) FAILED" -f $script:fails)
    exit 1
}