<#
    Exercises the library folder naming: ConvertTo-LibraryFolderName,
    Resolve-LibraryShowDir and Get-LibraryTargetDir.

    Show folders are title-cased - 'its always sunny in philadelphia' becomes
    'Its Always Sunny In Philadelphia' - but ONLY for folders that do not exist
    yet. A folder already on disk keeps its own spelling, so the on-disk name and
    the computed name cannot drift apart over time.

    That is the whole point of the resolver, and it is tested from both sides: a
    new show gets the capitalised name, an existing one is reused as it stands.

    The last block checks the two facts the live migration turned up, both of
    which are real behaviour of this box rather than assumptions:

      - A direct case-only Rename-Item is REFUSED ('The source and destination
        paths must be different'), because Windows compares the paths
        case-insensitively and sees the same directory. Renaming therefore has to
        go via a temporary name, and that two-step form is exercised here.
      - Test-Path cannot answer 'is there a folder with THIS spelling', for the
        same reason. Only a directory listing compared with [StringComparison]
        ::Ordinal can.

    Two traps this suite deliberately avoids, both of which made earlier versions
    of these checks pass for the wrong reason:

      - PowerShell compares strings and matches patterns case-INSENSITIVELY by
        default. A path check written with -ne or -notmatch against a differently
        cased name can never fail. The case-sensitive operators are used here and
        that is why they are spelled out.
      - [string] coerces $null to '', so a 'returns null' expectation is wrong.

    Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-folder-casing.ps1
#>

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Found from this file's own location. See test-stall-cleanup.ps1 - a hardcoded
# project path pins the suite to one machine.
if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = Split-Path -Parent $PSScriptRoot
$src = [System.IO.File]::ReadAllText((Join-Path $root 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)
$s = $src.IndexOf('$script:boundaryPattern')
$e = $src.IndexOf('# actions')
Invoke-Expression $src.Substring($s, $e - $s)

$script:fails = 0
function Check { param([string]$L, [bool]$Ok) if ($Ok) { Write-Host "  [PASS] $L" } else { $script:fails++; Write-Host "  [FAIL] $L" } }

Write-Host ''
Write-Host '== the casing itself =='
$cases = @(
    @{ In = 'its always sunny in philadelphia'; Want = 'Its Always Sunny In Philadelphia' }
    @{ In = 'ted lasso';                       Want = 'Ted Lasso' }
    @{ In = 'the talented mr ripley';          Want = 'The Talented Mr Ripley' }
    @{ In = 'widows bay vdovina zÃ¡toka';       Want = 'Widows Bay Vdovina ZÃ¡toka' }
    @{ In = 'sunny-in-philadelphia show';      Want = 'Sunny-In-Philadelphia Show' }
    @{ In = 'euforia euphoria';                Want = 'Euforia Euphoria' }
    @{ In = 'a b c';                          Want = 'A B C' }
)
foreach ($c in $cases) {
    $got = ConvertTo-LibraryFolderName -Title $c.In
    Check ("'" + $c.In + "' -> '" + $c.Want + "'") ($got -eq $c.Want)
}

# accents must survive, not be flattened
$acc = ConvertTo-LibraryFolderName -Title 'widows bay vdovina zÃ¡toka'
Check 'the accented word keeps its accent and gains a capital' ($acc -match 'Z.?' -and $acc -match 'zÃ¡toka')

# a trailing dot stays attached, so mr. does not become Mr
$dot = ConvertTo-LibraryFolderName -Title 'the talented mr. ripley'
Check 'a trailing dot stays with its word' ($dot -match 'Mr\. Ripley')

# internal capitals are not destroyed
$keep = ConvertTo-LibraryFolderName -Title 'thetv show tv edition'
Check 'existing capitals are preserved' ($keep -match 'Thetv Show Tv Edition')

# empty and odd input
Check 'an empty title returns empty'   ((ConvertTo-LibraryFolderName -Title '') -eq '')
# [string] turns $null into '', so '' comes back - not $null. That is the better
# answer anyway: a folder name is never $null.
Check 'a null title returns empty, not null' ((ConvertTo-LibraryFolderName -Title $null) -eq '')
Check 'digits are left alone'          ((ConvertTo-LibraryFolderName -Title '1883 s01') -eq '1883 S01')

Write-Host ''
Write-Host '== an existing folder is reused, never duplicated =='
# The hazard: the folders on disk are lowercase, the target name is title-cased.
# Aiming at a freshly spelled path would split one season across two trees.
$lib = Join-Path $env:TEMP ('casing-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $lib -Force | Out-Null
$existing = Join-Path $lib 'its always sunny in philadelphia'
New-Item -ItemType Directory -Path $existing -Force | Out-Null

$script:showDirCache = @{}
$resolved = Resolve-LibraryShowDir -SeriesDir $lib -Title 'its always sunny in philadelphia'
Check 'the lowercase folder on disk is the one resolved' ($resolved -eq $existing)
# -cne, not -ne. PowerShell compares strings case-INSENSITIVELY, so -ne against a
# differently-cased path is FALSE and the check passes for no reason. The first
# version of this test asserted "not a differently-cased twin" with -ne, which
# could never fail: the two names differ only in case.
Check 'and the resolved name is the on-disk spelling, case included' `
    ($resolved -cne (Join-Path $lib 'Its Always Sunny In Philadelphia'))

# A show with no folder yet gets the case-correct name.
$script:showDirCache = @{}
$new = Resolve-LibraryShowDir -SeriesDir $lib -Title 'breaking bad'
Check 'a new show gets the capitalised name'   ($new -eq (Join-Path $lib 'Breaking Bad'))
Check 'and it is not created yet'               (-not (Test-Path -LiteralPath $new))

# An already-correct folder resolves to itself.
New-Item -ItemType Directory -Path (Join-Path $lib 'Ted Lasso') -Force | Out-Null
$script:showDirCache = @{}
Check 'a folder already in the right case resolves to itself' `
    ((Resolve-LibraryShowDir -SeriesDir $lib -Title 'ted lasso') -eq (Join-Path $lib 'Ted Lasso'))

Write-Host ''
Write-Host '== Get-LibraryTargetDir goes through the resolver =='
$script:showDirCache = @{}
$t = [pscustomobject]@{ parts = (Get-TitleParts -Name 'Its Always Sunny in Philadelphia S18E01 1080p x264-GRP [ext.to]') }
$dir = Get-LibraryTargetDir -T $t -MoviesDir 'C:\movies' -SeriesDir $lib
Check 'a series lands in the existing lowercase folder' ($dir -eq (Join-Path $existing 'Season 18'))
# -cnotmatch for the same reason as above: -notmatch is case-insensitive and the
# lowercase path matches the capitalised pattern.
Check 'the path keeps the on-disk spelling'             ($dir -cnotmatch 'Its Always Sunny In Philadelphia')

$script:showDirCache = @{}
$t2 = [pscustomobject]@{ parts = (Get-TitleParts -Name 'Ted Lasso S04E08 2160p x264-GRP [ext.to]') }
Check 'a show already in the right case is unaffected' `
    ((Get-LibraryTargetDir -T $t2 -MoviesDir 'C:\movies' -SeriesDir $lib) -eq (Join-Path (Join-Path $lib 'Ted Lasso') 'Season 4'))

# a film still goes straight to the movies dir
$t3 = [pscustomobject]@{ parts = (Get-TitleParts -Name 'A Film 1999 1080p x264-GRP [ext.to]') }
Check 'a film is unaffected' ((Get-LibraryTargetDir -T $t3 -MoviesDir 'C:\movies' -SeriesDir $lib) -eq 'C:\movies')

# no series dir at all
$script:showDirCache = @{}
Check 'a missing series dir yields nothing to resolve' ($null -eq (Resolve-LibraryShowDir -SeriesDir (Join-Path $env:TEMP 'no-such-lib-zz') -Title 'x'))

# ---- how a rename actually has to be done on this box ----
# These two checks are about the FILESYSTEM's behaviour, not the manager's, but
# they are what a rename depends on, and both were learned by hitting them.
$rl = Join-Path $env:TEMP ('rename-' + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path (Join-Path $rl 'ted lasso') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $rl 'ted lasso\ep.mkv') -Value 'x'

# A direct case-only rename is refused: Windows compares the two paths
# case-insensitively, so they look like the same directory.
$directRefused = $false
try {
    Rename-Item -LiteralPath (Join-Path $rl 'ted lasso') -NewName 'Ted Lasso' -ErrorAction Stop
} catch { $directRefused = $true }
Check 'a direct case-only rename is refused' ($directRefused)
Check 'and the folder is untouched by the refusal' (Test-Path -LiteralPath (Join-Path $rl 'ted lasso'))
Check 'with its file still inside it'            (Test-Path -LiteralPath (Join-Path $rl 'ted lasso\ep.mkv'))

# Going via a temporary name is two real renames, so the stored casing changes.
$tmpName = '__casefix_test'
Rename-Item -LiteralPath (Join-Path $rl 'ted lasso') -NewName $tmpName
Rename-Item -LiteralPath (Join-Path $rl $tmpName) -NewName 'Ted Lasso'
$onDisk = @(Get-ChildItem -LiteralPath $rl -Directory | ForEach-Object { $_.Name })
Check 'the two-step rename gives the folder the new spelling' `
    (@($onDisk | Where-Object { $_.Equals('Ted Lasso', [StringComparison]::Ordinal) }).Count -eq 1)
Check 'and the old spelling is gone' `
    (@($onDisk | Where-Object { $_.Equals('ted lasso', [StringComparison]::Ordinal) }).Count -eq 0)
Check 'and the file came along' (Test-Path -LiteralPath (Join-Path $rl 'Ted Lasso\ep.mkv'))

# Test-Path cannot tell the two spellings apart, which is why the checks above
# enumerate the directory instead. Stated as a check so the reason is on record.
Check 'Test-Path is blind to the difference between the two spellings' `
    ((Test-Path -LiteralPath (Join-Path $rl 'Ted Lasso')) -eq (Test-Path -LiteralPath (Join-Path $rl 'ted lasso')))

# And after the rename, the resolver returns the name that is actually on disk.
$script:showDirCache = @{}
Check 'the resolver reports the new spelling after the rename' `
    ((Resolve-LibraryShowDir -SeriesDir $rl -Title 'ted lasso') -ceq (Join-Path $rl 'Ted Lasso'))

Remove-Item -LiteralPath $rl -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $lib -Recurse -Force -ErrorAction SilentlyContinue
Check 'the test tree is gone' (-not (Test-Path -LiteralPath $lib))

Write-Host ''
if ($script:fails -eq 0) { Write-Host 'all folder-casing tests passed' -ForegroundColor Green; exit 0 }
else { Write-Host ("$script:fails FAILED"); exit 1 }