# Isolated production decision/action blocks. No live API or library access.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = [IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'))
$start = $src.IndexOf('        if ($set.Count -ge 2) {')
$end = $src.IndexOf('        Write-Host ("  {0}" -f $label)', $start)
if ($start -lt 0 -or $end -le $start) { throw 'Set decision block missing' }
$decision = $src.Substring($start, $end - $start)
$script:fails = 0
function Check { param($Name, $Ok) if ($Ok) { "[PASS] $Name" } else { $script:fails++; "[FAIL] $Name" } }
function Test-AlreadyGone { param($T) $script:gone.ContainsKey($T.hash) }
function Test-Errored { param($T) $false }
function Test-Claimed { param($Path, $Torrents) if ($Path -eq $Torrents[0].content_path) { $Torrents[0] } }
function Stop-TorrentAndConfirm {
    param($T)
    [void]$script:stops.Add($T.hash)
    $T.hash -ne $script:stopFailure
}
function Remove-Torrent {
    param($T, $Reason, [switch]$Knows, [switch]$AllowErrored, [switch]$AllowIncomingBetter, $DeleteFiles = $null)
    if (-not $Knows -or -not $AllowIncomingBetter) { throw 'Keeper/bypass flags missing' }
    $script:gone[$T.hash] = $true
    $script:lastDeleteFiles = $DeleteFiles
}
function Write-Log { param($Level, $Message) }
function CopyOf {
    param($Hash, $Size, $Progress, $Path = '')
    [pscustomobject]@{ hash = $Hash; name = 'identical display name'; size = $Size; progress = $Progress; content_path = $Path }
}
function Judge {
    param($Copies, $StopFailure = '')
    $script:gone = @{}
    $script:stops = New-Object Collections.ArrayList
    $script:stopFailure = $StopFailure
    $script:lastDeleteFiles = $null
    $set = $Copies; $DryRun = $false; $guardDuplicates = $false
    $tolerance = 10; $label = 'Synthetic same content'; $k = 'same-set'
    Invoke-Expression $decision
}
Judge @((CopyOf 'finished' 100 1), (CopyOf 'incoming' 200 0.3))
Check 'only finished copy survives a larger incoming download' ($script:gone.Count -eq 0)
Judge @((CopyOf 'small' 50 1), (CopyOf 'best' 100 1), (CopyOf 'incoming' 200 0.3))
Check 'only smaller finished duplicate goes while better version downloads' ($script:gone.Count -eq 1 -and $script:gone.ContainsKey('small'))
Check 'surviving finished keeper is stopped before deletion' ($script:stops -contains 'best')
Judge @((CopyOf 'b' 100 1), (CopyOf 'a' 100 1), (CopyOf 'incoming' 200 0.3))
Check 'equal finished copies retain exactly one hash-stable keeper' ($script:gone.Count -eq 1 -and $script:gone.ContainsKey('b'))
Judge @((CopyOf 'small' 50 1), (CopyOf 'best' 100 1)) 'best'
Check 'failed keeper stop prevents duplicate deletion' ($script:gone.Count -eq 0)
Judge @((CopyOf 'old' 100 1), (CopyOf 'new' 200 1))
Check 'newly finished better copy replaces previous keeper' ($script:gone.Count -eq 1 -and $script:gone.ContainsKey('old'))
Judge @((CopyOf 'finished' 100 1), (CopyOf 'unknown' 0 0))
Check 'unknown-size magnet does not displace finished copy' ($script:gone.Count -eq 0)
Judge @((CopyOf 'a' 100 1 'shared-payload'), (CopyOf 'b' 100 1 'shared-payload'))
Check 'shared payload duplicate removes entry without deleting keeper bytes' ($script:gone.ContainsKey('b') -and $script:lastDeleteFiles -eq $false)

# Execute the real library action loop against tiny disposable files.
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$errors)
if ($errors.Count) { throw 'Manager parse errors' }
$loop = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.ForEachStatementAst] -and
    $node.Variable.VariablePath.UserPath -eq 'd' -and $node.Condition.Extent.Text -eq '$libDupes'
}, $true)
if (-not $loop) { throw 'Library action loop missing' }
$base = Join-Path $env:TEMP ('finished-policy-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base | Out-Null
try {
    $file = Join-Path $base 'duplicate.mkv'
    foreach ($action in 'delete-file-only', 'delete') {
        [IO.File]::WriteAllText($file, 'tiny fixture')
        $all = @((CopyOf 'keeper' 100 1), (CopyOf 'pack' 50 1))
        $libDupes = @([pscustomobject]@{
            Action = $action; Owner = $null; OwnerHash = ''; File = $file
            Episode = '1-E1'; Reason = 'synthetic duplicate'; KeeperHashes = @('keeper')
            StopHashes = @('keeper', 'pack')
        })
        $script:actions = New-Object Collections.ArrayList
        $DryRun = $true
        Invoke-Expression $loop.Extent.Text
        Check "$action dry run leaves duplicate bytes intact" (Test-Path -LiteralPath $file)
        $DryRun = $false; $script:stopFailure = 'pack'
        Invoke-Expression $loop.Extent.Text
        Check "$action failed stop leaves duplicate intact" (Test-Path -LiteralPath $file)
        $script:stopFailure = 'keeper'
        Invoke-Expression $loop.Extent.Text
        Check "$action failed keeper stop prevents removal" (Test-Path -LiteralPath $file)
        $script:stopFailure = ''; $script:stops.Clear()
        Invoke-Expression $loop.Extent.Text
        Check "$action confirmed stops permit removal" (-not (Test-Path -LiteralPath $file))
        Check "$action stops both keeper and duplicate owner" ($script:stops -contains 'keeper' -and $script:stops -contains 'pack')
    }
}
finally { Remove-Item -LiteralPath $base -Recurse -Force }
if ($script:fails) { exit 1 }
exit 0
