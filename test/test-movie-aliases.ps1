# Confirm the specified localized/title-prefix variants converge on one movie,
# including the one release incorrectly tagged as the S00E01 TV special.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$source = [IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'), [Text.Encoding]::UTF8)
$start = $source.IndexOf('$script:boundaryPattern'); $end = $source.IndexOf('# actions', $start)
if ($start -lt 0 -or $end -le $start) { throw 'parser and identity slice not found' }
Invoke-Expression $source.Substring($start, $end - $start)
$script:fails = 0
function Check { param($Name,$Ok) if ($Ok) { "[PASS] $Name" } else { $script:fails++; "[FAIL] $Name" } }
function Add-TestTitleAlias {
    param([hashtable]$Aliases, [string]$Release, [string]$CanonicalTitle)
    $parts = Get-TitleParts -Name $Release
    $Aliases[[string]$parts.Title] = $CanonicalTitle
}
function Add-TestYearAlias {
    param([hashtable]$Aliases, [string]$Release, $CanonicalIdentity)
    $parts = Get-TitleParts -Name $Release
    $Aliases[('{0}|{1}' -f [string]$parts.Year, [string]$parts.Title)] = $CanonicalIdentity
}

$titleAliases = @{}
$yearScopedMovieAliases = @{}
$specialMovieAliases = [pscustomobject]@{ 'the punisher one last kill' = 'the punisher one last kill' }

$names = @(
    'A.Marvel.Television.Special.Presentation.--.The.Punisher.One.Last.Kill.2026.ITA.ENG.1080p.DSNP.WEB-DL.DDP5.1.H.264-MeM.GP.mkv [ext.to]',
    'The Punisher One Last Kill 2026 1080p DSNP WEB-DL DDP5 1 Atmos H 264-WSKR [ext.to]',
    'Punisher_ Ostatnie starcie _ The Punisher_ One Last Kill [1080p] [DSNP] [WEB-DL] [H264] [DDP5.1.Atmos-KPFR] [Dubbing i Napisy PL] [ext.to]',
    'The Punisher S00E01 The Punisher One Last Kill 2160p DSNP WEB-DL DD 5 1 Atm [ext.to]'
)
Add-TestTitleAlias -Aliases $titleAliases -Release $names[0] -CanonicalTitle 'the punisher one last kill'
Add-TestTitleAlias -Aliases $titleAliases -Release $names[2] -CanonicalTitle 'the punisher one last kill'
$parts = @()
for ($i = 0; $i -lt $names.Count; $i++) {
    $p = Get-TitleParts -Name $names[$i]
    if ($i -eq 3) { $p = Resolve-SpecialMovieAlias -Parts $p -Name $names[$i] -Aliases $specialMovieAliases }
    $p = Resolve-PartsAlias -Parts $p -Aliases $titleAliases
    $parts += $p
}
Check 'the Marvel special-presentation prefix resolves to the movie identity' ($parts[0].Title -eq 'the punisher one last kill' -and $parts[0].Year -eq '2026')
Check 'the WSKR release is already parsed as the canonical movie' ($parts[1].Title -eq 'the punisher one last kill' -and $parts[1].Year -eq '2026')
Check 'the Polish/English alternate title resolves to the same movie' ($parts[2].Title -eq 'the punisher one last kill' -and -not $parts[2].Year)
Check 'the specific S00E01 release is reclassified as a movie' (-not $parts[3].IsSeries -and $parts[3].Season -eq $null -and $parts[3].Episode -eq $null)
Check 'the S00E01 release gets the same canonical movie title' ($parts[3].Title -eq 'the punisher one last kill')
for ($i=1; $i -lt $parts.Count; $i++) { Check "variant $i matches the canonical movie" (Test-SameTitle -A $parts[0] -B $parts[$i]) }

$other = Get-TitleParts -Name 'The Punisher S00E01 Frank Castle 2160p WEB-DL'
$safe = Resolve-SpecialMovieAlias -Parts $other -Name 'The Punisher S00E01 Frank Castle 2160p WEB-DL' -Aliases $specialMovieAliases
Check 'an unrelated Punisher S00E01 remains a series episode' ($safe.IsSeries -and $safe.Season -eq 0 -and $safe.Episode -eq 1)
$otherEpisode = Get-TitleParts -Name 'The Punisher S01E01 The Punisher One Last Kill 2160p WEB-DL'
$safe = Resolve-SpecialMovieAlias -Parts $otherEpisode -Name 'The Punisher S01E01 The Punisher One Last Kill 2160p WEB-DL' -Aliases $specialMovieAliases
Check 'the movie override does not affect a regular-season episode' ($safe.IsSeries -and $safe.Season -eq 1)

$mummyNames = @(
    'The Mummy (2026) 2160p DSNP WEB-DL',
    "Lee Cronin's The Mummy (2026) 1080p WEB-DL"
)
Add-TestYearAlias -Aliases $yearScopedMovieAliases -Release $mummyNames[0] -CanonicalIdentity 'lee cronins the mummy'
$mummy = foreach ($name in $mummyNames) {
    $p = Get-TitleParts -Name $name
    Resolve-YearScopedMovieAlias -Parts $p -Aliases $yearScopedMovieAliases
}
Check 'The Mummy 2026 resolves to Lee Cronin movie identity' ($mummy[0].Title -eq 'lee cronins the mummy' -and $mummy[0].Year -eq '2026')
Check 'Lee Cronins title already has the canonical identity' ($mummy[1].Title -eq 'lee cronins the mummy' -and $mummy[1].Year -eq '2026')
Check 'the two 2026 releases compare as the same movie' (Test-SameTitle -A $mummy[0] -B $mummy[1])
$oldMummy = Get-TitleParts -Name 'The Mummy (1999) 1080p BluRay'
$oldMummy = Resolve-YearScopedMovieAlias -Parts $oldMummy -Aliases $yearScopedMovieAliases
Check 'other years of The Mummy are not rewritten' ($oldMummy.Title -eq 'the mummy' -and $oldMummy.Year -eq '1999')
$notMummy = Get-TitleParts -Name 'The Mummy (2025) 1080p BluRay'
$notMummy = Resolve-YearScopedMovieAlias -Parts $notMummy -Aliases $yearScopedMovieAliases
Check 'the override is limited to the configured year' ($notMummy.Title -eq 'the mummy' -and $notMummy.Year -eq '2025')
$charlyA = Get-TitleParts -Name 'Charly (1968)'
$charlyB = Get-TitleParts -Name 'Charly i due mondi di Charly (1968)'
Add-TestYearAlias -Aliases $yearScopedMovieAliases -Release 'Charly i due mondi di Charly (1968)' -CanonicalIdentity 'charly'
$charlyA = Resolve-YearScopedMovieAlias -Parts $charlyA -Aliases $yearScopedMovieAliases
$charlyB = Resolve-YearScopedMovieAlias -Parts $charlyB -Aliases $yearScopedMovieAliases
Check 'Charly and Italian title resolve to one 1968 movie identity' ($charlyA.Title -eq 'charly' -and $charlyB.Title -eq 'charly' -and $charlyA.Year -eq '1968' -and $charlyB.Year -eq '1968')
$charlyRelease = Get-TitleParts -Name '(1968) Charly DVD-Rip (XVID, 2 0 AC3 @192kbps) [ext.to]'
Check 'a release with the year before Charly parses to the same movie' ($charlyRelease.Title -eq 'charly' -and $charlyRelease.Year -eq '1968' -and (Test-SameTitle -A $charlyA -B $charlyRelease))
$otherCharly = Get-TitleParts -Name 'Charly i due mondi di Charly (2002)'
$otherCharly = Resolve-YearScopedMovieAlias -Parts $otherCharly -Aliases $yearScopedMovieAliases
Check 'Charly title alias does not affect another year' ($otherCharly.Title -eq 'charly i due mondi di charly' -and $otherCharly.Year -eq '2002')
$mummyItalian = Get-TitleParts -Name 'mumia film lee cronina lee cronin s the mummy (2026)'
Add-TestYearAlias -Aliases $yearScopedMovieAliases -Release 'mumia film lee cronina lee cronin s the mummy (2026)' -CanonicalIdentity 'lee cronins the mummy'
$mummyItalian = Resolve-YearScopedMovieAlias -Parts $mummyItalian -Aliases $yearScopedMovieAliases
Check 'Mumia film Lee Cronina variant resolves to Lee Cronins The Mummy 2026' ($mummyItalian.Title -eq 'lee cronins the mummy' -and $mummyItalian.Year -eq '2026' -and -not $mummyItalian.IsSeries)
$brightCreatureTitles = @(
    'Criaturas luminosas Remarkably Bright Creatures (2026)',
    'Niezwykle szlachetne stworzenia Remarkably Bright Creatures (2026)',
    ("Pozoruhodn$([char]0x011B) bystr$([char]0x00E1) stvo$([char]0x0159)en$([char]0x00ED) Remarkably Bright Creatures (2026)"),
    'Remarkably Bright Creatures (2026)'
)
foreach ($name in $brightCreatureTitles | Select-Object -First 3) {
    Add-TestYearAlias -Aliases $yearScopedMovieAliases -Release $name -CanonicalIdentity 'remarkably bright creatures'
}
$brightCreatureParts = foreach ($name in $brightCreatureTitles) {
    $p = Get-TitleParts -Name $name
    Resolve-YearScopedMovieAlias -Parts $p -Aliases $yearScopedMovieAliases
}
Check 'localized 2026 Remarkably Bright Creatures titles resolve together' (@($brightCreatureParts | Where-Object { $_.Title -ne 'remarkably bright creatures' -or $_.Year -ne '2026' -or $_.IsSeries }).Count -eq 0)
$supergirlTitles = @('Only Polish Audio AI Supergirl (2026)', 'Only Polish Audio Supergirl (2026)', 'Supergirl (2026)')
foreach ($name in $supergirlTitles | Select-Object -First 2) {
    Add-TestYearAlias -Aliases $yearScopedMovieAliases -Release $name -CanonicalIdentity 'supergirl'
}
$supergirlParts = foreach ($name in $supergirlTitles) {
    $p = Get-TitleParts -Name $name
    Resolve-YearScopedMovieAlias -Parts $p -Aliases $yearScopedMovieAliases
}
Check 'Polish-audio Supergirl 2026 variants resolve to the same movie' (@($supergirlParts | Where-Object { $_.Title -ne 'supergirl' -or $_.Year -ne '2026' -or $_.IsSeries }).Count -eq 0)
$marsOneTitles = @('Mars One (2022)', 'Marte um aka Mars One (2022)', 'Marte um Mars One (2022)')
foreach ($name in $marsOneTitles | Select-Object -Skip 1) {
    Add-TestYearAlias -Aliases $yearScopedMovieAliases -Release $name -CanonicalIdentity 'mars one'
}
$marsOneParts = foreach ($name in $marsOneTitles) {
    $p = Get-TitleParts -Name $name
    Resolve-YearScopedMovieAlias -Parts $p -Aliases $yearScopedMovieAliases
}
Check 'Portuguese Mars One 2022 titles resolve to the same movie' (@($marsOneParts | Where-Object { $_.Title -ne 'mars one' -or $_.Year -ne '2022' -or $_.IsSeries }).Count -eq 0)
$otherMarsOne = Get-TitleParts -Name 'Marte um Mars One (2023)'
$otherMarsOne = Resolve-YearScopedMovieAlias -Parts $otherMarsOne -Aliases $yearScopedMovieAliases
Check 'Mars One aliases do not rewrite another year' ($otherMarsOne.Title -eq 'marte um mars one' -and $otherMarsOne.Year -eq '2023')
$somTitles = @(
    'O Som Ao Redor',
    'O Som Ao Redor aka Neighbouring Sounds (2012)',
    'Neighboring Sounds Sounds in the Neighborhood Sound Around O Som Ao Redor (2012)',
    'Neighbouring Sounds (2012)',
    'Sound around / Neighboring sounds / O som ao redor [2012, Brazil, drama, HDRip-AVC] Original + Sub Rus'
)
foreach ($name in $somTitles) {
    Add-TestTitleAlias -Aliases $titleAliases -Release $name -CanonicalTitle 'o som ao redor'
}
$somParts = foreach ($name in $somTitles) {
    $p = Get-TitleParts -Name $name
    Resolve-PartsAlias -Parts $p -Aliases $titleAliases
}
Check 'Portuguese, English, and descriptive titles resolve to O Som ao Redor' (@($somParts | Where-Object { $_.Title -ne 'o som ao redor' }).Count -eq 0)
Check 'the unyearred title and the 2012 releases compare as the same film' (@($somParts | Where-Object { -not (Test-SameTitle -A $somParts[0] -B $_) }).Count -eq 0)
$mortalKombatTitles = @('Mortal Kombat II (2026)', 'Mortal Kombat 2 (2026)', '2 Mortal Kombat II (2026)')
foreach ($name in @($mortalKombatTitles[1], $mortalKombatTitles[2])) {
    Add-TestYearAlias -Aliases $yearScopedMovieAliases -Release $name -CanonicalIdentity 'mortal kombat ii'
}
$mortalKombatParts = foreach ($name in $mortalKombatTitles) {
    $p = Get-TitleParts -Name $name
    Resolve-YearScopedMovieAlias -Parts $p -Aliases $yearScopedMovieAliases
}
Check 'Arabic-number and Roman-numeral Mortal Kombat II 2026 titles resolve together' (@($mortalKombatParts | Where-Object { $_.Title -ne 'mortal kombat ii' -or $_.Year -ne '2026' -or $_.IsSeries -or $_.Numbers.Count -gt 0 }).Count -eq 0)
Check 'the two Mortal Kombat II spellings compare as the same film' (@($mortalKombatParts | Where-Object { -not (Test-SameTitle -A $mortalKombatParts[0] -B $_) }).Count -eq 0)
$rebootCollection = Get-TitleParts -Name 'Mortal Kombat Reboot Collection (2021)'
Add-TestYearAlias -Aliases $yearScopedMovieAliases -Release 'Mortal Kombat Reboot Collection (2021)' `
    -CanonicalIdentity @{ title = 'mortal kombat ii'; year = '2026' }
$rebootCollection = Resolve-YearScopedMovieAlias -Parts $rebootCollection -Aliases $yearScopedMovieAliases
Check 'the explicitly identified 2021 reboot collection variant resolves to Mortal Kombat II 2026' ($rebootCollection.Title -eq 'mortal kombat ii' -and $rebootCollection.Year -eq '2026')
$rebootPack = Get-TitleParts -Name 'Mortal Kombat (Reboot) Collection (2021-2026) 1080p 10bit Bluray x265 HEVC'
$rebootPack = Resolve-YearScopedMovieAlias -Parts $rebootPack -Aliases $yearScopedMovieAliases
Check 'explicit Reboot Collection variant resolves to Mortal Kombat II 2026 identity' ($rebootPack.Title -eq 'mortal kombat ii' -and $rebootPack.Year -eq '2026' -and $rebootPack.Numbers.Count -eq 0)
Check 'Reboot Collection and Mortal Kombat II compare as the same movie' (Test-SameTitle -A $mortalKombatParts[0] -B $rebootPack)
$originalMortalKombat = Get-TitleParts -Name 'Mortal Kombat (2021) 1080p BluRay'
$originalMortalKombat = Resolve-YearScopedMovieAlias -Parts $originalMortalKombat -Aliases $yearScopedMovieAliases
Check 'the actual 2021 Mortal Kombat film remains separate' ($originalMortalKombat.Title -eq 'mortal kombat' -and $originalMortalKombat.Year -eq '2021')
if ($script:fails) { exit 1 }
exit 0
