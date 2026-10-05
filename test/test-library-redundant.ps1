<#
    Exercises Get-LibraryRedundantVerdicts (rule 4d), lifted out of
    qbt-manager.ps1 against a real temp folder tree.

    The rule, as the user stated it: an in-progress download whose FINAL size is
    within 10% of a finished copy already in the library - smaller, equal, or up
    to 10% bigger - is redundant and should be discarded as soon as its size is
    known, not after it finishes.

    Two properties are the whole point and are tested hardest:

      - it reads `size`, never `completed`. A download at 0% must be caught; a
        rule that waited for progress would be useless.
      - it is measured against the LIBRARY, because rule 4 cannot compare across
        release groups whose show names differ.

    And the boundary matters: 9.9% bigger is redundant, 10.1% bigger is not. A
    46 MB difference destroyed an eight-episode pack once, so the tolerance edge
    is pinned from both sides.

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-library-redundant.ps1
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

$src = [System.IO.File]::ReadAllText((Get-ProjectFile 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)
$s = $src.IndexOf('$script:boundaryPattern')
$e = $src.IndexOf('# actions')
if ($s -lt 0 -or $e -le $s) { throw 'could not locate the helper block in qbt-manager.ps1' }
Invoke-Expression $src.Substring($s, $e - $s)

$script:fails = 0
function Check {
    param([string]$Label, [bool]$Ok)
    # Write-Host, not a bare string. A bare string goes to the success stream and
    # the host stream separately, so the two interleave out of order the moment a
    # diagnostic uses Write-Host - which made three real failures look like they
    # belonged to a later section, and sent me hunting in the wrong place.
    if ($Ok) { Write-Host "  [PASS] $Label" } else { $script:fails++; Write-Host "  [FAIL] $Label" }
}

# KB. The rule compares sizes as a ratio, so the absolute scale is irrelevant and
# the suite stays tiny. See test-library-dedupe.ps1 for what happens otherwise.
$lib = Join-Path $env:TEMP ('redundant-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$films = Join-Path $lib 'Filmes'
$seriesDir = Join-Path $lib 'Séries'
$s18 = Join-Path (Join-Path $seriesDir 'its always sunny in philadelphia') 'Season 18'
New-Item -ItemType Directory -Path $films -Force | Out-Null
New-Item -ItemType Directory -Path $s18 -Force | Out-Null
$script:roots = @($lib)

function New-Episode {
    param([int]$Episode, [int]$KB = 1600, [string]$Season = 'Season 18')
    $dir = Join-Path $seriesDir "its always sunny in philadelphia\$Season"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $p = Join-Path $dir ("Its.Always.Sunny.in.Philadelphia.S18E{0:D2}.1080p.WEB-DL.x264-GRP.mkv" -f $Episode)
    $fs = [System.IO.File]::Create($p); $fs.SetLength([int64]$KB * 1KB); $fs.Close()
    return $p
}

# A download in progress. $SizeKB is what it will finish at - the number the rule
# reads. $Progress is deliberately independent of it.
function Dl {
    param(
        [string]$Hash,
        [string]$Name,
        [int]$SizeKB,
        [double]$Progress = 0.0,
        [string]$Path = ''
    )
    $p = $null
    try { $p = Get-TitleParts -Name $Name } catch { $p = $null }
    return [pscustomobject][ordered]@{
        hash = $Hash; name = $Name; content_path = $Path; progress = $Progress
        size = [int64]$SizeKB * 1KB; total_size = [int64]$SizeKB * 1KB
        completed = [int64]($SizeKB * 1KB * $Progress)
        state = 'downloading'; num_seeds = 1; num_leechs = 1; added_on = 0
        parts = $p
    }
}

function Judge {
    param([object[]]$Torrents, [double]$Tol = 10)
    return @(Get-LibraryRedundantVerdicts -Torrents $Torrents -MoviesDir $films -SeriesDir $seriesDir -TolerancePercent $Tol)
}


Write-Host ''
Write-Host '== the shipped config =='
Check 'the rule is enabled'          ($cfg.libraryRedundantEnabled -eq $true)
Check 'the tolerance is 10 percent'  ($cfg.libraryRedundantTolerancePercent -eq 10)

Write-Host ''
Write-Host '== the case the user reported =='
# Kitsune S18E06 at 1,64 GB, library copy at 1,64 GB, download 84% done.
$null = New-Episode -Episode 6 -KB 1680
$kitsune = Dl 'r1' 'Its Always Sunny in Philadelphia S18E06 The War on Alcohol 1080p AMZN WEB-DL DDP5 1 H 264-Kitsune [ext.to]' 1680 0.84
$r = Judge @($kitsune)
Check 'a download the same size as the library copy is deleted' (@(@($r)).Count -eq 1)
# The expected strings are computed from the objects, not typed in. The first
# version hardcoded '1,68 GB' for a 1680 KB file, which is 1,60 GB - a test that
# fails on my arithmetic rather than on the rule. And because the two sizes are
# equal here, the same literal cannot prove both appear: the two clauses are
# checked separately, by the words that introduce them.
$wantLib = '{0:N2} GB' -f ($r[0].LibBytes / 1GB)
$wantDl = '{0:N2} GB' -f ([double]$kitsune.size / 1GB)
Check 'the reason states the library size' ($r[0].Reason -match ('already has [^\r\n]*' + [regex]::Escape($wantLib)))
Check 'the reason states what it will finish at' ($r[0].Reason -match ('will finish at ' + [regex]::Escape($wantDl)))
Check 'and the two really are equal here' (($r[0].LibBytes -eq [int64]$kitsune.size))
Check 'the reason names the tolerance'   ($r[0].Reason -match '10%')
Check 'and the library file it matched'  ($r[0].Reason -match 'S18E6')

Write-Host ''
Write-Host '== it acts on FINAL size, at 0% =='
# The whole point: the download never happens. Four torrents at 0% with no bytes
# fetched, all matching a library episode.
$null = New-Episode -Episode 2 -KB 1600
$atZero = @(
    (Dl 'z1' 'Its Always Sunny in Philadelphia S18E02 Something 1080p AMZN WEB-DL x264-A [ext.to]' 1600 0.0)
    (Dl 'z2' 'Its Always Sunny in Philadelphia S18E02 Other 1080p AMZN WEB-DL x264-B [ext.to]' 1500 0.0)
    (Dl 'z3' 'Its Always Sunny in Philadelphia S18E02 Third 1080p AMZN WEB-DL x264-C [ext.to]' 1680 0.0)
)
$r = Judge $atZero
Check 'all three are deleted at 0% downloaded' (@(@($r)).Count -eq 3)
Check 'and the reason says what it will finish at' ($r[0].Reason -match 'will finish at')

Write-Host ''
Write-Host '== the tolerance boundary, pinned from both sides =='
$base = 1600
# exactly equal
$r = Judge @((Dl 'b1' 'Its Always Sunny in Philadelphia S18E02 Eq 1080p x264 [ext.to]' $base))
Check 'an identical size is redundant' (@(@($r)).Count -eq 1)

# 9% bigger - inside
$r = Judge @((Dl 'b2' 'Its Always Sunny in Philadelphia S18E02 Nine 1080p x264 [ext.to]' ([int]($base * 1.09))))
Check '9% bigger is still redundant' (@(@($r)).Count -eq 1)

# 11% bigger - outside
$r = Judge @((Dl 'b3' 'Its Always Sunny in Philadelphia S18E02 Eleven 1080p x264 [ext.to]' ([int]($base * 1.11))))
Check '11% bigger is KEPT - it may be the better copy' (@(@($r)).Count -eq 0)

# 50% smaller - inside, and must be caught
$r = Judge @((Dl 'b4' 'Its Always Sunny in Philadelphia S18E02 Half 1080p x264 [ext.to]' ([int]($base * 0.5))))
Check '50% smaller is redundant' (@(@($r)).Count -eq 1)

# a much bigger download - kept, it is probably 2160p
$r = Judge @((Dl 'b5' 'Its Always Sunny in Philadelphia S18E02 UHD 2160p x264 [ext.to]' ($base * 4)))
Check 'a 4x bigger download is kept' (@(@($r)).Count -eq 0)

Write-Host ''
Write-Host '== the tolerance is configurable =='
$r = Judge @((Dl 'c1' 'Its Always Sunny in Philadelphia S18E02 Eleven 1080p x264 [ext.to]' ([int]($base * 1.11)))) 25
Check 'at 25% the same download is redundant' (@(@($r)).Count -eq 1)
$r = Judge @((Dl 'c2' 'Its Always Sunny in Philadelphia S18E02 Eq 1080p x264 [ext.to]' $base)) 0
Check 'at 0% only an equal-or-smaller size is redundant' (@(@($r)).Count -eq 1)
$r = Judge @((Dl 'c3' 'Its Always Sunny in Philadelphia S18E02 Eq 1080p x264 [ext.to]' ([int]($base * 1.01)))) 0
Check 'and 1% bigger is not' (@(@($r)).Count -eq 0)

Write-Host ''
Write-Host '== packs are NOT judged by this rule =='
# A pack's total is not a per-episode quantity. Summing the library's individual
# episode files and holding that against a pack's total is not a comparison - it
# is total against total, dressed up as an episode-level measurement.
#
# The first version of this rule did exactly that, and these checks assert the
# opposite on purpose: every one of these packs is KEPT, however far under the sum
# it falls.
foreach ($ep in 1..4) { $null = New-Episode -Episode 7 -KB 1600 }
$packTotal = 4 * 1600

$r = Judge @((Dl 'p1' 'Its.Always.Sunny.in.Philadelphia S18E01-E04.1080p.WEB-DL.x264-P1 [ext.to]' $packTotal 0.0))
Check 'a pack exactly matching the summed episodes is KEPT' (@(@($r)).Count -eq 0)

# The dangerous case: a pack far smaller than the sum of its own episodes. Under
# the old rule this was deleted as "redundant"; a pack can easily total less than
# separate files of the same episodes, and that is not evidence of redundancy.
$r = Judge @((Dl 'p2' 'Its.Always.Sunny.in.Philadelphia S18E01-E04.1080p.WEB-DL.x264-P2 [ext.to]' 100 0.0))
Check 'a pack a fraction of the summed size is KEPT' (@(@($r)).Count -eq 0)

$r = Judge @((Dl 'p3' 'Its.Always.Sunny.in.Philadelphia S18E01-E04.2160p.WEB-DL.x264-P3 [ext.to]' ([int]($packTotal * 1.3)) 0.0))
Check 'a pack 30% over the sum is KEPT' (@(@($r)).Count -eq 0)

# A pack reaching an episode the library lacks, and a whole-season pack.
$r = Judge @((Dl 'p4' 'Its.Always.Sunny.in.Philadelphia S18E01-E06.1080p.WEB-DL.x264-P4 [ext.to]' 1000 0.0))
Check 'a pack reaching an episode the library lacks is KEPT' (@(@($r)).Count -eq 0)
$r = Judge @((Dl 'p5' 'Its.Always.Sunny.In.Philadelphia.S18.1080p.WEB-DL.x264-P5 [ext.to]' 1000 0.0))
Check 'a whole-season pack is KEPT' (@(@($r)).Count -eq 0)

# And a SINGLE of the same episode IS still judged - the rule is narrowed to
# singles, not switched off.
$r = Judge @((Dl 'p6' 'Its.Always.Sunny.in.Philadelphia S18E07 Single 1080p x264-P6 [ext.to]' 1600 0.0))
Check 'a single of an episode the library has is still judged' (@(@($r)).Count -eq 1)

Write-Host ''
Write-Host '== what it must never touch =='
# Complete: rule 4b compares finished files in the library instead.
$r = Judge @((Dl 'x1' 'Its Always Sunny in Philadelphia S18E02 Done 1080p x264 [ext.to]' 1600 1.0))
Check 'a COMPLETE download is not this rule''s business' (@(@($r)).Count -eq 0)

# A magnet: size 0 means UNKNOWN, not small. This must never be read as "smaller
# than the library copy", or every magnet on the machine is deleted on sight.
$r = Judge @((Dl 'x2' 'Its Always Sunny in Philadelphia S18E02 Magnet [ext.to]' 0 0.0))
Check 'a magnet with size 0 is never called smaller' (@(@($r)).Count -eq 0)

# An episode the library does not have at all.
$r = Judge @((Dl 'x3' 'Its Always Sunny in Philadelphia S18E09 Missing 1080p x264 [ext.to]' 1600 0.0))
Check 'an episode the library lacks is left alone' (@(@($r)).Count -eq 0)

# Unidentified.
$unk = Dl 'x4' '@@@@ [ext.to]' 1600 0.0
$unk.parts = $null
Check 'an unidentified download is never judged' (@(Judge @($unk)).Count -eq 0)

# Its OWN library file. A completed-then-moved torrent whose folder is in the
# library must not be compared against its own data.
$null = New-Episode -Episode 7 -KB 1600
$own = Dl 'x5' 'Its.Always.Sunny.in.Philadelphia S18E07.1080p.WEB-DL.x264-OWN [ext.to]' 1600 0.0 $s18
Check 'a download is never compared against its own library file' (@(Judge @($own)).Count -eq 0)

# And the guard is doing the work rather than the rule comparing nothing at all:
# the same torrent, pointed somewhere else, IS flagged.
$elsewhere = Dl 'x6' 'Its.Always.Sunny.in.Philadelphia S18E07.1080p.WEB-DL.x264-OTH [ext.to]' 1600 0.0 (Join-Path $env:TEMP 'elsewhere-entirely')
Check 'the same torrent IS flagged when it does not own the file' (@(Judge @($elsewhere)).Count -eq 1)

# Already removed by an earlier rule this run.
Check 'something deleted earlier this run is skipped' `
    (@(Get-LibraryRedundantVerdicts -Torrents @($kitsune) -MoviesDir $films -SeriesDir $seriesDir `
                                      -TolerancePercent 10 -Gone @{ r1 = $true }).Count -eq 0)

Write-Host ''
Write-Host '== films =='
$fp = Join-Path $films 'A Kept Film.mkv'
$fs = [System.IO.File]::Create($fp); $fs.SetLength([int64]4000 * 1KB); $fs.Close()
$r = Judge @((Dl 'f1' 'A Kept Film 1999 1080p BluRay x264-GRP [ext.to]' 4000 0.0))
Check 'a film matching a library film is deleted' (@(@($r)).Count -eq 1)
$r = Judge @((Dl 'f2' 'An Unkept Film 2001 1080p BluRay x264-GRP [ext.to]' 4000 0.0))
Check 'a film with no library copy is left alone'  (@(@($r)).Count -eq 0)

Write-Host ''
Write-Host '== rule 4 still compares packs, by exact range =='
# The pack-to-pack comparison this rule gave up is not lost: it lives in rule 4,
# keyed on the episode SET, which requires identical ranges. This asserts the key
# behaves that way, because the narrowing above is only safe if rule 4 covers it.
$s18key = Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Its.Always.Sunny.in.Philadelphia S18E01-E06.1080p x264-GRP [ext.to]')
$s18key2 = Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Other Show S18E01-E06 1080p x264-OTH [ext.to]')
$s18keyShort = Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Its.Always.Sunny.in.Philadelphia S18E01-E04.1080p x264-GRP [ext.to]')
Check 'the same range produces the same key'      ($s18key -eq 'S18-E1-E6')
Check 'an identical range of another show too'    ($s18key2 -eq 'S18-E1-E6')
Check 'a DIFFERENT range produces a different key' ($s18keyShort -ne $s18key)
Check 'and a single episode is never a pack key'  ((Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Its.Always.Sunny.in.Philadelphia S18E01 1080p x264-GRP [ext.to]')) -eq 'S18-E1')

Write-Host ''
Write-Host '== the call site removes the partial data =='
# The rule stops a download nobody wanted, so the bytes already fetched for it
# are waste too. Asserted against the source because the function never deletes.
$runStart = $src.IndexOf('Redundant download check')
Check 'the redundant pass was found in the run body' ($runStart -gt 0)
if ($runStart -gt 0) {
    $runBody = $src.Substring($runStart, 3000)
    Check 'the call deletes the torrent AND its data' `
        ($runBody -match 'Remove-Torrent -T \$r\.Torrent -Reason \$r\.Reason -DeleteFiles \$true')
    # SINGLE quotes. In a double-quoted PowerShell string `\$` does not escape the
    # dollar - the backslash is literal and $r interpolates away - so the pattern
    # silently becomes a string that matches nothing, and the check fails while the
    # code is correct.
    $stopPat = 'torrents/stop'' -Fields @\{ hashes = \$r\.Torrent\.hash \}'
    Check 'and it is stopped first' ($runBody -match $stopPat)
}

# ---------------------------------------------------------------------------
# cleanup
# ---------------------------------------------------------------------------
foreach ($x in $script:roots) {
    if (Test-Path -LiteralPath $x) { Remove-Item -LiteralPath $x -Recurse -Force -ErrorAction SilentlyContinue }
}
$mine = 0
foreach ($x in $script:roots) { if (Test-Path -LiteralPath $x) { $mine++ } }
Check 'every tree it created is gone' ($mine -eq 0)

Write-Host ''
if ($script:fails -eq 0) {
    Write-Host 'all library-redundant tests passed'
}
else {
    Write-Host ("{0} library-redundant test(s) FAILED" -f $script:fails)
    exit 1
}
