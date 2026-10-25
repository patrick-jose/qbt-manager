# Machine-local identification for a known unlabelled DoVi release.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'), [Text.Encoding]::UTF8)
$start = $source.IndexOf('$script:boundaryPattern'); $end = $source.IndexOf('# actions', $start)
if ($start -lt 0 -or $end -le $start) { throw 'dovi detection slice not found' }
Invoke-Expression $source.Substring($start, $end - $start)
$config = [IO.File]::ReadAllText((Join-Path $root 'config.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
$local = [IO.File]::ReadAllText((Join-Path $root 'config.local.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
$cfg = $config
$cfg | Add-Member -NotePropertyName doviPatternOverrides -NotePropertyValue $local.doviPatternOverrides -Force
$script:fails = 0
function Check { param($Name,$Ok) if($Ok){"[PASS] $Name"}else{$script:fails++;"[FAIL] $Name"} }

$torrentName = 'The.Punisher.One.Last.Kill.2026.2160p.DSNP.WEB-DL.DDP5.1.Atmos.H265.Dual.YG? [ext.to]'
$mediaName = 'The.Punisher.One.Last.Kill.2026.2160p.DSNP.WEB-DL.DDP5.1.Atmos.H265.Dual YG.mkv'
Check 'the exact torrent release without a DoVi tag is caught' (-not [string]::IsNullOrWhiteSpace((Get-DoviHit -Name $torrentName)))
Check 'the exact media filename is caught' (-not [string]::IsNullOrWhiteSpace((Get-DoviHit -Name $mediaName)))
Check 'an unrelated non-DoVi Punisher release is not caught' ($null -eq (Get-DoviHit -Name 'The.Punisher.One.Last.Kill.2026.1080p.DSNP.WEB-DL.H264-WSKR.mkv'))
Check 'existing standard DoVi tags remain caught' (-not [string]::IsNullOrWhiteSpace((Get-DoviHit -Name 'Example.Movie.2026.2160p.HDR10.DoVi.HEVC')))
$doviMetadataJson = '{"media":{"track":[{"@type":"Video","Format":"HEVC","HDR_Format":"Dolby Vision","HDR_Format_Profile":"dvhe.08.06, BL+RPU"}]}}'
$hdr10MetadataJson = '{"media":{"track":[{"@type":"Video","Format":"HEVC","HDR_Format":"HDR10","HDR_Format_Profile":"Main 10@L5.1@High"}]}}'
Check 'Dolby Vision track metadata is recognized' (-not [string]::IsNullOrWhiteSpace((Get-DoviMetadataHitFromJson -Json $doviMetadataJson)))
Check 'HDR10-only metadata is not mistaken for Dolby Vision' ($null -eq (Get-DoviMetadataHitFromJson -Json $hdr10MetadataJson))
$doviCodecMetadataJson = '{"media":{"track":[{"@type":"Video","CodecID":"V_MPEGH/ISO/HEVC","CodecID_Hint":"dvhe.08.06"}]}}'
Check 'Dolby Vision codec profile metadata is recognized' (-not [string]::IsNullOrWhiteSpace((Get-DoviMetadataHitFromJson -Json $doviCodecMetadataJson)))
$withoutNameTag = [pscustomobject]@{name='The Punisher S00E01 The Punisher One Last Kill 2160p';content_path='C:\Downloads\The Punisher S00E01 The Punisher One Last Kill 2160p DoVi H 265-playWEB.mkv'}
Check 'DoVi tags in qBittorrent content paths are caught even if display name omits them' (-not [string]::IsNullOrWhiteSpace((Get-TorrentDoviHit -Torrent $withoutNameTag)))
$script:doviPayloadFileCache = @{}
function Invoke-ApiGet { param([string]$Endpoint) @([pscustomobject]@{name='Widows Bay S01E05 What to Expect on Your Trip 2160p ATVP WEB-DL Atmos DV HDR H265-FLUX.mkv'}) }
$truncatedMagnetName = [pscustomobject]@{name='Widows Bay S01E05 What to Expect on Your Trip 2160p ATVP WEB-DL DDP5.1 At';content_path='C:\Downloads\Widows Bay S01E05';has_metadata=$true;hash='fixture-hash'}
Check 'payload filename DoVi marker is caught when magnet/display name is truncated' (-not [string]::IsNullOrWhiteSpace((Get-TorrentDoviHit -Torrent $truncatedMagnetName -IncludePayloadFiles)))
$script:doviPayloadFileCache = $null
$script:doviMetadataCache = $null
$strictTemp = [IO.Path]::ChangeExtension([IO.Path]::GetTempFileName(), '.mkv')
try {
    [IO.File]::WriteAllBytes($strictTemp, [byte[]]@())
    $strictError = $null
    try {
        & {
            Set-StrictMode -Version 2.0
            $strictTorrent = [pscustomobject]@{name='Widows Bay S01E05';content_path='';save_path='';has_metadata=$true;hash='strict-mode-fixture'}
            [void](Get-TorrentDoviHit -Torrent $strictTorrent -IncludePayloadFiles)
            [void](Get-DoviMetadataHit -Path $strictTemp)
        }
    } catch { $strictError = $_ }
    Check 'DoVi caches initialize safely under StrictMode' ($null -eq $strictError)
} finally { Remove-Item -LiteralPath $strictTemp -Force -ErrorAction SilentlyContinue }
$managerSource = [IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'), [Text.Encoding]::UTF8)
$statusSource = [IO.File]::ReadAllText((Join-Path $root 'status.ps1'), [Text.Encoding]::UTF8)
Check 'manager DoVi rule checks torrent name, payload filenames, and metadata' ($managerSource.Contains('$hit = Get-TorrentDoviHit -Torrent $t -IncludePayloadFiles'))
Check 'read-only preview uses the same DoVi identity helper' ($statusSource.Contains('Get-TorrentDoviHit -Torrent $T -IncludePayloadFiles'))
if ($script:fails) { exit 1 }
exit 0
