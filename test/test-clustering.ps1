# Exercises the second clustering pass for series (Merge-SeriesClusters), which
# folds groups of one episode back together when their titles disagree.
#
# Series releases name the episode inconsistently and sometimes not at all, so
# 'ted lasso', 'ted lasso follow the anger' and 'ted lasso mae sull autobus ita
# eng' are one show and the parser cannot tell. That left a finished 1080p
# sitting in the library beside a finished 2160p of the same episode, because
# dedup only ever compares inside a group.
#
# Two bugs this suite exists to keep fixed, both of which made the pass look
# like it was doing nothing at all:
#   - arrays unrolled on the way in, so every show name came out empty;
#   - arrays unrolled on the way out, so merged groups arrived as their members.
# And one design bug, subtler: suffixes measured per pair instead of against one
# show name, which made an ordinary episode title look like a repeated suffix
# and blocked the very merge it was meant to police.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-clustering.ps1

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
if ($s -lt 0 -or $e -le $s) { throw 'could not locate the detection block in qbt-manager.ps1' }
Invoke-Expression $src.Substring($s, $e - $s)

$script:fails = 0
function Check {
    param([string]$label, [bool]$ok)
    if ($ok) { "  [PASS] $label" } else { $script:fails++; "  [FAIL] $label" }
}

# A torrent, with its parsed title parts attached the way the manager does.
function T {
    param([string]$Name)
    $p = Get-TitleParts -Name $Name
    return [pscustomobject]@{ name = $Name; parts = $p }
}

# One single-member group per torrent, i.e. the worst case the first pass can
# hand to the second.
function Separate {
    param([string[]]$Names)
    $out = New-Object System.Collections.ArrayList
    foreach ($n in $Names) {
        $c = New-Object System.Collections.ArrayList
        [void]$c.Add((T $n))
        [void]$out.Add($c)
    }
    return ,$out
}

# Each member's name, sorted, so group contents can be compared as text.
function Names {
    param($Clusters)
    $r = @()
    foreach ($c in $Clusters) { foreach ($m in $c) { $r += $m.name } }
    return (@($r) | Sort-Object) -join ' | '
}

# Group sizes only, for counting merges without depending on order.
function Shape {
    param($Clusters)
    return (@($Clusters | ForEach-Object { $_.Count }) | Sort-Object -Descending) -join ','
}

$nameE8Short = 'Ted Lasso S04E08 MULTI 1080p WEB H264-HiggsBoson [ext.to]'
$nameE8Long  = 'Ted Lasso S04E08 Follow the Anger 2160p ATVP WEB-DL DDP5 1 H 265-NTb [ext.to]'
$nameE9En    = 'Ted Lasso S04E09 Mae Rides the Bus 2160p ATVP WEB-DL DDP5 1 Atmos H 265-playWEB [ext.to]'
$nameE9It    = 'Ted.Lasso.S04E09.Mae.sull.autobus.ITA.ENG.1080p.ATVP.WEB-DL.DDP5.1.Atmos.H.264-MeM.GP.mkv [ext.to]'
$nameE9Short = 'Ted.Lasso.S04E09.1080p.WEB-DL.DUAL.5.1 [ext.to]'
$nameSpin8   = 'Ted Lasso Spin Off S04E08 1080p WEB-DL [ext.to]'
$nameSpin9   = 'Ted Lasso Spin Off S04E09 1080p WEB-DL [ext.to]'
$nameOther8  = 'Breaking Bad S04E08 1080p WEB-DL [ext.to]'
$nameOther9  = 'Breaking Bad S04E09 1080p WEB-DL [ext.to]'
$nameFilm1   = 'The Talented Mr Ripley (1999) (1080i x265 10bit BluRay AC3 5 1) [Prof] [ext.to]'
$nameFilm2   = 'The.Talented.Mr.Ripley.1999.1080p.GER.Blu-ray.REMUX.AVC.DTS-HD.MA.5.1-DIY [ext.to]'

'== the episode title is not part of the show name =='
# These three used to parse as three different shows - 'ted lasso',
# 'ted lasso follow the anger', 'ted lasso mae sull...' - because the episode
# title sat after the marker and was kept as title text. The parser now cuts the
# show name at the marker, so they agree before clustering ever runs.
Check "'$nameE8Short' parses to 'ted lasso'"          ((T $nameE8Short).parts.Title -eq 'ted lasso')
Check "'$nameE8Long' parses to 'ted lasso'"           ((T $nameE8Long).parts.Title -eq 'ted lasso')
Check "'$nameE9It' is S4E9 and parses to 'ted lasso'" (((T $nameE9It).parts.Season -eq 4) -and ((T $nameE9It).parts.Episode -eq 9) -and ((T $nameE9It).parts.Title -eq 'ted lasso'))
Check "'$nameE9En' parses to 'ted lasso'"             ((T $nameE9En).parts.Title -eq 'ted lasso')
Check 'and the three now cluster as one title'        ((@($nameE8Short, $nameE8Long) | ForEach-Object { (T $_).parts.Title } | Sort-Object -Unique).Count -eq 1)
Check "'$nameOther8' parses to 'breaking bad'"        ((T $nameOther8).parts.Title -eq 'breaking bad')
Check "'$nameFilm1' is not series"                    ((T $nameFilm1).parts.IsSeries -eq $false)

'== Get-CommonRun =='
# Built as literal arrays rather than inline in the call. An array written
# inline is the exact shape that gets unrolled on the way in and turns into one
# list per word, so the tests say it the way a caller has to say it.
$wTedLasso = @('ted', 'lasso')
$wLonger   = @('ted', 'lasso', 'mae', 'rides', 'the', 'bus')
$wBreaking = @('breaking', 'bad')

Check 'one title gives itself'                     ((Get-CommonRun -TokenLists @(,$wTedLasso)) -eq 'ted lasso')
Check 'one list, not one word per list'            ((Get-CommonRun -TokenLists @(,@('ted', 'lasso', 'mae'))) -eq 'ted lasso mae')
Check 'titles sharing a prefix give the prefix'    ((Get-CommonRun -TokenLists @($wLonger, $wTedLasso)) -eq 'ted lasso')
Check 'titles sharing nothing give empty'          ((Get-CommonRun -TokenLists @($wBreaking, $wTedLasso)) -eq '')
Check 'no titles at all give empty'                ((Get-CommonRun -TokenLists @()) -eq '')

'== one episode, titles that disagree =='
$c = Merge-SeriesClusters -Clusters (Separate @($nameE8Short, $nameE8Long))
Check 'a bare show name and a named one merge'      (@($c).Count -eq 1)
Check 'both members survive in the one group'       ($c[0].Count -eq 2)
Check 'the group is a collection, not loose members' ($c[0] -is [System.Collections.ArrayList])

'== the two languages of one episode =='
$c = Merge-SeriesClusters -Clusters (Separate @($nameE9En, $nameE9It, $nameE9Short))
Check 'English + Italian + bare title become one group' (@($c).Count -eq 1)
Check 'all three members survive'                    ($c[0].Count -eq 3)

'== different episodes are never joined =='
$c = Merge-SeriesClusters -Clusters (Separate @($nameE8Short, $nameE8Long, $nameE9En, $nameE9Short))
Check 'S4E8 and S4E9 stay apart' (@($c).Count -eq 2)
Check 'the two groups are 2 and 2' ((Shape $c) -eq '2,2')

'== DIFFERENT SHOWS NEVER MERGE =='
# Same season, same episode number, unrelated titles. This is the guard that
# makes the pass safe: the family is the first word of the show name.
$c = Merge-SeriesClusters -Clusters (Separate @($nameE8Short, $nameOther8, $nameE9Short, $nameOther9))
Check 'two shows at the same episode number stay apart' (@($c).Count -eq 4)
Check 'every group still holds exactly one member'      ((Shape $c) -eq '1,1,1,1')

# Same two shows, two episodes each - the arrangement that would look correct
# if the pass only ever compared one episode at a time.
$c = Merge-SeriesClusters -Clusters (Separate @($nameE8Short, $nameE9Short, $nameOther8, $nameOther9))
Check 'two shows with two episodes each stay as four groups' (@($c).Count -eq 4)
Check 'each of those groups holds one member'                ((Shape $c) -eq '1,1,1,1')

'== a suffix repeated across episodes is a show name, not an episode =='
# 'ted lasso spin off' at S4E8 and S4E9: the same trailing words on two
# episodes means they belong to the show, so they must not be used to join it to
# plain 'ted lasso' at either episode.
$c = Merge-SeriesClusters -Clusters (Separate @($nameSpin8, $nameE8Short, $nameSpin9, $nameE9Short))
Check 'a spin-off is not pulled into the show at S4E8' (@($c).Count -eq 4)
Check 'nor at S4E9'                                   ((Shape $c) -eq '1,1,1,1')

# The spin-off's own two episodes must still not merge with each other either.
$c = Merge-SeriesClusters -Clusters (Separate @($nameSpin8, $nameSpin9))
Check 'a spin-off does not merge across its own episodes' (@($c).Count -eq 2)

'== an ordinary episode title is not mistaken for a show name =='
# The regression that mattered: each episode of 'ted lasso' carries a different
# trailing title, which is what episode titles do. Measuring a suffix per pair
# made 'mae rides the bus' look like a suffix on two episodes and blocked the
# merge. All three episodes here must group correctly.
$c = Merge-SeriesClusters -Clusters (Separate @($nameE8Short, $nameE8Long, $nameE9Short, $nameE9En, $nameE9It))
Check 'both episodes group fully despite different episode titles' (@($c).Count -eq 2)
Check 'the groups are 2 and 3'                            ((Shape $c) -eq '3,2')

'== films are untouched by this pass =='
$c = Merge-SeriesClusters -Clusters (Separate @($nameFilm1, $nameFilm2))
Check 'two films stay two groups'       (@($c).Count -eq 2)
Check 'each keeps its single member'    ((Shape $c) -eq '1,1')

'== nothing to merge =='
$c = Merge-SeriesClusters -Clusters (Separate @($nameOther8))
Check 'a single group is returned as-is' (@($c).Count -eq 1)
Check 'and keeps its member'             ($c[0].Count -eq 1)

'== no member is lost or duplicated =='
$all = @($nameE8Short, $nameE8Long, $nameE9Short, $nameE9En, $nameE9It, $nameSpin8, $nameSpin9, $nameOther8, $nameOther9)
$c = Merge-SeriesClusters -Clusters (Separate $all)
$flat = @()
foreach ($g in $c) { foreach ($m in $g) { $flat += $m.name } }
$got  = ((@($flat) | Sort-Object) -join ' | ')
$want = ((@($all)  | Sort-Object) -join ' | ')
Check 'every torrent appears exactly once' ($got -eq $want)

''
"== a pack must not bridge two single episodes =="
# A pack carries a range, so its episode key matches one single episode and, via
# the merge pass, could pull a different episode's group into the same cluster.
# Packs are skipped by that pass for exactly this reason.
$pk  = 'Widows.Bay.S01E01-10.1080p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]'
$s1  = 'Widows Bay S01E01 Welcome to Widows Bay 2160p ATVP WEB-DL DDP5 1 Atmos H 265 [ext.to]'
$s9  = 'Widows Bay S01E09 2160p ATVP WEB-DL DDP5 1 Atmos H 265-NTb [ext.to]'

$pkParts = (T $pk).parts
Check 'the pack parses with a range' ($pkParts.IsMultiEpisode -and $pkParts.EpisodeLast -eq 10)

$c1 = Merge-SeriesClusters -Clusters (Separate @($s1, $s9, $pk))
Check 'two different episodes stay in separate groups beside a pack' ((Shape $c1) -eq '1,1,1')
Check 'and no group holds more than one of them' (@($c1 | Where-Object { $_.Count -gt 1 }).Count -eq 0)

# Compared as the same joined string the suite uses elsewhere: .Split(' | ')
# would bind to Split(char[]) and break on every space in the name.
$wantNames = ((@($s1, $s9, $pk)) | Sort-Object) -join ' | '
Check 'every torrent is still reported exactly once' ((Names $c1) -eq $wantNames)

$c2 = Merge-SeriesClusters -Clusters (Separate @($s1, $pk))
Check 'a pack does not join a single episode group' ((Shape $c2) -eq '1,1')

$c3 = Merge-SeriesClusters -Clusters (Separate @($s1, $s9))
Check 'the same two episodes without a pack are unchanged' ((Shape $c3) -eq '1,1')

# Two packs of one show must land in the SAME group, so they show up together
# rather than as unrelated releases.
$pAll = @(
    'Widows.Bay.S01E01-10.1080p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]'
    'WidowS Bay S01e01-10 [1080p Ita Eng Spa HEVC10 SubS] byMe7alh [MIRCrew] [ext.to]'
    'WidowS Bay S01e01-10 [720p Ita Eng Spa SubS] byMe7alh [MIRCrew] [ext.to]'
    'Widows.Bay S01E01-E10 [ext.to]'
    'Widows.Bay.S01E01-06.1080p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]'
)
$built = New-Object System.Collections.ArrayList
foreach ($n in $pAll) {
    $one = T $n
    $placed = $false
    foreach ($g in $built) {
        if (Test-SameTitle -A $one.parts -B $g[0].parts) { [void]$g.Add($one); $placed = $true; break }
    }
    if (-not $placed) {
        $ng = New-Object System.Collections.ArrayList
        [void]$ng.Add($one)
        [void]$built.Add($ng)
    }
}
Check "all $($pAll.Count) packs of one show form ONE group" ((Shape $built) -eq '5')

$films = @(
    'The Talented Mr Ripley (1999) (1080i x265 10bit BluRay AC3 5 1) [Prof] [ext.to]'
    'The.Talented.Mr.Ripley.1999.1080p.GER.Blu-ray.REMUX.AVC.DTS-HD.MA.5.1-DIY [ext.to]'
)
Check 'films are still untouched by this change' `
    ((Shape (Merge-SeriesClusters -Clusters (Separate $films))) -eq '1,1')


Write-Host '== the display tag says what each release holds ==' -ForegroundColor Cyan

# The report the user reads, not a decision: a group headed "S18E1" holding 28
# packs looked like 28 copies of one episode. Get-SetTag is what puts the truth
# on each row, and it has to agree with the key dedup partitions on.
Check 'a single episode is tagged E7' `
    ((Get-SetTag -Parts (Get-TitleParts -Name 'Show Name S03E07 1080p WEB-DL')) -eq 'E7')

Check 'a pack is tagged with its range' `
    ((Get-SetTag -Parts (Get-TitleParts -Name 'Show Name S03E01-E10 1080p WEB-DL')) -eq 'E1-E10')

Check 'a whole-season pack is tagged as the season' `
    ((Get-SetTag -Parts (Get-TitleParts -Name 'Show Name S03 1080p WEB-DL')) -eq 'season')

Check 'a film carries no tag' `
    ((Get-SetTag -Parts (Get-TitleParts -Name 'The Talented Mr Ripley (1999) 1080p BluRay')) -eq '')

$pairs = @('Show Name S03E07 1080p', 'Show Name S03E01-E10 1080p', 'Show Name S03 1080p')
$want = @('S3-E7', 'S3-E1-E10', 'S3-ALL')
$got = @($pairs | ForEach-Object { Get-EpisodeSetKey -Parts (Get-TitleParts -Name $_) })
Check 'the key beside each tag is the one it was derived from' `
    (($got -join ',') -eq ($want -join ','))

$mixed = @('Show Name S18E01 1080p', 'Show Name S18E01-E06 1080p')
$tags = @($mixed | ForEach-Object { Get-SetTag -Parts (Get-TitleParts -Name $_) })
Check 'a pack and a single episode in one group get different tags' `
    (($tags | Sort-Object -Unique).Count -eq 2)

Check 'a padded range and an unpadded one get the same tag' `
    ((Get-SetTag -Parts (Get-TitleParts -Name 'Show Name S03E01-E06 1080p')) -eq
     (Get-SetTag -Parts (Get-TitleParts -Name 'Show Name S3E1-6 1080p')))
Write-Host '== a show name that lost its apostrophe upstream ==' -ForegroundColor Cyan

# Some release groups drop the apostrophe before qBittorrent ever sees the name:
# "It s Always Sunny in Philadelphia ... playWEB" carries no apostrophe at all,
# just a space, so there is nothing for the parser to drop. The family test keys
# on the FIRST WORD, so "it" and "its" were two families and those releases could
# not see the other hundred-odd members of their own show.
#
# Rejoining happens only when the rejoined name equals another show name IN FULL,
# and only when exactly one candidate does. Removing one space from a name could
# have been any of a handful of things; landing exactly on another show's
# complete name is not one of them by accident.
$splitShow = @(
    'It s Always Sunny in Philadelphia S18E03 The Gang Gets Tested 1080p DSNP WEB-DL DD5 1 H 264-playWEB [ext.to]',
    'Its.Always.Sunny.In.Philadelphia.S18E03.HD1080p.WEBRip.Rus [ext.to]',
    'Its.Always.Sunny.In.Philadelphia.S18E03.720p.Ru.Ultradox [ext.to]'
)
Check 'the split spelling parses with the space still in it' `
    (((T $splitShow[0]).parts.Title) -eq 'it s always sunny in philadelphia')
Check 'and rejoins the show it is really part of' `
    ((Shape (Merge-SeriesClusters -Clusters (Separate $splitShow))) -eq '3')

$splitPlusOther = @(
    'It s Always Sunny in Philadelphia S18E03 1080p DSNP WEB-DL [ext.to]',
    'Its.Always.Sunny.In.Philadelphia.S18E03.HD1080p.WEBRip.Rus [ext.to]',
    'Veep S18E03 1080p WEB-DL [ext.to]'
)
Check 'a different show is not pulled in by the rejoin' `
    ((Shape (Merge-SeriesClusters -Clusters (Separate $splitPlusOther))) -eq '2,1')

$longFirstWord = @(
    'Showt s Always Sunny In Philadelphia S18E03 1080p DSNP WEB-DL [ext.to]',
    'Showts Always Sunny In Philadelphia S18E03 1080p WEB-DL [ext.to]'
)
Check 'a first word of four letters or more is never rejoined' `
    ((Shape (Merge-SeriesClusters -Clusters (Separate $longFirstWord))) -eq '1,1')

$filmSplit = @(
    "It s Always Sunny in Philadelphia 2018 1080p BluRay x264 [ext.to]",
    'Its.Always.Sunny.In.Philadelphia.2018.1080p.BluRay.x264-GRP [ext.to]'
)
Check 'films are still untouched by the rejoin' `
    ((Shape (Merge-SeriesClusters -Clusters (Separate $filmSplit))) -eq '1,1')

Write-Host '== the show part of a group header ==' -ForegroundColor Cyan

# The year only appears when every member of the group states the same one, so a
# header can never put '(2026)' above a row that never claimed a year.
$sY = Get-TitleParts -Name 'Breaking Bad S04E08 2026 1080p WEB-DL [ext.to]'
$sN = Get-TitleParts -Name 'Breaking Bad S04E08 1080p WEB-DL [ext.to]'
Check 'all members state it, so it is printed' ((Get-ShowLabel -Parts @($sY, $sY)) -eq 'breaking bad (2026)')
Check 'one member does not, so it is not'     ((Get-ShowLabel -Parts @($sY, $sN)) -eq 'breaking bad')
Check 'no parts, no label'                     ((Get-ShowLabel -Parts @()) -eq '')
"checks: $($script:fails) failed"
if ($script:fails -gt 0) { exit 1 }
exit 0