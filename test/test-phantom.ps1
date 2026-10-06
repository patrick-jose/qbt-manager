<#
    Exercises Get-PhantomVerdicts (rule 4c), lifted out of qbt-manager.ps1
    against a real temp folder tree.

    A phantom is a torrent that reports 100% over data that is not on disk. The
    rule removes the entry, but ONLY when every episode it claimed is verifiably
    present in the library. That condition is the whole point: deleting any
    finished torrent whose folder happens to be missing would destroy the only
    record of a season whose data was merely unreachable - a detached drive, a
    permissions problem, a folder someone moved by hand.

    So the tests are mostly about what it must NOT do.

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-phantom.ps1
#>

$ErrorActionPreference = 'Stop'
if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
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

# The whole helper block: the rule calls Get-TitleParts and Get-LibraryEpisodeFiles,
# both of which are defined earlier in the file than the rule is.
$src = [System.IO.File]::ReadAllText((Get-ProjectFile 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)
$s = $src.IndexOf('$script:boundaryPattern')
$e = $src.IndexOf('# actions')
if ($s -lt 0 -or $e -le $s) { throw 'could not locate the helper block in qbt-manager.ps1' }
Invoke-Expression $src.Substring($s, $e - $s)

$script:fails = 0
function Check {
    param([string]$Label, [bool]$Ok)
    if ($Ok) { "  [PASS] $Label" } else { $script:fails++; "  [FAIL] $Label" }
}

$script:roots = @()

# A library tree. Films go to one folder, series to per-show/season folders.
$lib = Join-Path $env:TEMP ('phantom-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$films = Join-Path $lib 'Filmes'
$s18 = Join-Path (Join-Path (Join-Path $lib 'Séries') 'its always sunny in philadelphia') 'Season 18'
New-Item -ItemType Directory -Path $films -Force | Out-Null
New-Item -ItemType Directory -Path $s18 -Force | Out-Null
$script:roots += $lib

# KB, not MB. See test-library-dedupe.ps1: a test that creates real gigabytes on a
# machine with a nearly full disk is a test that can fill it.
function New-Episode {
    param([int]$Episode, [int]$KB = 1500, [string]$Show = 'Its.Always.Sunny.in.Philadelphia')
    $dir = $s18
    if ($Show -ne 'Its.Always.Sunny.in.Philadelphia') {
        $dir = Join-Path (Join-Path (Join-Path $lib 'Séries') $Show) 'Season 18'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $p = Join-Path $dir ("{0}.S18E{1:D2}.1080p.WEB-DL.x264-GRP.mkv" -f $Show, $Episode)
    $fs = [System.IO.File]::Create($p); $fs.SetLength([int64]$KB * 1KB); $fs.Close()
    return $p
}
function New-Film {
    param([string]$Title)
    $p = Join-Path $films ($Title + '.mkv')
    $fs = [System.IO.File]::Create($p); $fs.SetLength([int64]4000 * 1KB); $fs.Close()
    return $p
}

# A finished torrent whose content_path points at a folder that does not exist.
function Phantom {
    param(
        [string]$Hash,
        [string]$Name,
        [string]$Path,
        [double]$Progress = 1.0
    )
    $p = $null
    try { $p = Get-TitleParts -Name $Name } catch { $p = $null }
    return [pscustomobject][ordered]@{
        hash = $Hash; name = $Name; content_path = $Path; progress = $Progress
        size = [int64]12000000000; total_size = [int64]12000000000
        state = 'stoppedUP'; num_seeds = 0; num_leechs = 0; added_on = 0
        parts = $p
    }
}

function Judge {
    param([object[]]$Torrents)
    return @(Get-PhantomVerdicts -Torrents $Torrents -MoviesDir $films -SeriesDir (Join-Path $lib 'Séries'))
}
function Deletes { param($Rows) @($Rows | Where-Object { $_.Action -eq 'delete' }) }
function Holds   { param($Rows) @($Rows | Where-Object { $_.Action -eq 'hold' }) }

$missing18 = Join-Path (Join-Path $lib 'Séries') 'its always sunny in philadelphia\Season 18\gone-entirely'
$missingFilm = Join-Path $films 'Gone Film'

Write-Host ''
Write-Host '== the shipped config =='
Check 'phantom cleanup is enabled'  ($cfg.phantomCleanupEnabled -eq $true)

Write-Host ''
Write-Host '== the case the rule is for =='
# The Ultradox pack: S18E01-E07, reported 100%, folder long gone. The library
# holds all seven episodes, so the entry is pure fiction and goes.
foreach ($ep in 1..7) { $null = New-Episode -Episode $ep }
$ultradox = Phantom 'ph1' 'Its.Always.Sunny.In.Philadelphia.S18E01-E07.400p.Ru.Ultradox [ext.to]' $missing18
$r = Judge @($ultradox)
Check 'a phantom with its episodes all in the library is deleted' (@(Deletes $r).Count -eq 1)
Check 'and it is the only verdict'                          (@($r).Count -eq 1)
Check 'the reason says phantom'                             ($r[0].Reason -match 'phantom')
Check 'the reason names the library episodes'              ($r[0].Reason -match 'S18E1')
Check 'the reason says the data is gone'                   ($r[0].Reason -match 'gone')

Write-Host ''
Write-Host '== the one case that must NEVER delete =='
# One episode of the range is missing from the library. The entry is then the
# ONLY record that episode ever existed, and the data may be recoverable.
#
# The range is E01-E08 while the library holds only E01-E07, so E08 is genuinely
# absent. Claiming E01-E07 here - the same range as the case above - would prove
# nothing, because every episode in it is present.
$other18 = Join-Path (Join-Path $lib 'Séries') 'its always sunny in philadelphia\Season 18\also-gone'
$partial = Phantom 'ph2' 'Its.Always.Sunny.In.Philadelphia.S18E01-E08.400p.Ru.Ultradox [ext.to]' $other18
$r = Judge @($partial)
Check 'a phantom missing one episode is NOT deleted'  (@(Deletes $r).Count -eq 0)
Check 'it is held instead'                            (@(Holds $r).Count -eq 1)
Check 'the hold names the missing episode'            ($r[0].Reason -match 'S18E8')
Check 'the hold says the entry is the only record'    ($r[0].Reason -match 'only record')

# The mirror image: hold one episode back and nothing goes.
$held18 = Join-Path (Join-Path $lib 'Séries') 'its always sunny in philadelphia\Season 18\third-gone'
$all8 = Join-Path (Join-Path (Join-Path $lib 'Séries') 'its always sunny in philadelphia') 'Season 18\aardvark'
foreach ($ep in 1..8) { $null = New-Episode -Episode $ep }
$range8 = Phantom 'ph3' 'Its.Always.Sunny.In.Philadelphia.S18E01-E08.400p.Ru.Ultradox [ext.to]' $all8
Check 'a full range with every episode present is deleted' (@(Deletes (Judge @($range8))).Count -eq 1)

Write-Host ''
Write-Host '== what is not a phantom =='
# Still downloading: its folder is being written to.
$live = Phantom 'ph4' 'Its.Always.Sunny.In.Philadelphia.S18E01.1080p.WEB-DL.x264-GRP [ext.to]' `
        (Join-Path (Join-Path (Join-Path $lib 'Séries') 'its always sunny in philadelphia') 'Season 18\incoming') 0.42
Check 'an incomplete download is never a phantom'  (@(Judge @($live)).Count -eq 0)

# Finished, and its data really is there.
$real = Phantom 'ph5' 'Its.Always.Sunny.In.Philadelphia.S18E01.1080p.WEB-DL.x264-GRP [ext.to]' $s18 1.0
Check 'a finished torrent whose folder exists is left alone' (@(Judge @($real)).Count -eq 0)

# Finished, but the folder it claims is in staging, not the library. That is the
# reaper's business, not this rule's.
$staging = Join-Path $lib 'temp\some-incomplete-folder'
New-Item -ItemType Directory -Path $staging -Force | Out-Null
$inTemp = Phantom 'ph6' 'Its.Always.Sunny.In.Philadelphia.S18E01.1080p.WEB-DL.x264-GRP [ext.to]' (Join-Path $staging 'x') 1.0
Check 'a missing path under staging is not this rule''s business' (@(Judge @($inTemp)).Count -eq 0)

# No content_path at all: a magnet. Nothing to verify, nothing claimed.
$magnet = Phantom 'ph7' 'Some Magnet [ext.to]' '' 1.0
Check 'a torrent with no content_path is never a phantom' (@(Judge @($magnet)).Count -eq 0)

# Unidentified: the episodes it held cannot be derived, so nothing is verifiable.
$unknown = Phantom 'ph8' '@@@@ [ext.to]' $missing18 1.0
$unknown.parts = $null
Check 'an unidentified finished torrent is never a phantom' (@(Judge @($unknown)).Count -eq 0)

Write-Host ''
Write-Host '== a shared folder is never touched =='
# Two torrents claiming the same path: the folder is not this one's to remove,
# and the data may belong to the other.
$shared = Join-Path (Join-Path (Join-Path $lib 'Séries') 'its always sunny in philadelphia') 'Season 18\shared-name'
$a = Phantom 'pha' 'Its.Always.Sunny.In.Philadelphia.S18E01-E07.400p.Ru.Ultradox [ext.to]' $shared
$b = Phantom 'phb' 'Its.Always.Sunny.In.Philadelphia.S18E01-E07.400p.Ru.Other [ext.to]' $shared
$r = Judge @($a, $b)
Check 'neither of two torrents sharing a path is deleted' (@(Deletes $r).Count -eq 0)
Check 'both are held'                                   (@(Holds $r).Count -eq 2)
Check 'and the hold says why'                            ($r[0].Reason -match 'other torrent')

Write-Host ''
Write-Host '== films =='
$null = New-Film -Title 'A Replacement Film'
$filmOk = Phantom 'phf1' 'A Replacement Film 1999 1080p BluRay x264-GRP [ext.to]' $missingFilm
$r = Judge @($filmOk)
Check 'a film whose replacement is in the library is deleted' (@(Deletes $r).Count -eq 1)

$filmNo = Phantom 'phf2' 'An Unreplaced Film 2001 1080p BluRay x264-GRP [ext.to]' $missingFilm
$r = Judge @($filmNo)
Check 'a film with no replacement is held'                  (@(Deletes $r).Count -eq 0)
Check 'and the hold says nothing replaced it'               ($r[0].Reason -match 'nothing has replaced')

Write-Host ''
Write-Host '== a real episode range, not a single =='
# The Ultradox case exactly: E01-E07, all seven present.
$r = Judge @($ultradox)
Check 'a seven-episode range is recognised as a range' ($r[0].Reason -match 'S18E1-E7')

Write-Host ''
Write-Host '== the call site must delete the ENTRY only =='
# Everything above exercises Get-PhantomVerdicts, which decides but never deletes.
# The dangerous half - whether the files go with the entry - lives at the CALL
# SITE, so it is asserted against the source. Verified by flipping $false to $true
# and watching this check fail.
$runStart = $src.IndexOf("Write-Host 'Phantom check")
Check 'the phantom pass was found in the run body' ($runStart -gt 0)
if ($runStart -gt 0) {
    $runBody = $src.Substring($runStart, 2500)
    # The -Knows flag sits between the target and -Reason, so the pattern names
    # the arguments rather than the whole call. A full-call pattern stopped
    # matching the moment -Knows was added, which reads as "the rule changed" when
    # the only change was a flag on a different concern.
    Check 'the call deletes the entry WITHOUT files' `
        ($runBody -match 'Remove-Torrent -T \$p\.Torrent -Knows -Reason \$p\.Reason -DeleteFiles \$false')
    Check 'and never with files' `
        ($runBody -notmatch 'Remove-Torrent -T \$p\.Torrent -Knows -Reason \$p\.Reason -DeleteFiles \$true')
    # SINGLE quotes below, and not by habit. In a double-quoted PowerShell string
    # `\$` does not escape the dollar - the backslash is literal, $p then
    # interpolates away, and the pattern silently becomes
    # "torrents/stop' -Fields @{ hashes = \.Torrent\.hash }", which matches
    # nothing. That made this check fail while the code was perfectly correct.
    # A comment must also not sit between a backtick continuation and its
    # expression, or the continuation is broken.
    $stopPat = 'torrents/stop'' -Fields @\{ hashes = \$p\.Torrent\.hash \}'
    Check 'the phantom is stopped before it is removed' ($runBody -match $stopPat)
}

Write-Host ''
Write-Host '== nothing else is disturbed =='
# A healthy library: no torrent is a phantom and nothing is proposed.
$healthy = @(
    (Phantom 'ok1' 'Its.Always.Sunny.In.Philadelphia.S18E01.1080p.WEB-DL.x264-GRP [ext.to]' $s18 1.0)
    (Phantom 'ok2' 'Its.Always.Sunny.In.Philadelphia.S18E02.1080p.WEB-DL.x264-GRP [ext.to]' $s18 0.5)
)
Check 'a healthy library proposes nothing' (@(Judge $healthy).Count -eq 0)

# A missing library folder is not an error.
$noLib = Join-Path $env:TEMP ('no-such-library-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
Check 'a missing library folder yields nothing' `
    (@(Get-PhantomVerdicts -Torrents @($ultradox) -MoviesDir $noLib -SeriesDir $noLib).Count -eq 0)

# ---------------------------------------------------------------------------
# cleanup
# ---------------------------------------------------------------------------
foreach ($r in $script:roots) {
    if (Test-Path -LiteralPath $r) { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}
$mine = 0
foreach ($r in $script:roots) { if (Test-Path -LiteralPath $r) { $mine++ } }
Check 'every tree it created is gone' ($mine -eq 0)

Write-Host ''
if ($script:fails -eq 0) {
    Write-Host 'all phantom tests passed'
}
else {
    Write-Host ("{0} phantom test(s) FAILED" -f $script:fails)
    exit 1
}