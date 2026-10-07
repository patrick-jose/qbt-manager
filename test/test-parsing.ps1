# Exercises Get-TitleParts / Test-SameTitle / DoVi detection lifted out of
# qbt-manager.ps1. Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-parsing.ps1

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

$src = [System.IO.File]::ReadAllText((Get-ProjectFile 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)

$s = $src.IndexOf('$script:boundaryPattern')
$e = $src.IndexOf('function Get-DoviHit')
if ($s -lt 0 -or $e -lt 0) { throw 'could not locate the normalisation block' }
Invoke-Expression $src.Substring($s, $e - $s)

$script:fails = 0
function Check {
    param([string]$label, [bool]$ok)
    if ($ok) { "  [PASS] $label" } else { $script:fails++; "  [FAIL] $label" }
}
function Parts  { param([string]$n) Get-TitleParts -Name $n }
function Same    { param([string]$a, [string]$b) Test-SameTitle -A (Parts $a) -B (Parts $b) }
function Dump    {
    param([string]$n)
    $p = Parts $n
    $short = $n; if ($n.Length -gt 54) { $short = $n.Substring(0, 51) + '...' }
    if (-not $p) { '{0,-54} -> <unidentified>' -f $short; return }
    '{0,-54} -> title="{1}" yr={2} ser={3} S{4}E{5} nums=[{6}]' -f $short, $p.Title, $p.Year, $p.IsSeries, $p.Season, $p.Episode, ($p.Numbers -join ',')
}

$cn = [char]0x5929 + [char]0x624D + [char]0x745E + [char]0x666E + [char]0x5229

$ripley = @(
    'The Talented Mr Ripley 1999 1080p BluRay x264 DTS-WiKi [MovietaM] [ext.to]',
    'The Talented Mr Ripley (1999) (1080i x265 10bit BluRay AC3 5 1) [Prof] [ext.to]',
    'The.Talented.Mr.Ripley.1999.1080p.GER.Blu-ray.REMUX.AVC.DTS-HD.MA.5.1-DIY [ext.to]',
    ($cn + '.The.Talented.Mr.Ripley.1999.1080p.GER.Blu-ray.REMUX.AVC.DTS-HD.MA.5.1-DIY@UBits.mkv'),
    'The Talented mr. Ripley [1999, USA, thriller, drama, crime, Blu-ray disc (custom) 1080i] AVO Vizgunov + Dub + Original eng + Sub rus [ext.to]'
)
$amy = @(
    'Amy 2015 Bluray 1080p TrueHD x264-Grym [ext.to]',
    'Amy.2015.1080p.Chadov.Perevodman.Subs [ext.to]',
    'Amy.2015.2160p.HMAX.WEB-DL.x265.10bit.HDR.DTS-HD.MA.5.1-SWTYBLZ [ext.to]'
)

Write-Host '=== the five Ripley releases (incl. a CJK-prefixed one) ==='
foreach ($n in $ripley) { Dump $n }
$allSame = $true
for ($i = 1; $i -lt $ripley.Count; $i++) { if (-not (Same $ripley[0] $ripley[$i])) { $allSame = $false } }
Check 'all five Ripley releases match each other' $allSame

Write-Host ''
Write-Host '=== the three Amy releases ==='
foreach ($n in $amy) { Dump $n }
$allSameA = $true
for ($i = 1; $i -lt $amy.Count; $i++) { if (-not (Same $amy[0] $amy[$i])) { $allSameA = $false } }
Check 'all three Amy releases match each other' $allSameA
Check 'Ripley never matches Amy' (-not (Same $ripley[0] $amy[0]))

Write-Host ''
Write-Host '=== series: per-episode matching ==='
$series = @(
    'The.Office.US.S01E01.PROPER.1080p.WEB-DL.DD5.1.H.264-CtrlSD',
    'The.Office.S01E01.720p.HDTV.x264-KILLERS',
    'The Office S01E02 720p WEB-DL x264'
)
foreach ($n in $series) { Dump $n }
Check 'classified as SERIES'                ((Parts $series[0]).IsSeries)
Check 'S01E01 releases match despite US vs non-US noise' (Same $series[0] $series[1])
Check 'S01E02 kept separate from S01E01'    (-not (Same $series[0] $series[2]))

Write-Host ''
Write-Host '=== FALSE-POSITIVE GUARDS: these must never match ==='
$guard = @(
    @('The Talented Mr Ripley 1999 1080p BluRay x264', 'The Talented Mr Ripley 2002 1080p BluRay x264', 'different years'),
    @('Terminator 2 Judgment Day 1991 1080p BluRay x264', 'Terminator 3 Rise of Machines 2003 1080p BluRay x264', 'different sequels'),
    @('The Matrix 1999 1080p BluRay x264', 'The Matrix Revolutions 2003 1080p BluRay x264', 'different films in a series'),
    @('Ocean.s.8.2018 1080p BluRay x264', 'Ocean.s.11.2018 1080p BluRay x264', 'different films in a series'),
    @('The Office US S01E01 1080p WEB-DL x264', 'The Office UK S01E01 1080p WEB-DL x264', 'US vs UK remake')
)
foreach ($g in $guard) {
    Dump $g[0]; Dump $g[1]
    Check ("separate: {0}" -f $g[2]) (-not (Same $g[0] $g[1]))
}

Write-Host ''
Write-Host '=== same film, numeric title, must MATCH ==='
Dump '1917.2019.1080p.BluRay.x264-SPARKS'
Dump '1917.2019.2160p.BluRay.x265-GROUP'
Check 'two encodes of 1917 match' (Same '1917.2019.1080p.BluRay.x264-SPARKS' '1917.2019.2160p.BluRay.x265-GROUP')
Check '1917 does not match 2001' (-not (Same '1917.2019.1080p.BluRay.x264' '2001.A.Space.Odyssey.1968.1080p.BluRay.x264'))

Write-Host ''
Write-Host '=== numeric-title films must still identify ==='
foreach ($n in @('1917.2019.1080p.BluRay.x264-SPARKS', '2001.A.Space.Odyssey.1968.1080p.BluRay.x264')) { Dump $n }
Check '1917 identifies'    ($null -ne (Parts '1917.2019.1080p.BluRay.x264-SPARKS'))
Check '2001 identifies'    ($null -ne (Parts '2001.A.Space.Odyssey.1968.1080p.BluRay.x264'))

Write-Host ''
Write-Host '=== DoVi detection ==='
$cfg = [System.IO.File]::ReadAllText((Get-ProjectFile 'config.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$doviPatterns = @($cfg.doviPatterns)
function Hit([string]$n) {
    foreach ($p in $doviPatterns) { if ([regex]::IsMatch($n, "(?i)$p")) { return $true } }
    return $false
}
$doviWant = @(
    'Movie.2024.2160p.WEB-DL.DV.HDR10.HEVC-FraMeSToR',
    'Movie.2024.2160p.BluRay.DoVi.HEVC.DV-Group',
    'Movie 2024 2160p Dolby Vision HDR x265',
    'Movie.2024.1080p.DV.HDR10.x265-GRP',
    'Show.S01E01.2160p.DV.WEB-DL.mkv',
    'Movie.2024.2160p.WEB-DL.DV.mkv'
)
$doviNotWant = @(
    'Movie.2024.1080p.BluRay.DTS-HD.MA.5.1.x264-GROUP',
    'Movie.2024.2160p.WEB-DL.HDR10.HEVC-GROUP',
    'Movie.2024.480p.DVDRip.XviD-GROUP',
    'Some.Movie.2024.DTS.x264.DVDRip',
    'Movie.2024.1080p.BluRay.DD5.1.x264-CtrlSD',
    'ADVANCED.Wrestling.2016.1080p.WEB-DL.x264',
    'The Talented Mr Ripley 1999 1080p BluRay x264 DTS-WiKi'
)
$doviOk = $true
foreach ($n in $doviWant) { $h = Hit $n; if (-not $h) { $doviOk = $false }; '  {0,-50} {1}' -f $n, $(if ($h) { 'HIT   (correct)' } else { 'MISS  <-- BUG' }) }
Write-Host ''
foreach ($n in $doviNotWant) { $h = Hit $n; if ($h) { $doviOk = $false }; '  {0,-50} {1}' -f $n, $(if ($h) { 'HIT <-- FALSE POSITIVE' } else { 'clear (correct)' }) }
Check 'DoVi: no misses, no false positives' $doviOk

Write-Host ''
Write-Host '=== Blu-ray disc-rip detection ==='
$discPatterns = @($cfg.discRipPatterns)
function DiscHit([string]$n) {
    foreach ($p in $discPatterns) { if ([regex]::IsMatch($n, "(?i)$p")) { return $true } }
    return $false
}
# genuine full disc structures
$discWant = @(
    'The Talented mr. Ripley [1999, USA, thriller, Blu-ray disc (custom) 1080i] AVO',
    'Movie.2020.1080p.BluRay.DISC1-GROUP',
    'Movie.2020.1080p.CompleteBD-GROUP',
    'Movie.2020.1080p.BD50-GROUP',
    'Movie.2020.2160p.BD25.1F4U-GROUP',
    'Movie.2020.BluRay.BDMV',
    'Movie.2020.1080p.FullBD-GROUP',
    'Movie.2020.1080p.BDISO-GROUP'
)
# transcodes and REMUXes sourced from Blu-ray: these must be KEPT
$discNotWant = @(
    'The Talented Mr Ripley (1999) (1080i x265 10bit BluRay AC3 5 1) [Prof]',
    'Amy 2015 Bluray 1080p TrueHD x264-Grym',
    'The.Talented.Mr.Ripley.1999.1080p.GER.Blu-ray.REMUX.AVC.DTS-HD.MA.5.1-DIY',
    'Movie.2020.1080p.BluRay.x264-GROUP',
    'Movie.2020.1080p.BDRip.x264-GROUP',
    'Movie.2020.2160p.UHD.BluRay.REMUX.HEVC-GROUP',
    'Movie.2020.720p.BluRay.DTS.x264-GROUP'
)
$discOk = $true
foreach ($n in $discWant) { $h = DiscHit $n; if (-not $h) { $discOk = $false }; '  {0,-58} {1}' -f $n, $(if ($h) { 'HIT   (correct)' } else { 'MISS  <-- BUG' }) }
Write-Host ''
foreach ($n in $discNotWant) { $h = DiscHit $n; if ($h) { $discOk = $false }; '  {0,-58} {1}' -f $n, $(if ($h) { 'HIT <-- FALSE POSITIVE' } else { 'clear (correct)' }) }
Check 'disc rip: no misses, no false positives' $discOk

'=== multi-episode packs: the range must not leak into the show name ==='
# Real names out of the user's own queue. Every one of these used to carry the
# range end into the title as ordinary text, so S01E01-10 became the show
# 'widows bay 10' and S01E01-06 became 'widows bay 06'. One series split into two
# invented shows, so overlapping packs could never be compared, and each pack
# printed a different name.
$packWant = @(
    # name, title, season, episode, last episode, is a pack
    @('Widows.Bay.S01E01-10.1080p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]', 'widows bay', 1, 1, 10, $true),
    @('WidowS Bay S01e01-10 [1080p Ita Eng Spa HEVC10 SubS] byMe7alh [MIRCrew] [ext.to]', 'widows bay', 1, 1, 10, $true),
    @('WidowS Bay S01e01-10 [720p Ita Eng Spa SubS] byMe7alh [MIRCrew] [ext.to]', 'widows bay', 1, 1, 10, $true),
    @('Widows.Bay S01E01-E10 [ext.to]', 'widows bay', 1, 1, 10, $true),
    @('Widows.Bay.S01E01-06.1080p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]', 'widows bay', 1, 1, 6, $true),
    @('Its.Always.Sunny.in.Philadelphia.S18E01-E05.400p.Ru.Ultradox [ext.to]', 'its always sunny in philadelphia', 18, 1, 5, $true),
    @('Its.Always.Sunny.in.Philadelphia.S18E01-E08.1080p.Ru.Ultradox [ext.to]', 'its always sunny in philadelphia', 18, 1, 8, $true)
)
$packOk = $true
foreach ($row in $packWant) {
    $p = Get-TitleParts -Name $row[0]
    $bad = @()
    if (-not $p) {
        $bad += 'unidentified'
    } else {
        if ($p.Title -ne $row[1])              { $bad += "title='$($p.Title)' want '$($row[1])'" }
        if ($p.Season -ne $row[2])             { $bad += "season=$($p.Season)" }
        if ($p.Episode -ne $row[3])            { $bad += "episode=$($p.Episode)" }
        if ($p.EpisodeLast -ne $row[4])        { $bad += "last=$($p.EpisodeLast)" }
        if ([bool]$p.IsMultiEpisode -ne $row[5]) { $bad += "multi=$($p.IsMultiEpisode)" }
        # the range end must not survive as a sequel number either
        if (@($p.Numbers).Count -gt 0)         { $bad += "numbers=[$($p.Numbers -join ',')]" }
    }
    if ($bad.Count -gt 0) { $packOk = $false }
    '  {0,-60} {1}' -f $row[0].Substring(0, [Math]::Min(58, $row[0].Length)), $(if ($bad.Count -eq 0) { 'ok' } else { 'BAD: ' + ($bad -join '; ') })
}
Check 'every pack parses to the plain show name, with its range intact' $packOk

$wb = @($packWant | Where-Object { $_[1] -eq 'widows bay' })
$wbTitles = @($wb | ForEach-Object { (Get-TitleParts -Name $_[0]).Title } | Sort-Object -Unique)
Check "all $($wb.Count) Widows Bay packs are ONE show, not 'widows bay 10' and 'widows bay 06'" `
    (@($wbTitles).Count -eq 1 -and $wbTitles[0] -eq 'widows bay')

$sgTitles = @($packWant | Where-Object { $_[1] -like 'its always*' } | ForEach-Object { (Get-TitleParts -Name $_[0]).Title } | Sort-Object -Unique)
Check 'the 400p and the 1080p Sunny packs are one show too' `
    (@($sgTitles).Count -eq 1 -and $sgTitles[0] -eq 'its always sunny in philadelphia')

$misses = 0
foreach ($a in $wb) {
    foreach ($b in $wb) {
        if ($a[0] -ge $b[0]) { continue }
        if (-not (Test-SameTitle -A (Get-TitleParts -Name $a[0]) -B (Get-TitleParts -Name $b[0]))) { $misses++ }
    }
}
Check 'every pair of Widows Bay packs compares as the same title' ($misses -eq 0)

'== a single episode is still a single episode =='
$singleWant = @(
    @('Widows Bay S01E01 Welcome to Widows Bay 2160p ATVP WEB-DL DDP5 1 Atmos H 265 [ext.to]', 'widows bay', 1, 1, $false),
    @('Its.Always.Sunny.in.Philadelphia.S18E01.1080p.NTb [ext.to]', 'its always sunny in philadelphia', 18, 1, $false),
    @('Its.Always.Sunny.in.Philadelphia.S18E05.1080p.NTb [ext.to]', 'its always sunny in philadelphia', 18, 5, $false),
    @('The.Office.US.S01E01.PROPER.1080p.WEB-DL.DD5.1.H.264-KILLERS [ext.to]', 'the office us', 1, 1, $false),
    @('Show.S01E01-01.1080p.WEB-DL.x264-GRP [ext.to]', 'show', 1, 1, $false)
)
$singleOk = $true
foreach ($row in $singleWant) {
    $p = Get-TitleParts -Name $row[0]
    if (-not $p) { $singleOk = $false; continue }
    if ($p.Title -ne $row[1] -or $p.Season -ne $row[2] -or $p.Episode -ne $row[3] -or [bool]$p.IsMultiEpisode -ne $row[4]) {
        $singleOk = $false
        '  {0,-60} BAD title=''{1}'' S{2}E{3} multi={4}' -f $row[0], $p.Title, $p.Season, $p.Episode, $p.IsMultiEpisode
    }
}
Check 'a single episode is still a single episode' $singleOk

$flat = Get-TitleParts -Name 'Show.S01E01-01.1080p.WEB-DL.x264-GRP [ext.to]'
Check 'a range that does not advance is one episode, not a pack' `
    ((-not $flat.IsMultiEpisode) -and ($null -eq $flat.EpisodeLast))

$tilde = Get-TitleParts -Name 'Show.S01E01~10.1080p.WEB-DL.x264-GRP [ext.to]'
Check 'a tilde range is a pack too' `
    ($tilde.IsMultiEpisode -and $tilde.EpisodeLast -eq 10 -and $tilde.Title -eq 'show')

$xsep = Get-TitleParts -Name 'Show 1x01-10 1080p WEB-DL x264-GRP [ext.to]'
Check 'the 1x01-10 form is a pack too' `
    ($xsep.IsMultiEpisode -and $xsep.EpisodeLast -eq 10 -and $xsep.Title -eq 'show' -and $xsep.Season -eq 1)

'== the cut, and the numbers it must not eat =='
# 400p was missing from the boundary list, so the cut never fired on those
# releases and '400p ru ultradox' ended up inside the show name. The bare numbers
# are deliberately NOT added without their suffix: the existing branch makes p/i
# optional, and a title that is just a number would be cut in half.
Check '400p is a boundary'          ([regex]::IsMatch('Its.Always.Sunny 400p.Ru', $script:boundaryPattern))
Check 'a bare 400 is not a boundary' (-not [regex]::IsMatch('Its.Always.Sunny 400.Ru', $script:boundaryPattern))

$brk = Get-TitleParts -Name 'Show.400.Season.2020.1080p.WEB-DL.x264-GRP [ext.to]'
Check 'a bare number in a title survives, and is kept as a number' `
    (($brk.Title -like 'show 400*') -and (@($brk.Numbers) -contains '400'))

$brk2 = Get-TitleParts -Name 'Show.400p.Season.2020.1080p.WEB-DL.x264-GRP [ext.to]'
Check '400p does cut the title short' ($brk2.Title -eq 'show')

'== a trailing source tag =='
# The bracketed tag only survived when nothing technical followed it, because
# then there was nothing for the cut to stop at.
$tag = Get-TitleParts -Name 'Widows.Bay S01E01-E10 [ext.to]'
Check 'a trailing [ext.to] does not become part of the show name' ($tag.Title -eq 'widows bay')
$yr = Get-TitleParts -Name 'The Talented Mr Ripley (1999) [Prof] [ext.to]'
Check 'a bracketed year and tag still parse' ($yr.Title -eq 'the talented mr ripley' -and $yr.Year -eq '1999')

'== an apostrophe is part of the word, not a separator =='
# Normalising the apostrophe away turned "It's" into "it s". The clustering pass
# groups a show family by the FIRST WORD of the show name, so "it" and "its"
# became two families: S18E3, S18E5 and S18E6 each printed as two groups, and no
# release in one of them could ever be weighed against the better copy sitting
# in the other. Twenty-two releases were stranded this way.
$apos = Get-TitleParts -Name "It's.Always.Sunny.In.Philadelphia.S18E03.HD1080p.WEBRip.Rus [ext.to]"
Check 'a dotted apostrophe is dropped, not spaced' ($apos.Title -eq 'its always sunny in philadelphia')
Check 'the season and episode still read'          ($apos.Season -eq 18 -and $apos.Episode -eq 3)

$aposWd = Get-TitleParts -Name "Widow's.Bay.S01E01.1080p.WEB [ext.to]"
Check 'so a possessive and a plain spelling are one show' `
    (($aposWd.Title -eq 'widows bay') -and ((Get-TitleParts -Name 'Widows.Bay.S01E01.1080p.WEB [ext.to]').Title -eq 'widows bay'))

$aposEnd = Get-TitleParts -Name "The Bachelor's S01E01 1080p WEB [ext.to]"
Check 'a trailing apostrophe is dropped too' ($aposEnd.Title -eq 'the bachelors')

'== the compact range, S18E01E02 =='
# The single-episode pattern ends at the episode number and then insists the
# next character is not a word character - which the E of E02 is - so nothing
# matched at all. The bare-E pattern then claimed the E02 half, and the release
# parsed as season 1 episode 2 under the show "its always sunny in philadelphia
# s18e01": a season welded onto the show name, in a season nobody else was in,
# so it could never be compared with anything.
$cmp1 = Get-TitleParts -Name 'Its.Always.Sunny.In.Philadelphia.S18E01E02.1080p.ColdFilm'
Check 'the season is read from the compact form' ($cmp1.Season -eq 18)
Check 'both halves of the compact range are read' ($cmp1.Episode -eq 1 -and $cmp1.EpisodeLast -eq 2)
Check 'the compact range is a pack'                ($cmp1.IsMultiEpisode)
Check 'no marker is left in the show name'        ($cmp1.Title -eq 'its always sunny in philadelphia')
Check 'the compact form reaches the set the dashed one does' ((Get-EpisodeSetKey -Parts $cmp1) -eq 'S18-E1-E2')

$cmp2 = Get-TitleParts -Name 'Widows.Bay.S01E01E05.1080p.WEB'
Check 'a second compact form agrees' ((Get-EpisodeSetKey -Parts $cmp2) -eq 'S1-E1-E5')

Check 'one episode after a season marker is still one episode' `
    (-not (Get-TitleParts -Name 'Show Name S18E01 1080p WEB').IsMultiEpisode)

Check 'a range that does not advance is still one episode' `
    (-not (Get-TitleParts -Name 'Show Name S18E02-E02 1080p WEB').IsMultiEpisode)

'== a bare E.. takes the season stated earlier in the name =='
# "Euphoria.S03.Dub E01-E08" is season 3. Defaulting to season 1 filed it under
# S1 and left "s03 dub" welded onto the show name, so the group printed as
# "euphoria s03 dub S1E1-E8" - wrong show, wrong season, comparable with nothing.
$bare = Get-TitleParts -Name 'Euphoria.S03.Dub E01-E08 [ext.to]'
Check 'the season is taken from earlier in the name' ($bare.Season -eq 3)
Check 'and the show name is cut there'               ($bare.Title -eq 'euphoria')
Check 'the range survives intact'                    ($bare.Episode -eq 1 -and $bare.EpisodeLast -eq 8)
Check 'the set key is the stated season'             ((Get-EpisodeSetKey -Parts $bare) -eq 'S3-E1-E8')

$bare2 = Get-TitleParts -Name "O.Segredo.de.Widow's.Bay.S01.Dub E01-E08 [ext.to]"
Check 'a padded season is taken from earlier too'   ($bare2.Season -eq 1)
Check 'and its show name loses the season and the dub tag' ($bare2.Title -eq 'o segredo de widows bay')

Check 'a bare E.. with no season stated still defaults to season 1' `
    ((Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Breaking Bad E05 1080p WEB-DL x264')) -eq 'S1-E5')
Check 'Se5 is one episode of an implied season 1, not season 5' `
    ((Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Breaking Bad Se5 1080p WEB-DL x264')) -eq 'S1-E5')
Check 'a season stated as a word is taken from earlier too' `
    ((Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Breaking Bad Season 4 E01-E05 1080p WEB-DL x264')) -eq 'S4-E1-E5')

Check 'a group tag is not a season to inherit' ((Get-TitleParts -Name 'Show S0NNER.1080p.WEB.x264').IsSeries -eq $false)
Check 'a trailing S0 is not a season either'   ((Get-TitleParts -Name 'Show 1080p x264-S0').IsSeries -eq $false)
Check 'a dotted number before a bare E is not a season' `
    ((Get-TitleParts -Name 'Ocean.s.8.2018.1080p.BluRay.x264').IsSeries -eq $false)

'== a year printed on one release does not hide the others =='
# Demanding equal years split one episode in two. "S18E04 2026 A Virtual
# Insanity" and "S18E04.1080p.rus" are the same episode of the same show, but
# they landed in different groups, so a finished copy in one never counted
# against anything in the other, and the group printed twice: once as
# "(2026) S18E4" above three rows and once as "S18E4" above two.
Check 'a stated year matches a release with no year' `
    (Same 'Its Always Sunny in Philadelphia S18E04 2026 A Virtual Insanity 1080p AMZN WEB-DL DDP5 1 H 264-NTb [ext.to]' `
          'Its.Always.Sunny.in.Philadelphia.S18E04.1080p.rus [ext.to]')
Check 'and so does a film' `
    (Same 'Amy 2015 Bluray 1080p TrueHD x264-Grym [ext.to]' 'Amy.1080p.BluRay.x264-GRP [ext.to]')
Check 'two DIFFERENT stated years still refuse the match' `
    (-not (Same 'The Talented Mr Ripley 1999 1080p BluRay x264' 'The Talented Mr Ripley 2002 1080p BluRay x264'))
Check 'a US/UK remake is still kept apart' `
    (-not (Same 'The Office US S01E01 1080p WEB-DL x264' 'The Office UK S01E01 1080p WEB-DL x264'))

'== the show part of a header never claims more than the rows say =='
# The year is there to tell two remakes apart, but it used to be taken from
# whichever member sorted first. Once a release that states a year may share a
# group with one that does not, sorting first alone decides the header, and
# "(2026)" could sit above rows that never claimed a year at all.
$withY = Get-TitleParts -Name 'Show Name S03E01 2026 1080p WEB-DL'
$noY    = Get-TitleParts -Name 'Show Name S03E01 1080p WEB-DL'
$oldY   = Get-TitleParts -Name 'Show Name S03E01 2013 1080p WEB-DL'
Check 'the year is read off the name, and absent when none is printed' `
    (($withY.Year -eq '2026') -and (-not $noY.Year))
Check 'every member states the same year, so it is printed' ((Get-ShowLabel -Parts @($withY, $withY)) -eq 'show name (2026)')
Check 'one member with no year, so none is printed'  ((Get-ShowLabel -Parts @($withY, $noY)) -eq 'show name')
Check 'no year anywhere, so none is printed'         ((Get-ShowLabel -Parts @($noY, $noY)) -eq 'show name')
Check 'two different years, so none is printed'      ((Get-ShowLabel -Parts @($withY, $oldY)) -eq 'show name')
Check 'the show name is still there when the year is not' ((Get-ShowLabel -Parts @($noY)).StartsWith('show name'))
Check 'no parts at all gives no label'               ((Get-ShowLabel -Parts @()) -eq '')

'== the label is the whole of what a header adds to the show name =='
# A printed header is the show name plus this and nothing else, so a header
# reading S18E1-E8 can only ever sit above releases holding episodes 1 to 8.
Check 'a single episode'      ((Get-EpisodeSetLabel -Key 'S03-E7') -eq 'S03E7')
Check 'a pack'                ((Get-EpisodeSetLabel -Key 'S03-E1-E10') -eq 'S03E1-E10')
Check 'a whole season'        ((Get-EpisodeSetLabel -Key 'S03-ALL') -eq 'S03')
Check 'a film'                ((Get-EpisodeSetLabel -Key 'film') -eq '')

Write-Host '== the preview and the rule must agree on which end of the queue is the front ==' -ForegroundColor Cyan

# status.ps1 is a preview of qbt-manager.ps1. It re-implements the
# no-metadata rule rather than calling it, so the two copies of the sort can
# drift apart. When they do, the preview reports deletions that will not happen
# and stays quiet about the ones that will - the one failure mode a preview must
# not have. It happened for real: status.ps1 still said Descending after the
# manager was flipped to Ascending, and reported ten Euphoria magnets "will
# delete on next run" while the manager was going to delete none of them.
$statusSrc = [System.IO.File]::ReadAllText((Get-ProjectFile 'status.ps1'), [System.Text.Encoding]::UTF8)

function Get-QueueSort {
    param([string]$Text)
    $m = [regex]::Match($Text, '(?s)Sort-Object\s+-Property\s*@\{\s*Expression\s*=\s*\{\s*\$_\.priority\s*\}\s*;\s*(Ascending|Descending)\s*=\s*\$\w+\s*\}')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

$mgrSort = Get-QueueSort -Text $src
$staSort = Get-QueueSort -Text $statusSrc

Check 'the queue sort could be found in qbt-manager.ps1' ($null -ne $mgrSort)
Check 'the queue sort could be found in status.ps1' ($null -ne $staSort)
Check 'status.ps1 previews the queue in the order the manager ranks it' ($mgrSort -eq $staSort)
Check 'the front of the queue is the oldest, not the newest' ($mgrSort -eq 'Ascending')

# Rule 2 is "a magnet that found nothing to download from": no size reported for
# longer than the tolerance, deleted - but only while qBittorrent is actually
# giving it a slot. `priority` is the queue position, so the window is
# 1..metadataPriorityRankLimit and the clock runs only inside it.
#
# The cap was removed once on the grounds that priority was a 0..7 want tier. It
# is not, and removing it deleted 205 torrents that had never been handed a turn.
# The checks below pin both halves of the window down, and the guards above pin
# the sort down. test-queue-window.ps1 proves the behaviour against synthetic
# torrents; these prove the two files were not edited apart.
$cfgSrc = [System.IO.File]::ReadAllText((Get-ProjectFile 'config.json'), [System.Text.Encoding]::UTF8)

Check 'qbt-manager.ps1 applies the queue window'           ($src -match 'metadataPriorityRankLimit')
Check 'status.ps1 applies the same queue window'          ($statusSrc -match 'metadataPriorityRankLimit')
Check 'config.json carries the window size'               ($cfgSrc -match 'metadataPriorityRankLimit')
Check 'and config.json is still valid JSON'               ($null -ne ($cfgSrc | ConvertFrom-Json))
Check 'the manager window is 1..limit'                    ($src -match '\$pos\s*-ge\s*1\)\s*-and\s*\(\$pos\s*-le\s*\$QueueLimit\)')
Check 'status.ps1 uses the same 1..limit window'          ($statusSrc -match '\$pos\s*-ge\s*1\)\s*-and\s*\(\$pos\s*-le\s*\$limit\)')
Check 'the window is applied before the timeout, not after' ($statusSrc -match '\$inWindow\s*=\s*\(\(\$limit\s*-gt\s*0\)')
Check 'the clock is the time spent inside the window'     ($src -match 'windowSince')
Check 'the preview reads the same windowSince clock'      ($statusSrc -match 'windowSince')
Check 'a magnet outside the window cannot be deleted'     ($src -match '\$delete\s*=\s*\(\$inWindow\s+-and')
Check 'the preview agrees on the in-window gate'          ($statusSrc -match 'WillDelete\s*=\s*\(\$inWindow\s+-and')
# Scoped to $Hashes, case-SENSITIVELY, and neither of those is incidental.
#
# The original pattern `NotePropertyValue ([pscustomobject]@{ since =` matched
# anywhere in the manager, so it began failing the moment rule 2d added a stall
# clock - a single `since` beside `windowSince`, with a completely different job.
#
# -cmatch, not -match: PowerShell's operators are case-INSENSITIVE by default, so a
# case-insensitive `since` also matches the `Since` inside `windowSince`. That is
# why the obvious fix below still failed - it was matching the very field this rule
# is supposed to be keeping.
#
# What it asserts: no entry written INTO THE PER-TORRENT HASH TABLE carries a bare
# `since`. That is the old age-since-added clock, which judged a magnet on how long
# it had existed rather than how long it had been inside the window - the bug that
# had it deleting queued magnets on arrival. A clock stored per hash cannot
# reintroduce it, so the pattern is anchored to $Hashes, which is what the old code
# wrote to, rather than to Add-Member generally.
Check 'no per-hash entry carries a bare since clock'     ($src -cnotmatch '(?s)\$Hashes\s*\|\s*Add-Member[^\n]*\n?[^\n]*\bsince\s*=')
Check 'the per-hash clock is still windowSince'          ($src -cmatch '\$Hashes\s*\|\s*Add-Member[\s\S]{0,120}windowSince\s*=')
Check 'the stall clock is a single one, not per torrent' ($src -cmatch "-NotePropertyName\s+'stall'")

# Prove the two checks above can both fail, because a pattern that cannot fail is
# decoration. Each of these is the shipped source with one targeted mutation, and
# each must be caught by the check it is aimed at.
$noBareSince = $src -creplace '(?s)(\$Hashes\s*\|\s*Add-Member[^\n]*\n[^\n]*?)windowSince(\s*=)', '$1since$2'
Check 'MUTATION: a bare since in the hash table IS caught' `
    ($noBareSince -cmatch '(?s)\$Hashes\s*\|\s*Add-Member[^\n]*\n?[^\n]*\bsince\s*=')
# Must mirror the scoped pattern above exactly. An earlier version of this
# mutation test checked `-cnotmatch 'windowSince'` - bare, unanchored - and passed
# for the wrong reason: renaming only the ASSIGNMENTS leaves the $windowSince
# variable and its .ToString() call in place, so the string is still in the file
# and the check never failed. A mutation test has to test the check, not a
# looser cousin of it.
$noWindow = $src -creplace '(?s)(\$Hashes\s*\|\s*Add-Member[\s\S]{0,120}?)windowSince(\s*=)', '$1since$2'
Check 'MUTATION: losing the per-hash windowSince IS caught' ($noWindow -cnotmatch '(?s)\$Hashes\s*\|\s*Add-Member[\s\S]{0,120}windowSince\s*=')
$noStall = $src -creplace "-NotePropertyName\s+'stall'", "-NotePropertyName 'drain'"
Check 'MUTATION: losing the stall clock IS caught'       ($noStall -cnotmatch "-NotePropertyName\s+'stall'")
Check 'the manager logs why a magnet was deleted'         ($src -match 'no availability')
Check 'the manager names the queue position it judged at' ($src -match 'queue position')
Check 'the manager reports seeds and peers in that reason' ($src -match '(?s)num_seeds.*num_leechs')

# Rule 2c is the drain: one magnet an hour from behind the window, and only when
# something further down the queue is actually downloading.
#
# The same drift hazard as above applies twice over here, because there are two
# more conditions that can silently disagree between the two files: WHICH torrent
# is the candidate, and WHAT counts as a witness. A preview with a wider witness
# test would report deletions the manager never performs; one with a different
# candidate would name the wrong torrent. So the witness allowlist is compared
# state-by-state rather than merely checked for presence - a single state added to
# one file and not the other is exactly the failure this guards against.
Write-Host ''
Write-Host '== the preview and the rule must agree on the drain ==' -ForegroundColor Cyan

# Pulls the state names out of each copy's Test-ActivelyDownloading. An allowlist
# is a switch with 'return $true' cases, so the true-branch states are the ones
# that decide the verdict.
function Get-WitnessStates {
    param([string]$Text)
    $m = [regex]::Match($Text, '(?s)function\s+Test-ActivelyDownloading.*?switch\s*\(\$s\)\s*\{(.*?)default')
    if (-not $m.Success) { return $null }
    $found = @()
    # Single-quoted: in a double-quoted one, $true interpolates to True and the
    # regex becomes \True, which is an unrecognised escape.
    foreach ($mm in [regex]::Matches($m.Groups[1].Value, "'([A-Za-z0-9]+)'\s*\{\s*return\s+\`$true")) {
        $found += $mm.Groups[1].Value
    }
    return $found
}

$mgrWitness = Get-WitnessStates -Text $src
$staWitness = Get-WitnessStates -Text $statusSrc

Check 'the manager witness test could be found'      ($null -ne $mgrWitness)
Check 'the preview witness test could be found'      ($null -ne $staWitness)
if ($null -ne $mgrWitness -and $null -ne $staWitness) {
    $onlyMgr = @($mgrWitness | Where-Object { $staWitness -notcontains $_ })
    $onlySta = @($staWitness | Where-Object { $mgrWitness -notcontains $_ })
    Check 'the two witness allowlists are identical' (($onlyMgr.Count -eq 0) -and ($onlySta.Count -eq 0))
    Check 'no state in the manager allowlist is missing from the preview' ($onlyMgr.Count -eq 0)
    Check 'no state in the preview allowlist is missing from the manager' ($onlySta.Count -eq 0)
}

Check 'the manager has the drain'                      ($src -match 'function Get-QueueDrainVerdict')
Check 'the preview has the drain'                      ($statusSrc -match 'function Get-QueueDrainVerdict')
Check 'config.json carries the drain switch'           ($cfgSrc -match 'queueDrainEnabled')
Check 'and the drain is on in the shipped config'      ($cfg.queueDrainEnabled -eq $true)
Check 'the manager honours the drain switch'           ($src -match "queueDrainEnabled")
Check 'the preview honours the drain switch'           ($statusSrc -match "queueDrainEnabled")

# The witness must be FURTHER DOWN the queue. `if ($pos -le $candPos) { continue }`
# is the whole of that, and it is the check most likely to be "simplified" into
# something that also accepts a torrent above the candidate - which would make the
# witness a coincidence rather than a proof, and the rule unsafe on a stalled
# client.
Check 'the manager only accepts a witness further down' ($src -match 'if\s*\(\$pos\s+-le\s+\$candPos\)\s*\{\s*continue\s*\}')
Check 'the preview only accepts a witness further down' ($statusSrc -match 'if\s*\(\$pos\s+-le\s+\$candPos\)\s*\{\s*continue\s*\}')
Check 'the candidate cannot be its own witness'          ($src -match 'candidate\.hash\)\s*\{\s*continue\s*\}')

# One candidate per run is the rate limit, so a single break in the candidate
# loop would let the whole queue drain at once.
Check 'the manager takes the first candidate and stops' ($src -match '(?s)\$candidate\s*=\s*\$t.*?break')
Check 'the drain runs behind the window'                ($src -match '\$pos\s+-le\s+\$QueueLimit\)\s*\{\s*continue\s*\}')

Write-Host ''
if ($script:fails -eq 0) {


    Write-Host 'ALL CHECKS PASSED'
} else {
    Write-Host ("{0} CHECK(S) FAILED" -f $script:fails)
    exit 1
}
