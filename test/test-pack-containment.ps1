$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = [IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'), [Text.Encoding]::UTF8)
$start = $src.IndexOf('$script:boundaryPattern')
$end = $src.IndexOf('# actions', $start)
if ($start -lt 0 -or $end -le $start) { throw 'could not locate manager helper block' }
Invoke-Expression $src.Substring($start, $end - $start)

$script:fails = 0
function Check {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { "[PASS] $Name" } else { $script:fails++; "[FAIL] $Name" }
}

function Pack {
    param([string]$Hash, [string]$Name, [double]$TotalGB, [double]$Progress)
    [pscustomobject]@{
        hash = $Hash; name = $Name; size = [int64]($TotalGB * 1GB); progress = $Progress
        parts = (Get-TitleParts -Name $Name)
    }
}
function Video {
    param([string]$Name, [double]$GB)
    [pscustomobject]@{ name = $Name; size = [int64]($GB * 1GB) }
}

$candidate = Pack 'candidate' 'Example Show S01E01-E02 1080p WEB-DL' 5 0
$keeper = Pack 'keeper' 'Example Show S01E01-E04 2160p WEB-DL' 20 1
$cache = @{
    candidate = @((Video 'Example.Show.S01E01.mkv' 2.0), (Video 'Example.Show.S01E02.mkv' 2.5))
    keeper = @((Video 'Example.Show.S01E01.mkv' 3.0), (Video 'Example.Show.S01E02.mkv' 3.5),
               (Video 'Example.Show.S01E03.mkv' 4.0), (Video 'Example.Show.S01E04.mkv' 4.0))
}
$verdict = Get-ContainedPackDuplicateVerdict -Candidate $candidate -Keeper $keeper `
    -SetKeyCache @{} -FileSizeCache $cache
Check 'an unfinished smaller subset pack is removable against a finished wider pack' `
    ($null -ne $verdict -and $verdict.First -eq 1 -and $verdict.Last -eq 2)
Check 'the proof compares each episode file, not the pack totals' `
    ($verdict.Comparisons.Count -eq 2 -and $verdict.Comparisons[0].KeeperBytes -gt $verdict.Comparisons[0].CandidateBytes -and
     $verdict.Comparisons[1].KeeperBytes -gt $verdict.Comparisons[1].CandidateBytes)

$cache.keeper[1] = Video 'Example.Show.S01E02.mkv' 2.0
Check 'one smaller keeper episode prevents removing the whole candidate pack' `
    ($null -eq (Get-ContainedPackDuplicateVerdict -Candidate $candidate -Keeper $keeper -SetKeyCache @{} -FileSizeCache $cache))
$cache.keeper[1] = Video 'Example.Show.S01E02.mkv' 3.5

$otherSeason = Pack 'other-season' 'Example Show S02E01-E04 2160p WEB-DL' 20 1
Check 'a different season cannot be used as the keeper' `
    ($null -eq (Get-ContainedPackDuplicateVerdict -Candidate $candidate -Keeper $otherSeason -SetKeyCache @{} -FileSizeCache $cache))
$otherShow = Pack 'other-show' 'Different Show S01E01-E04 2160p WEB-DL' 20 1
Check 'a different show cannot be used as the keeper' `
    ($null -eq (Get-ContainedPackDuplicateVerdict -Candidate $candidate -Keeper $otherShow -SetKeyCache @{} -FileSizeCache $cache))
$unfinished = Pack 'unfinished' 'Example Show S01E01-E04 2160p WEB-DL' 20 0.99
Check 'an unfinished wider pack cannot be used as the keeper' `
    ($null -eq (Get-ContainedPackDuplicateVerdict -Candidate $candidate -Keeper $unfinished -SetKeyCache @{} -FileSizeCache $cache))

# If qBittorrent conservatively declines whole-torrent data deletion because the
# content_path claims overlap, the fallback may remove only exact, unclaimed
# candidate files after the larger keeper is confirmed on disk.
$tree = Join-Path ([IO.Path]::GetTempPath()) ('qbt-pack-clean-' + [guid]::NewGuid().ToString('N'))
$candidateDir = Join-Path $tree 'candidate'
$keeperDir = Join-Path $tree 'keeper'
New-Item -ItemType Directory -Path $candidateDir,$keeperDir -Force | Out-Null
$candidate = Pack 'candidate' 'Example Show S01E01-E02 1080p WEB-DL' 5 0
$candidate | Add-Member -NotePropertyName save_path -NotePropertyValue $tree -Force
$candidate | Add-Member -NotePropertyName content_path -NotePropertyValue $candidateDir -Force
$keeper = Pack 'keeper' 'Example Show S01E01-E04 2160p WEB-DL' 20 1
$keeper | Add-Member -NotePropertyName save_path -NotePropertyValue $tree -Force
$keeper | Add-Member -NotePropertyName content_path -NotePropertyValue $keeperDir -Force
$candidateRows = @(
    [pscustomobject]@{ name = 'candidate/Example.Show.S01E01.mkv'; size = 2L }
    [pscustomobject]@{ name = 'candidate/Example.Show.S01E02.mkv'; size = 2L }
)
$keeperRows = @(
    [pscustomobject]@{ name = 'keeper/Example.Show.S01E01.mkv'; size = 3L }
    [pscustomobject]@{ name = 'keeper/Example.Show.S01E02.mkv'; size = 3L }
    [pscustomobject]@{ name = 'keeper/Example.Show.S01E03.mkv'; size = 3L }
    [pscustomobject]@{ name = 'keeper/Example.Show.S01E04.mkv'; size = 3L }
)
foreach ($row in $candidateRows) { [IO.File]::WriteAllBytes((Join-Path $candidateDir (Split-Path -Leaf $row.name)), [byte[]]::new([int]$row.size)) }
foreach ($row in $keeperRows) { [IO.File]::WriteAllBytes((Join-Path $keeperDir (Split-Path -Leaf $row.name)), [byte[]]::new([int]$row.size)) }
$script:gone = @{ candidate = $true }
$script:actions = New-Object System.Collections.ArrayList
$script:allTorrents = @($candidate, $keeper)
$DryRun = $false
function Write-Log { param([string]$Level, [string]$Message) }
function Invoke-ApiGet {
    param([string]$Endpoint)
    if ($Endpoint -eq 'torrents/info?hashes=candidate') { return @() }
    if ($Endpoint -eq 'torrents/files?hash=keeper') { return $keeperRows }
    if ($Endpoint -eq 'torrents/files?hash=third') { return $candidateRows }
    throw "unexpected API request in fixture: $Endpoint"
}
$cleanupCache = @{ candidate = $candidateRows; keeper = $keeperRows }
$cleanupVerdict = [pscustomobject]@{ Season = 1; First = 1; Last = 2 }
Remove-RedundantPackPayloadFiles -Candidate $candidate -Keeper $keeper -Verdict $cleanupVerdict `
    -FileCache $cleanupCache -Torrents $script:allTorrents
Check 'the fallback removes listed duplicate episode files after the candidate entry is gone' `
    (-not (Test-Path -LiteralPath (Join-Path $candidateDir (Split-Path -Leaf $candidateRows[0].name))) -and
     -not (Test-Path -LiteralPath (Join-Path $candidateDir (Split-Path -Leaf $candidateRows[1].name))))
Check 'the fallback prunes only the now-empty candidate release directory' (-not (Test-Path -LiteralPath $candidateDir))
Check 'verified keeper files remain untouched' `
    ((Get-Item -LiteralPath (Join-Path $keeperDir (Split-Path -Leaf $keeperRows[0].name))).Length -eq 3 -and
     (Get-Item -LiteralPath (Join-Path $keeperDir (Split-Path -Leaf $keeperRows[1].name))).Length -eq 3)

# An exact file-path claim from a different live entry defeats the fallback,
# even though the pack-level proof itself is valid.
New-Item -ItemType Directory -Path $candidateDir -Force | Out-Null
foreach ($row in $candidateRows) { [IO.File]::WriteAllBytes((Join-Path $candidateDir (Split-Path -Leaf $row.name)), [byte[]]::new([int]$row.size)) }
$third = [pscustomobject]@{ hash = 'third'; name = 'other owner'; save_path = $tree; content_path = $candidateDir }
$script:allTorrents = @($candidate, $keeper, $third)
$cleanupCache.third = $candidateRows
Remove-RedundantPackPayloadFiles -Candidate $candidate -Keeper $keeper -Verdict $cleanupVerdict `
    -FileCache $cleanupCache -Torrents $script:allTorrents
Check 'an exact file-level owner claim prevents cleanup of shared media' `
    ((Test-Path -LiteralPath (Join-Path $candidateDir (Split-Path -Leaf $candidateRows[0].name))) -and
     (Test-Path -LiteralPath (Join-Path $candidateDir (Split-Path -Leaf $candidateRows[1].name))))
Remove-Item -LiteralPath $tree -Recurse -Force

if ($script:fails) { throw "$script:fails pack containment check(s) failed" }
