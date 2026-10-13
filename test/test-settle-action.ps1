# Real tiny media/sidecar fixtures; production planner and mover, mocked API only.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$src = [IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'))
$start = $src.IndexOf('$script:boundaryPattern'); $end = $src.IndexOf('# actions', $start)
Invoke-Expression $src.Substring($start, $end - $start)
$start = $src.IndexOf('function Remove-OrphanPath {'); $end = $src.IndexOf('function Ensure-Category {', $start)
Invoke-Expression $src.Substring($start, $end - $start)
$start = $src.IndexOf('function Invoke-SettlePlan'); $end = $src.IndexOf('# Reap totals', $start)
Invoke-Expression $src.Substring($start, $end - $start)
$script:fails = 0
function Check { param($Name, $Ok) if ($Ok) { "[PASS] $Name" } else { $script:fails++; "[FAIL] $Name" } }
function Write-Log { param($Level, $Message) Write-Host "  $Level $Message" }
function Stop-TorrentAndConfirm { param($T) $script:stopCalls++; return $script:stopOk }
function Invoke-ApiGet {
    param($Endpoint)
    if ($Endpoint -like 'torrents/info?hashes=*') {
        if (-not $script:removed) { return @($script:activePlan.Torrent) }
        return @()
    }
    return @()
}
function Remove-Torrent {
    param($T, [switch]$Knows, $DeleteFiles, [switch]$AllowIncomingBetter, $Reason)
    $script:removeCalls++
    if (-not $Knows -or $DeleteFiles -ne $false) { throw 'entry removal must preserve media' }
    $journal = Join-Path $script:settleJournalDir ($T.hash + '.json')
    if (-not (Test-Path -LiteralPath $journal)) { throw 'entry removal happened before durable journal write' }
    foreach ($f in $script:activePlan.Files) {
        if (-not (Test-Path -LiteralPath $f.Path) -or (Get-Item -LiteralPath $f.Path).Length -ne $f.Bytes) {
            throw 'media was moved before entry removal or source was not validated'
        }
    }
    $script:removed = -not $script:denyRemoval
}
function Reset {
    $script:actions = New-Object Collections.ArrayList
    $script:stopOk = $true; $script:stopCalls = 0; $script:removeCalls = 0
    $script:removed = $false; $script:denyRemoval = $false
    $script:settleJournalDir = Join-Path $base ('journal-' + [guid]::NewGuid().ToString('N'))
    $script:pendingSettleRecords = @()
}
$base = Join-Path $env:TEMP ('settle-action-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $base | Out-Null
function Fixture {
    param($Label, [switch]$Pack)
    $fixtureRoot = Join-Path $base $Label
    $save = Join-Path $fixtureRoot 'Downloads'
    $series = Join-Path $fixtureRoot ('S' + [char]0xE9 + 'ries')
    $payload = Join-Path $save 'Release'
    New-Item -ItemType Directory -Path $payload -Force | Out-Null
    New-Item -ItemType Directory -Path $series -Force | Out-Null
    $names = @('Release/Example.Show.S01E08.mkv', 'Release/Stills/info.txt', 'Release/Example.Show.srt', 'Release/Sample/Example.Show.sample.mkv')
    if ($Pack) { $names += 'Release/Example.Show.S01E09.mkv' }
    $files = @()
    foreach ($name in $names) {
        $path = Join-Path $save $name
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, 'small media fixture')
        $files += [pscustomobject]@{ name = $name; size = (Get-Item -LiteralPath $path).Length }
    }
    $title = if ($Pack) { 'Example Show S01E08-E09 1080p WEB-DL' } else { 'Example Show S01E08 1080p WEB-DL' }
    $torrent = [pscustomobject]@{
        hash = ([guid]::NewGuid().ToString('N') + '00000000'); name = $title; progress = 1; state = 'stoppedUP'
        save_path = $save; content_path = $payload; parts = (Get-TitleParts -Name $title)
    }
    $lister = { param($h) return $files }.GetNewClosure()
    $verdicts = Get-SettleVerdicts -Torrents @($torrent) -FileLister $lister -SeriesDir $series -MoviesDir (Join-Path $fixtureRoot 'Movies')
    if ($verdicts[$torrent.hash].Verdict -ne 'SETTLE') { throw 'fixture did not produce a settle plan' }
    [pscustomobject]@{ Plan = $verdicts[$torrent.hash]; Files = $files; Torrent = $torrent; Payload = $payload; Save = $save; Series = $series }
}
function Run {
    param($Fixture, $Others = @())
    $script:activePlan = $Fixture.Plan
    $listed = if ($script:removed) { @($Others) } else { @($Fixture.Torrent) + @($Others) }
    Invoke-SettlePlan -Plan $Fixture.Plan -Torrents $listed
}
try {
    Reset; $DryRun = $false; $f = Fixture 'success'
    Check 'API path includes payload folder exactly once' ($f.Plan.Files[0].Path -eq (Join-Path $f.Payload 'Example.Show.S01E08.mkv'))
    Check 'samples are not flattened as main media' ($f.Plan.Files.Count -eq 1 -and $f.Plan.Discard.Count -eq 3)
    $ok = Run $f
    Check 'real media-only settle completes' $ok
    Check 'only main media remains in the season folder' (@(Get-ChildItem -LiteralPath $f.Plan.Dir -Recurse -File).Count -eq 1)
    Check 'entry removed without data before media movement' ($script:removed -and $script:removeCalls -eq 1)
    Check 'completed settle clears its durable pending record' (@(Get-PendingSettleRecords).Count -eq 0)
    Check 'sidecars samples and empty payload folder are removed' (-not (Test-Path -LiteralPath $f.Payload))
    Check 'shared save root is never deleted' (Test-Path -LiteralPath $f.Save)

    Reset; $DryRun = $true; $f = Fixture 'dry-run'; $ok = Run $f
    Check 'dry run does not stop or remove an entry' ($ok -and $script:stopCalls -eq 0 -and $script:removeCalls -eq 0)
    Check 'dry run leaves all payload files intact' (@(Get-ChildItem -LiteralPath $f.Payload -Recurse -File).Count -eq 4)

    Reset; $DryRun = $false; $script:stopOk = $false; $f = Fixture 'stop-failure'; $ok = Run $f
    Check 'unconfirmed stop prevents all file movement' (-not $ok -and (Test-Path -LiteralPath $f.Plan.Files[0].Path))
    Check 'unconfirmed stop preserves torrent entry' ($script:removeCalls -eq 0)

    Reset; $f = Fixture 'collision'
    New-Item -ItemType Directory -Path $f.Plan.Dir -Force | Out-Null
    [IO.File]::WriteAllText($f.Plan.Files[0].Target, 'x')
    $ok = Run $f
    Check 'even a smaller destination is never overwritten' (-not $ok -and (Get-Item -LiteralPath $f.Plan.Files[0].Target).Length -eq 1)
    Check 'collision leaves original media and entry intact' ((Test-Path -LiteralPath $f.Plan.Files[0].Path) -and $script:removeCalls -eq 0)

    Reset; $f = Fixture 'locked-pack' -Pack
    $locked = [IO.File]::Open($f.Plan.Files[1].Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $ok = Run $f } finally { $locked.Dispose() }
    Check 'locked media does not prevent removal of the best finished entry' (-not $ok -and $script:removed -and $script:removeCalls -eq 1)
    Check 'partially flattened pack is retained in the durable pending record' ((Test-Path -LiteralPath $f.Plan.Files[0].Target) -and @(Get-PendingSettleRecords).Count -eq 1)
    $script:pendingSettleRecords = @() # Simulate a new manager process.
    $ok = Run $f
    Check 'pack succeeds after file lock is released' ($ok -and $script:removed)
    Check 'retry after restart does not remove the entry twice' ($script:removeCalls -eq 1)

    Reset; $f = Fixture 'remove-refused'; $script:denyRemoval = $true; $ok = Run $f
    Check 'unconfirmed entry removal prevents media movement' (-not $ok -and (Test-Path -LiteralPath $f.Plan.Files[0].Path))
    Check 'sidecars survive unconfirmed entry removal' (@(Get-ChildItem -LiteralPath $f.Payload -Recurse -File).Count -eq 4)

    Reset; $f = Fixture 'shared'
    $other = [pscustomobject]@{ hash = ('b' * 40); content_path = $f.Payload }
    $ok = Run $f @($other)
    Check 'shared torrent payload prevents flattening under another entry' (-not $ok -and $script:removeCalls -eq 0)

    Reset; $f = Fixture 'unlisted'
    [IO.File]::WriteAllText((Join-Path $f.Payload 'keep.me'), 'unlisted user file')
    $ok = Run $f
    Check 'cleanup preserves unlisted files instead of recursively deleting payload' ($ok -and (Test-Path -LiteralPath (Join-Path $f.Payload 'keep.me')))

    Reset; $f = Fixture 'already-flat'
    New-Item -ItemType Directory -Path $f.Plan.Dir -Force | Out-Null
    Move-Item -LiteralPath $f.Plan.Files[0].Path -Destination $f.Plan.Files[0].Target
    $f.Plan.Files[0].Path = $f.Plan.Files[0].Target
    $ok = Run $f
    Check 'already-flat media verifies and removes only the entry' ($ok -and $script:removed -and (Test-Path -LiteralPath $f.Plan.Files[0].Target))

    $nested = [pscustomobject]@{ content_path = (Join-Path $f.Plan.Dir 'Release\media.mkv'); save_path = $f.Save }
    Check 'move verification accepts content nested under the target folder' (Test-MoveSettled -T $nested -TargetDir $f.Plan.Dir)
    $nested.content_path = $f.Plan.Dir + '-other\media.mkv'
    Check 'move verification does not mistake a sibling prefix for the target' (-not (Test-MoveSettled -T $nested -TargetDir $f.Plan.Dir))
    $rejected = $false
    try { Resolve-TorrentFilePath -T $f.Torrent -Name '../outside.mkv' | Out-Null } catch { $rejected = $true }
    Check 'file names escaping save_path are rejected' $rejected

    # A separate Windows process holds the media just as Plex does. No mocks of
    # Move-Item or locks: the OS itself denies the rename.
    Reset; $f = Fixture 'external-process-lock'
    $ready = Join-Path $base 'lock-ready'; $release = Join-Path $base 'lock-release'
    $lockPath = $f.Plan.Files[0].Path.Replace("'", "''")
    $command = @"
`$stream = [IO.File]::Open('$lockPath', [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    [IO.File]::WriteAllText('$ready', 'ready')
    while (-not (Test-Path -LiteralPath '$release')) { Start-Sleep -Milliseconds 50 }
} finally { `$stream.Dispose() }
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $locker = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) -PassThru -WindowStyle Hidden
    try {
        $deadline = (Get-Date).AddSeconds(10)
        while (-not (Test-Path -LiteralPath $ready)) {
            if ((Get-Date) -ge $deadline -or $locker.HasExited) { throw 'external lock process failed to acquire its fixture' }
            Start-Sleep -Milliseconds 50
        }
        $watch = [Diagnostics.Stopwatch]::StartNew(); $ok = Run $f; $watch.Stop()
        Check 'external lock removes entry but leaves media safely pending' (-not $ok -and $script:removed -and (Test-Path -LiteralPath $f.Plan.Files[0].Path))
        Check 'locked move returns promptly instead of stalling the pass' ($watch.Elapsed.TotalSeconds -lt 5)
        Check 'locked media is protected from orphan and duplicate cleanup' (Test-PendingSettlePath -Path $f.Payload)
        Check 'orphan delete helper refuses a pending media folder' (-not (Remove-OrphanPath -Path $f.Payload -Roots @($f.Save)) -and (Test-Path -LiteralPath $f.Plan.Files[0].Path))
        $lockedHash = $f.Torrent.hash
        $healthy = Fixture 'healthy-after-locked'
        $script:removed = $false; $script:removeCalls = 0
        $ok = Run $healthy
        Check 'a locked item does not block the next healthy torrent' ($ok -and (Test-Path -LiteralPath $healthy.Plan.Files[0].Target))
        Check 'healthy completion does not discard the locked item journal' (@(Get-PendingSettleRecords | Where-Object { $_.Plan.Torrent.hash -eq $lockedHash }).Count -eq 1)
        $batchHealthy = Fixture 'healthy-pending-batch'
        foreach ($file in $batchHealthy.Plan.Files) { $file | Add-Member -NotePropertyName MoveStarted -NotePropertyValue $false -Force }
        Save-PendingSettleRecord -Record ([pscustomobject]@{ Plan = $batchHealthy.Plan; EntryRemoved = $true; CreatedAt = (Get-Date).ToString('o') })
        $watch.Restart(); $completed = Invoke-PendingSettles -Torrents @(); $watch.Stop()
        Check 'production pending batch continues past a locked item' ($completed -eq 1 -and (Test-Path -LiteralPath $batchHealthy.Plan.Files[0].Target))
        Check 'pending batch stays bounded while another process retains its lock' ($watch.Elapsed.TotalSeconds -lt 5)
        [IO.File]::WriteAllText($release, 'release')
        if (-not $locker.WaitForExit(5000)) { throw 'external lock did not release' }
        $script:pendingSettleRecords = @(Get-PendingSettleRecords)
        $resumed = Invoke-PendingSettles -Torrents @()
        Check 'next run resumes an unlisted torrent from its durable journal' ($resumed -eq 1 -and (Test-Path -LiteralPath $f.Plan.Files[0].Target))
        Check 'resumed completion removes listed residues and pending record' (-not (Test-Path -LiteralPath $f.Payload) -and @(Get-PendingSettleRecords).Count -eq 0)
    }
    finally {
        [IO.File]::WriteAllText($release, 'release')
        if (-not $locker.WaitForExit(5000)) { $locker.Kill(); $locker.WaitForExit() }
        $locker.Dispose()
    }

    Reset; $f = Fixture 'locked-sidecar'
    $sidecar = [IO.File]::Open($f.Plan.Discard[0], [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { $ok = Run $f } finally { $sidecar.Dispose() }
    Check 'locked residue does not undo entry removal or media flattening' (-not $ok -and $script:removed -and (Test-Path -LiteralPath $f.Plan.Files[0].Target))
    Check 'locked residue retains its cleanup journal for the next run' (@(Get-PendingSettleRecords).Count -eq 1)
    $script:pendingSettleRecords = @()
    $completed = Invoke-PendingSettles -Torrents @()
    Check 'residue cleanup resumes without moving media or deleting entry again' ($completed -eq 1 -and $script:removeCalls -eq 1 -and -not (Test-Path -LiteralPath $f.Payload))

    Reset; $f = Fixture 'journal-failure'
    [IO.File]::WriteAllText($script:settleJournalDir, 'not a directory')
    $ok = Run $f
    Check 'unavailable journal preserves entry and media' (-not $ok -and $script:removeCalls -eq 0 -and (Test-Path -LiteralPath $f.Plan.Files[0].Path))
}
finally { Remove-Item -LiteralPath $base -Recurse -Force }
if ($script:fails) { exit 1 }
exit 0
