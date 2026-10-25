$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'), [Text.Encoding]::UTF8)
$start = $source.IndexOf('$script:boundaryPattern'); $end = $source.IndexOf('# actions', $start)
if ($start -lt 0 -or $end -le $start) { throw 'identity helper block not found' }
Invoke-Expression $source.Substring($start, $end - $start)
$script:fails = 0
function Check { param($Label, $Ok) if ($Ok) { Write-Host "[PASS] $Label" } else { $script:fails++; Write-Host "[FAIL] $Label" } }

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
        return [pscustomobject]@{ results = @([pscustomobject]@{ id = 123; title = 'Mars One'; original_title = 'Mars One'; release_date = '2022-01-01' }) }
    }
    if ($uri -match '/search/tv') {
        return [pscustomobject]@{ results = @([pscustomobject]@{ id = 77; name = 'Widows Bay'; original_name = 'Widows Bay'; first_air_date = '2025-01-01' }) }
    }
    throw "unexpected TMDB fixture URI: $uri"
}

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
$old = Get-TitleParts -Name 'Mars One (2022)'
$wrong = Get-TmdbIdentity -Parts $old -Name 'Mars One (2022)' -BearerToken 'test-token' -Cache @{} -Request $request -MaxLookups 8
Check 'a same-title result from a different year is not accepted' ($wrong.status -eq 'notfound')

$script:tmdbMode = 'ambiguous'
$ambig = Get-TitleParts -Name 'Same Name (2022)'
$ambiguous = Get-TmdbIdentity -Parts $ambig -Name 'Same Name (2022)' -BearerToken 'test-token' -Cache @{} -Request $request -MaxLookups 8
Check 'multiple matching TMDB works are marked ambiguous, not guessed' ($ambiguous.status -eq 'ambiguous' -and -not $ambiguous.id)

$tv = Get-TitleParts -Name 'Widows Bay S01E02 1080p WEB-DL (2025)'
$tvIdentity = Get-TmdbIdentity -Parts $tv -Name 'Widows Bay S01E02 1080p WEB-DL (2025)' `
    -BearerToken 'test-token' -Cache @{} -Request $request -MaxLookups 8
Check 'series searches use the TV endpoint and return a TV identity' ($tvIdentity.status -eq 'matched' -and $tvIdentity.type -eq 'tv' -and $tvIdentity.id -eq '77')

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
if (@($merged).Count -ne 1 -or @($merged[0]).Count -ne 2) { Write-Host "[DEBUG] mergeCount=$(@($merged).Count) shape=$(@($merged | ForEach-Object { $_.Count }) -join ',') showA=$($showA.parts.Title) showB=$($showB.parts.Title) epA=$($showA.parts.Episode) epB=$($showB.parts.Episode)" }
Check 'TMDB-matched series variants merge for the same season and episode' (@($merged).Count -eq 1 -and @($merged[0]).Count -eq 2)

$budgetCache = @{}
$script:tmdbRequestCount = 0
$budgetParts = Get-TitleParts -Name 'Mars One (2022)'
$null = Get-TmdbIdentity -Parts $budgetParts -Name 'Mars One (2022)' -BearerToken 'test-token' `
    -Cache $budgetCache -Request $request -MaxLookups 5 -MaxRequests 1
$budgetCount = $script:tmdbRequestCount
$null = Get-TmdbIdentity -Parts (Get-TitleParts 'Another Name (2022)') -Name 'Another Name (2022)' `
    -BearerToken 'test-token' -Cache @{} -Request $request -MaxLookups 5 -MaxRequests 1
Check 'TMDB network calls obey the per-run request budget' ($budgetCount -le 1 -and $script:tmdbRequestCount -eq $budgetCount)

if ($script:fails) { exit 1 }
exit 0
