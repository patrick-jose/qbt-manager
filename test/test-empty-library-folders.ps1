# Only empty, unclaimed, recognisable release trees may be pruned from libraries.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'))
$start = $source.IndexOf('$script:boundaryPattern'); $end = $source.IndexOf('# actions', $start)
Invoke-Expression $source.Substring($start, $end - $start)
$start = $source.IndexOf('function Remove-EmptyLibraryReleaseFolders'); $end = $source.IndexOf('function Invoke-PendingSettles', $start)
Invoke-Expression $source.Substring($start, $end - $start)
$script:actions = New-Object Collections.ArrayList
$script:pendingSettleRecords = @()
$script:fails = 0
function Check { param($Name, $Ok) if ($Ok) { "[PASS] $Name" } else { $script:fails++; "[FAIL] $Name" } }
function Write-Log { param($Level, $Message) }
$base = Join-Path $env:TEMP ('empty-library-' + [guid]::NewGuid().ToString('N'))
$series = Join-Path $base 'Series'
$season = Join-Path $series 'Example Show\Season 1'
New-Item -ItemType Directory -Path $season -Force | Out-Null
function Folder { param($Name) $path = Join-Path $season $Name; New-Item -ItemType Directory -Path $path -Force | Out-Null; $path }
try {
    $empty = Folder 'Example.Show.S01E08.4320p.WEB-DL'
    $nested = Folder 'Example.Show.S01E08.1080p.WEB-DL'
    New-Item -ItemType Directory -Path (Join-Path $nested 'Stills\Empty') -Force | Out-Null
    $nonempty = Folder 'Example.Show.S01E08.720p.WEB-DL'
    [IO.File]::WriteAllText((Join-Path $nonempty 'media.mkv'), 'keep media')
    $sidecar = Folder 'Example.Show.S01E08.480p.WEB-DL'
    [IO.File]::WriteAllText((Join-Path $sidecar 'readme.txt'), 'unlisted user file')
    $userFolder = Folder 'My Notes'
    $wrongShow = Folder 'Another.Show.S01E08.1080p.WEB-DL'
    $wrongSeason = Folder 'Example.Show.S02E08.1080p.WEB-DL'
    $claimed = Folder 'Example.Show.S01E08.2160p.WEB-DL'
    $pending = Folder 'Example.Show.S01E08.1440p.WEB-DL'
    $torrent = [pscustomobject]@{ hash = ('a' * 40); content_path = (Join-Path $claimed 'media.mkv') }
    $script:pendingSettleRecords = @([pscustomobject]@{ Plan = [pscustomobject]@{ Files = @([pscustomobject]@{ Path = (Join-Path $pending 'media.mkv'); Target = (Join-Path $season 'pending.mkv') }) } })
    $candidates = @(Get-EmptyLibraryReleaseFolders -SeriesDir $series -Torrents @($torrent))
    Check 'finds exactly the two empty release trees' ($candidates.Count -eq 2)
    Check 'empty failed-move destination is eligible' (@($candidates.Root) -contains $empty)
    Check 'empty nested sidecar directories are eligible' (@($candidates.Root) -contains $nested)
    $DryRun = $true
    Remove-EmptyLibraryReleaseFolders -SeriesDir $series -Torrents @($torrent)
    Check 'dry run leaves empty release folders intact' ((Test-Path -LiteralPath $empty) -and (Test-Path -LiteralPath $nested))
    $DryRun = $false
    Remove-EmptyLibraryReleaseFolders -SeriesDir $series -Torrents @($torrent)
    Check 'live cleanup removes empty release trees' (-not (Test-Path -LiteralPath $empty) -and -not (Test-Path -LiteralPath $nested))
    Check 'media-bearing release is preserved' (Test-Path -LiteralPath (Join-Path $nonempty 'media.mkv'))
    Check 'folder with unlisted residues is not guessed safe to delete' (Test-Path -LiteralPath (Join-Path $sidecar 'readme.txt'))
    Check 'live torrent claim protects an empty release directory' (Test-Path -LiteralPath $claimed)
    Check 'pending settle protects an empty release directory' (Test-Path -LiteralPath $pending)
    Check 'unrecognised user folder is preserved' (Test-Path -LiteralPath $userFolder)
    Check 'a different show or season is not pruned from the wrong folder' ((Test-Path -LiteralPath $wrongShow) -and (Test-Path -LiteralPath $wrongSeason))
    Check 'show season and library structure are preserved' ((Test-Path -LiteralPath $season) -and (Test-Path -LiteralPath $series))
    $anotherSeason = Join-Path $series 'Example Show\Season 2'
    $anotherRelease = Join-Path $anotherSeason 'Example.Show.S02E08.1080p.WEB-DL'
    New-Item -ItemType Directory -Path $anotherRelease -Force | Out-Null
    Remove-EmptyLibraryReleaseFolders -SeriesDir $series -Torrents @($torrent) -SeasonDir $season
    Check 'targeted cleanup does not touch another season' (Test-Path -LiteralPath $anotherRelease)
    # OS-level non-recursive deletion fails immediately if a file appears, without
    # prompting for recursive removal or deleting the newly arrived media.
    $race = Folder 'Example.Show.S01E08.540p.WEB-DL'
    [IO.File]::WriteAllText((Join-Path $race 'arrived.mkv'), 'new media')
    $refused = $false
    try { [IO.Directory]::Delete($race, $false) } catch { $refused = $true }
    Check 'non-recursive removal refuses newly arrived data without prompting' ($refused -and (Test-Path -LiteralPath (Join-Path $race 'arrived.mkv')))
}
finally { Remove-Item -LiteralPath $base -Recurse -Force }
if ($script:fails) { exit 1 }
exit 0
