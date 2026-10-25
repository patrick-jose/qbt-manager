$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'), [Text.Encoding]::UTF8)
$start = $source.IndexOf('$script:boundaryPattern'); $end = $source.IndexOf('# actions', $start)
if ($start -lt 0 -or $end -le $start) { throw 'helper block not found' }
Invoke-Expression $source.Substring($start, $end - $start)
$start = $source.IndexOf('function Remove-EmptyManagedDirectories')
$end = $source.IndexOf('function Invoke-PendingSettles', $start)
if ($start -lt 0 -or $end -le $start) { throw 'empty-directory cleanup function not found' }
Invoke-Expression $source.Substring($start, $end - $start)

$script:actions = New-Object Collections.ArrayList
$script:pendingSettleRecords = @()
$script:fails = 0
function Write-Log { param($Level, $Message) }
function Check { param($Label, $Ok) if ($Ok) { Write-Host "[PASS] $Label" } else { $script:fails++; Write-Host "[FAIL] $Label" } }

$base = Join-Path $env:TEMP ('empty-managed-' + [guid]::NewGuid().ToString('N'))
$movies = Join-Path $base 'Filmes'
$series = Join-Path $base 'Series'
$temp = Join-Path $base 'temp'
New-Item -ItemType Directory -Path @($movies, $series, $temp) -Force | Out-Null
try {
    $movieEmpty = Join-Path $movies 'A movie release'
    $nestedEmpty = Join-Path $series 'Show\Season 1\Empty Release\Empty Child'
    $cleanNested = Join-Path $series 'Clean Show\Season 1\Empty Release\Empty Child'
    $nonempty = Join-Path $movies 'Keep this folder'
    $claimed = Join-Path $temp 'Active torrent folder'
    $pending = Join-Path $series 'Show\Season 2\Pending release'
    New-Item -ItemType Directory -Path @($movieEmpty, $nestedEmpty, $cleanNested, $nonempty, $claimed, $pending) -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $nonempty 'keep.txt'), 'user data')

    $torrent = [pscustomobject]@{ hash = 'a' * 40; name = 'active'; content_path = (Join-Path $claimed 'payload.mkv') }
    $script:pendingSettleRecords = @([pscustomobject]@{ Plan = [pscustomobject]@{ Files = @([pscustomobject]@{ Path = (Join-Path $pending 'payload.mkv'); Target = '' }) } })

    $script:actions.Clear()
    $DryRun = $true
    Remove-EmptyManagedDirectories -Roots @($movies, $series, $temp) -Torrents @($torrent)
    Check 'dry run reports empty library folders' (@($script:actions | Where-Object { $_ -like 'WOULD REMOVE EMPTY DIRECTORY*' }).Count -ge 2)
    Check 'dry run removes nothing' ((Test-Path $movieEmpty) -and (Test-Path $nestedEmpty))

    $script:actions.Clear()
    $DryRun = $false
    Remove-EmptyManagedDirectories -Roots @($movies, $series, $temp) -Torrents @($torrent)
    Check 'empty movie release folder is removed' (-not (Test-Path $movieEmpty))
    Check 'nested empty release and structural folders are removed' (-not (Test-Path (Join-Path $series 'Clean Show')))
    Check 'a structural folder containing a pending settle remains' (Test-Path (Join-Path $series 'Show'))
    Check 'managed roots themselves are preserved' ((Test-Path $movies) -and (Test-Path $series) -and (Test-Path $temp))
    Check 'a folder containing user data is preserved' ((Test-Path $nonempty) -and (Test-Path (Join-Path $nonempty 'keep.txt')))
    Check 'an active torrent claimed directory is preserved' (Test-Path $claimed)
    Check 'a pending settle directory is preserved' (Test-Path $pending)
    Check 'successful removals are recorded' (@($script:actions | Where-Object { $_ -like 'REMOVED EMPTY DIRECTORY*' }).Count -ge 5)
}
finally { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
if ($script:fails) { exit 1 }
exit 0
