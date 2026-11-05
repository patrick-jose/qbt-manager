$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'))
$start = $source.IndexOf('function Test-Claimed {')
$end = $source.IndexOf('function Get-PhantomVerdicts {', $start)
if ($start -lt 0 -or $end -le $start) { throw 'could not locate torrent path ownership helpers' }
$resolveStart = $source.IndexOf('function Resolve-TorrentFilePath {')
$resolveEnd = $source.IndexOf('function Test-SettleMedia {', $resolveStart)
if ($resolveStart -lt 0 -or $resolveEnd -le $resolveStart) { throw 'could not locate torrent file path resolver' }
$priorityStart = $source.IndexOf('function Set-TorrentFilePriorityVerified {')
$priorityEnd = $source.IndexOf('# Has this torrent''s data actually arrived', $priorityStart)
if ($priorityStart -lt 0 -or $priorityEnd -le $priorityStart) { throw 'could not locate verified file-priority helper' }
$resolverSource = $source.Substring($resolveStart, $resolveEnd - $resolveStart)
$prioritySource = $source.Substring($priorityStart, $priorityEnd - $priorityStart)
Invoke-Expression ($resolverSource + [Environment]::NewLine + $prioritySource)
Invoke-Expression $source.Substring($start, $end - $start)
$stopStart = $source.IndexOf('function Stop-TorrentAndConfirm {')
$stopEnd = $source.IndexOf('function Remove-Torrent {', $stopStart)
if ($stopStart -lt 0 -or $stopEnd -le $stopStart) { throw 'could not locate torrent-stop and file-removal helpers' }
Invoke-Expression $source.Substring($stopStart, $stopEnd - $stopStart)
function Test-PendingSettlePath { param([string]$Path) return $false }

$script:fails = 0
function Check {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { "[PASS] $Name" } else { $script:fails++; "[FAIL] $Name" }
}

$owner = [pscustomobject]@{ hash = 'a'; name = 'pack'; content_path = 'C:\downloads\Show.Pack'; progress = 1 }
$same = [pscustomobject]@{ hash = 'b'; name = 'shared'; content_path = 'C:\downloads\Show.Pack'; progress = 1 }
$sibling = [pscustomobject]@{ hash = 'c'; name = 'sibling'; content_path = 'C:\downloads\Show.Pack.Other'; progress = 1 }
$nested = [pscustomobject]@{ hash = 'd'; name = 'nested'; content_path = 'C:\downloads\Show.Pack\episode.mkv'; progress = 1 }

Check 'overlapping torrent claims protect shared payload paths' `
    ((Test-OtherTorrentClaimsPath -Path $owner.content_path -Torrents @($owner, $same) -ExcludeHash $owner.hash).hash -eq 'b')
Check 'a sibling path with only a matching prefix is not a claim' `
    ($null -eq (Test-OtherTorrentClaimsPath -Path $owner.content_path -Torrents @($sibling) -ExcludeHash $owner.hash))
Check 'nested content paths count as overlapping ownership' `
    ((Test-OtherTorrentClaimsPath -Path $owner.content_path -Torrents @($nested) -ExcludeHash $owner.hash).hash -eq 'd')
Check 'a retained pack claims its individual episode file' `
    ((Test-OtherTorrentClaimsPath -Path 'C:\downloads\Show.Pack\episode.mkv' -Torrents @($owner)).hash -eq 'a')
Check 'the torrent being removed can be excluded from the owner check' `
    ($null -eq (Test-OtherTorrentClaimsPath -Path $owner.content_path -Torrents @($owner) -ExcludeHash $owner.hash))

$script:fileListing = @([pscustomobject]@{ index = 3; name = 'pack/episode.mkv'; priority = 1; size = 25 })
$script:filePriorityPosts = @()
$script:applyFilePriority = $true
function Invoke-ApiGet { param([string]$Endpoint) @($script:fileListing) }
function Invoke-ApiPost {
    param([string]$Endpoint, [hashtable]$Fields)
    $script:filePriorityPosts += ,([pscustomobject]@{ Endpoint = $Endpoint; Fields = $Fields.Clone() })
    if ($script:applyFilePriority) { $script:fileListing[0].priority = [int]$Fields.priority }
}
$pack = [pscustomobject]@{ hash = 'packhash'; save_path = 'C:\downloads' }
$episodePath = 'C:\downloads\pack\episode.mkv'
Check 'file skip requires qBittorrent to confirm priority zero' `
    (Set-TorrentFilePriorityVerified -Torrent $pack -Path $episodePath)
Check 'skip request uses the exact qBittorrent file index' `
    ($script:filePriorityPosts.Count -eq 1 -and $script:filePriorityPosts[0].Endpoint -eq 'torrents/filePrio' -and
     $script:filePriorityPosts[0].Fields.id -eq '3' -and $script:filePriorityPosts[0].Fields.priority -eq '0')
Check 'already skipped files do not need a redundant API mutation' `
    ((Set-TorrentFilePriorityVerified -Torrent $pack -Path $episodePath) -and $script:filePriorityPosts.Count -eq 1)
$script:fileListing[0].priority = 1; $script:applyFilePriority = $false
Check 'a priority change that cannot be verified refuses deletion' `
    (-not (Set-TorrentFilePriorityVerified -Torrent $pack -Path $episodePath))
$script:fileListing = @([pscustomobject]@{ index = 3; name = 'pack/episode.mkv'; priority = 1; size = 25 },
                       [pscustomobject]@{ index = 4; name = 'pack/episode.mkv'; priority = 1; size = 25 })
Check 'ambiguous file mappings are never submitted for skipping' `
    (-not (Set-TorrentFilePriorityVerified -Torrent $pack -Path $episodePath))

Write-Host ''
Write-Host '== shared exact file owners =='
$script:mockTorrentList = @(
    [pscustomobject]@{ hash = 'owner-a'; name = 'pack A'; content_path = 'C:\downloads\pack'; save_path = 'C:\downloads'; state = 'downloading'; progress = 1 },
    [pscustomobject]@{ hash = 'owner-b'; name = 'pack B'; content_path = 'C:\downloads\pack'; save_path = 'C:\downloads'; state = 'downloading'; progress = 1 }
)
$script:mockFileListings = @{
    'owner-a' = @([pscustomobject]@{ index = 1; name = 'pack/episode.mkv'; priority = 1; size = 25 })
    'owner-b' = @([pscustomobject]@{ index = 4; name = 'pack/episode.mkv'; priority = 1; size = 25 })
}
$script:applyFilePriorityByHash = @{ 'owner-a' = $true; 'owner-b' = $true }
$script:failFileReadHash = ''
$script:mockPosts = @()
function Invoke-ApiGet {
    param([string]$Endpoint)
    if ($Endpoint -eq 'torrents/info') { return @($script:mockTorrentList) }
    if ($Endpoint -match '^torrents/files\?hash=(?<hash>[^&]+)$') {
        $hash = $Matches.hash
        if ($script:failFileReadHash -eq $hash) { throw "mock file-list failure for $hash" }
        return @($script:mockFileListings[$hash])
    }
    throw "unexpected mock API GET: $Endpoint"
}
function Invoke-ApiPost {
    param([string]$Endpoint, [hashtable]$Fields)
    $script:mockPosts += ,([pscustomobject]@{ Endpoint = $Endpoint; Fields = $Fields.Clone() })
    if ($Endpoint -eq 'torrents/stop') {
        foreach ($torrent in $script:mockTorrentList) {
            if ([string]$torrent.hash -eq [string]$Fields.hashes) { $torrent.state = 'stoppedUP' }
        }
    }
    if ($Endpoint -eq 'torrents/filePrio' -and $script:applyFilePriorityByHash[[string]$Fields.hash]) {
        foreach ($file in @($script:mockFileListings[[string]$Fields.hash])) {
            if ([int]$file.index -eq [int]$Fields.id) { $file.priority = [int]$Fields.priority }
        }
    }
}
function Start-Sleep { param([int]$Milliseconds) }

$sharedPath = 'C:\downloads\pack\episode.mkv'
$sharedOwners = Prepare-ExactTorrentFileForRemoval -Path $sharedPath `
    -Torrents $script:mockTorrentList -RequiredHashes @('owner-a') -Gone @{}
Check 'all exact owners are stopped and verified to skip the shared file' `
    ($sharedOwners.Verified -and $sharedOwners.Owners.Count -eq 2 -and
     @($script:mockPosts | Where-Object { $_.Endpoint -eq 'torrents/stop' }).Count -eq 2 -and
     @($script:mockPosts | Where-Object { $_.Endpoint -eq 'torrents/filePrio' }).Count -eq 2 -and
     $script:mockFileListings['owner-a'][0].priority -eq 0 -and
     $script:mockFileListings['owner-b'][0].priority -eq 0)

foreach ($torrent in $script:mockTorrentList) { $torrent.state = 'downloading' }
foreach ($hash in @('owner-a', 'owner-b')) { $script:mockFileListings[$hash][0].priority = 1 }
$script:applyFilePriorityByHash = @{ 'owner-a' = $true; 'owner-b' = $false }
$script:mockPosts = @()
$unverifiedSharedOwners = Prepare-ExactTorrentFileForRemoval -Path $sharedPath `
    -Torrents $script:mockTorrentList -RequiredHashes @('owner-a') -Gone @{}
Check 'one owner failing priority verification refuses shared-file removal' `
    (-not $unverifiedSharedOwners.Verified -and $script:mockFileListings['owner-b'][0].priority -eq 1)

$script:failFileReadHash = 'owner-b'
$script:mockPosts = @()
$unreadableSharedOwners = Prepare-ExactTorrentFileForRemoval -Path $sharedPath `
    -Torrents $script:mockTorrentList -RequiredHashes @('owner-a') -Gone @{}
Check 'an unreadable exact-owner file list refuses before stopping or unlinking' `
    (-not $unreadableSharedOwners.Verified -and
     @($script:mockPosts | Where-Object { $_.Endpoint -eq 'torrents/stop' }).Count -eq 0)
$script:failFileReadHash = ''

$removeStart = $source.IndexOf('function Remove-Torrent {')
$removeEnd = $source.IndexOf('# Polls qBittorrent until the move', $removeStart)
$removeBody = $source.Substring($removeStart, $removeEnd - $removeStart)
Check 'torrent-wide data deletion is guarded centrally' `
    ($removeBody -match 'if \(\$wantFiles\)' -and $removeBody -match 'Test-OtherTorrentClaimsPath' -and $removeBody -match '\$wantFiles = \$false')
Check 'retained-torrent file-only deletion verifies skipped priority before Remove-Item' `
    ($source -match '(?s)if \(\$d\.Action -eq ''delete-file-only''\).*?Prepare-ExactTorrentFileForRemoval.*?Remove-Item -LiteralPath \$d\.File')
Check 'pack-versus-single cleanup prepares every exact owner before unlinking' `
    ($source -match '(?s)Prepare-ExactTorrentFileForRemoval -Path \$packFilePath.*?-RequiredHashes @\(\[string\]\$pack\.hash\).*?Remove-Item -LiteralPath \$packFilePath')
Check 'file-only dry runs exit before changing torrent state' `
    ($source -match '(?s)if \(\$DryRun -and \$d\.Action -eq ''delete-file-only''\).*?continue\s*\}\s*if \(\$DryRun -and -not \$d\.Owner\)')
Check 'unowned-file deletion rechecks ownership immediately before Remove-Item' `
    ($source -match '(?s)No torrent claims it.*?Test-OtherTorrentClaimsPath.*?Remove-Item -LiteralPath \$d\.File')

if ($script:fails) { throw "$script:fails file ownership check(s) failed" }
