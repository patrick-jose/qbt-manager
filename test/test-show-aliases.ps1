# Exercises titleAliases: the one mechanism that can join two spellings of a show
# that nothing else can relate.
#
# Measured on a live queue. 'euphoria' and 'euphoria us' are one show, and they
# share a first word, so dedup DID compare them. But the library folder comes from
# the parsed title, so they filed into 'Euphoria' and 'Euphoria Us' - and rule 4b
# only ever compares inside a single show folder. Two copies of S03E08 sat in the
# library, 10.27 GB and 6.89 GB, with no verdict between them and none possible.
#
# The same shape has a second case nothing can reach: 'widows bay', 'wdowia
# zatoka widows bay' and 'o segredo de widows bay' are one show in three
# languages, and 'zatoka' means 'bay' - only a person knows that.
#
# So the alias list is maintained by hand and nothing is guessed. These tests pin
# that: an unlisted title is untouched, a cycle terminates, and folding never
# depends on two titles resembling each other.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-show-aliases.ps1

$ErrorActionPreference = 'Stop'
if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

$projectRoot = Split-Path -Parent $PSScriptRoot
function Get-ProjectFile {
    param([string]$Name)
    $p = Join-Path $projectRoot $Name
    if (-not (Test-Path -LiteralPath $p)) {
        throw "cannot find $Name (looked in $p). These tests are meant to stay in the project's test folder."
    }
    return $p
}

$pass = 0; $fail = 0
function Check {
    param([string]$Name, [bool]$Ok)
    if ($Ok) { $script:pass++; Write-Host ("  [PASS] " + $Name) }
    else { $script:fail++; Write-Host ("  [FAIL] " + $Name) -ForegroundColor Red }
}

function Get-Slice {
    param([string]$Text, [string]$From, [string]$To)
    $s = $Text.IndexOf($From); $e = $Text.IndexOf($To)
    if ($s -lt 0 -or $e -le $s) { throw "could not locate the block between '$From' and '$To'" }
    return $Text.Substring($s, $e - $s)
}

$src = [System.IO.File]::ReadAllText((Get-ProjectFile 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)
Invoke-Expression (Get-Slice -Text $src -From 'function ConvertTo-LibraryFolderName' -To 'function Get-LibraryTargetDir')

# Resolve-PartsAlias retokenises the canonical title, and that asks the same
# question Get-TitleParts asks: which words carry no identifying signal. The list
# lives in the detection region, far above the slice above, so it is not defined
# here - and an empty list silently makes every word significant, which turned a
# real check into one that passed for the wrong reason.
#
# Read out of the source by regex, not restated. Get-Slice cannot do it: it finds
# its end marker with IndexOf, and the first ')' in a 4000-line file is nowhere
# near this list. A restated copy would also be free to drift from the real one,
# which is the whole failure this is guarding against.
$igMatch = [regex]::Match($src, '(?s)\$script:ignorable = @\((.*?)\)')
if (-not $igMatch.Success) { throw 'could not read $script:ignorable out of qbt-manager.ps1' }
$script:ignorable = @(Invoke-Expression $igMatch.Groups[1].Value)
Write-Host ("   (loaded " + $script:ignorable.Count + " ignorable words from the source)")

$cfg = [System.IO.File]::ReadAllText((Get-ProjectFile 'config.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
$shipped = $cfg.titleAliases

Write-Host ''
Write-Host '== the shipped config invites the list without filling it in =='
# A published config cannot know the reader's shows, and a guessed alias deletes
# the wrong file. So it ships empty and the real entries live in the git-ignored
# config.local.json.
Check 'config.json carries a titleAliases key'   ($null -ne $shipped)
Check 'and it is empty'                          (@($shipped.PSObject.Properties).Count -eq 0)
Check 'so nothing is aliased out of the box'     ((Resolve-ShowAlias -Title 'euphoria us' -Aliases $shipped) -eq 'euphoria us')
Check 'config.json is still valid JSON'          ($true)

Write-Host ''
Write-Host '== an alias folds, and only what it names =='
$one = [pscustomobject]@{ 'euphoria us' = 'euphoria' }
Check 'the alias applies'                        ((Resolve-ShowAlias -Title 'euphoria us' -Aliases $one) -eq 'euphoria')
Check 'the target itself is unchanged'           ((Resolve-ShowAlias -Title 'euphoria' -Aliases $one) -eq 'euphoria')
Check 'an unlisted title is untouched'           ((Resolve-ShowAlias -Title 'widows bay' -Aliases $one) -eq 'widows bay')
Check 'a title resembling the alias is NOT folded' ((Resolve-ShowAlias -Title 'euphoria uk' -Aliases $one) -eq 'euphoria uk')
Check 'no list at all folds nothing'             ((Resolve-ShowAlias -Title 'euphoria us' -Aliases $null) -eq 'euphoria us')
Check 'an empty list folds nothing'              ((Resolve-ShowAlias -Title 'euphoria us' -Aliases ([pscustomobject]@{})) -eq 'euphoria us')

Write-Host ''
Write-Host '== case is not the point =='
# The parser lowercases every title, so the lookup has to be case-insensitive or
# it would silently never fire on the one thing it exists for.
Check 'an upper-case alias still folds'          ((Resolve-ShowAlias -Title 'EUPHORIA US' -Aliases $one) -eq 'euphoria')
Check 'an upper-case key still folds'            ((Resolve-ShowAlias -Title 'euphoria us' -Aliases ([pscustomobject]@{ 'EUPHORIA US' = 'euphoria' })) -eq 'euphoria')
Check 'a mixed-case key still folds'             ((Resolve-ShowAlias -Title 'euphoria us' -Aliases ([pscustomobject]@{ 'Euphoria Us' = 'euphoria' })) -eq 'euphoria')

Write-Host ''
Write-Host '== it works as a hashtable too =='
# ConvertFrom-Json gives a PSCustomObject, but a hand-edited config or a test may
# well be a hashtable, and only one of the two is a PSCustomObject.
$ht = @{ 'euphoria us' = 'euphoria' }
Check 'a hashtable alias list is read'           ((Resolve-ShowAlias -Title 'euphoria us' -Aliases $ht) -eq 'euphoria')

Write-Host ''
Write-Host '== chains resolve, and a cycle cannot hang the run =='
$chain = [pscustomobject]@{ 'a' = 'b'; 'b' = 'c'; 'c' = 'euphoria' }
Check 'a three-hop chain lands on the end'       ((Resolve-ShowAlias -Title 'a' -Aliases $chain) -eq 'euphoria')
Check 'the middle of the chain resolves too'     ((Resolve-ShowAlias -Title 'b' -Aliases $chain) -eq 'euphoria')
$cycle = [pscustomobject]@{ 'x' = 'y'; 'y' = 'x' }
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$cyc = Resolve-ShowAlias -Title 'x' -Aliases $cycle
$stopwatch.Stop()
Check 'a two-node cycle terminates'              ($cyc -eq 'y' -or $cyc -eq 'x')
Check 'and terminates quickly'                   ($stopwatch.ElapsedMilliseconds -lt 2000)
$selfLoop = [pscustomobject]@{ 'z' = 'z' }
Check 'a self-referential alias terminates'      ((Resolve-ShowAlias -Title 'z' -Aliases $selfLoop) -eq 'z')

Write-Host ''
Write-Host '== rubbish in the list cannot become a path =='
# Every one of these would produce a folder name if it were believed, and a folder
# named after nothing is how a library grows folders nobody can explain.
Check 'an empty alias value is ignored'          ((Resolve-ShowAlias -Title 'a' -Aliases ([pscustomobject]@{ 'a' = '' })) -eq 'a')
Check 'a null alias value is ignored'            ((Resolve-ShowAlias -Title 'a' -Aliases ([pscustomobject]@{ 'a' = $null })) -eq 'a')
# An empty KEY is asserted in the source rather than by calling it, because
# Windows PowerShell cannot produce one by any route: [pscustomobject]@{ '' = 'x' }
# is a parse error, Add-Member rejects the name, and ConvertFrom-Json rejects the
# JSON too. The guard is therefore unreachable from a config file on this runtime -
# it is there for a future one, and this is how it is pinned.
$aliasBody = Get-Slice -Text $src -From 'function Resolve-ShowAlias' -To 'function Resolve-LibraryShowDir'
Check 'an empty key is skipped in the source'   ($aliasBody -cmatch '\$p\[0\]\)?\.?IsNullOrWhiteSpace|if \(\[string\]::IsNullOrWhiteSpace\(\$p\[0\]\)\) \{ continue \}')
Check 'and so is an empty value'                ($aliasBody -cmatch 'if \(\[string\]::IsNullOrWhiteSpace\(\$p\[1\]\)\) \{ continue \}')
Check 'an empty title stays empty'               ((Resolve-ShowAlias -Title '' -Aliases $one) -eq '')
Check 'a null title stays null-ish, not a path'  ($null -eq (Resolve-ShowAlias -Title $null -Aliases $one) -or (Resolve-ShowAlias -Title $null -Aliases $one) -eq '')

Write-Host ''
Write-Host '== the two spellings resolve to ONE folder =='
# This is the whole point. A tree under the temp dir, so nothing here can touch
# the real library.
$tree = Join-Path ([System.IO.Path]::GetTempPath()) ('qbtselias-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $tree -Force | Out-Null
try {
    # The shape that caused the loss: two folders, one show.
    $a = New-Item -ItemType Directory -Path (Join-Path $tree 'Euphoria') -Force
    $b = New-Item -ItemType Directory -Path (Join-Path $tree 'Euphoria Us') -Force
    Check 'two folders exist to begin with'      ((Test-Path -LiteralPath $a.FullName) -and (Test-Path -LiteralPath $b.FullName))

    # Both spellings must land in the SAME place, or rule 4b cannot see across.
    $ra = Resolve-LibraryShowDir -SeriesDir $tree -Title 'euphoria' -Aliases $one
    $rb = Resolve-LibraryShowDir -SeriesDir $tree -Title 'euphoria us' -Aliases $one
    Check 'both spellings agree'                 ($ra -eq $rb)
    Check 'and it is the folder already on disk' ($ra -eq $a.FullName)

    # The second folder must not be chosen: the alias is what stops the split.
    Check 'the alias spelling does not pick the split folder' ($rb -ne $b.FullName)

    Write-Host ''
    Write-Host '== an existing folder still wins, so an alias cannot orphan files =='
    # Someone adds an alias for a show whose folder is already on disk under the
    # un-aliased name. Computing a fresh name would create a second folder and
    # leave the first one holding every file.
    $tree2 = Join-Path ([System.IO.Path]::GetTempPath()) ('qbtselias-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Path (Join-Path $tree2 'Some Show Us') -Force | Out-Null
    try {
        $r = Resolve-LibraryShowDir -SeriesDir $tree2 -Title 'some show us' -Aliases $one
        Check 'the pre-existing folder is reused'  ($r -eq (Join-Path $tree2 'Some Show Us'))
        Check 'and no second folder was created'   (@(Get-ChildItem -LiteralPath $tree2 -Directory).Count -eq 1)
    }
    finally { Remove-Item -LiteralPath $tree2 -Recurse -Force -ErrorAction SilentlyContinue }

    Write-Host ''
    Write-Host '== a show with no alias is completely unaffected =='
    $r = Resolve-LibraryShowDir -SeriesDir $tree -Title 'ted lasso' -Aliases $one
    Check 'it resolves to its own name'          ((Split-Path -Leaf $r) -eq 'Ted Lasso')
    Check 'and no folder was created for it yet' (-not (Test-Path -LiteralPath $r))
}
finally { Remove-Item -LiteralPath $tree -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host '== the missing-series-dir guard still holds =='
Check 'no series dir yields nothing'            ($null -eq (Resolve-LibraryShowDir -SeriesDir (Join-Path $tree 'nope') -Title 'euphoria' -Aliases $one))
Check 'a missing dir is not created'             (-not (Test-Path -LiteralPath (Join-Path $tree 'nope')))
Check 'no title yields nothing'                 ($null -eq (Resolve-LibraryShowDir -SeriesDir $tree -Title '' -Aliases $one))

Write-Host ''
Write-Host '== the alias reaches Get-LibraryTargetDir =='
# If the plumbing stopped here, the folder would be right in a test and wrong in a
# run. Asserted at the call site rather than by behaviour, because the behaviour
# needs a torrent object this suite does not build.
# Matched on $cfg.moviesDir, not on 'Get-LibraryTargetDir -T $t' alone. The settle
# rule added a second call site earlier in the file, and a first-match check simply
# took whichever came first - so it passed or failed on the wrong call, and the one
# it meant to guard went unchecked. A check that identifies its subject by position
# rather than by identity is a check that will eventually be about something else.
$moveLine = ($src -split "`n" | Where-Object { $_ -match 'Get-LibraryTargetDir -T \$t -MoviesDir \$cfg\.moviesDir' } | Select-Object -First 1)
Check 'the move passes the alias list'          ($moveLine -match '-Aliases \$cfg\.titleAliases')
# And the settle rule resolves its destination the same way, or a show the parser
# spells two ways would be cut into a folder of its own.
$settleLine = ($src -split "`n" | Where-Object { $_ -match 'Get-LibraryTargetDir -T \$t -MoviesDir \$MoviesDir' } | Select-Object -First 1)
Check 'and so does the settle rule'             (($null -ne $settleLine) -and ($settleLine -match '-Aliases \$Aliases'))
$defLine = ($src -split "`n" | Where-Object { $_ -match 'Resolve-LibraryShowDir -SeriesDir \$SeriesDir -Title \$T\.parts\.Title' } | Select-Object -First 1)
Check 'the target dir forwards it'              ($defLine -match '-Aliases \$Aliases')

Write-Host ''
Write-Host '== nothing folds by resemblance =='
# The property that must not erode. Two titles sharing a first word is how dedup
# groups a show; it is NOT evidence they are one show, and 'the office' / 'the
# bear' is the standing example of why. An alias is a statement by a person, and
# only a statement counts.
$noAuto = [pscustomobject]@{}
Check "'the office' is not folded into anything" ((Resolve-ShowAlias -Title 'the office' -Aliases $noAuto) -eq 'the office')
Check "'the bear' is not folded either"          ((Resolve-ShowAlias -Title 'the bear' -Aliases $noAuto) -eq 'the bear')
Check 'and an unlisted alias candidate too'      ((Resolve-ShowAlias -Title 'euphoria us' -Aliases $noAuto) -eq 'euphoria us')
# Translated titles stay apart on their own, which is the cost being accepted
# rather than paid for by guessing.
Check "'widows bay' is left alone"               ((Resolve-ShowAlias -Title 'widows bay' -Aliases $noAuto) -eq 'widows bay')
Check "'o segredo de widows bay' too"            ((Resolve-ShowAlias -Title 'o segredo de widows bay' -Aliases $noAuto) -eq 'o segredo de widows bay')

Write-Host ''
Write-Host '== and the test tree is gone =='
Check 'no alias tree left behind'                (@(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'qbtselias-*' -ErrorAction SilentlyContinue).Count -eq 0)

Write-Host ''
Write-Host ''
Write-Host '== an alias is about IDENTITY, not just folder naming =='
# 'Euforie - Euphoria S03E01 (2026)[1080p][CZ,SK,EN Dabing]' parses as
# 'euforie euphoria'. The Czech title of Euphoria in front of the English one, and
# a show family is the FIRST WORD of the parsed title - so it came out as the show
# 'euforie', in a group of its own, next to a season it belonged to.
#
# Resolve-ShowAlias was called from exactly one place, Resolve-LibraryShowDir. So
# an alias filed the show under the right name and still left every rule that
# GROUPS releases reading the raw spelling: dedup compared the wrong sets, and the
# two library rules looked for a folder nobody had.
#
# Resolve-PartsAlias applies the alias where identity is established, so the
# grouping key and the folder name are derived from the same title.

function Parts {
    param([string]$Title, [string[]]$Tokens, [int]$Season = 3, [int]$Episode = 1, [string]$Year = '')
    return [pscustomobject]@{
        IsSeries = $true
        Season   = $Season
        Episode  = $Episode
        EpisodeLast    = $Episode
        IsMultiEpisode = $false
        Year     = $Year
        Title    = $Title
        Tokens   = $Tokens
        Numbers  = @()
    }
}

$euforie = { param([object]$a) Parts 'euforie euphoria' @('euforie', 'euphoria') }

$r = Resolve-PartsAlias -Parts (& $euforie $null) -Aliases @{ 'euforie euphoria' = 'euphoria' }
Check 'the aliased title is the canonical one'      ($r.Title -eq 'euphoria')
# This is the part that decides anything. The family is the first word of the run
# of leading TOKENS, so rewriting Title alone would leave the group key reading
# 'euforie' and change nothing at all.
Check 'and the TOKENS are rebuilt, not just the title' (((@($r.Tokens)) -join ' ') -eq 'euphoria')
Check 'so the family becomes euphoria'              (@($r.Tokens)[0] -eq 'euphoria')

$untouched = Resolve-PartsAlias -Parts (& $euforie $null) -Aliases @{ 'euphoria us' = 'euphoria' }
Check 'an unlisted title is untouched'              ($untouched.Title -eq 'euforie euphoria')
Check 'with its tokens intact'                      ((@($untouched.Tokens) -join ' ') -eq 'euforie euphoria')
Check 'no alias table folds nothing'                ((Resolve-PartsAlias -Parts (& $euforie $null) -Aliases $null).Title -eq 'euforie euphoria')
Check 'a null parts object is passed through'       ($null -eq (Resolve-PartsAlias -Parts $null -Aliases @{ 'x' = 'y' }))

# Resemblance is not evidence. 'euforia', 'euforie' and 'euphoria' are one show to
# a person and three strings to a parser - but only the alias the user wrote is
# applied. Nothing here works out which words are foreign names of one another.
Check 'a sibling spelling with no alias stays put' `
    ((Resolve-PartsAlias -Parts (Parts 'euforia euphoria' @('euforia', 'euphoria')) -Aliases @{ 'euforie euphoria' = 'euphoria' }).Title -eq 'euforia euphoria')

# Chains are followed, so an alias may name a title that is itself aliased.
$chain = Resolve-PartsAlias -Parts (Parts 'show b' @('show', 'b')) -Aliases @{ 'show b' = 'show a'; 'show a' = 'show c' }
Check 'a chain of aliases lands on the last one'   ($chain.Title -eq 'show c')
Check 'and its tokens follow'                       ((@($chain.Tokens) -join ' ') -eq 'show c')

# An alias to something that yields no usable token would leave the release with
# NO grouping key at all, and a group with no key is skipped by every rule - so
# honouring it would silence dedup for every OTHER release of the same show.
# Refused instead. 'season' is on the ignorable list, so it tokenises to nothing.
$bad = Resolve-PartsAlias -Parts (Parts 'the show' @('the', 'show')) -Aliases @{ 'the show' = 'season' }
Check 'an alias with no usable tokens is refused'   ($bad.Title -eq 'the show')
Check 'and its tokens are left alone too'          (((@($bad.Tokens)) -join ' ') -eq 'the show')

# A bare number is NOT untokenisable, and must not be treated as one: '1917' and
# '2001' are real titles, which is why Get-TitleParts carries a numericTitle case
# at all. An alias pointing at a number is honoured.
$num = Resolve-PartsAlias -Parts (Parts 'the show' @('the', 'show')) -Aliases @{ 'the show' = '2001' }
Check 'an alias to a numeric title IS honoured'     ($num.Title -eq '2001')

# The season, episode and year must survive: the alias is about which show, never
# about which episode.
$kept = Resolve-PartsAlias -Parts (Parts 'euforie euphoria' @('euforie', 'euphoria') 3 7 '2026') -Aliases @{ 'euforie euphoria' = 'euphoria' }
Check 'season and episode are untouched by an alias' (($kept.Season -eq 3) -and ($kept.Episode -eq 7))
Check 'and so is the year'                          ($kept.Year -eq '2026')

Write-Host ''
Write-Host '== both files must resolve identity, or the preview lies =='
# Same drift shape as the two already found this session: a rule that exists in two
# places, one fixed and one not. The preview showing a release as its own show while
# the run files it under Euphoria is exactly the failure to avoid.
$mgrSrc = [System.IO.File]::ReadAllText((Join-Path $projectRoot 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)
$preSrc = [System.IO.File]::ReadAllText((Join-Path $projectRoot 'status.ps1'), [System.Text.Encoding]::UTF8)
Check 'the manager resolves the alias where parts are attached' `
    ($mgrSrc -cmatch '(?s)Get-TitleParts -Name \$t\.name.{0,900}?Resolve-PartsAlias -Parts \$parts')
Check 'the preview does the same' `
    ($preSrc -cmatch '(?s)Get-TitleParts -Name \(Get-Prop \$t ''name''\).{0,900}?Resolve-PartsAlias -Parts \$parts')
# Resolve-ShowAlias had a single call site, inside folder naming, and that is why
# an alias could not reach the rules that group releases. There are three now: two
# that resolve a title string, and one that resolves a parsed release - and the
# third is the one that makes grouping agree with filing.
$showCalls  = ([regex]::Matches($mgrSrc, 'Resolve-ShowAlias -Title')).Count
$partsCalls = ([regex]::Matches($mgrSrc, 'Resolve-PartsAlias -Parts')).Count
Check 'Resolve-PartsAlias exists and is reachable'  ($mgrSrc -cmatch '(?m)^function Resolve-PartsAlias')
Check 'and folder naming is no longer the only caller' (($showCalls -ge 2) -and ($partsCalls -ge 1))
if ($fail -eq 0) {
    Write-Host ("all show-alias tests passed (" + $pass + " checks)") -ForegroundColor Green
    exit 0
} else {
    Write-Host ("$fail of " + ($pass + $fail) + " show-alias checks FAILED") -ForegroundColor Red
    exit 1
}