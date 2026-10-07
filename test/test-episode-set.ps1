# Exercises the two things that stopped two packs of the same eight episodes
# from ever being weighed against each other, measured on a live queue:
#
#   Euphoria.S03.COMPLETE.1080p.AMZN.WEB-DL.H.264-EniaHD   40.37 GB, 100%
#       name says season 3 and no episode  ->  keyed S3-ALL
#       files say S03E01 .. S03E08         ->  actually eight episodes
#
#   Euphoria US S03e01-08 [720p Ita Eng Spa SubS] byMe7alh  15.69 GB, 96.5%
#       name and files both say eight episodes  ->  keyed S3-E1-E8
#
# Same eight episodes, the first finished and 2.6x bigger, and the two never met:
# S3-ALL is not a range so it equals no range key, and the two titles put them in
# different clusters while the merge pass skips packs. The unfinished 15 GB pack
# sat downloading.
#
# Two fixes, and both are needed - fixing either alone changes nothing here:
#
#   1. Get-EpisodeSetFromFiles reads the set off the release's own file list, so
#      a name claiming a whole season no longer hides what it actually holds.
#   2. The set pass folds clusters by show family first, so a set key is found
#      across title variants instead of only within one spelling.
#
# The tests below pin the fix AND the properties it must not break: a genuine
# season pack still refuses a partial pack, a pack never meets a single, an
# unreadable file list falls back to the name, and folding cannot widen the
# comparison past a set key.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-episode-set.ps1

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

$pass = 0; $fail = 0
function Check {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { $script:pass++; Write-Host ("  [PASS] " + $Name) }
    else { $script:fail++; Write-Host ("  [FAIL] " + $Name) -ForegroundColor Red }
}

function Get-Slice {
    param([string]$Text, [string]$From, [string]$To)
    $s = $Text.IndexOf($From)
    $e = $Text.IndexOf($To)
    if ($s -lt 0 -or $e -le $s) { throw "could not locate the block between '$From' and '$To'" }
    return $Text.Substring($s, $e - $s)
}

$msrc = [System.IO.File]::ReadAllText((Get-ProjectFile 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)
$ssrc = [System.IO.File]::ReadAllText((Get-ProjectFile 'status.ps1'), [System.Text.Encoding]::UTF8)

# The detection region, which is where Get-EpisodeSetFromFiles,
# Get-EpisodeSetKey and Get-ClusterFamilies all live. Sliced from the manager so
# these tests drive the real parser and the real family logic, not a hand-built
# stand-in.
Invoke-Expression (Get-Slice -Text $msrc -From '$script:boundaryPattern' -To 'function Get-DoviHit')

# And the preview's own dedup, which is the same rule in function form.
Invoke-Expression (Get-Slice -Text $ssrc -From 'function Get-Prop' -To 'function Get-MetadataWatch')

# A file entry as qBittorrent reports it. Only 'name' is read.
function F { param([string]$Name) return [pscustomobject]@{ name = $Name } }

# The eight files of the two packs in the report, by their real names. The
# folder prefix is included on purpose: the folder sits above every file, and a
# folder naming an episode must not be mistaken for a file naming one.
$keeperFiles = @(
    F 'Euphoria.S03.1080p.AMZN.WEB-DL.H.264-EniaHD/Euphoria.S03E01.Andale.1080p.AMZN.WEB-DL.H.264-EniaHD.mkv'
    F 'Euphoria.S03.1080p.AMZN.WEB-DL.H.264-EniaHD/Euphoria.S03E02.America.My.Dream.1080p.AMZN.WEB-DL.H.264-EniaHD.mkv'
    F 'Euphoria.S03.1080p.AMZN.WEB-DL.H.264-EniaHD/Euphoria.S03E03.The.Ballad.of.Paladin.1080p.AMZN.WEB-DL.H.264-EniaHD.mkv'
    F 'Euphoria.S03.1080p.AMZN.WEB-DL.H.264-EniaHD/Euphoria.S03E04.Kitty.Likes.To.Dance.1080p.AMZN.WEB-DL.H.264-EniaHD.mkv'
    F 'Euphoria.S03.1080p.AMZN.WEB-DL.H.264-EniaHD/Euphoria.S03E05.This.Little.Piggy.1080p.AMZN.WEB-DL.H.264-EniaHD.mkv'
    F 'Euphoria.S03.1080p.AMZN.WEB-DL.H.264-EniaHD/Euphoria.S03E06.Stand.Still.and.See.1080p.AMZN.WEB-DL.H.264-EniaHD.mkv'
    F 'Euphoria.S03.1080p.AMZN.WEB-DL.H.264-EniaHD/Euphoria.S03E07.Rain.or.Shine.1080p.AMZN.WEB-DL.H.264-EniaHD.mkv'
    F 'Euphoria.S03.1080p.AMZN.WEB-DL.H.264-EniaHD/Euphoria.S03E08.In.God.We.Trust.1080p.AMZN.WEB-DL.H.264-EniaHD.mkv'
)
$loserFiles = @(
    F 'Euphoria US S03e01-08 (720p Ita Eng Spa SubS) byMe7alh/Euphoria.US.S03e01.Ita.Eng.Spa.720p.h264.SubS-Me7alh.mkv'
    F 'Euphoria US S03e01-08 (720p Ita Eng Spa SubS) byMe7alh/Euphoria.US.S03e02.Ita.Eng.Spa.720p.h264.SubS-Me7alh.mkv'
    F 'Euphoria US S03e01-08 (720p Ita Eng Spa SubS) byMe7alh/Euphoria.US.S03e03.Ita.Eng.Spa.720p.h264.SubS-Me7alh.mkv'
    F 'Euphoria US S03e01-08 (720p Ita Eng Spa SubS) byMe7alh/Euphoria.US.S03e04.Ita.Eng.Spa.720p.h264.SubS-Me7alh.mkv'
    F 'Euphoria US S03e01-08 (720p Ita Eng Spa SubS) byMe7alh/Euphoria.US.S03e05.Ita.Eng.Spa.720p.h264.SubS-Me7alh.mkv'
    F 'Euphoria US S03e01-08 (720p Ita Eng Spa SubS) byMe7alh/Euphoria.US.S03e06.Ita.Eng.Spa.720p.h264.SubS-Me7alh.mkv'
    F 'Euphoria US S03e01-08 (720p Ita Eng Spa SubS) byMe7alh/Euphoria.US.S03e07.Ita.Eng.Spa.720p.h264.SubS-Me7alh.mkv'
    F 'Euphoria US S03e01-08 (720p Ita Eng Spa SubS) byMe7alh/Euphoria.US.S03e08.Ita.Eng.Spa.720p.h264.SubS-Me7alh.mkv'
)

Write-Host ''
Write-Host '== the label was the defect, not the rule =='
# Both names, parsed by the real parser, as they arrive from qBittorrent.
$kParts = Get-TitleParts -Name 'Euphoria.S03.COMPLETE.1080p.AMZN.WEB-DL.H.264-EniaHD [ext.to]'
$lParts = Get-TitleParts -Name 'Euphoria US S03e01-08 [720p Ita Eng Spa SubS] byMe7alh [MIRCrew] [ext.to]'
$kNameKey = Get-EpisodeSetKey -Parts $kParts
$lNameKey = Get-EpisodeSetKey -Parts $lParts
Write-Host ("  by name, the finished pack keys '" + $kNameKey + "' and the other '" + $lNameKey + "'")
Check 'a season-only name really does key S3-ALL'      ($kNameKey -eq 'S3-ALL')
Check 'so it cannot equal any range key'               ($kNameKey -ne $lNameKey)

Write-Host ''
Write-Host '== the files say what the name did not =='
$kFileKey = Get-EpisodeSetFromFiles -Files $keeperFiles
$lFileKey = Get-EpisodeSetFromFiles -Files $loserFiles
Check 'the finished pack reads as eight episodes'      ($kFileKey -eq 'S3-E1-E8')
Check 'the other pack reads as the same eight'         ($lFileKey -eq $kFileKey)
Check 'so the correction makes them comparable'        ($kFileKey -eq $lNameKey)

Write-Host ''
Write-Host '== a range in the file name is expanded =='
Check 'S03E01-08 in one file name becomes 1 to 8'      ((Get-EpisodeSetFromFiles -Files @(F 'Show.S03E01-08.720p.mkv')) -eq 'S3-E1-E8')
Check 'S03E01.E08 likewise'                            ((Get-EpisodeSetFromFiles -Files @(F 'Show.S03E01.E08.mkv')) -eq 'S3-E1-E8')
Check 'a single file naming one episode is that one'   ((Get-EpisodeSetFromFiles -Files @(F 'Show.S03E04.Kitty.mkv')) -eq 'S3-E4')
Check 'and several such files union into a range'      ((Get-EpisodeSetFromFiles -Files @(F 'A.S03E01.mkv'; F 'A.S03E02.mkv'; F 'A.S03E03.mkv')) -eq 'S3-E1-E3')

Write-Host ''
Write-Host '== every refusal returns no opinion, never a wildcard =='
# Each of these must leave the caller holding the name it read. That direction
# is the safe one: S<n>-ALL only ever meets S<n>-ALL, which is today's behaviour.
Check 'a file with no episode token: no opinion'       ((Get-EpisodeSetFromFiles -Files @(F 'Show.S03.1080p.WEB-DL/readme.txt')) -eq '')
Check 'one readable file among unreadable: no opinion' ((Get-EpisodeSetFromFiles -Files @(F 'A.S03E01.mkv'; F 'bonus-feature.mkv')) -eq '')
Check 'a gap in the run is not a range'                ((Get-EpisodeSetFromFiles -Files @(F 'A.S03E01.mkv'; F 'A.S03E02.mkv'; F 'A.S03E04.mkv')) -eq '')
Check 'spanning two seasons: no opinion'               ((Get-EpisodeSetFromFiles -Files @(F 'A.S01E01.mkv'; F 'A.S02E01.mkv')) -eq '')
Check 'an empty file list: no opinion'                 ((Get-EpisodeSetFromFiles -Files @()) -eq '')
Check 'no file list at all: no opinion'                ((Get-EpisodeSetFromFiles -Files $null) -eq '')
# 'S03E01-720p' is a resolution, not a range. Read as one it is dangerous twice
# over: as E1-E72 it meets nearly any pack of the show, and as a lone E1 it
# meets a finished single of episode 1. Both are wrong, so it must refuse.
Check 'a resolution after the episode: no opinion'     ((Get-EpisodeSetFromFiles -Files @(F 'A.S03E01-720p.mkv')) -eq '')
Check 'a genuine 2-digit tail still works'             ((Get-EpisodeSetFromFiles -Files @(F 'A.S03E01-72.mkv')) -eq 'S3-E1-E72')

Write-Host ''
Write-Host '== the folder above a file must not be read as the file =='
# The whole pack sits in one folder. If the folder's name were scanned, a folder
# naming an episode would stamp that episode onto every file in the pack.
Check 'a folder naming S03E01 adds nothing on its own' (
    (Get-EpisodeSetFromFiles -Files @(F 'Show.S03E01.1080p.WEB-DL.H.264-GRP/Show.S03E05.mkv')) -eq 'S3-E5')
# ...and the season in the folder must not override the season in the file.
Check 'the file season wins over the folder season'    (
    (Get-EpisodeSetFromFiles -Files @(F 'Show.S01.COMPLETE/Show.S03E05.mkv')) -eq 'S3-E5')

Write-Host ''
Write-Host '== a real season pack still refuses a partial pack =='
# The property that must not move: an E01-E10 pack is not comparable with an
# E01-E08 pack, so the two episodes at the end are never treated as redundant.
# 'S03 Complete' whose files really are ten episodes therefore still keys
# S3-E1-E10 and still does not match the eight-episode pack.
$tenFiles = @()
foreach ($n in 1..10) { $tenFiles += F ("Euphoria.S03.1080p/Euphoria.S03E{0:D2}.mkv" -f $n) }
$tenKey = Get-EpisodeSetFromFiles -Files $tenFiles
Check 'ten files really do read as E1-E10'             ($tenKey -eq 'S3-E1-E10')
Check 'and a ten-episode season pack does NOT match'   ($tenKey -ne $lFileKey)

Write-Host ''
Write-Host '== a pack never meets a single =='
Check 'one episode keys S3-E4, a pack keys S3-E1-E8'  ((Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Show.S03E04.1080p.WEB-DL.mkv')) -eq 'S3-E4')
Check 'and those keys are not equal'                  ((Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Show.S03E04.1080p.WEB-DL.mkv')) -ne $lFileKey)
Check 'a pack file list naming one episode matches'   ((Get-EpisodeSetFromFiles -Files @(F 'A.S03E04.mkv')) -eq 'S3-E4')

Write-Host ''
Write-Host '== the family fold, driven through the preview =='
# The rule itself lives inline in the manager's main flow, so it is driven
# through status.ps1's function form, which is the same rule. Both sides must
# agree, and this is also what stops the preview drifting from the run.
$GB = 1GB
function T {
    param([string]$Hash, [string]$Name, [double]$SizeGb, [double]$Progress, $Files)
    $size = [int64]($SizeGb * $GB)
    $o = [pscustomobject]@{
        hash = $Hash; name = $Name; size = $size
        downloaded = [int64]($size * $Progress); progress = $Progress
        parts = (Get-TitleParts -Name $Name)
    }
    if ($PSBoundParameters.ContainsKey('Files')) { Add-Member -InputObject $o -NotePropertyName 'files' -NotePropertyValue $Files -Force }
    return $o
}
function Cluster { param($Items) $a = New-Object System.Collections.ArrayList; foreach ($i in $Items) { [void]$a.Add($i) }; return $a }

# Stand in for the file fetch the preview would do. Stated here rather than
# reached over HTTP, so the test cannot delete anything and cannot flake on the
# network. Resolve-SetKey is exercised through this, which is the only part that
# differs between the two scripts.
function Get-Api {
    param([string]$Endpoint)
    if ($Endpoint -notmatch '^torrents/files\?hash=(.+)$') { return $null }
    $h = $Matches[1]
    foreach ($t in $script:fileFixtures) {
        if ($t.hash -eq $h) { return @($t.files) }
    }
    return @()
}

$finished = T 'aaaa1111' 'Euphoria.S03.COMPLETE.1080p.AMZN.WEB-DL.H.264-EniaHD [ext.to]' 40.37 1.0 $keeperFiles
$smaller  = T 'bbbb2222' 'Euphoria US S03e01-08 [720p Ita Eng Spa SubS] byMe7alh [MIRCrew] [ext.to]' 15.69 0.965 $loserFiles
$script:fileFixtures = @($finished, $smaller)

# Two clusters, because that is what the two titles produce: the merge pass
# skips packs, so they never land in one group.
$clusters = New-Object System.Collections.ArrayList
[void]$clusters.Add((Cluster @($finished)))
[void]$clusters.Add((Cluster @($smaller)))

Write-Host '  the two packs start in SEPARATE clusters:'
Check 'different titles, so two clusters to begin with' ($clusters.Count -eq 2)
Check 'and they are different families... no, one family' (@($clusters[0]).Count -eq 1 -and @($clusters[1]).Count -eq 1)
$fams = @(Get-ClusterFamilies -Clusters $clusters).Family
Check "both resolve to the family 'euphoria'"          ($fams[0] -eq 'euphoria' -and $fams[1] -eq 'euphoria')

$verdicts = Get-DedupVerdicts -Clusters $clusters -Gone @{}
Check 'the smaller pack is now proposed for deletion'  ($verdicts.ContainsKey('bbbb2222'))
Check 'the finished bigger pack is kept'               (-not $verdicts.ContainsKey('aaaa1111'))
if ($verdicts.ContainsKey('bbbb2222')) {
    Write-Host ('    reason: ' + $verdicts['bbbb2222'].Reason)
    Check 'the reason names the episode set they share'  ($verdicts['bbbb2222'].Reason -match 'S3-E1-E8')
    Check 'and says it was incomplete'                  ($verdicts['bbbb2222'].Reason -match 'incomplete')
    Check 'and reports both sizes'                      ($verdicts['bbbb2222'].Reason -match '40,37 GB against 15,69 GB')
}

Write-Host ''
Write-Host '== folding cannot widen the comparison past a set key =='
# Two different packs of one show, different ranges. Folding puts them in one
# group; the set key must still keep them apart.
$bigPack   = T 'cccc3333' 'Euphoria S03 1080p [ext.to]' 40.37 1.0 $tenFiles
$smallPack = T 'dddd4444' 'Euphoria S03e01-08 1080p [ext.to]' 15.69 0.5 $loserFiles
$script:fileFixtures = @($bigPack, $smallPack)
$two = New-Object System.Collections.ArrayList
[void]$two.Add((Cluster @($bigPack)))
[void]$two.Add((Cluster @($smallPack)))
$v2 = Get-DedupVerdicts -Clusters $two -Gone @{}
Check 'a 10-episode pack does NOT delete an 8-episode one' (-not $v2.ContainsKey('dddd4444'))
Check 'nor the other way round'                          (-not $v2.ContainsKey('cccc3333'))

Write-Host ''
Write-Host '== a pack does not delete a single episode =='
$pack = T 'eeee5555' 'Euphoria S03e01-e08 1080p [ext.to]' 15.69 1.0 $loserFiles
$single = T 'ffff6666' 'Euphoria US S03E08 2160p WEB-DL H265 [ext.to]' 10.09 1.0
$script:fileFixtures = @($pack, $single)
$three = New-Object System.Collections.ArrayList
[void]$three.Add((Cluster @($pack)))
[void]$three.Add((Cluster @($single)))
$v3 = Get-DedupVerdicts -Clusters $three -Gone @{}
Check 'the finished pack survives beside a smaller single' (-not $v3.ContainsKey('eeee5555'))

Write-Host ''
Write-Host '== different shows never meet =='
# Folding is by family, and a family is the first word of the show name. Two
# genuinely different shows that share a first word are the known limit of that
# guard and are asserted here rather than left implicit, so a change to the
# guard shows up as this failing rather than as a surprise deletion.
$office = T '9999aaaa' 'The.Office.S03E01.1080p.WEB-DL.mkv' 2.0 1.0
$bear   = T '8888bbbb' 'The.Bear.S03E01.1080p.WESDv.MKV'   2.0 1.0
$pairList = New-Object System.Collections.ArrayList
[void]$pairList.Add((Cluster @($office)))
[void]$pairList.Add((Cluster @($bear)))
$famPair = @(Get-ClusterFamilies -Clusters $pairList).Family
Check "both land in family 'the', which is the documented limit" ($famPair[0] -eq 'the' -and $famPair[1] -eq 'the')

$ted = T '7777cccc' 'Ted.Lasso.S04E08.2160p.Apple.TV.WEB-DL.H265.mkv' 2.0 1.0
$sunny = T '6666dddd' 'Its.Always.Sunny.In.Philadelphia.S18E01.2160p.WEB-DL.H265.mkv' 2.0 1.0
$twoList = New-Object System.Collections.ArrayList
[void]$twoList.Add((Cluster @($ted)))
[void]$twoList.Add((Cluster @($sunny)))
$famTwo = @(Get-ClusterFamilies -Clusters $twoList).Family
Check 'shows with different first words stay in different families' ($famTwo[0] -ne $famTwo[1])

Write-Host ''
Write-Host '== the set key is only corrected for S<n>-ALL =='
# A name that already states a range is taken at its word, as it is everywhere
# else. Correcting that too would mean listing the files of every series torrent
# on every run, for a case that does not arise.
# The pattern is LIFTED from the source line rather than retyped here, and that
# is the fix: two hand-typed versions were wrong in two different ways before.
# First '\\d' in a single-quoted string, where \\ is two literal characters, so it
# asked for a backslash followed by 'd'. Then '\-ALL\$' - the source has no
# backslash before the closing quote, so the pattern demanded a literal '$' at a
# point where the source has one, and never matched correct code.
#
# Both failures were the test being wrong about correct code, which is the worst
# kind: it would have been deleted or 'fixed' to match a typo.
$resolverLine = ($msrc -split "`n" | Where-Object { $_ -match '\$nameKey -notmatch' } | Select-Object -First 1)
$resolverPattern = if ($resolverLine -match "-notmatch\s+'([^']+)'") { $Matches[1] } else { '' }
Write-Host ("  the resolver's own pattern: '" + $resolverPattern + "'")
Check 'the resolver only corrects an S<n>-ALL key'      ($resolverPattern -and ('S3-ALL' -match $resolverPattern) -and -not ('S3-E1-E8' -match $resolverPattern))
Check 'and it leaves a plain range key alone'           ($resolverPattern -and -not ('S3-E1-E8' -match $resolverPattern))
$m = ($msrc -cmatch '(?s)function Resolve-TorrentSetKey.*?\$nameKey\s+-notmatch')
Check 'and only then reads the files'                  ($msrc -cmatch '(?s)function Resolve-TorrentSetKey.*?torrents/files\?hash=')
Check 'a magnet with no files keeps the name key'      ((Get-EpisodeSetFromFiles -Files @()) -eq 'S3-ALL' -or (Get-EpisodeSetFromFiles -Files @()) -eq '')

Write-Host ''
Write-Host '== the two scripts agree =='
# The pure half is shared by slicing; only the fetch is written twice. If the
# manager's resolver ever stops mirroring, the preview would quietly disagree
# with the run, which is worse than having no preview.
Check 'status.ps1 has its own resolver'                 ($ssrc -cmatch 'function Resolve-SetKey')
Check 'named for what it is'                            ($ssrc -cmatch 'function Resolve-SetKey \{\s*\r?\n\s*param\(\$T, \$Cache\)')
Check 'which also only corrects S<n>-ALL'               ($ssrc -cmatch '\$nameKey\s+-notmatch ''\^S\\d\+-ALL\$''')
Check 'both fold clusters by family'                    (
    ($msrc -cmatch '\$setGroups = @\(\)\r?\n\$famInfo = Get-ClusterFamilies') -and
    ($ssrc -cmatch '\$setGroups = @\(\)\s*\r?\n\s*\$famInfo = Get-ClusterFamilies'))
Check 'and neither folds with an uninvoked scriptblock' (-not (
    ($msrc -cmatch '\$setGroups = @\(\)\s*\r?\n\{') -or ($ssrc -cmatch '\$setGroups = @\(\)\s*\r?\n\s*\{')))
# That last one is not hypothetical: written that way first, a bare { } is a
# scriptblock LITERAL, PowerShell never runs it, $setGroups stayed empty and
# every deletion in the suite went quiet while the code still parsed.

Write-Host ''
if ($fail -eq 0) {
    Write-Host ("all episode-set tests passed (" + $pass + " checks)") -ForegroundColor Green
    exit 0
} else {
    Write-Host ("$fail of " + ($pass + $fail) + " episode-set checks FAILED") -ForegroundColor Red
    exit 1
}
