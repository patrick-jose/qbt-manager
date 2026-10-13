# Existing qBittorrent categories are user-owned; only empty values are filled.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'), [Text.Encoding]::UTF8)
$start = $source.IndexOf('function Set-Category {')
$end = $source.IndexOf('# ---------------------------------------------------------------------------', $start)
if ($start -lt 0 -or $end -le $start) { throw 'Set-Category block not found' }
Invoke-Expression $source.Substring($start, $end - $start)
$script:fails = 0; $script:posts = @(); $script:logs = @()
$DryRun = $false
function Invoke-ApiPost { param($Endpoint,$Fields) $script:posts += [pscustomobject]@{Endpoint=$Endpoint;Fields=$Fields} }
function Write-Log { param($Level,$Message) $script:logs += [pscustomobject]@{Level=$Level;Message=$Message} }
function Check { param($Name,$Ok) if ($Ok) { "[PASS] $Name" } else { $script:fails++; "[FAIL] $Name" } }

$manual = [pscustomobject]@{ hash='abc'; name='Example Show S01E01'; category='Personal' }
Set-Category -T $manual -Category 'Series'
Check 'preserves a manually chosen non-default category' ($script:posts.Count -eq 0 -and $manual.category -eq 'Personal')
Check 'logs that the existing category was preserved' (@($script:logs | Where-Object { $_.Message -match 'remains.*Personal' }).Count -eq 1)

$script:logs = @()
$already = [pscustomobject]@{ hash='def'; name='Example Show S01E02'; category='Series' }
Set-Category -T $already -Category 'Series'
Check 'does nothing when the torrent already has the inferred category' ($script:posts.Count -eq 0 -and $script:logs.Count -eq 0)

$empty = [pscustomobject]@{ hash='ghi'; name='Example Show S01E03'; category='' }
Set-Category -T $empty -Category 'Series'
Check 'fills an empty category' ($script:posts.Count -eq 1 -and $script:posts[0].Endpoint -eq 'torrents/setCategory' -and $script:posts[0].Fields.category -eq 'Series')

$script:posts = @(); $DryRun = $true
$dry = [pscustomobject]@{ hash='jkl'; name='Example Movie (2026)'; category=$null }
Set-Category -T $dry -Category 'Movies'
Check 'dry run previews filling empty categories without API writes' ($script:posts.Count -eq 0 -and @($script:logs | Where-Object { $_.Message -match 'empty category.*Movies' }).Count -eq 1)
$script:logs = @()
$dryManual = [pscustomobject]@{ hash='mno'; name='Example Movie (2026)'; category='Manual Movies' }
Set-Category -T $dryManual -Category 'Movies'
Check 'dry run also preserves non-empty manual categories' ($script:posts.Count -eq 0 -and @($script:logs | Where-Object { $_.Message -match 'remains.*Manual Movies' }).Count -eq 1)

if ($script:fails) { exit 1 }
exit 0
