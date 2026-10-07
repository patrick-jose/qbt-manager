<#
    Exercises Get-LibraryDuplicateVerdicts (rule 4b), lifted out of
    qbt-manager.ps1 against a real temp folder tree.

    This rule exists because of a measured loss: 7 duplicated episodes of one
    season, 10,5 GB, every copy finished, every copy in the library. Rule 4 could
    not see them, because it compares inside a cluster and a cluster's family is
    the FIRST WORD of the show name - so 'its always sunny in philadelphia',
    'c'e sempre il sole a philadelphia' and 'www.uindex.org - ...' are three
    clusters of one show and never meet.

    The library folder is what makes this rule possible without a heuristic: the
    manager put those files in that folder itself, so the folder is a grouping
    already proven by a different route.

    Everything runs against real files on disk rather than synthetic objects,
    because the whole rule is about what is IN a folder - the names, the
    extensions, the lengths. A mocked FileInfo would test the arithmetic and
    nothing else.

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-library-dedupe.ps1
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

# ---------------------------------------------------------------------------
# lift the rule out of the manager and run it
# ---------------------------------------------------------------------------
# The whole helper block, not just the rule: the rule calls Get-TitleParts to read
# an episode out of a file name, and that function is defined earlier in the file
# than the rule is. Slicing from the rule alone loads a function that calls
# something undefined, which fails only when the first file is read.
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

# ---------------------------------------------------------------------------
# a real folder tree to judge
# ---------------------------------------------------------------------------
# Every path here is built from bytes, never typed. PowerShell 5.1 reads a .ps1
# without a BOM as ANSI, so a literal accented character in this file is not the
# character that ends up on disk - and the first version of this suite silently
# created nothing at all because of exactly that.
$showName   = 'its always sunny in philadelphia'
$folderA    = 'C' + [char]0x27 + [char]0xE8 + ' Sempre il Sole a Philadelphia S18'
$folderB    = 'Its Always Sunny In Philadelphia s18 WEB-DL 1080p'

$script:roots = @()

function New-Tree {
    param([string]$ShowName, [int]$Season, [hashtable]$Layout, [string[]]$Folders = @())
    # $Layout maps "folder|filename" to a size in MB.
    $base = Join-Path $env:TEMP ('libdup-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $seasonDir = Join-Path (Join-Path $base $ShowName) ("Season $Season")
    foreach ($f in @($Folders) + @($Layout.Keys | ForEach-Object { ($_ -split '\|')[0] } | Sort-Object -Unique)) {
        $d = Join-Path $seasonDir $f
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    foreach ($k in $Layout.Keys) {
        $parts = $k -split '\|'
        $p = Join-Path (Join-Path $seasonDir $parts[0]) $parts[1]
        $fs = [System.IO.File]::Create($p)
        # Sizes are in KB, not MB, and the whole suite stays under 200 MB.
        #
        # Not a style choice. The first version of this file created real files
        # sized in MB, and three trees reached 30 GB each on a machine with 8 GB
        # free. It then threw before its cleanup loop, so 24 directories were
        # orphaned in %TEMP% and held 186 GB until they were found and removed.
        # The rule only ever compares one length against another, so a few hundred
        # KB per file is more than enough to order them.
        $fs.SetLength([int64]$Layout[$k] * 1KB)
        $fs.Close()
    }
    $script:roots += $base
    return $base
}

# Call sites wrap the result in @(). See the note under Deletes.
function Judge {
    param([string]$Root)
    @(Get-LibraryDuplicateVerdicts -SeriesDir $Root -Torrents @())
}
# @($Rows) normalises the PARAMETER, because a function returning one row hands
# back a bare PSCustomObject rather than an array.
#
# No comma on the return, deliberately. These are always consumed as
# @(Deletes $rows).Count, and `return ,$r` would wrap the array a SECOND time:
# @(,@()) is a one-element array holding an empty array, so "no duplicates" would
# report a count of 1 and every negative check would pass for the wrong reason.
# The comma form was tried first and broke exactly those checks.
function Deletes  { param($Rows) @(@($Rows) | Where-Object { $_.Action -eq 'delete' }) }
function Holds    { param($Rows) @(@($Rows) | Where-Object { $_.Action -eq 'hold' }) }
function Names    { param($Rows) @(@($Rows) | ForEach-Object { Split-Path -Leaf $_.File } | Sort-Object) }

Write-Host ''
Write-Host '== the shipped config =='
Check 'the rule is enabled'      ($cfg.libraryDedupeEnabled -eq $true)
# "seriesDir is set", not "seriesDir looks like a path".
#
# The original check was `-match 'S'`, a proxy for "this contains a capital S,
# therefore it is a real Windows path". That stopped being true when config.json
# became publishable and the paths moved to config.local.json: the committed value
# is the placeholder PUT-YOUR-PATH-HERE, which has no capital S in it. So the
# check failed for a reason that had nothing to do with this rule.
#
# What matters here is only that the key exists and is a non-empty string. Whether
# it resolves to a real directory depends on config.local.json, which a fresh
# clone does not have and must not be required to have - so this cannot assert
# that, and the placeholder is not a failure. test-config.ps1 covers the merge.
Check 'seriesDir is set'         (-not [string]::IsNullOrWhiteSpace([string]$cfg.seriesDir))

Write-Host ''
Write-Host '== the case that motivated it: 7 episodes, two release groups =='
# The exact shapes that were on disk. folderA carries the season in every file
# name; folderB's files carry no season at all, which is the whole difficulty.
$layout = @{}
foreach ($ep in 1..7) {
    $layout["$folderA|Its.Always.Sunny.in.Philadelphia.S18E0$ep.ENG.SUB.ITA.1080p.WEB-DL.x264-ipdrofficial.mkv"] = (1500 + $ep)
    $layout["$folderB|e0$ep - Episode $ep.mkv"] = (1000 + $ep)
}
# E08 exists once and must never be touched.
$layout["$folderA|Its.Always.Sunny.in.Philadelphia.S18E08.ENG.SUB.ITA.1080p.WEB-DL.x264-ipdrofficial.mkv"] = 1520
# A pack in the same folder is not a duplicate of any single episode.
$layout["$folderA|Its.Always.Sunny.In.Philadelphia.S18E01-E08.1080p.WEB-DL.x264-PACKGRP.mkv"] = 12000

$root = New-Tree -ShowName $showName -Season 18 -Layout $layout
$r = @(Judge $root)
$d = @(Deletes $r)

Check 'all 7 duplicated episodes are found'          ($d.Count -eq 7)
Check 'and nothing else is'                          ($r.Count -eq 7)
Check 'the episode 8 file is left alone'             (@(Names $r) -notcontains 'Its.Always.Sunny.in.Philadelphia.S18E08.ENG.SUB.ITA.1080p.WEB-DL.x264-ipdrofficial.mkv')
Check 'the pack is left alone'                       (@(Names $r) -notcontains 'Its.Always.Sunny.In.Philadelphia.S18E01-E08.1080p.WEB-DL.x264-PACKGRP.mkv')
Check 'the smaller of each pair is the one flagged'  ((@(Names $d) | Where-Object { $_ -like 'e0*' }).Count -eq 7)
Check 'the bigger ipdrofficial copies survive'        (@(Names $r) -notcontains 'Its.Always.Sunny.in.Philadelphia.S18E01.ENG.SUB.ITA.1080p.WEB-DL.x264-ipdrofficial.mkv')

# The reason has to say enough to act on without re-deriving it.
$one = $d[0]
Check 'the reason names the season'                  ($one.Reason -match 'Season 18')
Check 'and both sizes'                               (($one.Reason -match 'GB') -and ($one.Reason -match 'same episode'))

Write-Host ''
Write-Host '== a season from the folder name, never from the file =='
# 'e01 - Title.mkv' parses as season 1 because it states no season. The rule must
# still recognise it, or it cannot see half of every duplicate pair.
$p = Get-TitleParts -Name 'e01 - Frank Marries a Corpse.mkv'
Check 'a bare e01 filename really does parse as season 1' ($p.Season -eq 1)
$found = @(@($d | Where-Object { (Split-Path -Leaf $_.File) -like 'e0*' }))
Check 'and is still matched inside Season 18'        ($found.Count -eq 7)

Write-Host ''
Write-Host '== a tie keeps one deterministic finished copy =='
$tieLayout = @{
    "$folderA|Its.Always.Sunny.in.Philadelphia.S18E01.1080p.WEB-DL.x264-A.mkv" = 1500
    "$folderB|Its.Always.Sunny.in.Philadelphia.S18E01.1080p.WEB-DL.x264-B.mkv" = 1500
}
$rootTie = New-Tree -ShowName $showName -Season 18 -Layout $tieLayout
$rTie = @(Judge $rootTie)
$holdsTie = @(Holds $rTie)
Check 'two equal copies delete one duplicate'         (@(Deletes $rTie).Count -eq 1)
# The larger of two equal files is the keeper and is not reported at all; the
# OTHER one is reported as held. Two rows would be wrong - it would name the
# keeper as a candidate for deletion of itself.
Check 'the equal-sized spare is not held'             ($holdsTie.Count -eq 0)
Check 'the duplicate explains itself'                 ($rTie[0].Reason -match 'duplicate episode')
Check 'a hold never carries an owning torrent'       (@($rTie | Where-Object { $_.OwnerHash -ne '' }).Count -eq 0)

# A file's allocated length is not evidence that its owning torrent finished.
$tieFiles = @(Get-ChildItem -LiteralPath $rootTie -Recurse -File | Sort-Object FullName)
$allocated = [IO.File]::OpenWrite($tieFiles[0].FullName)
try { $allocated.SetLength(1800KB) } finally { $allocated.Dispose() }
$unfinishedOwner = [pscustomobject]@{ hash = 'unfinished'; content_path = $tieFiles[0].FullName; progress = 0.2 }
$preallocated = @(Get-LibraryDuplicateVerdicts -SeriesDir $rootTie -Torrents @($unfinishedOwner))
Check 'unfinished preallocated file cannot displace the finished copy' ($preallocated.Count -eq 0)
$finishedOwner = [pscustomobject]@{ hash = 'finished'; content_path = $tieFiles[0].FullName; progress = 1 }
$goneOwner = @(Get-LibraryDuplicateVerdicts -SeriesDir $rootTie -Torrents @($finishedOwner) -Gone @{ finished = $true })
Check 'entry already removed cannot serve as a library keeper' ($goneOwner.Count -eq 0)

$incomingRoot = New-Tree -ShowName 'Example Show' -Season 1 -Layout @{
    'small|Example.Show.S01E01.small.mkv' = 100
    'best|Example.Show.S01E01.best.mkv' = 200
    'incoming|Example.Show.S01E01.incoming.mkv' = 400
}
$incomingFile = @(Get-ChildItem -LiteralPath $incomingRoot -Recurse -File | Where-Object { $_.Name -match 'incoming' })[0]
$incomingOwner = [pscustomobject]@{ hash = 'incoming'; content_path = $incomingFile.FullName; progress = 0.2 }
$withIncoming = @(Get-LibraryDuplicateVerdicts -SeriesDir $incomingRoot -Torrents @($incomingOwner))
Check 'larger downloading file does not block finished duplicate cleanup' ($withIncoming.Count -eq 1)
Check 'library removes small finished copy and preserves current best' ($withIncoming.Count -eq 1 -and $withIncoming[0].File -match 'small.mkv$')

Write-Host ''
Write-Host '== three copies of one episode: only the smallest go =='
$folderC = 'A Third Release Group'
$threeLayout = @{}
$threeLayout["$folderA|Its.Always.Sunny.in.Philadelphia.S18E02.1080p.WEB-DL.x264-BIG.mkv"]   = 1900
$threeLayout["$folderB|Its.Always.Sunny.in.Philadelphia.S18E02.1080p.WEB-DL.x264-MID.mkv"]   = 1400
$threeLayout["$folderC|Its.Always.Sunny.in.Philadelphia.S18E02.1080p.WEB-DL.x264-SMALL.mkv"] = 900
$root3 = New-Tree -ShowName $showName -Season 18 -Layout $threeLayout
$r3 = Judge $root3
Check 'of three copies, exactly two are flagged'    ((Deletes $r3).Count -eq 2)
Check 'and the largest is the one kept'             (@(Names $r3) -notcontains 'Its.Always.Sunny.in.Philadelphia.S18E02.1080p.WEB-DL.x264-BIG.mkv')
Check 'the smallest is among the flagged'           (@(Names $r3) -contains 'Its.Always.Sunny.in.Philadelphia.S18E02.1080p.WEB-DL.x264-SMALL.mkv')
Check 'and the middle one too'                      (@(Names $r3) -contains 'Its.Always.Sunny.in.Philadelphia.S18E02.1080p.WEB-DL.x264-MID.mkv')

Write-Host ''
Write-Host '== what this rule must never do =='
# Two different shows are two different folders, so nothing here can compare them.
$other = New-Tree -ShowName 'a completely different show' -Season 18 -Layout @{
    "$folderA|Its.Always.Sunny.in.Philadelphia.S18E01.1080p.WEB-DL.x264-X.mkv" = 1500
}
Check 'a different show folder is never compared'   ((Judge $other).Count -eq 0)

# Different seasons of one show are different episodes.
$twoSeasons = New-Tree -ShowName $showName -Season 18 -Layout @{
    "$folderA|Its.Always.Sunny.in.Philadelphia.S18E01.1080p.WEB-DL.x264-A.mkv" = 1500
    "$folderB|Its.Always.Sunny.in.Philadelphia.S18E01.1080p.WEB-DL.x264-B.mkv" = 1200
}
$season19 = Join-Path (Join-Path $twoSeasons $showName) 'Season 19'
New-Item -ItemType Directory -Path $season19 -Force | Out-Null
$p19 = Join-Path $season19 'Its.Always.Sunny.in.Philadelphia.S19E01.1080p.WEB-DL.x264-A.mkv'
$fs = [System.IO.File]::Create($p19); $fs.SetLength([int64]1200 * 1KB); $fs.Close()
$rSeason = Judge $twoSeasons
Check 'S18E1 smaller copy is flagged against S18E1'  (@(Names $rSeason) -contains 'Its.Always.Sunny.in.Philadelphia.S18E01.1080p.WEB-DL.x264-B.mkv')
Check 'and S19E1 is never flagged against S18E1'    (@(Names $rSeason) -notcontains 'Its.Always.Sunny.in.Philadelphia.S19E01.1080p.WEB-DL.x264-A.mkv')

# A file whose name yields no episode is skipped, never a wildcard.
$noEp = New-Tree -ShowName $showName -Season 18 -Layout @{
    "$folderA|Some Featurette - Behind The Scenes.mkv" = 1500
    "$folderB|Another Extra.mkv"                       = 900
}
Check 'files naming no episode are skipped'          ((Judge $noEp).Count -eq 0)

# A whole-season pack claims no single episode, so it duplicates nothing.
$seasonPack = New-Tree -ShowName $showName -Season 18 -Layout @{
    "$folderA|Its.Always.Sunny.in.Philadelphia.S18.1080p.WEB-DL.x264-A.mkv" = 12000
    "$folderB|Its.Always.Sunny.in.Philadelphia.S18.1080p.WEB-DL.x264-B.mkv" = 900
}
Check 'a whole-season pack is skipped'               ((Judge $seasonPack).Count -eq 0)

# A range pack vs a single episode: never comparable, exactly as in rule 4.
$rangeVsSingle = New-Tree -ShowName $showName -Season 18 -Layout @{
    "$folderA|Its.Always.Sunny.in.Philadelphia.S18E01-E08.1080p.WEB-DL.x264-RANGE.mkv"  = 12000
    "$folderB|Its.Always.Sunny.in.Philadelphia.S18E01.1080p.WEB-DL.x264-SINGLE.mkv"    = 1200
}
Check 'a range pack is not a duplicate of one of its episodes' ((Judge $rangeVsSingle).Count -eq 0)

# Non-video files are not episodes.
$srtTree = New-Tree -ShowName $showName -Season 18 -Layout @{
    "$folderA|Its.Always.Sunny.in.Philadelphia.S18E01.1080p.WEB-DL.x264-A.mkv" = 1500
    "$folderB|Its.Always.Sunny.in.Philadelphia.S18E01.1080p.WEB-DL.x264-B.srt" = 2
}
Check 'a subtitle file is not a duplicate episode'  ((Judge $srtTree).Count -eq 0)

# No library folder at all is not an error, and must not delete anything.
Check 'a missing library folder yields nothing'      (@(Get-LibraryDuplicateVerdicts -SeriesDir (Join-Path $env:TEMP 'no-such-lib-xyz') -Torrents @()).Count -eq 0)
# A real but empty library folder. Not $env:TEMP itself, which is full of other
# people's files and would make this assert something meaningless.
$emptyLib = Join-Path $env:TEMP ('libdup-empty-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $emptyLib -Force | Out-Null
$script:roots += $emptyLib
Check 'an empty library folder yields nothing'       (@(Get-LibraryDuplicateVerdicts -SeriesDir $emptyLib -Torrents @()).Count -eq 0)

Write-Host ''
Write-Host '== ownership, when qBittorrent knows about the file =='
# A file with no owning torrent is still a duplicate, but it must be removable by
# path rather than by torrent - and it must say so.
$noOwner = New-Tree -ShowName $showName -Season 18 -Layout @{
    "$folderA|Its.Always.Sunny.in.Philadelphia.S18E03.1080p.WEB-DL.x264-BIG.mkv"   = 1900
    "$folderB|Its.Always.Sunny.in.Philadelphia.S18E03.1080p.WEB-DL.x264-SMALL.mkv" = 900
}
$rNoOwner = @(Judge $noOwner)
Check 'an unowned duplicate is still found'         (@(Deletes $rNoOwner).Count -eq 1)
Check 'and it carries no torrent hash'              ([string]$rNoOwner[0].OwnerHash -eq '')
Check 'the reason says no torrent claims it'        ($rNoOwner[0].Reason -match 'no torrent claims')

Write-Host ''
Write-Host '== a duplicate that belongs to a PACK =='
# The case that makes this rule dangerous. A pack is the ONLY record of its other
# episodes, so deleting its entry to remove one duplicate file takes wanted - and
# sometimes unique - episodes with it. The file is the duplicate; the entry is not.
#
# The torrents below are synthetic objects, but only their hash/content_path/
# name are read, and every one of those is a real string in the real shape. What
# is NOT faked is the file tree: the pack's other episodes really are absent from
# the library folder, which is the fact the decision turns on.

function Fake-Torrent {
    param([string]$Hash, [string]$Name, [string]$ContentPath, [string]$Parts)
    $o = [pscustomobject]@{ hash = $Hash; name = $Name; content_path = $ContentPath; state = 'stoppedUP'; progress = 1 }
    if ($Parts) { $o | Add-Member -NotePropertyName parts -NotePropertyValue ($Parts | ConvertFrom-Json) }
    return $o
}

# Call sites wrap the result: @(Judge-With ...). No comma on the return, for the
# reason spelled out under Deletes below.
function Judge-With {
    param([string]$Root, [object[]]$Torrents)
    @(Get-LibraryDuplicateVerdicts -SeriesDir $Root -Torrents $Torrents)
}
function FileOnly { param($Rows) @(@($Rows) | Where-Object { $_.Action -eq 'delete-file-only' }) }

# The pack holds S18E01-E05. Its E03 file is in the library and is the SMALLER
# copy of E03, so it is the duplicate. E01, E02, E04 and E05 are NOT in the
# library at all - the pack is the only record of them.
# The filenames carry the full release prefix, not a bare 'S18E03.mkv'. That is
# not decoration: a name with no title before the season marker parses as NOT a
# series at all, so both files here were skipped and the pair never met.
$packDirName = 'The Pack Folder'
$packE3 = 'Its.Always.Sunny.in.Philadelphia.S18E03'
$packLayout = @{
    "$packDirName|$packE3.1080p.WEB-DL.x264-PACKGRP.mkv" = 900
    "$folderB|$packE3.1080p.WEB-DL.x264-BIGGER.mkv"     = 1900
}
$rootPack = New-Tree -ShowName $showName -Season 18 -Layout $packLayout
$packHash = 'a' * 40
$packTorrent = Fake-Torrent -Hash $packHash `
    -Name 'Its.Always.Sunny.in.Philadelphia.S18E01-E05.1080p.WEB-DL.x264-PACKGRP [ext.to]' `
    -ContentPath (Join-Path (Join-Path (Join-Path $rootPack $showName) 'Season 18') $packDirName) `
    -Parts '{"IsMultiEpisode":true,"Episode":1,"EpisodeLast":5,"Season":18,"Title":"its always sunny in philadelphia"}'

$rp = @(Judge-With $rootPack @($packTorrent))
$fileOnlyPack = @(FileOnly $rp)
Check 'a duplicate file inside a pack is found'            ($rp.Count -eq 1)
Check 'but the entry is NOT deleted with it'              ($rp[0].Action -eq 'delete-file-only')
Check 'and it carries no torrent hash to delete'          ([string]$rp[0].OwnerHash -eq '')
Check 'and no owner object is handed to the caller'       ($null -eq $rp[0].Owner)
Check 'the reason names the episodes at stake'            ($rp[0].Reason -match 'S18E01')
Check 'the pack entry is kept, and says so'              ($rp[0].Reason -match 'entry is kept')
Check 'it is not also listed as a full delete'            ((Deletes $rp).Count -eq 0)

# Same pack, but the library already holds every OTHER episode the pack carries.
# Then the entry has nothing left that only it holds, so it goes with its data.
$allEpLayout = @{}
$packE0 = 'Its.Always.Sunny.in.Philadelphia.S18E0'
foreach ($ep in 1, 2, 4, 5) {
    # a DIFFERENT release group holds these, so they survive the entry going
    $allEpLayout["$folderB|$packE0$ep.1080p.WEB-DL.x264-OTHERGRP.mkv"] = 1500
}
$allEpLayout["$packDirName|$packE3.1080p.WEB-DL.x264-PACKGRP.mkv"] = 900
$allEpLayout["$folderA|$packE3.1080p.WEB-DL.x264-BIGGER.mkv"]     = 1900
$rootAllEp = New-Tree -ShowName $showName -Season 18 -Layout $allEpLayout

$packTorrent2 = Fake-Torrent -Hash $packHash `
    -Name 'Its.Always.Sunny.in.Philadelphia.S18E01-E05.1080p.WEB-DL.x264-PACKGRP [ext.to]' `
    -ContentPath (Join-Path (Join-Path (Join-Path $rootAllEp $showName) 'Season 18') $packDirName) `
    -Parts '{"IsMultiEpisode":true,"Episode":1,"EpisodeLast":5,"Season":18,"Title":"its always sunny in philadelphia"}'
$rt = @(Judge-With $rootAllEp @($packTorrent2))
Check 'a pack with no episode left unheld is deleted whole' (@(Deletes $rt).Count -eq 1)
Check 'and it takes its hash with it'                        ([string]$rt[0].OwnerHash -eq $packHash)
Check 'the reason explains that nothing is lost'             ($rt[0].Reason -match 'already in the library')

# The same pack, but one of its other episodes is held ONLY by this pack. That is
# the case that must hold, because deleting the entry would strand the episode.
$strandLayout = @{}
$strandLayout["$packDirName|$packE3.1080p.WEB-DL.x264-PACKGRP.mkv"] = 900
$strandLayout["$folderA|$packE3.1080p.WEB-DL.x264-BIGGER.mkv"]     = 1900
# E02 is in the library and only the pack holds it
$strandLayout["$packDirName|$($packE0)2.1080p.WEB-DL.x264-PACKGRP.mkv"] = 1500
$rootStrand = New-Tree -ShowName $showName -Season 18 -Layout $strandLayout
$packTorrent3 = Fake-Torrent -Hash $packHash `
    -Name 'Its.Always.Sunny.in.Philadelphia.S18E01-E05.1080p.WEB-DL.x264-PACKGRP [ext.to]' `
    -ContentPath (Join-Path (Join-Path (Join-Path $rootStrand $showName) 'Season 18') $packDirName) `
    -Parts '{"IsMultiEpisode":true,"Episode":1,"EpisodeLast":5,"Season":18,"Title":"its always sunny in philadelphia"}'
$rs = @(Judge-With $rootStrand @($packTorrent3))
Check 'an episode only the pack holds blocks the deletion'  (@(Deletes $rs).Count -eq 0)
Check 'and the duplicate is left as a file-only candidate'   (@(FileOnly $rs).Count -eq 1)

# A SINGLE-episode torrent is unaffected: there is nothing else to lose, so it is
# deleted whole exactly as before.
$e4 = 'Its.Always.Sunny.in.Philadelphia.S18E04'
$singleLayout = @{}
$singleLayout["$folderB|$e4.1080p.WEB-DL.x264-SMALL.mkv"] = 900
$singleLayout["$folderA|$e4.1080p.WEB-DL.x264-BIG.mkv"]   = 1900
$rootSingle = New-Tree -ShowName $showName -Season 18 -Layout $singleLayout
$singleHash = 'b' * 40
$singleTorrent = Fake-Torrent -Hash $singleHash `
    -Name 'Its.Always.Sunny.in.Philadelphia.S18E04.1080p.WEB-DL.x264-SMALL [ext.to]' `
    -ContentPath (Join-Path (Join-Path (Join-Path $rootSingle $showName) 'Season 18') $folderB) `
    -Parts '{"IsMultiEpisode":false,"Episode":4,"Season":18,"Title":"its always sunny in philadelphia"}'
$rSingle = @(Judge-With $rootSingle @($singleTorrent))
Check 'a single-episode duplicate is still deleted whole'    (@(Deletes $rSingle).Count -eq 1)
Check 'with its hash, so the data goes too'                  ([string]$rSingle[0].OwnerHash -eq $singleHash)

Write-Host ''
Write-Host '== the switch =='
Check 'the rule can be turned off in config'         ($cfg.PSObject.Properties['libraryDedupeEnabled'] -ne $null)

# ---------------------------------------------------------------------------
# cleanup
# ---------------------------------------------------------------------------
# A plain loop, not a try/finally: the whole suite runs under
# $ErrorActionPreference = 'Stop', and a throw part-way through is exactly how
# 186 GB of test files ended up orphaned in %TEMP% once already. There is no way
# to run a finally around the body of a script without wrapping the entire script,
# so the honest fix is to make the body not throw: New-Tree creates its directory
# before writing into it, and every Check reports rather than throws.
#
# Only the trees this run created are removed. A wildcard sweep over 'libdup-*'
# would also delete a concurrent run's directories, which are not this script's
# to touch.
foreach ($r in $script:roots) {
    if (Test-Path -LiteralPath $r) { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
}

# Prove it, rather than trusting it. This suite writes to disk, so "it cleaned up
# after itself" is a claim worth checking every run.
$mine = 0
foreach ($r in $script:roots) { if (Test-Path -LiteralPath $r) { $mine++ } }
Check 'every tree it created is gone'          ($mine -eq 0)

Write-Host ''
if ($script:fails -eq 0) {
    Write-Host 'all library-dedupe tests passed'
}
else {
    Write-Host ("{0} library-dedupe test(s) FAILED" -f $script:fails)
    exit 1
}
