# Regression tests for the loss of 2026-10-05.
#
#   2026-10-05 22:28:13 [DELETE] "Euphoria.S03.COMPLETE.1080p.AMZN.WEB-DL.H.264-EniaHD" [c7fc56a6]
#     - duplicate episode inside Euphoria\Season 3: 5,61 GB beside the larger 8,16 GB
#       copy of the same episode (3-E7)
#
# One file of eight was the duplicate: the 5,61 GB 1080p of S03E07, sitting beside
# an 8,16 GB 2160p of the same episode. The rule correctly identified the FILE. It
# then deleted the whole 40 GB pack instead, and S03E01-E06 and S03E08 - roughly
# 31 GB with no other copy anywhere on the machine - went with it.
#
# WHY IT HAPPENED. The pack-safety guard read an explicit episode range out of the
# torrent NAME:
#
#     if ($Owner.parts.IsMultiEpisode -and $Owner.parts.EpisodeLast) { ... }
#
# A whole-season pack states no range. 'Euphoria.S03.COMPLETE' parses to Episode 0,
# IsMultiEpisode false, EpisodeLast null, so the guard was false, the branch that
# protects a pack was skipped entirely, and the verdict fell through to a plain
# `delete` carrying the pack's hash. The check only ever ran for packs that
# happened to name their range.
#
# So this suite states the rule the user gave: a duplicate EPISODE is removed, and
# an entry that holds anything else is never removed with it.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-pack-safety.ps1

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

$script:pass = 0; $script:fail = 0
function Check {
    param([string]$Label, [bool]$Ok)
    if ($Ok) { $script:pass++; Write-Host "  [PASS] $Label" }
    else { $script:fail++; Write-Host "  [FAIL] $Label" -ForegroundColor Red }
}

function Get-Slice {
    param([string]$Text, [string]$From, [string]$To)
    $a = $Text.IndexOf($From); $b = $Text.IndexOf($To)
    if ($a -lt 0 -or $b -le $a) { throw "could not locate the block between '$From' and '$To'" }
    return $Text.Substring($a, $b - $a)
}

$src = [System.IO.File]::ReadAllText((Get-ProjectFile 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)

# The detection region (Get-TitleParts and friends), then one slice carrying
# Test-Claimed, the rule itself and its file helper - they are contiguous, and
# slicing them apart leaves the rule itself undefined.
Invoke-Expression (Get-Slice $src '$script:boundaryPattern' 'function Get-DoviHit')
Invoke-Expression (Get-Slice $src 'function Test-Claimed' 'function Get-PhantomVerdicts')
foreach ($fn in 'Get-LibraryDuplicateVerdicts', 'Get-LibraryEpisodeFiles', 'Test-Claimed', 'Get-TitleParts') {
    if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { throw "$fn was not loaded by the slices" }
}

# Resolve-TorrentSetKey is in the actions region and is what the fix now calls, so
# it is sliced directly. It needs Invoke-ApiGet to read a pack's file list, which
# is the ONE thing not worth reaching over the network for: a stub lets each test
# state exactly which episodes its pack holds, which is the fact under test.
Invoke-Expression (Get-Slice $src 'function Resolve-TorrentSetKey' 'function Get-PackEpisodeBytes')
$script:fileLists = @{}
function Invoke-ApiGet {
    param([string]$Endpoint)
    if ($Endpoint -notmatch 'torrents/files\?hash=(.+)$') { return @() }
    $h = $Matches[1].ToLowerInvariant()
    if ($script:fileLists.ContainsKey($h)) { return @($script:fileLists[$h]) }
    return @()
}

# ---------------------------------------------------------------------------
# a real folder tree, and real torrents pointing into it
# ---------------------------------------------------------------------------
$script:roots = @()

# Trees left behind by a run that threw part-way through. The suite cleans up at
# the end, but a crashed run leaves its tree on disk, and the final check would
# then report an earlier run's leftovers as its own failure. Cleared first so the
# check means what it says.
foreach ($stale in @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'packsafe-*' -ErrorAction SilentlyContinue)) {
    Remove-Item -LiteralPath $stale.FullName -Recurse -Force -ErrorAction SilentlyContinue
}

function New-Tree {
    param([hashtable]$Layout)
    # $Layout maps "folder|filename" to a size in KB. KB, not MB: an earlier suite
    # created files sized in MB, filled an 8 GB disk, and orphaned 186 GB in %TEMP%
    # before its cleanup loop could run.
    $base = Join-Path $env:TEMP ('packsafe-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $seasonDir = Join-Path (Join-Path $base 'Some Show') 'Season 3'
    foreach ($f in @($Layout.Keys | ForEach-Object { ($_ -split '\|')[0] } | Sort-Object -Unique)) {
        New-Item -ItemType Directory -Path (Join-Path $seasonDir $f) -Force | Out-Null
    }
    foreach ($k in $Layout.Keys) {
        $parts = $k -split '\|'
        $p = Join-Path (Join-Path $seasonDir $parts[0]) $parts[1]
        $fs = [System.IO.File]::Create($p)
        $fs.SetLength([int64]$Layout[$k] * 1KB)
        $fs.Close()
    }
    $script:roots += $base
    return $base
}

function Fake-Torrent {
    param([string]$Hash, [string]$Name, [string]$Root, [string]$Folder, [string]$Parts)
    $o = [pscustomobject]@{
        hash = $Hash; name = $Name; state = 'stoppedUP'; progress = 1
        content_path = (Join-Path (Join-Path (Join-Path $Root 'Some Show') 'Season 3') $Folder)
    }
    if ($Parts) { $o | Add-Member -NotePropertyName parts -NotePropertyValue ($Parts | ConvertFrom-Json) }
    return $o
}

function Judge-With { param([string]$Root, [object[]]$Torrents) @(Get-LibraryDuplicateVerdicts -SeriesDir $Root -Torrents $Torrents) }
function Deletes      { param($Rows) @(@($Rows) | Where-Object { $_.Action -eq 'delete' }) }
function FileOnly     { param($Rows) @(@($Rows) | Where-Object { $_.Action -eq 'delete-file-only' }) }
function Holds        { param($Rows) @(@($Rows) | Where-Object { $_.Action -eq 'hold' }) }

# The real names, sizes and file lists from the incident, so the test is the
# incident and not a paraphrase of it.
$PACK = 'Some.Show.S03.COMPLETE.1080p.AMZN.WEB-DL.H.264-EniaHD [ext.to]'
$PACK_HASH = ('c' * 8) + ('7fc56a6' + ('0' * 23))
$packFolder = 'Some.Show.S03.1080p.AMZN.WEB-DL.H.264-EniaHD'
$otherFolder = 'www.UIndex.org - Some.Show.S03E07.2160p.SDR.WEB.DD5.1.H265-GRP'
$e3 = 'Some.Show.S03E03.The.Ballad.of.Paladin.1080p.AMZN.WEB-DL.H.264-EniaHD.mkv'
$e7small = 'Some.Show.S03E07.Rain.or.Shine.1080p.AMZN.WEB-DL.H.264-EniaHD.mkv'
$e7big = 'Some.Show.S03E07.MULTi.2160p.SDR.WEB.DD5.1.H265-SiC.mkv'

# The pack's own eight files, as qBittorrent would list them. This is what tells
# the rule the pack holds eight episodes, and it is the fact the old guard could
# not see because the name states no range.
$packFiles = @()
foreach ($n in 1..8) {
    $packFiles += [pscustomobject]@{ name = ("Some.Show.S03.1080p.AMZN.WEB-DL.H.264-EniaHD/Some.Show.S03E{0:D2}.1080p.AMZN.WEB-DL.H.264-EniaHD.mkv" -f $n) }
}
$script:fileLists[$PACK_HASH.ToLowerInvariant()] = $packFiles

# A whole-season pack's PARTS, exactly as the parser produces them: Episode 0,
# not multi-episode, no EpisodeLast. Stated here rather than derived, so the test
# fails loudly if the parser ever changes shape underneath it.
$packParts = '{"IsSeries":true,"IsMultiEpisode":false,"Episode":0,"EpisodeLast":null,"Season":3,"Title":"some show"}'

Write-Host ''
Write-Host '== what the parser makes of a whole-season pack =='
$pp = Get-TitleParts -Name $PACK
Check 'it is a series'                     ($pp.IsSeries)
Check 'with episode 0'                     ($pp.Episode -eq 0)
Check 'NOT flagged multi-episode'          (-not $pp.IsMultiEpisode)
Check 'and with no EpisodeLast'            ($null -eq $pp.EpisodeLast)
Write-Host '  the old guard was: IsMultiEpisode -and EpisodeLast - both false, so the'
Write-Host '  pack-safety branch was skipped and the verdict became a plain delete.'

Write-Host ''
Write-Host '== the incident, reproduced =='
# The library holds the pack's E03, and TWO copies of E07 - the pack's 5,61 GB
# 1080p and someone else's larger 2160p. E01, E02, E04, E05, E06 and E08 are NOT
# in the library: the pack is the only record of them.
$layout = @{
    "$packFolder|$e3"      = 900
    "$packFolder|$e7small" = 900
    "$otherFolder|$e7big"  = 1900
}
$root = New-Tree -Layout $layout
$pack = Fake-Torrent -Hash $PACK_HASH -Name $PACK -Root $root -Folder $packFolder -Parts $packParts
$rows = @(Judge-With $root @($pack))

Check 'exactly one verdict'                ($rows.Count -eq 1)
Check 'and it is the SMALLER E07 file'    ((Split-Path -Leaf $rows[0].File) -eq $e7small)
Check 'it is NOT a whole-entry delete'     (@(Deletes $rows).Count -eq 0)
Check 'it is a file-only removal'          (@(FileOnly $rows).Count -eq 1)
Check 'and no hash is carried, so the entry cannot be deleted' ([string]$rows[0].OwnerHash -eq '')
Check 'no Owner is handed to the caller'   ($null -eq $rows[0].Owner)
Write-Host ('  reason: ' + $rows[0].Reason)

Write-Host ''
Write-Host '== the six episodes the pack still holds are named =='
# The point of the verdict is that it says what would be lost. E07 is the
# duplicate and must NOT appear; the other six must.
$reason = [string]$rows[0].Reason
foreach ($n in 1, 2, 4, 5, 6, 8) {
    Check ("S3E{0} is named as still held" -f $n) ($reason -match ("S3E" + $n))
}
Check 'S3E07 is NOT named - it is the duplicate' (-not ($reason -match 'S3E07'))

Write-Host ''
Write-Host '== a single-episode owner is still deleted whole =='
# The rule that used to work, and must keep working. A one-episode entry holds
# nothing that deleting it could lose beyond the file already going.
$singleRoot = New-Tree -Layout @{
    "$packFolder|$e3"      = 900
    "$otherFolder|$e3"     = 1900
}
$singleHash = ('d' * 8) + ('11111111' + ('0' * 23))
$single = Fake-Torrent -Hash $singleHash `
    -Name 'Some.Show.S03E03.The.Ballad.of.Paladin.1080p.AMZN.WEB-DL.H.264-EniaHD [ext.to]' `
    -Root $singleRoot -Folder $packFolder `
    -Parts '{"IsSeries":true,"IsMultiEpisode":false,"Episode":3,"EpisodeLast":null,"Season":3,"Title":"some show"}'
$singleRows = @(Judge-With $singleRoot @($single))
Check 'it is deleted whole'                (@(Deletes $singleRows).Count -eq 1)
Check 'with its hash, so the data goes'    ([string]$singleRows[0].OwnerHash -eq $singleHash)

Write-Host ''
Write-Host '== a named-range pack is still protected =='
# The case that already worked, kept working. The fix must not have been 'always
# delete-file-only'.
$rangeRoot = New-Tree -Layout @{
    "$packFolder|$e3"      = 900
    "$packFolder|$e7small" = 900
    "$otherFolder|$e7big"  = 1900
}
$rangeHash = ('e' * 8) + ('22222222' + ('0' * 23))
$rangePack = Fake-Torrent -Hash $rangeHash `
    -Name 'Some.Show.S03E01-E08.1080p.AMZN.WEB-DL.H.264-EniaHD [ext.to]' `
    -Root $rangeRoot -Folder $packFolder `
    -Parts '{"IsSeries":true,"IsMultiEpisode":true,"Episode":1,"EpisodeLast":8,"Season":3,"Title":"some show"}'
$rangeRows = @(Judge-With $rangeRoot @($rangePack))
Check 'a range pack is protected too'     (@(Deletes $rangeRows).Count -eq 0)
Check 'file-only, as before'               (@(FileOnly $rangeRows).Count -eq 1)

Write-Host ''
Write-Host '== a pack that really holds nothing else IS deleted =='
# The other direction, and the one that keeps 'protect every pack' from being just
# a slower way of filling the disk.
#
# Getting orphaned down to zero needs the library to hold EVERY other episode of
# the pack from a DIFFERENT entry - otherwise each of them is held only by this
# pack and is correctly reported as still-held. The first version of this test
# just added a second E3 file and expected a delete; the library still lacked
# E01, E02, E04, E05, E06 and E08, so file-only was the right answer and the test
# was wrong.
#
# So: a pack holds E01-E03. Three single-episode entries also hold E01, E02 and
# E03, each with its own file in the library. The pack's files are the SMALLER
# copy of all three, so all three are duplicates - and for each one, every other
# episode of the pack is held by a different entry. Nothing is orphaned, so the
# pack's entry goes with its data.
$clearLayout = @{}
foreach ($n in 1..3) {
    $clearLayout["$packFolder|Some.Show.S03E{0:D2}.PACK.1080p.mkv" -f $n] = 900
    $clearLayout["$otherFolder|Some.Show.S03E{0:D2}.OTHER.2160p.mkv" -f $n] = 1900
}
$clearRoot = New-Tree -Layout $clearLayout
$clearHash = ('f' * 8) + ('33333333' + ('0' * 23))
$clearPack = Fake-Torrent -Hash $clearHash `
    -Name 'Some.Show.S03E01-E03.1080p.WEB-DL.H.264-EniaHD [ext.to]' `
    -Root $clearRoot -Folder $packFolder `
    -Parts '{"IsSeries":true,"IsMultiEpisode":true,"Episode":1,"EpisodeLast":3,"Season":3,"Title":"some show"}'
$clearTorrents = @($clearPack)
for ($n = 1; $n -le 3; $n++) {
    $clearTorrents += Fake-Torrent -Hash (('1' * 8) + ('4444444' + $n) + ('0' * 19)) `
        -Name ("Some.Show.S03E{0:D2}.2160p.WEB-DL.H265-OTHERGRP [ext.to]" -f $n) `
        -Root $clearRoot -Folder $otherFolder `
        -Parts ('{"IsSeries":true,"IsMultiEpisode":false,"Episode":' + $n + ',"EpisodeLast":null,"Season":3,"Title":"some show"}')
}
$clearRows = @(Judge-With $clearRoot $clearTorrents)
Check 'three duplicates are found'         ($clearRows.Count -eq 3)
Check 'NOT one of them is file-only'       (@(FileOnly $clearRows).Count -eq 0)
Check 'every one deletes the pack entry'   (@(Deletes $clearRows).Count -eq 3)
Check 'and the pack hash is carried'       (@($clearRows | Where-Object { [string]$_.OwnerHash -eq $clearHash }).Count -eq 3)

Write-Host ''
Write-Host '== an owner whose episodes cannot be read is NEVER deleted =='
# The refusal that has to hold when nothing is known. A magnet, or an unreadable
# file list, is not evidence of a single episode - it is an absence of evidence,
# and the guess would be 'everything it holds'.
$unkRoot = New-Tree -Layout @{
    "$packFolder|$e3"      = 900
    "$packFolder|$e7small" = 900
    "$otherFolder|$e7big"  = 1900
}
$unkHash = ('a' * 8) + ('44444444' + ('0' * 23))
$unkPack = Fake-Torrent -Hash $unkHash `
    -Name 'Some.Show.S03.COMPLETE.1080p.WEB-DL.H264-GRP [ext.to]' `
    -Root $unkRoot -Folder $packFolder `
    -Parts '{"IsSeries":true,"IsMultiEpisode":false,"Episode":0,"EpisodeLast":null,"Season":3,"Title":"some show"}'
# Deliberately NO file list registered for this hash, so the name cannot be
# corrected and no range can be established.
$unkRows = @(Judge-With $unkRoot @($unkPack))
Check 'it is not deleted whole'            (@(Deletes $unkRows).Count -eq 0)
Check 'it is file-only'                    (@(FileOnly $unkRows).Count -eq 1)
Check 'and the reason admits the guess'    ([string]$unkRows[0].Reason -match 'could not be established')
Check 'no hash is carried'                 ([string]$unkRows[0].OwnerHash -eq '')

Write-Host ''
Write-Host '== the caller must actually remove the file =='
# The second bug, found while diagnosing the first. The panel branch for
# 'delete-file-only' ended in `continue`, which skipped the removal below it, so
# every such verdict was announced and never carried out - silently, every run.
$runBody = ($src -split "`n")
$callAt = ($runBody | Select-String -Pattern 'Get-LibraryDuplicateVerdicts -SeriesDir \$cfg\.seriesDir' | Select-Object -First 1).LineNumber
$panelAt = 0; $removeAt = 0
for ($k = $callAt; $k -lt $callAt + 140; $k++) {
    if ($runBody[$k] -match 'ForegroundColor Magenta') { $panelAt = $k }
    # The FIRST removal after the panel, not the last. There are two Remove-Item
    # calls on this path - the file-only one and the no-owner one - and reaching
    # to the second spans the file-only branch's own `continue`, which is correct
    # code and made this check fail against a fixed script.
    if ($removeAt -eq 0 -and $panelAt -gt 0 -and $runBody[$k] -match 'Remove-Item -LiteralPath \$d\.File') { $removeAt = $k }
}
Check 'the panel branch was located'       ($panelAt -gt 0)
Check 'the removal was located'            ($removeAt -gt $panelAt)
$panelBlock = ($runBody[$panelAt..($removeAt - 1)]) -join "`n"
$panelOnly = ($panelBlock -split '# Both sides are stopped')[0]
Check 'the panel itself does NOT skip deletion' (-not ($panelOnly -cmatch '(?m)^\s*continue\s*$'))
Write-Host '  a `continue` between the panel and the removal skips the removal.'

Write-Host ''
Write-Host '== the verdict can never carry a hash with delete-file-only =='
# Belt and braces on the same property, asserted at the source: the two are what
# the caller acts on, and delete-file-only with a hash would let a future edit
# delete the entry through the other branch.
$verdictBlock = (Get-Slice $src 'function Get-LibraryDuplicateVerdicts' 'function Get-LibraryEpisodeFiles')
Check 'OwnerHash is blank for delete-file-only' ($verdictBlock -cmatch "OwnerHash\s+= if \(\`$action -eq 'delete-file-only'\) \{ '' \}")
Check 'and Owner is null for delete-file-only'    ($verdictBlock -cmatch "Owner\s+= \`$\(if \(\`$action -eq 'delete-file-only'\) \{ \`$null \}")

Write-Host ''
Write-Host '== every tree this suite created is gone =='
foreach ($r in $script:roots) { Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction SilentlyContinue }
$left = @(Get-ChildItem -LiteralPath $env:TEMP -Directory -Filter 'packsafe-*' -ErrorAction SilentlyContinue)
Check 'no pack-safety tree left behind'    ($left.Count -eq 0)

Write-Host ''
if ($script:fail -eq 0) {
    Write-Host ("all pack-safety tests passed (" + $script:pass + " checks)") -ForegroundColor Green
    exit 0
} else {
    Write-Host ("$script:fail of " + ($script:pass + $script:fail) + " pack-safety checks FAILED") -ForegroundColor Red
    exit 1
}
