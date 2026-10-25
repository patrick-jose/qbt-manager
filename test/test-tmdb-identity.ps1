$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'), [Text.Encoding]::UTF8)
$start = $source.IndexOf('$script:boundaryPattern'); $end = $source.IndexOf('# actions', $start)
if ($start -lt 0 -or $end -le $start) { throw 'identity helper block not found' }
Invoke-Expression $source.Substring($start, $end - $start)
$script:fails = 0
function Check { param($Label, $Ok) if ($Ok) { Write-Host "[PASS] $Label" } else { $script:fails++; Write-Host "[FAIL] $Label" } }
function Reset-TmdbBudget { $script:tmdbNewLookupCount = 0; $script:tmdbRequestCount = 0 }

$script:tmdbNewLookupCount = 0
$script:tmdbRequestCount = 0
$script:tmdbCalls = 0
$script:tmdbMode = 'mars'
$request = {
    param($uri)
    $script:tmdbCalls++
    if ($uri -match '/alternative_titles$') {
        return [pscustomobject]@{ titles = @([pscustomobject]@{ title = 'Marte Um' }); results = @([pscustomobject]@{ name = 'Marte Um' }) }
    }
    if ($uri -match '/tv/(\d+)$') {
        $seasons = if ($Matches[1] -eq '200') { 3 } else { 1 }
        return [pscustomobject]@{ id = [int]$Matches[1]; number_of_seasons = $seasons }
    }
    if ($uri -match '/search/movie') {
        if ($script:tmdbMode -eq 'ambiguous') {
            return [pscustomobject]@{ results = @(
                [pscustomobject]@{ id = 10; title = 'Same Name'; original_title = 'Same Name'; release_date = '2022-01-01' },
                [pscustomobject]@{ id = 11; title = 'Same Name'; original_title = 'Same Name'; release_date = '2022-04-01' }
            ) }
        }
        if ($script:tmdbMode -eq 'wrong-year') {
            return [pscustomobject]@{ results = @([pscustomobject]@{ id = 12; title = 'Mars One'; original_title = 'Mars One'; release_date = '2012-01-01' }) }
        }
        if ($script:tmdbMode -eq 'movie-yearless') {
            return [pscustomobject]@{ results = @([pscustomobject]@{ id = 555; title = 'Some Indie Film'; original_title = 'Some Indie Film'; release_date = '' }) }
        }
        return [pscustomobject]@{ results = @([pscustomobject]@{ id = 123; title = 'Mars One'; original_title = 'Mars One'; release_date = '2022-01-01' }) }
    }
    if ($uri -match '/search/tv') {
        if ($script:tmdbMode -eq 'tv-correction') {
            # TMDB itself finds nothing for 'bbc louis ...'; the lookup must ask
            # again without the broadcaster prefix.
            if ($uri -notmatch [regex]::Escape([uri]::EscapeDataString('louis theroux life on the edge'))) {
                return [pscustomobject]@{ results = @() }
            }
            return [pscustomobject]@{ results = @([pscustomobject]@{ id = 109937; name = 'Louis Theroux: Life on the Edge'; original_name = 'Louis Theroux: Life on the Edge'; first_air_date = '2020-09-06' }) }
        }
        if ($script:tmdbMode -eq 'tv-multiseason') {
            return [pscustomobject]@{ results = @([pscustomobject]@{ id = 200; name = 'Planet Earth'; original_name = 'Planet Earth'; first_air_date = '2006-03-05' }) }
        }
        if ($script:tmdbMode -eq 'tv-ambiguous') {
            return [pscustomobject]@{ results = @(
                [pscustomobject]@{ id = 300; name = 'Same Show'; original_name = 'Same Show'; first_air_date = '2020-01-01' },
                [pscustomobject]@{ id = 301; name = 'Same Show'; original_name = 'Same Show'; first_air_date = '2021-01-01' }
            ) }
        }
        if ($script:tmdbMode -eq 'tv-year' -or $script:tmdbMode -eq 'tv-wrong-year') {
            $air = if ($script:tmdbMode -eq 'tv-year') { '2020-01-01' } else { '2015-01-01' }
            return [pscustomobject]@{ results = @([pscustomobject]@{ id = 400; name = 'Some Documentary'; original_name = 'Some Documentary'; first_air_date = $air }) }
        }
        return [pscustomobject]@{ results = @([pscustomobject]@{ id = 77; name = 'Widows Bay'; original_name = 'Widows Bay'; first_air_date = '2025-01-01' }) }
    }
    throw "unexpected TMDB fixture URI: $uri"
}

Reset-TmdbBudget
$cache = @{}
$mars = Get-TitleParts -Name 'Marte Um aka Mars One (2022) 720p WEB-DL'
$identity = Get-TmdbIdentity -Parts $mars -Name 'Marte Um aka Mars One (2022) 720p WEB-DL' `
    -BearerToken 'test-token' -Cache $cache -Request $request -MaxLookups 8
Check 'localized movie alias resolves to a unique year-matched TMDB ID' ($identity.status -eq 'matched' -and $identity.type -eq 'movie' -and $identity.id -eq '123')
$firstCalls = $script:tmdbCalls
$again = Get-TmdbIdentity -Parts $mars -Name 'Marte Um aka Mars One (2022) 720p WEB-DL' `
    -BearerToken 'test-token' -Cache $cache -Request $request -MaxLookups 8
Check 'resolved identities are served from cache without more requests' ($again.id -eq '123' -and $script:tmdbCalls -eq $firstCalls)

$script:tmdbMode = 'wrong-year'
Reset-TmdbBudget
$old = Get-TitleParts -Name 'Mars One (2022)'
$wrong = Get-TmdbIdentity -Parts $old -Name 'Mars One (2022)' -BearerToken 'test-token' -Cache @{} -Request $request -MaxLookups 8
Check 'a same-title result from a different year is not accepted' ($wrong.status -eq 'notfound')

$script:tmdbMode = 'ambiguous'
Reset-TmdbBudget
$ambig = Get-TitleParts -Name 'Same Name (2022)'
$ambiguous = Get-TmdbIdentity -Parts $ambig -Name 'Same Name (2022)' -BearerToken 'test-token' -Cache @{} -Request $request -MaxLookups 8
Check 'multiple matching TMDB works are marked ambiguous, not guessed' ($ambiguous.status -eq 'ambiguous' -and -not $ambiguous.id)

Reset-TmdbBudget
$tv = Get-TitleParts -Name 'Widows Bay S01E02 1080p WEB-DL (2025)'
$tvIdentity = Get-TmdbIdentity -Parts $tv -Name 'Widows Bay S01E02 1080p WEB-DL (2025)' `
    -BearerToken 'test-token' -Cache @{} -Request $request -MaxLookups 8
Check 'series searches use the TV endpoint and return a TV identity' ($tvIdentity.status -eq 'matched' -and $tvIdentity.type -eq 'tv' -and $tvIdentity.id -eq '77')

# --- a marker-less release is retried against TV ---------------------------
$script:tmdbMode = 'tv-correction'
Reset-TmdbBudget
$louis = Get-TitleParts -Name 'BBC Louis Theroux: Life on the Edge 1080p HDTV x265-MVGroup'
Check 'a marker-less name is parsed as a film first' (-not $louis.IsSeries -and $louis.Episode -eq $null)
$correctionCache = @{}
$louisIdentity = Get-TmdbIdentity -Parts $louis -Name 'BBC Louis Theroux: Life on the Edge 1080p HDTV x265-MVGroup' `
    -BearerToken 'test-token' -Cache $correctionCache -Request $request -MaxLookups 8
Check 'a unique exact-title TV match is accepted for a film-shaped release' ($louisIdentity.status -eq 'matched' -and $louisIdentity.type -eq 'tv' -and $louisIdentity.id -eq '109937' -and $louisIdentity.corrected)
$louisParts = Set-TmdbIdentity -Parts $louis -Identity $louisIdentity
Check 'a single-season show becomes a season pack' ($louisParts.IsSeries -and $louisParts.Season -eq 1 -and $louisParts.Episode -eq 0 -and -not $louisParts.IsMultiEpisode)
Check 'TMDB does not rewrite the parsed filing title' ($louisParts.Title -eq $louis.Title -and $louisParts.Title -eq 'bbc louis theroux life on the edge')
Check 'the season pack keys as a whole season' ((Get-EpisodeSetKey -Parts $louisParts) -eq 'S1-ALL')

$callsBeforeCache = $script:tmdbCalls
$cachedCorrection = Get-TmdbIdentity -Parts $louis -Name 'BBC Louis Theroux: Life on the Edge 1080p HDTV x265-MVGroup' `
    -BearerToken 'test-token' -Cache $correctionCache -Request $request -MaxLookups 8
Check 'a corrected identity is cached with its season evidence' ($cachedCorrection.corrected -and $cachedCorrection.season -eq 1 -and $script:tmdbCalls -eq $callsBeforeCache)

$script:tmdbMode = 'tv-multiseason'
Reset-TmdbBudget
$planet = Get-TitleParts -Name 'BBC Planet Earth 1080p BluRay'
$multi = Get-TmdbIdentity -Parts $planet -Name 'BBC Planet Earth 1080p BluRay' `
    -BearerToken 'test-token' -Cache @{} -Request $request -MaxLookups 8
Check 'a multi-season match never invents a season' ($multi.status -eq 'matched' -and $multi.type -eq 'tv' -and -not $multi.corrected -and $multi.seasons -eq 3)
$planetParts = Set-TmdbIdentity -Parts $planet -Identity $multi
Check 'a multi-season result leaves the release a film' (-not $planetParts.IsSeries -and $planetParts.TmdbId -eq '200')

$script:tmdbMode = 'tv-ambiguous'
Reset-TmdbBudget
$sameShow = Get-TitleParts -Name 'BBC Same Show 1080p HDTV'
$ambigShow = Get-TmdbIdentity -Parts $sameShow -Name 'BBC Same Show 1080p HDTV' `
    -BearerToken 'test-token' -Cache @{} -Request $request -MaxLookups 8
Check 'two exact TV candidates never change the media type' ($ambigShow.status -eq 'ambiguous' -and -not $ambigShow.id -and -not (Set-TmdbIdentity -Parts $sameShow -Identity $ambigShow).IsSeries)

$script:tmdbMode = 'tv-year'
Reset-TmdbBudget
$doc = Get-TitleParts -Name 'Some Documentary 2020 1080p WEB-DL'
$yearCorrection = Get-TmdbIdentity -Parts $doc -Name 'Some Documentary 2020 1080p WEB-DL' `
    -BearerToken 'test-token' -Cache @{} -Request $request -MaxLookups 8
Check 'a year-scoped film lookup falls back to TV only after a miss' ($yearCorrection.status -eq 'matched' -and $yearCorrection.type -eq 'tv' -and $yearCorrection.corrected)

$script:tmdbMode = 'tv-wrong-year'
Reset-TmdbBudget
$wrongShow = Get-TmdbIdentity -Parts $doc -Name 'Some Documentary 2020 1080p WEB-DL' `
    -BearerToken 'test-token' -Cache @{} -Request $request -MaxLookups 8
Check 'a TV result from a different year cannot re-type the release' ($wrongShow.status -eq 'notfound')

$script:tmdbMode = 'movie-yearless'
Reset-TmdbBudget
$indie = Get-TitleParts -Name 'Some Indie Film 1080p WEB-DL'
$filmIdentity = Get-TmdbIdentity -Parts $indie -Name 'Some Indie Film 1080p WEB-DL' `
    -BearerToken 'test-token' -Cache @{} -Request $request -MaxLookups 8
Check 'a yearless exact movie match keeps the release a film' ($filmIdentity.status -eq 'matched' -and $filmIdentity.type -eq 'movie' -and -not (Set-TmdbIdentity -Parts $indie -Identity $filmIdentity).IsSeries)

# --- identity comparisons --------------------------------------------------
$movieA = Get-TitleParts -Name 'Mars One (2022)'
$movieB = Get-TitleParts -Name 'Marte Um aka Mars One (2022)'
foreach ($p in @($movieA, $movieB)) {
    $p | Add-Member TmdbId '123' -Force
    $p | Add-Member TmdbType 'movie' -Force
}
Check 'equal TMDB movie IDs override localized title mismatch' (Test-SameTitle -A $movieA -B $movieB)
$movieB.TmdbId = '999'
Check 'different TMDB IDs prevent a title-similarity false match' (-not (Test-SameTitle -A $movieA -B $movieB))

$showA = [pscustomobject]@{ parts = (Get-TitleParts -Name 'Widows Bay S01E02 The Trip 2025') }
$showB = [pscustomobject]@{ parts = (Get-TitleParts -Name 'O Segredo de Widows Bay S01E02 The Trip 2025') }
foreach ($show in @($showA, $showB)) {
    $show.parts | Add-Member TmdbId '77' -Force
    $show.parts | Add-Member TmdbType 'tv' -Force
    $show.parts | Add-Member TmdbNameKey 'widows bay' -Force
}
$fam = Get-ClusterFamilies -Clusters @(@($showA), @($showB))
Check 'localized series variants share the TMDB family ID' ($fam.Family[0] -eq 'tmdb:77' -and $fam.Family[1] -eq 'tmdb:77')
$groups = New-Object Collections.ArrayList
foreach ($show in @($showA, $showB)) { $group = New-Object Collections.ArrayList; [void]$group.Add($show); [void]$groups.Add($group) }
$merged = Merge-SeriesClusters -Clusters $groups
Check 'TMDB-matched series variants merge for the same season and episode' (@($merged).Count -eq 1 -and @($merged[0]).Count -eq 2)

$strictError = $null
try {
    & {
        Set-StrictMode -Version Latest
        $plainA = Get-TitleParts -Name 'Widows Bay S01E02'
        $plainB = Get-TitleParts -Name 'The Office S01E02'
        [void](Test-SameTitle -A $plainA -B $plainB)
        [void](Test-SameMediaIdentity -A $plainA -B $plainB)
        [void](Get-ClusterFamilies -Clusters @(@([pscustomobject]@{ parts = $plainA }), @([pscustomobject]@{ parts = $plainB })))
        [void](Set-FamilyLabels -Clusters @(@([pscustomobject]@{ parts = $plainA })))
        # A cache entry written before the correction fields existed must not
        # crash the preview.
        $legacyIdentity = [pscustomobject]@{ status = 'matched'; id = '123'; type = 'movie'; name = 'Mars One' }
        $legacyParts = Set-TmdbIdentity -Parts (Get-TitleParts -Name 'Mars One (2022)') -Identity $legacyIdentity
        if (-not $legacyParts.TmdbId) { throw 'legacy identity was not attached' }
    }
} catch { $strictError = $_ }
Check 'identity helpers tolerate missing TMDB fields under strict mode' ($null -eq $strictError)

$budgetCache = @{}
Reset-TmdbBudget
$budgetParts = Get-TitleParts -Name 'Mars One (2022)'
$null = Get-TmdbIdentity -Parts $budgetParts -Name 'Mars One (2022)' -BearerToken 'test-token' `
    -Cache $budgetCache -Request $request -MaxLookups 5 -MaxRequests 1
$budgetCount = $script:tmdbRequestCount
$null = Get-TmdbIdentity -Parts (Get-TitleParts 'Another Name (2022)') -Name 'Another Name (2022)' `
    -BearerToken 'test-token' -Cache @{} -Request $request -MaxLookups 5 -MaxRequests 1
Check 'TMDB network calls obey the per-run request budget' ($budgetCount -le 1 -and $script:tmdbRequestCount -eq $budgetCount)

if ($script:fails) { exit 1 }
exit 0
