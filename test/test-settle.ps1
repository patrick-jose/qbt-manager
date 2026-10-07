<#
    Rule 3b: the settle rule.

    The user's rule, in their words:

        "when qbittorrent finishes downloading the best version of an episode or a
         movie (i.e. there's no more torrents on the list, queued or active, of
         episodes or packs or movie containing that episode or movie) I manually
         get the media file from the subfolder of the torrent download and cut to
         the main folder ... this is strict to the stage of there's no more
         possibility of getting a better version of said media file and that's why
         I remove it from the qbittorrent list too (without deleting the files)"

    Two parts of that sentence are load-bearing, and both are tested here:

      1. "no more torrents ... containing that episode or movie" - stricter than
         "could be bigger". Anything unfinished blocks, including a magnet whose
         size is unknown. Treating unknown as harmless would settle on the
         strength of not knowing.

      2. "no more POSSIBILITY of a better version" - so the file must not move
         while anything could still turn out better, even if it would be SMALLER.
         A 480p rip is not a better version, but its existence means the question
         is still open.

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-settle.ps1
#>

$ErrorActionPreference = 'Stop'
if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$projectRoot = Split-Path -Parent $PSScriptRoot

function Get-ProjectFile {
    param([string]$Name)
    $p = Join-Path $projectRoot $Name
    if (-not (Test-Path -LiteralPath $p)) { throw "cannot find $Name (looked in $p)" }
    return $p
}

$script:pass = 0
$script:fails = 0
function Check {
    param([string]$Label, $Ok)
    if ($Ok) { $script:pass++; Write-Host ("    [PASS] " + $Label) }
    else { $script:fails++; Write-Host ("    [FAIL] " + $Label) -ForegroundColor Red }
}

$msrc = [System.IO.File]::ReadAllText((Get-ProjectFile 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)

# The whole pure-decision region, sliced the same way status.ps1 slices it. Any
# narrower window and Get-SettleVerdicts would be calling functions it cannot see,
# and the suite would be testing a stub rather than the real thing.
$sA = $msrc.IndexOf('$script:boundaryPattern')
$sB = $msrc.IndexOf('# actions')
if ($sA -lt 0 -or $sB -le $sA) { throw 'could not locate the decision region in qbt-manager.ps1' }
Invoke-Expression $msrc.Substring($sA, $sB - $sA)

# The slice defines the API helpers but this suite never reaches the network: the
# file listing arrives through -FileLister, and Resolve-TorrentSetKey only asks the
# API for a season pack whose name does not state its range.
function Invoke-ApiGet { param([string]$Endpoint) return @() }

$script:pass = 0
$script:fails = 0

$GB = 1GB

# A REAL library tree, because Resolve-LibraryShowDir only returns a show folder
# when the series directory exists - and when it does not, Get-LibraryTargetDir
# silently answers with the series ROOT. That is the hazard the series-root guard
# exists for, and a fixture under a path that does not exist would have tested the
# guard instead of the thing being guarded.
$libRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('qbtsettle-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$MOVIES = Join-Path $libRoot 'Filmes'
$SERIES = Join-Path $libRoot 'Series'
New-Item -ItemType Directory -Path $MOVIES -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $SERIES 'Some Show\Season 3') -Force | Out-Null

function Film {
    param([string]$Hash, [double]$Gb, [double]$Progress, [string]$Title = 'Some Movie')
    return [pscustomobject][ordered]@{
        hash = $Hash; name = "$Title 2019 1080p WEB-DL"; size = [int64]($Gb * $GB)
        progress = $Progress; state = $(if ($Progress -ge 1) { 'stoppedUP' } else { 'downloading' })
        priority = 1; content_path = 'C:\lib\Filmes\Some Movie 2019 1080p WEB-DL'; parts = (Get-TitleParts -Name "$Title 2019 1080p WEB-DL")
    }
}

function Ep {
    param([string]$Hash, [string]$Name, [double]$Gb, [double]$Progress)
    return [pscustomobject][ordered]@{
        hash = $Hash; name = $Name; size = [int64]($Gb * $GB)
        progress = $Progress; state = $(if ($Progress -ge 1) { 'stoppedUP' } else { 'downloading' })
        priority = 1; content_path = 'C:\lib\Series\Some Show\Season 3'; parts = (Get-TitleParts -Name $Name)
    }
}

# A file listing, standing in for torrents/files.
function Lister {
    param([hashtable]$Map)
    return { param($h) if ($Map.ContainsKey($h)) { return @($Map[$h]) } return @() }.GetNewClosure()
}
function F { param([string]$Name, [double]$Gb) return [pscustomobject]@{ name = $Name; size = [int64]($Gb * $GB) } }

$ALIASES = @{}

Write-Host ''
Write-Host '== a set key says which episodes a release holds =='
$sp = Get-SetKeySpan -Key 'S3-E7'
Check 'a single episode'                ($sp.Known -and $sp.Season -eq 3 -and $sp.First -eq 7 -and $sp.Last -eq 7)
$sp = Get-SetKeySpan -Key 'S3-E1-E10'
Check 'a range, both ends'               ($sp.Known -and $sp.First -eq 1 -and $sp.Last -eq 10)
$sp = Get-SetKeySpan -Key 'S3-ALL'
Check 'a whole season'                   ($sp.Known -and $sp.First -eq 1 -and $sp.Last -eq 999)
$sp = Get-SetKeySpan -Key 'film'
Check 'a film is not a series'           ($sp.Known -and $sp.IsFilm)
$sp = Get-SetKeySpan -Key ''
Check 'an unknown key is reported unknown' (-not $sp.Known)

Check 'a range covers an episode inside it'      (Test-SetKeyCovers -Key 'S3-E1-E10' -Season 3 -Episode 7)
Check 'a range does not cover one past its end'  (-not (Test-SetKeyCovers -Key 'S3-E1-E6' -Season 3 -Episode 7))
Check 'a range does not cross seasons'           (-not (Test-SetKeyCovers -Key 'S3-E1-E10' -Season 4 -Episode 7))
Check 'a single episode covers only itself'      (Test-SetKeyCovers -Key 'S3-E7' -Season 3 -Episode 7)
Check 'a single episode covers nothing else'     (-not (Test-SetKeyCovers -Key 'S3-E7' -Season 3 -Episode 8))
Check 'a season pack covers the whole season'    (Test-SetKeyCovers -Key 'S3-ALL' -Season 3 -Episode 42)
# An unknown key covers nothing. If it covered everything, one unidentifiable
# release would freeze every settle in the run - and if it covered nothing, that
# same release would be settled on no evidence at all.
Check 'an unknown key covers NOTHING'            (-not (Test-SetKeyCovers -Key '' -Season 3 -Episode 1))
Check 'a film covers no episode'                 (-not (Test-SetKeyCovers -Key 'film' -Season 3 -Episode 1))

Write-Host ''
Write-Host '== the settled case: nothing unfinished holds the episode =='
$done = Ep 'a' 'Some Show S03E07 2160p WEB-DL' 9.0 1.0
$v = Get-SettleVerdicts -Torrents @($done) -FileLister (Lister @{ a = @((F 'Show.S03E07.mkv' 9.0)) }) `
        -MoviesDir $MOVIES -SeriesDir $SERIES -Aliases $ALIASES
Check 'a finished episode with no rival SETTLES' ($v.ContainsKey('a') -and $v['a'].Verdict -eq 'SETTLE')
Check 'and the file goes to the TOP of the season folder' `
    ((Split-Path -Parent $v['a'].Files[0].Target) -eq (Join-Path $SERIES 'Some Show\Season 3'))
Check 'keeping the release file name' `
    ((Split-Path -Leaf $v['a'].Files[0].Target) -eq 'Show.S03E07.mkv')

Write-Host ''
Write-Host '== anything unfinished blocks, whatever its size =='
# Smaller. A 480p is not a better version - but while it exists the question of
# which version is best is still open, which is the stage the user set.
$m = Ep 'a' 'Some Show S03E07 2160p WEB-DL' 9.0 1.0
$small = Ep 'b' 'Some Show S03E07 480p WEBRip' 0.6 0.4
$v = Get-SettleVerdicts -Torrents @($m, $small) -FileLister (Lister @{ a = @((F 'Show.S03E07.mkv' 9.0)) }) `
        -MoviesDir $MOVIES -SeriesDir $SERIES -Aliases $ALIASES
Check 'an unfinished SMALLER copy still holds it' ($v.ContainsKey('a') -and $v['a'].Verdict -eq 'WAIT')
Check 'and the reason names the blocker'         ($v['a'].Reason -match "smaller|still hold")

# A magnet. Size unknown, and unknown must not be read as harmless.
$m = Ep 'a' 'Some Show S03E07 2160p WEB-DL' 9.0 1.0
$mag = Ep 'c' 'Some Show S03E07 1080p' 0.0 0.0
$mag.state = 'metaDL'
$v = Get-SettleVerdicts -Torrents @($m, $mag) -FileLister (Lister @{ a = @((F 'Show.S03E07.mkv' 9.0)) }) `
        -MoviesDir $MOVIES -SeriesDir $SERIES -Aliases $ALIASES
Check 'a MAGNET blocks - its size is unknown'    ($v.ContainsKey('a') -and $v['a'].Verdict -eq 'WAIT')

# Stopped, at priority 0, out of the queue. It cannot deliver anything by itself,
# but it is not this rule's business to assume the user has given up on it.
$m = Ep 'a' 'Some Show S03E07 2160p WEB-DL' 9.0 1.0
$stopped = Ep 'd' 'Some Show S03E07 2160p WEB-DL' 12.0 0.3
$stopped.state = 'stoppedDL'
$stopped.priority = 0
$v = Get-SettleVerdicts -Torrents @($m, $stopped) -FileLister (Lister @{ a = @((F 'Show.S03E07.mkv' 9.0)) }) `
        -MoviesDir $MOVIES -SeriesDir $SERIES -Aliases $ALIASES
Check 'a STOPPED unfinished copy blocks'         ($v.ContainsKey('a') -and $v['a'].Verdict -eq 'WAIT')

# A FINISHED copy never blocks: it is not going to arrive, and two finished copies
# of one episode is rule 4's business, not this rule's.
$m = Ep 'a' 'Some Show S03E07 2160p WEB-DL' 9.0 1.0
$other = Ep 'e' 'Some Show S03E07 1080p WEB-DL' 3.0 1.0
$v = Get-SettleVerdicts -Torrents @($m, $other) -FileLister (Lister @{ a = @((F 'Show.S03E07.mkv' 9.0)) }) `
        -MoviesDir $MOVIES -SeriesDir $SERIES -Aliases $ALIASES
Check 'another FINISHED copy does not block'     ($v.ContainsKey('a') -and $v['a'].Verdict -eq 'SETTLE')

Write-Host ''
Write-Host '== a pack: all or nothing, because a live entry re-fetches =='
$packName = 'Some Show S03E01-E08 1080p WEB-DL'
$pack = Ep 'p' $packName 40.0 1.0
$packFiles = @((F 'Show.S03E01.mkv' 5.0), (F 'Show.S03E02.mkv' 5.0), (F 'nfo', 0.0))
$v = Get-SettleVerdicts -Torrents @($pack) -FileLister (Lister @{ p = $packFiles }) `
        -MoviesDir $MOVIES -SeriesDir $SERIES -Aliases $ALIASES
Check 'a clear pack settles'                     ($v.ContainsKey('p') -and $v['p'].Verdict -eq 'SETTLE')
Check 'and only its MEDIA files are moved'       (@($v['p'].Files).Count -eq 2)
Check 'the .nfo is left behind'                  (@($v['p'].Files | Where-Object { $_.Leaf -eq 'nfo' }).Count -eq 0)

# One unfinished single for episode 2 of the pack's range. Settling episodes 1, 3
# and so on would leave a live entry missing a file, and qBittorrent would fetch
# it again - so the whole pack waits.
$single = Ep 's' 'Some Show S03E02 2160p WEB-DL' 9.0 0.4
$v = Get-SettleVerdicts -Torrents @($pack, $single) -FileLister (Lister @{ p = $packFiles }) `
        -MoviesDir $MOVIES -SeriesDir $SERIES -Aliases $ALIASES
Check 'a pack with ONE blocked episode waits in FULL' ($v.ContainsKey('p') -and $v['p'].Verdict -eq 'WAIT')
Check 'and moves nothing at all'                 (@($v['p'].Files).Count -eq 0)

# A single outside the pack's range does not block it.
$outside = Ep 'o' 'Some Show S03E09 2160p WEB-DL' 9.0 0.4
$v = Get-SettleVerdicts -Torrents @($pack, $outside) -FileLister (Lister @{ p = $packFiles }) `
        -MoviesDir $MOVIES -SeriesDir $SERIES -Aliases $ALIASES
Check 'an episode outside the range does not block' ($v.ContainsKey('p') -and $v['p'].Verdict -eq 'SETTLE')

Write-Host ''
Write-Host '== films =='
$film = Film 'f1' 20.0 1.0 'Some Movie'
$v = Get-SettleVerdicts -Torrents @($film) -FileLister (Lister @{ f1 = @((F 'Some Movie 2019 1080p WEB-DL.mkv' 20.0)) }) `
        -MoviesDir $MOVIES -SeriesDir $SERIES -Aliases $ALIASES
Check 'a finished film with no rival settles'     ($v.ContainsKey('f1') -and $v['f1'].Verdict -eq 'SETTLE')
Check 'into the movies folder'                   ((Split-Path -Parent $v['f1'].Files[0].Target) -eq $MOVIES)

$rival = Film 'f2' 44.0 0.2 'Some Movie'
$v = Get-SettleVerdicts -Torrents @($film, $rival) -FileLister (Lister @{ f1 = @((F 'Some Movie 2019 1080p WEB-DL.mkv' 20.0)) }) `
        -MoviesDir $MOVIES -SeriesDir $SERIES -Aliases $ALIASES
Check 'an unfinished film of the same title blocks' ($v.ContainsKey('f1') -and $v['f1'].Verdict -eq 'WAIT')

$otherFilm = Film 'f3' 8.0 0.2 'Another Movie'
$v = Get-SettleVerdicts -Torrents @($film, $otherFilm) -FileLister (Lister @{ f1 = @((F 'Some Movie 2019 1080p WEB-DL.mkv' 20.0)) }) `
        -MoviesDir $MOVIES -SeriesDir $SERIES -Aliases $ALIASES
Check 'a DIFFERENT film does not block it'       ($v.ContainsKey('f1') -and $v['f1'].Verdict -eq 'SETTLE')

# A whole-season key spans 1 to 999, so it overlaps anything in that season and
# holds under anything else. Asking it per episode instead would be 999 questions
# about episodes an eight-episode pack does not have.
Check 'a season pack overlaps its own season'  (Test-SpanOverlap -A (Get-SetKeySpan 'S3-ALL') -B (Get-SetKeySpan 'S3-E1-E8'))
Check 'and not another season'                 (-not (Test-SpanOverlap -A (Get-SetKeySpan 'S3-ALL') -B (Get-SetKeySpan 'S4-E1')))
Check 'a range overlaps an episode inside it'  (Test-SpanOverlap -A (Get-SetKeySpan 'S3-E1-E10') -B (Get-SetKeySpan 'S3-E7'))
Check 'and nothing outside it'                 (-not (Test-SpanOverlap -A (Get-SetKeySpan 'S3-E1-E6') -B (Get-SetKeySpan 'S3-E7')))
Check 'an unknown span overlaps NOTHING'       (-not (Test-SpanOverlap -A (Get-SetKeySpan '') -B (Get-SetKeySpan 'S3-E7')))
Check 'a film overlaps no episode'             (-not (Test-SpanOverlap -A (Get-SetKeySpan 'film') -B (Get-SetKeySpan 'S3-E1')))

Write-Host ''
Write-Host '== not knowing is the reason to wait =='
$noFiles = Ep 'n' 'Some Show S03E07 2160p WEB-DL' 9.0 1.0
$v = Get-SettleVerdicts -Torrents @($noFiles) -FileLister (Lister @{}) -MoviesDir $MOVIES -SeriesDir $SERIES -Aliases $ALIASES
Check 'a torrent with no readable file list waits' (-not $v.ContainsKey('n'))

$noMedia = Ep 'q' 'Some Show S03E07 2160p WEB-DL' 9.0 1.0
$v = Get-SettleVerdicts -Torrents @($noMedia) -FileLister (Lister @{ q = @((F 'readme.txt' 0.0), (F 'poster.jpg' 0.1)) }) `
        -MoviesDir $MOVIES -SeriesDir $SERIES -Aliases $ALIASES
Check 'a torrent with no media file waits'        (-not $v.ContainsKey('q'))

$unidentified = Ep 'u' 'Some Show S03E07 2160p WEB-DL' 9.0 1.0
$unidentified.parts = $null
$v = Get-SettleVerdicts -Torrents @($unidentified) -FileLister (Lister @{ u = @((F 'Show.S03E07.mkv' 9.0)) }) `
        -MoviesDir $MOVIES -SeriesDir $SERIES -Aliases $ALIASES
Check 'an UNIDENTIFIED torrent waits'            (-not $v.ContainsKey('u'))

$gone = Ep 'g' 'Some Show S03E07 2160p WEB-DL' 9.0 1.0
$v = Get-SettleVerdicts -Torrents @($gone) -Gone @{ g = $true } -FileLister (Lister @{ g = @((F 'Show.S03E07.mkv' 9.0)) }) `
        -MoviesDir $MOVIES -SeriesDir $SERIES -Aliases $ALIASES
Check 'something this run already deleted waits'  (-not $v.ContainsKey('g'))

# A whole-season key is read as the whole season, which is the CONSERVATIVE
# reading: it asks about every episode in the season rather than only the eight
# the pack holds, so it holds the pack back more often than strictly necessary.
# Erring that way costs a postponement. The earlier form of this check asserted
# the opposite, and was wrong about its own code.
$seasonPack = Ep 'w' 'Some Show S03 Complete 1080p WEB-DL' 40.0 1.0
$v = Get-SettleVerdicts -Torrents @($seasonPack) -FileLister (Lister @{ w = @((F 'Show.S03E01.mkv' 5.0)) }) `
        -MoviesDir $MOVIES -SeriesDir $SERIES -Aliases $ALIASES
Check 'a whole-season pack with nothing against it settles' ($v.ContainsKey('w') -and $v['w'].Verdict -eq 'SETTLE')

# ...but one unfinished episode ANYWHERE in that season holds the whole pack back,
# because the pack claims the season and cannot say which parts of it are its own.
$inSeason = Ep 'x' 'Some Show S03E44 2160p WEB-DL' 9.0 0.3
$v = Get-SettleVerdicts -Torrents @($seasonPack, $inSeason) -FileLister (Lister @{ w = @((F 'Show.S03E01.mkv' 5.0)) }) `
        -MoviesDir $MOVIES -SeriesDir $SERIES -Aliases $ALIASES
Check 'one unfinished episode holds a season pack back' ($v.ContainsKey('w') -and $v['w'].Verdict -eq 'WAIT')

# A SERIES file must not land in the series root. Get-LibraryTargetDir returns
# exactly that when the series directory cannot be resolved, and a file loose in
# the root is invisible to every rule that works per show folder from then on.
$rootTarget = $null
$v = Get-SettleVerdicts -Torrents @($done) -FileLister (Lister @{ a = @((F 'Show.S03E07.mkv' 9.0)) }) `
        -MoviesDir $MOVIES -SeriesDir 'C:\no\such\series\root' -Aliases $ALIASES
if ($v.ContainsKey('a')) { $rootTarget = $v['a'].Verdict }
Check 'a file is never settled into the series ROOT' ($rootTarget -eq 'WAIT')

Write-Host ''
Write-Host '== the action must be all-or-nothing and must keep the data =='
$act = $msrc
Check 'finished entry removal passes -Knows and preserves data' ($act -cmatch 'Remove-Torrent -T \$t -Knows -DeleteFiles \$false')
# The ordering is the safety. Stop, move, verify, and only then remove the entry.
$stopAt = $act.IndexOf('Stop-TorrentAndConfirm -T $t')
$rmAt = $act.IndexOf('Remove-Torrent -T $t -Knows -DeleteFiles $false')
$mvAt = $act.IndexOf('Move-Item -LiteralPath $src -Destination $dst')
$vfAt = $act.IndexOf('$after.Length -eq [int64]$f.Bytes')
Check 'it STOPS the torrent before moving'      ($stopAt -gt 0 -and $stopAt -lt $mvAt)
Check 'it MOVES the file'                       ($mvAt -gt 0)
Check 'it VERIFIES the size after the move'     ($vfAt -gt $mvAt)
Check 'and only THEN removes the entry'         ($rmAt -gt $vfAt)
Check 'a failed verification keeps the entry'   ($act -cmatch '\$failed\.Count -gt 0')
Check 'an unconfirmed stop keeps the entry'     ($act -cmatch 'if \(-not \$stoppedOk\)')
# Refusing to overwrite is rule 4b's call to make, not this rule's.
Check 'it refuses to overwrite a library file'  ($act -cmatch 'already in the library')

Write-Host ''
Write-Host ''
Remove-Item -LiteralPath $libRoot -Recurse -Force -ErrorAction SilentlyContinue
Check 'the fixture tree is gone' (@(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'qbtsettle-*' -ErrorAction SilentlyContinue).Count -eq 0)

if ($script:fails -eq 0) {
    Write-Host ("all settle tests passed (" + $script:pass + " checks)") -ForegroundColor Green
    exit 0
}
else {
    Write-Host ("$fail of " + ($script:pass + $script:fails) + " settle checks FAILED") -ForegroundColor Red
    exit 1
}
