$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'))
$start = $source.IndexOf('function Test-Claimed {')
$end = $source.IndexOf('function Get-PhantomVerdicts {', $start)
if ($start -lt 0 -or $end -le $start) { throw 'could not locate torrent path ownership helpers' }
Invoke-Expression $source.Substring($start, $end - $start)
$resolveStart = $source.IndexOf('function Resolve-TorrentFilePath {')
$resolveEnd = $source.IndexOf('function Test-SettleMedia {', $resolveStart)
if ($resolveStart -lt 0 -or $resolveEnd -le $resolveStart) { throw 'could not locate torrent file path resolver' }
Invoke-Expression $source.Substring($resolveStart, $resolveEnd - $resolveStart)

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

$removeStart = $source.IndexOf('function Remove-Torrent {')
$removeEnd = $source.IndexOf('# Polls qBittorrent until the move', $removeStart)
$removeBody = $source.Substring($removeStart, $removeEnd - $removeStart)
Check 'torrent-wide data deletion is guarded centrally' `
    ($removeBody -match 'if \(\$wantFiles\)' -and $removeBody -match 'Test-OtherTorrentClaimsPath' -and $removeBody -match '\$wantFiles = \$false')
Check 'retained-torrent file-only deletion verifies skipped priority before Remove-Item' `
    ($source -match '(?s)if \(\$d\.Action -eq ''delete-file-only''\).*?Set-TorrentFilePriorityVerified.*?Remove-Item -LiteralPath \$d\.File')
Check 'unowned-file deletion rechecks ownership immediately before Remove-Item' `
    ($source -match '(?s)No torrent claims it.*?Test-OtherTorrentClaimsPath.*?Remove-Item -LiteralPath \$d\.File')

if ($script:fails) { throw "$script:fails file ownership check(s) failed" }
