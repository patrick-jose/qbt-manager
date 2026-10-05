# Exercises Get-StalledWatch lifted out of qbt-manager.ps1 with synthetic
# torrents, so the seven-day rule can be checked against time travel instead of
# against whatever happens to be downloading today.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-stalled.ps1

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

$cfg = [System.IO.File]::ReadAllText((Get-ProjectFile 'config.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json

$src = [System.IO.File]::ReadAllText((Get-ProjectFile 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)
$s = $src.IndexOf('$script:boundaryPattern')
$e = $src.IndexOf('# actions')
if ($s -lt 0 -or $e -le $s) { throw 'could not locate the detection block' }
Invoke-Expression $src.Substring($s, $e - $s)

$script:fails = 0
function Check {
    param([string]$label, [bool]$ok)
    if ($ok) { "  [PASS] $label" } else { $script:fails++; "  [FAIL] $label" }
}

$NOW = [datetime]'2026-10-04 12:00:00'

function T {
    param(
        [string]$Hash,
        [string]$State = 'stalledDL',
        [double]$Completed = 1GB,
        [double]$Total = 10GB,
        [double]$Progress = 0.1,
        $LastActivity,
        $AddedOn
    )
    $p = [ordered]@{
        hash = $Hash; name = "Torrent $Hash"; state = $State
        completed = [int64]$Completed; total_size = [int64]$Total
        amount_left = [int64]($Total - $Completed); progress = $Progress
        last_activity = $LastActivity; added_on = $AddedOn
    }
    return [pscustomobject]$p
}
function Unix { param([datetime]$D) [int64][DateTimeOffset]::new($D.ToUniversalTime()).ToUnixTimeSeconds() }
function Days { param([double]$D) [math]::Round($D, 1) }
function Row { param($Rows, [string]$Hash) @($Rows | Where-Object { $_.Hash -eq $Hash })[0] }

# -- 1. a torrent first seen 10 days after its last byte ---------------------

$st = [pscustomobject]@{}
$rows = @(Get-StalledWatch -Torrents @(T -Hash 'a' -LastActivity (Unix ($NOW.AddDays(-10))) -AddedOn (Unix ($NOW.AddDays(-20)))) -Stalled $st -Now $NOW)
Check 'first sighting seeds the clock from last_activity' ((Days $rows[0].IdleDays) -eq 10.0)
Check 'a torrent idle 10 days is marked for deletion'    $rows[0].WillDelete
Check 'one row per eligible torrent'                     ($rows.Count -eq 1)

# -- 2. first sighting, but it was active an hour ago -----------------------

$st = [pscustomobject]@{}
$rows = @(Get-StalledWatch -Torrents @(T -Hash 'b' -LastActivity (Unix ($NOW.AddHours(-1))) -AddedOn (Unix ($NOW.AddDays(-30)))) -Stalled $st -Now $NOW)
Check 'a torrent active an hour ago is not stalled'  (-not $rows[0].WillDelete)
Check 'it is left with the whole 7 days'             ((Days $rows[0].Remaining) -eq 7.0)

# -- 3. the table remembers, and a byte resets the clock --------------------

$st = [pscustomobject]@{}
$st | Add-Member -NotePropertyName 'c' -NotePropertyValue ([pscustomobject]@{
    lastProgressAt = $NOW.AddDays(-9).ToString('o'); bytes = [int64]1GB })
$rows = @(Get-StalledWatch -Torrents @(T -Hash 'c' -Completed 1GB) -Stalled $st -Now $NOW)
Check 'no movement for 9 days is a deletion'          $rows[0].WillDelete
Check 'the byte count is what decides, not the clock' ((Days $rows[0].IdleDays) -eq 9.0)

$rows = @(Get-StalledWatch -Torrents @(T -Hash 'c' -Completed 2GB) -Stalled $st -Now $NOW)
Check 'one extra byte resets the clock'               (-not $rows[0].WillDelete)
Check 'after the reset it has the full 7 days back'   ((Days $rows[0].Remaining) -eq 7.0)
Check 'and the stored byte count moved with it'       ($st.c.bytes -eq [int64]2GB)

# -- 4. states that must never be judged ------------------------------------

$paused = T -Hash 'p' -State 'pausedDL'  -LastActivity (Unix ($NOW.AddDays(-30))) -AddedOn (Unix ($NOW.AddDays(-30)))
$stopd  = T -Hash 's' -State 'stoppedDL' -LastActivity (Unix ($NOW.AddDays(-30))) -AddedOn (Unix ($NOW.AddDays(-30)))
$magnet = T -Hash 'm' -State 'metaDL' -Completed 0 -Total 0 -Progress 0 -LastActivity (Unix ($NOW.AddDays(-30))) -AddedOn (Unix ($NOW.AddDays(-30)))
$done   = T -Hash 'd' -Completed 10GB -Total 10GB -Progress 1 -State 'stoppedUP' -LastActivity (Unix ($NOW.AddDays(-30))) -AddedOn (Unix ($NOW.AddDays(-30)))

$st = [pscustomobject]@{}
$rows = @(Get-StalledWatch -Torrents @($paused, $stopd, $magnet, $done) -Stalled $st -Now $NOW)
Check 'a torrent the user paused is left alone'      ($rows.Count -eq 0)
Check 'paused and stopped leave no table entry'      ($st.PSObject.Properties.Name.Count -eq 0)

# -- 5. a paused torrent already in the table stops being counted -----------

$st = [pscustomobject]@{}
$st | Add-Member -NotePropertyName 'p' -NotePropertyValue ([pscustomobject]@{
    lastProgressAt = $NOW.AddDays(-90).ToString('o'); bytes = [int64]1GB })
[void]@(Get-StalledWatch -Torrents @($paused) -Stalled $st -Now $NOW)
Check 'a paused torrent is dropped from the table'   ($st.PSObject.Properties.Name.Count -eq 0)

# -- 6. clock skew must not age a brand new torrent -----------------------

$st = [pscustomobject]@{}
$future = T -Hash 'f' -LastActivity (Unix ($NOW.AddDays(3))) -AddedOn (Unix ($NOW.AddHours(-1)))
$rows = @(Get-StalledWatch -Torrents @($future) -Stalled $st -Now $NOW)
Check 'a last_activity in the future is clamped'     ((Days $rows[0].IdleDays) -eq 0.0)
Check 'so a skewed clock cannot delete it'           (-not $rows[0].WillDelete)

$st = [pscustomobject]@{}
$early = T -Hash 'e' -LastActivity (Unix ($NOW.AddDays(-30))) -AddedOn (Unix ($NOW.AddDays(-2)))
$rows = @(Get-StalledWatch -Torrents @($early) -Stalled $st -Now $NOW)
Check 'last_activity before added_on is ignored'     ((Days $rows[0].IdleDays) -eq 2.0)
Check 'a torrent added 2 days ago is not stalled yet' (-not $rows[0].WillDelete)
Check 'and it keeps the remaining 5 days'            ((Days $rows[0].Remaining) -eq 5.0)

# -- 7. the boundary is inclusive ------------------------------------------

$st = [pscustomobject]@{}
$exact = T -Hash 'x' -LastActivity (Unix ($NOW.AddDays(-7))) -AddedOn (Unix ($NOW.AddDays(-40)))
$rows = @(Get-StalledWatch -Torrents @($exact) -Stalled $st -Now $NOW)
Check 'exactly 7.0 days is a deletion'               $rows[0].WillDelete

$st = [pscustomobject]@{}
$under = T -Hash 'y' -LastActivity (Unix ($NOW.AddDays(-6.9))) -AddedOn (Unix ($NOW.AddDays(-40)))
$rows = @(Get-StalledWatch -Torrents @($under) -Stalled $st -Now $NOW)
Check '6.9 days is still kept'                       (-not $rows[0].WillDelete)

# -- 8. the table is pruned so it cannot grow forever ----------------------

$st = [pscustomobject]@{}
foreach ($h in 'gone1', 'gone2') {
    $st | Add-Member -NotePropertyName $h -NotePropertyValue ([pscustomobject]@{
        lastProgressAt = $NOW.ToString('o'); bytes = [int64]0 })
}
$st | Add-Member -NotePropertyName 'stay' -NotePropertyValue ([pscustomobject]@{
    lastProgressAt = $NOW.ToString('o'); bytes = [int64]0 })
[void]@(Get-StalledWatch -Torrents @(T -Hash 'stay') -Stalled $st -Now $NOW)
Check 'entries for departed torrents are pruned'     ($st.PSObject.Properties.Name.Count -eq 1)
Check 'and the live one is kept'                     ($st.PSObject.Properties.Name -contains 'stay')

# -- 9. the rule can be switched off ---------------------------------------

$st = [pscustomobject]@{}
$saved = $cfg.stalledDeleteDays
$cfg.stalledDeleteDays = 0
$rows = @(Get-StalledWatch -Torrents @(T -Hash 'off' -LastActivity (Unix ($NOW.AddDays(-90))) -AddedOn (Unix ($NOW.AddDays(-90)))) -Stalled $st -Now $NOW)
Check 'stalledDeleteDays = 0 disables the rule'      ($rows.Count -eq 0)
$cfg.stalledDeleteDays = $saved

# -- 10. a completed torrent cannot be stalled ---------------------------

$st = [pscustomobject]@{}
$rows = @(Get-StalledWatch -Torrents @(T -Hash 'k' -Completed 10GB -Total 10GB -Progress 1 -State 'uploading' -LastActivity (Unix ($NOW.AddDays(-90))) -AddedOn (Unix ($NOW.AddDays(-90)))) -Stalled $st -Now $NOW)
Check 'a seeding torrent is never judged stalled'    ($rows.Count -eq 0)

''
if ($script:fails -eq 0) { 'all stalled-rule tests passed' }
else { "$($script:fails) test(s) FAILED"; exit 1 }