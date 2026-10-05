# Exercises the dedup rule: in a cluster, the largest version that is 100%
# downloaded is kept, and everything smaller is deleted whether or not it is
# itself finished. Bigger unfinished versions survive.
#
# This rule was rewritten. It used to be "delete an incomplete version only if
# it was within duplicateTolerancePct of a finished one", which meant an
# incomplete copy 50% smaller than a finished one survived - the exact case this
# rule now exists to handle. These tests pin the new behaviour, and pin the two
# boundaries that must NOT move with it.
#
# The rule itself lives inline in the main flow of qbt-manager.ps1 rather than in
# a function, so it cannot be lifted out by slicing the way the detection
# functions can. Get-DedupVerdicts in status.ps1 is the same rule in function
# form; it is sliced here and driven directly, which also keeps the preview from
# drifting away from the manager.
#
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\test-dedup.ps1

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

# The real config, so a test can never pass against a tolerance the live
# manager is not using.
$cfg = [System.IO.File]::ReadAllText((Get-ProjectFile 'config.json'), [System.Text.Encoding]::UTF8) | ConvertFrom-Json

$src = [System.IO.File]::ReadAllText((Get-ProjectFile 'status.ps1'), [System.Text.Encoding]::UTF8)
$GB = 1GB

function Get-Slice {
    param([string]$Text, [string]$From, [string]$To)
    $s = $Text.IndexOf($From)
    $e = $Text.IndexOf($To)
    if ($s -lt 0 -or $e -le $s) { throw "could not locate the block between '$From' and '$To'" }
    return $Text.Substring($s, $e - $s)
}

# One slice from Get-Prop to Get-MetadataWatch: that range holds Get-Prop,
# Get-ClusterLabel and Get-DedupVerdicts, plus the helpers they call. Slicing to
# the next function name rather than to a brace count avoids tripping over
# braces inside strings.
# Whether a torrent is a multi-episode pack is decided by Get-TitleParts, so the
# parser is sliced from the manager as well and driven with real release names.
# A hand-built flag here would test nothing at all.
$msrc = [System.IO.File]::ReadAllText((Get-ProjectFile 'qbt-manager.ps1'), [System.Text.Encoding]::UTF8)
Invoke-Expression (Get-Slice -Text $msrc -From '$script:boundaryPattern' -To 'function Get-DoviHit')

# A pack, carrying the parts the real parser produced for its release name.
function P {
    param([string]$Hash, [string]$Name, [double]$SizeGb, [double]$Progress)
    $size = [int64]($SizeGb * $GB)
    return [pscustomobject]@{
        hash       = $Hash
        name       = $Name
        size       = $size
        downloaded = [int64]($size * $Progress)
        progress   = $Progress
        parts      = (Get-TitleParts -Name $Name)
    }
}

# Get-PackEpisodeBytes reads the pack's own file list, so it is the piece that
# makes the pack-vs-single comparison a measurement instead of an average. It
# lives in the manager, and the preview calls it too, so both sides use the one
# implementation.
Invoke-Expression (Get-Slice -Text $msrc -From 'function Get-PackEpisodeBytes' -To '# Where a completed torrent belongs')

# The one thing that cannot be sliced is the API call itself. Stubbed here so the
# tests can state each pack's real per-episode sizes - which is the whole point
# of the rule: episodes inside one pack are NOT equal, so the file list has to
# be supplied rather than derived.
$script:fileLists = @{}
function Invoke-ApiGet {
    param([string]$Endpoint)
    if ($Endpoint -match '^torrents/files\?hash=(.+)$') {
        $h = $Matches[1].ToLowerInvariant()
        if ($script:fileLists.ContainsKey($h)) { return $script:fileLists[$h] }
        return @()
    }
    throw "unexpected endpoint in the dedup tests: $Endpoint"
}
function Set-PackFiles {
    param([string]$Hash, [object[]]$Entries)
    $script:fileLists[$Hash.ToLowerInvariant()] = $Entries
}
function File {
    param([string]$Name, [double]$SizeGb)
    return [pscustomobject]@{ name = $Name; size = [int64]($SizeGb * $GB) }
}

Invoke-Expression (Get-Slice -Text $src -From 'function Get-Prop' -To 'function Get-MetadataWatch')

# If the verdict function did not come along, every check below would pass for
# the wrong reason - an empty verdict set looks exactly like "nothing deleted".
if (-not (Get-Command Get-DedupVerdicts -ErrorAction SilentlyContinue)) {
    throw 'Get-DedupVerdicts was not found in status.ps1 - the dedup tests cannot run'
}
if (-not (Get-Command Get-PackEpisodeBytes -ErrorAction SilentlyContinue)) {
    throw 'Get-PackEpisodeBytes was not found in qbt-manager.ps1 - the dedup tests cannot run'
}

$script:fails = 0
function Check {
    param([string]$label, [bool]$ok)
    if ($ok) { "  [PASS] $label" } else { $script:fails++; "  [FAIL] $label" }
}

# 'Got' is the bytes fetched so far. It is recorded on the object purely so the
# tests can prove the rule ignores it: the real objects carry it, and reading it
# by mistake would change verdicts in the cases below.
#
# The parsed title is attached the way a real cluster member has it attached. It
# is not decoration: the rule groups by episode set, which it reads off the
# parsed parts. A member built without them is not something the manager can
# produce - unidentified torrents never reach a cluster - so leaving them off
# here would test a shape that cannot occur.
function T {
    param([string]$Hash, [double]$SizeGb, [double]$Progress, [double]$GotGb = -1)
    $size = [int64]($SizeGb * 1GB)
    $got = if ($GotGb -ge 0) { [int64]($GotGb * 1GB) } else { [int64]($size * $Progress) }
    return [pscustomobject]@{
        hash       = $Hash
        name       = "release-$Hash"
        size       = $size
        downloaded = $got
        progress   = $Progress
        parts      = (Get-TitleParts -Name 'The Example 2019 1080p WEB-DL x264-GRP')
    }
}

# Verdict hashes for a cluster, as a plain sorted list for comparison.
function Verdicts {
    param([object[]]$Members)
    $gone = @{}
    $v = Get-DedupVerdicts -Clusters @(, @($Members)) -Gone $gone
    return @($v.Keys | Sort-Object)
}
function Reason {
    param([object[]]$Members, [string]$Hash)
    $gone = @{}
    $v = Get-DedupVerdicts -Clusters @(, @($Members)) -Gone $gone
    return $v[$Hash].Reason
}

"== the case the rule was rewritten for =="
$grp = @(
    T 'big2160done'  7.72 1.0     # finished 2160p
    T 'small1080a'   3.87 0.30    # incomplete 1080p, 50% smaller
    T 'small1080b'   3.87 0.00
    T 'small1080c'   3.87 0.03
    T 'big2160wip'   9.03 0.27    # incomplete 2160p, BIGGER than the keeper
)
$v = Verdicts $grp
Check 'a finished 2160p deletes every smaller incomplete copy'  (@($v).Count -eq 3)
Check 'the three 1080p copies are all deleted'  (@($v) -contains 'small1080a' -and @($v) -contains 'small1080b' -and @($v) -contains 'small1080c')
Check 'the finished keeper is kept'                             (-not (@($v) -contains 'big2160done'))
Check 'a BIGGER incomplete version survives'                    (-not (@($v) -contains 'big2160wip'))
Check 'the reason says it was incomplete, not a size difference' `
    ((Reason $grp 'small1080a') -like 'incomplete, and a bigger version is already finished*')
Check 'the reason names the finished keeper'                    ((Reason $grp 'small1080a') -like '*release-big2160done*')
Check 'the reason reports both sizes'                           ((Reason $grp 'small1080a') -match '7,72 GB against 3,87 GB')

"== the size gap no longer matters =="
foreach ($gap in 0.001, 0.05, 0.5, 0.95) {
    $small = [math]::Round(10 * (1 - $gap), 2)
    $pair = @((T 'done' 10 1.0), (T 'wip' $small 0.5))
    Check ("a copy {0:P0} smaller is deleted just the same" -f $gap) `
        ((Verdicts $pair) -contains 'wip')
}

"== two finished copies: the smaller one still goes =="
$two = @((T 'big' 7.72 1.0), (T 'small' 3.87 1.0))
Check 'a smaller finished copy is deleted'   ((Verdicts $two) -contains 'small')
Check 'the larger finished copy is kept'     (-not ((Verdicts $two) -contains 'big'))
Check 'the reason says smaller completed version' ((Reason $two 'small') -like 'smaller completed version*')

"== equal sizes are not 'smaller' =="
$equal = @((T 'a' 5.0 1.0), (T 'b' 5.0 0.4))
Check 'an identical-size copy is NOT deleted' (@(Verdicts $equal).Count -eq 0)

"== nothing happens without a finished version =="
$noneFinished = @((T 'a' 9.03 0.27), (T 'b' 7.72 0.10), (T 'c' 3.87 0.30))
Check 'no finished version means no deletions at all' (@(Verdicts $noneFinished).Count -eq 0)

"== the keeper must survive the run's earlier rules =="
# A finished copy already marked gone by, say, the DoVi rule must not be allowed
# to keep protecting the group.
$goneKeeper = @{}
$goneKeeper['big'] = $true
$v2 = Get-DedupVerdicts -Clusters @(, @((T 'big' 7.72 1.0), (T 'small' 3.87 0.2))) -Gone $goneKeeper
Check 'a keeper already removed cannot protect the group' (@($v2.Keys).Count -eq 0)

"== single-version clusters are left alone =="
Check 'one version on its own is never deleted' (@(Verdicts @((T 'only' 4.0 0.5))).Count -eq 0)

"== the comparison is on TOTAL size, never on bytes fetched =="
# The real Ripley pair: a 38.40 GB REMUX holding 4.30 GB (11.2%) against a
# finished 17.06 GB encode. Judged on downloaded bytes the REMUX is the smaller
# number and would be deleted. Judged on total size - which is what the rule
# must use, and what happened live - it is the bigger one and survives.
$remux  = T 'remux'  38.40 0.112 4.30
$encode = T 'encode' 17.06 1.0   17.06
$v = Verdicts @($remux, $encode)
Check 'an unfinished bigger-total release survives a finished smaller-total one' (@($v).Count -eq 0)
Check 'it really has fewer bytes than the keeper, so that is not a no-op' `
    ($remux.downloaded -lt $encode.size)

# The mirror image: 3.42 GB total with nothing downloaded yet still goes. The
# rule is not "whichever has fetched the least wins".
$tiny = T 'tiny' 3.42 0.0 0.0
Check 'a barely-started smaller-total release is still deleted' `
    ((Verdicts @($tiny, $encode)) -contains 'tiny')

# Totals and fetched bytes ordered in opposite directions inside one cluster, so
# the two possible readings disagree and the verdict identifies which is used.
$finishedBig       = T 'fb' 20.0 1.0 20.0
$unfinishedBigger  = T 'ub' 30.0 0.5  1.0
$finishedSmall     = T 'fs' 10.0 1.0 10.0
$unfinishedSmall   = T 'us'  5.0 0.2  0.1
$v = Verdicts @($finishedBig, $unfinishedBigger, $finishedSmall, $unfinishedSmall)
Check 'the keeper is the largest by TOTAL size'      (-not (@($v) -contains 'fb'))
Check 'a smaller finished release goes'             (@($v) -contains 'fs')
Check 'a bigger unfinished release stays'           (@($v) -notcontains 'ub')
Check 'a smaller unfinished release goes'           (@($v) -contains 'us')

"== a total of 0 means unknown, not smallest =="
$v = Verdicts @((T 'magnet' 0 0 0), (T 'done' 5.0 1.0))
Check 'a magnet with no known total is NOT deleted as a duplicate' (@($v).Count -eq 0)

# The magnet must be skipped while a genuine smaller release in the same group
# is still removed - the guard is not a blanket exemption for the cluster.
$v = Verdicts @((T 'magnet2' 0 0 0), (T 'done2' 5.0 1.0), (T 'small' 3.0 0.1))
Check 'a magnet is skipped while a real smaller release still goes' `
    ((@($v).Count -eq 1) -and (@($v) -contains 'small'))

"== the config knob really is gone =="
Check 'duplicateTolerancePct is no longer in config.json' (-not ($cfg.PSObject.Properties.Name -contains 'duplicateTolerancePct'))

''
"== a multi-episode pack is not a version of one episode =="
# A pack holds a RANGE of episodes, so it is not a rival version of any single
# episode: it is always the biggest thing in the room, and nothing it holds is
# covered by a finished episode 1. It is therefore neither the copy to keep nor
# the copy to drop. (Two packs of the SAME range are a different case - see
# below.)
$pack10  = P 'pack10'  'Widows.Bay.S01E01-10.1080p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]' 60.0 1.00
$pack06  = P 'pack06'  'Widows.Bay.S01E01-06.1080p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]' 40.0 0.40
$e1big   = P 'e1big'   'Widows.Bay.S01E01.2160p.ATVP.WEB-DL.DDP5.1.Atmos.H.265-NTb [ext.to]'           8.0 1.00
$e1small = P 'e1small' 'Widows.Bay.S01E01.1080p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]'           3.0 1.00
Check 'a finished pack is recognised from its release name' ($pack10.parts.IsMultiEpisode -and $pack10.parts.EpisodeLast -eq 10)
Check 'an unfinished pack is recognised too'                ($pack06.parts.IsMultiEpisode -and $pack06.parts.EpisodeLast -eq 6)
Check 'a single episode is not a pack'                      (-not $e1big.parts.IsMultiEpisode)

# The pack's OWN files, deliberately uneven. Dividing 60 GB by 10 gives 6 GB for
# every episode, but real packs are nothing like that: measured on this client,
# one S18 pack holds E01 at 1.74 GB, E03 at 1.81 GB and E04 at 1.48 GB. So E01 is
# given a SMALLER file than the 8 GB single, and E02 a LARGER one, and the two
# singles are compared against their own episodes respectively.
Set-PackFiles -Hash 'pack10' -Entries @(
    (File 'Widows Bay S01E01 1080p.mkv' 5.5),
    (File 'Widows Bay S01E02 1080p.mkv' 9.0),
    (File 'Widows Bay S01E03 1080p.mkv' 6.0)
)
$e2 = P 'e2big' 'Widows.Bay.S01E02.2160p.ATVP.WEB-DL.DDP5.1.Atmos.H.265-NTb [ext.to]' 3.0 1.00

Check 'a pack is weighed on the episode it shares, not its average' `
    ((Get-PackEpisodeBytes -Hash 'pack10' -Season 1 -Episode 1 -Cache @{}) -eq [int64](5.5 * $GB))
Check 'and each of its episodes measures differently' `
    ((Get-PackEpisodeBytes -Hash 'pack10' -Season 1 -Episode 2 -Cache @{}) -eq [int64](9.0 * $GB))

# E01's file in the pack is 5.5 GB and e1big is 8 GB of the same episode, so the
# single is the bigger copy of that one episode. The PACK IS STILL NOT DELETED.
#
# This used to assert the opposite, and the opposite was wrong. It cost real data
# on 2026-10-05: the scheduled run deleted Its.Always.Sunny.in.Philadelphia
# S18E01-E08 because a single's copy of S18E01 was 46 MB bigger than the pack's own
# S18E01 file. E02-E08 had no other copy anywhere, and removing the pack's entry
# left them on disk belonging to no torrent at all. A pack is the only record
# qBittorrent has of the episodes it holds, so a disagreement about one episode
# must never remove it.
$v = Verdicts @($pack10, $e1big)
Check 'a pack is NOT deleted by a bigger single of the same episode' (-not (@($v) -contains 'pack10'))
Check 'and the pass takes no action at all in that direction' (@($v).Count -eq 0)

# E02's file in the pack is 9 GB and e2big is 3 GB of that episode, so the
# single IS the spare copy and goes - the one case this pass may act on, because
# a single holds nothing but that episode, which the pack already carries.
$v = Verdicts @($pack10, $e2)
Check 'a single loses where the pack holds a bigger file for that episode' `
    ((@($v).Count -eq 1) -and (@($v) -contains 'e2big'))
Check 'the pack survives when it holds the bigger episode' (-not (@($v) -contains 'pack10'))

# The size difference that caused the loss is noise between two encodes. A pack
# must survive a margin of any size, up to being nearly twice the single's size.
Set-PackFiles -Hash 'pack10' -Entries @(
    (File 'Widows Bay S01E01 1080p.mkv' 5.5),
    (File 'Widows Bay S01E02 1080p.mkv' 9.0),
    (File 'Widows Bay S01E03 1080p.mkv' 6.0)
)
$v = Verdicts @($pack10, $e1big)
Check 'a 45% size margin on one episode still does not remove the pack' (-not (@($v) -contains 'pack10'))
Check 'and the reason for deleting a single says the pack holds more' `
    ((Reason @($pack10, $e2) 'e2big') -match 'cannot replace')

# An episode that cannot be measured must produce no deletion at all.
$v = Verdicts @($pack06, $e1big)
Check 'an unfinished pack is not deleted against a finished single episode' (@($v).Count -eq 0)

$pack2 = P 'pack2' 'Widows.Bay.S01E01-E02.2160p.ATVP.WEB-DL.DDP5.1.Atmos.H.265-NTb [ext.to]' 60.0 1.00
$singleInside = P 'sInside' 'Widows.Bay.S01E01.1080p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]' 8.0 1.00
$v = Verdicts @($pack2, $singleInside)
Check 'a pack with no readable file list is never weighed, so nothing is deleted' `
    (@($v).Count -eq 0)

Set-PackFiles -Hash 'pack2' -Entries @(
    (File 'Widows Bay S01E01 2160p.mkv' 12.0),
    (File 'Widows Bay S01E02 2160p.mkv' 12.0)
)
$v = Verdicts @($pack2, $singleInside)
Check 'once the file list is readable, the smaller single is deleted' `
    ((@($v).Count -eq 1) -and (@($v) -contains 'sInside'))
Check 'and the pack survives that comparison' (-not (@($v) -contains 'pack2'))

$v = Verdicts @($pack10, $pack06)
Check 'a finished pack and an unfinished pack are NOT deduplicated against each other' (@($v).Count -eq 0)

# A group is headed by the episode SET it holds, and the set is what the rows
# were weighed under, so the range has to survive into the header even though the
# label itself carries only the show name.
$packHeader = ('{0} {1}' -f (Get-ClusterLabel -Members @($pack10)),
                              (Get-EpisodeSetLabel -Key (Get-EpisodeSetKey -Parts $pack10.parts))).Trim()
Check 'the report shows the range, not just the first episode' ($packHeader -eq 'widows bay S1E1-E10')

# The rest of the set-key spellings, so a header can never over-claim either.
Check 'a single episode is headed by just that episode' `
    ((Get-EpisodeSetLabel -Key (Get-EpisodeSetKey -Parts $pack06.parts)) -eq 'S1E1-E6')
Check 'a whole-season pack is headed by the season and no episode' `
    ((Get-EpisodeSetLabel -Key 'S18-ALL') -eq 'S18')
Check 'a film is headed by nothing at all' ((Get-EpisodeSetLabel -Key 'film') -eq '')

# The exact pair the user was looking at: a finished 8-episode pack beside a
# finished single episode. Before the fix the pack was always larger, so it
# became the keeper and the single episode was deleted as the smaller version.
$sunnyPack = P 'spack' 'Its.Always.Sunny.in.Philadelphia.S18E01-E08.1080p.Ru.Ultradox [ext.to]' 31.0 1.0
$sunnyOne  = P 'sone'  'Its.Always.Sunny.in.Philadelphia.S18E01.1080p.NTb [ext.to]'           2.4 1.0
# The pack's E01 file is 3.2 GB, so the 2.4 GB single is the smaller copy and goes.
# Note the pack's total is 31 GB - irrelevant to a single episode.
Set-PackFiles -Hash 'spack' -Entries @(
    (File 'Its Always Sunny S18E01 1080p.mkv' 3.2),
    (File 'Its Always Sunny S18E02 1080p.mkv' 3.9)
)
$v = Verdicts @($sunnyPack, $sunnyOne)
Check 'the Sunny 8-episode pack deletes the smaller finished S18E01' `
    ((@($v).Count -eq 1) -and (@($v) -contains 'sone'))

"== two packs of the SAME range are true rivals =="
# Same range means same episodes, so one of them really is a spare copy of the
# other and the ordinary rule applies unchanged. This is the case where a pack
# IS worth deleting - and the reason it is safe is that the range matches
# exactly. A pack of a different range is left alone, because the smaller one
# still holds episodes the bigger one does not.
function PackOf { param([string]$Hash, [string]$Name, [double]$SizeGb, [double]$Progress) return (P $Hash $Name $SizeGb $Progress) }

# The same range, one finished and one not: the finished 1080p pack is the
# keeper and the unfinished smaller 720p pack goes.
$pA = PackOf 'pA' 'Widows.Bay.S01E01-10.1080p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]' 60.0 1.00
$pB = PackOf 'pB' 'Widows.Bay.S01E01-10.720p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]'  24.0 0.55
$v = Verdicts @($pA, $pB)
Check 'a finished pack of a range deletes a smaller unfinished pack of the SAME range' ((@($v).Count -eq 1) -and (@($v) -contains 'pB'))
Check 'the finished pack is the one kept' (-not (@($v) -contains 'pA'))
Check 'the reason calls it a bigger finished version' ((Reason @($pA,$pB) 'pB') -like 'incomplete, and a bigger version is already finished*')
Check 'and it names the episode set it was matched on' ((Reason @($pA,$pB) 'pB') -like '*(S1-E1-E10)*')

# The same range the other way round: the finished pack is the SMALLER one, so
# it goes and the unfinished bigger one survives. Size still decides.
$v = Verdicts @($pB, $pA)
Check 'a finished pack is deleted when a BIGGER pack of the same range is also finished' (@($v) -contains 'pB')

# Both finished, same range: the smaller is the redundant copy.
$pC = PackOf 'pC' 'Widows.Bay.S01E01-10.720p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]'  24.0 1.00
$v = Verdicts @($pA, $pC)
Check 'two finished packs of the same range: the smaller is deleted' ((@($v).Count -eq 1) -and (@($v) -contains 'pC'))
Check 'and the reason says smaller completed version' ((Reason @($pA,$pC) 'pC') -like 'smaller completed version*')

# Equal ranges, equal sizes: nothing is "smaller", so nothing goes.
$pD = PackOf 'pD' 'Widows.Bay.S01E01-10.720p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]'  24.0 0.20
$pE = PackOf 'pE' 'Widows.Bay.S01E01-10.720p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]'  24.0 1.00
Check 'identical-size packs of one range are NOT deleted' (@(Verdicts @($pD, $pE)).Count -eq 0)

# Neither finished: the rule needs a finished copy to act on.
$pF = PackOf 'pF' 'Widows.Bay.S01E01-10.720p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]'  24.0 0.30
$pG = PackOf 'pG' 'Widows.Bay.S01E01-10.720p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]'  12.0 0.10
Check 'two unfinished packs of one range delete nothing' (@(Verdicts @($pF, $pG)).Count -eq 0)

# A pack whose size is still unknown is skipped, exactly as a single is.
$pH = PackOf 'pH' 'Widows.Bay.S01E01-10.720p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]'   0.0 0.00
Check 'a same-range pack with no known total is NOT deleted' (@(Verdicts @($pA, $pH)).Count -eq 0)

"== a different range is not a rival, however tempting the sizes =="
# 60 GB finished against 40 GB unfinished. The old rule would have deleted the
# 40 GB one on size alone and lost episodes 7-10 outright. The range says these
# hold different things, so they are never weighed against each other.
Check 'a finished 10-episode pack does not delete an unfinished 6-episode pack' (@(Verdicts @($pack10, $pack06)).Count -eq 0)
Check '...and the unfinished one is never the keeper either' (-not (@(Verdicts @($pack10, $pack06)) -contains 'pack06'))

# Overlapping ranges that do not start together are separate too.
$q1 = PackOf 'q1' 'Widows.Bay.S01E01-05.720p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]'  12.0 1.00
$q2 = PackOf 'q2' 'Widows.Bay.S01E03-10.720p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]'  20.0 1.00
Check 'two overlapping packs with different first episodes delete nothing' (@(Verdicts @($q1, $q2)).Count -eq 0)

"== a pack and the single inside it are weighed per episode =="
# Same pair as above, restated where it is read in isolation. The pack's own file
# for S01E01 is 5.5 GB and the single is 8 GB, so the single is the bigger copy of
# that one episode - and the pass still removes nothing.
#
# This asserted the opposite for a long time, and the opposite destroyed a
# 12,54 GB eight-episode pack on 2026-10-05 over a 46 MB difference on one
# episode. It is restated here, in the section a reader lands on first, so the
# correct behaviour cannot be quietly reverted by someone tidying the tests.
$v = Verdicts @($pack10, $e1big)
Check 'a finished pack beside its own first finished single deletes NOTHING' (@($v).Count -eq 0)
Check 'the pack is not the per-episode loser'  (-not (@($v) -contains 'pack10'))
Check 'and neither is the single'             (-not (@($v) -contains 'e1big'))

"== whole-season packs =="
# A pack that names a season but no episode covers every episode of that season.
# There is no episode to record, so the parser sets episode 0 and the set key
# comes out as S<season>-ALL. Two packs of the same season are therefore rivals
# and deduplicate; a pack of another season is not.
$s1 = PackOf 's1' 'Widows.Bay.S01.1080p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]'  55.0 1.00
$s2 = PackOf 's2' 'Widows.Bay.S01.720p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]'  20.0 1.00
Check 'two season packs of one season land on one title' ($s1.parts.Title -eq $s2.parts.Title)
Check 'the smaller of two packs of one season is deleted' ((@(Verdicts @($s1, $s2)) -contains 's2'))
Check 'and the larger is kept' (-not (@(Verdicts @($s1, $s2)) -contains 's1'))
$s3 = PackOf 's3' 'Widows.Bay.S02.1080p.ATVP.WEB-DL.ITA.ENG.DD5.1.H.264-G66 [ext.to]'  55.0 1.00
Check 'but packs of DIFFERENT seasons do not touch each other' (@(Verdicts @($s1, $s3)).Count -eq 0)
$s4 = PackOf 's4' 'Widows Bay Season 1 1080p WEB x264'  55.0 1.00
$s5 = PackOf 's5' 'Widows Bay Season 1 720p WEB x264'  20.0 1.00
Check 'the spelled-out form clusters the same way' ($s4.parts.Title -eq $s5.parts.Title)
Check 'and its smaller pack is deleted too' ((@(Verdicts @($s4, $s5)) -contains 's5'))
$s6 = PackOf 's6' 'Widows Bay Season 2 1080p WEB x264'  55.0 1.00
Check 'different seasons stay apart in that form too' (@(Verdicts @($s4, $s6)).Count -eq 0)

"== the set key itself =="
# A season with no episode number is a WHOLE-SEASON pack. Every spelling of that
# has to land on the same key, or the same season written three different ways
# produces three groups that never meet each other.
Check 'a bare padded S01 is S1-ALL' ((Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Breaking Bad S01 1080p WEB-DL x264')) -eq 'S1-ALL')
Check 'a bare unpadded s18 is too' ((Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Its Always Sunny In Philadelphia s18 WEB-DL 1080p [ext.to]')) -eq 'S18-ALL')
Check 'the padded spelling agrees' ((Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Breaking Bad S18 1080p WEB-DL x264')) -eq 'S18-ALL')
Check 'Season01 is the same key' ((Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Breaking Bad Season01 1080p WEB-DL x264')) -eq 'S1-ALL')
Check 'and so is Season 1 with a space' ((Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Breaking Bad Season 1 1080p WEB-DL x264')) -eq 'S1-ALL')
Check 'so is Season 1 Complete' ((Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Breaking Bad Season 1 Complete 1080p WEB-DL x264')) -eq 'S1-ALL')
#
# The season token has to leave the title. Left in there it is ordinary text, so
# the pack could only ever match a release that spelled its season the same way.
Check 'the season is lifted out of the title' ((Get-TitleParts -Name 'Its Always Sunny In Philadelphia s18 WEB-DL 1080p [ext.to]').Title -eq 'its always sunny in philadelphia')
Check 'and out of the padded spelling' ((Get-TitleParts -Name 'Breaking Bad S01 1080p WEB-DL x264').Title -eq 'breaking bad')
#
# An episode number still wins, so these are not whole-season packs.
Check 'an episode number is not a season pack' ((Get-TitleParts -Name 'Breaking Bad S01E01 1080p WEB-DL x264').Episode -eq 1)
Check 'a range is not a season pack either' ((Get-TitleParts -Name 'Breaking Bad S01E01-10 1080p WEB-DL x264').IsMultiEpisode)
Check 'a bare E5 is still a single episode' ((Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Breaking Bad E05 1080p WEB-DL x264')) -eq 'S1-E5')
Check 'Se5 is read as a single episode, not a season' ((Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Breaking Bad Se5 1080p WEB-DL x264')) -eq 'S1-E5')
Check 'two different seasons never share a key' ((Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Breaking Bad Season02 1080p WEB-DL x264')) -ne 'S1-ALL')
#
# Guard tags: a group name is not a season. The digits have to form a real
# number, which is what keeps -S0NNER and a trailing x264-S0 out.
Check 'a group tag is not a season' ((Get-TitleParts -Name 'Show S0NNER 1080p WEB x264').IsSeries -eq $false)
Check 'a trailing S0 is not a season' ((Get-TitleParts -Name 'Show 1080p x264-S0').IsSeries -eq $false)
Check 'a group tag after a channel is not a season' ((Get-TitleParts -Name 'Show WEB-DL 5.1 1080p x264-S0NNER').IsSeries -eq $false)
#
# Films are untouched by the new branch.
Check 'a dotted numeric title is still a film' ((Get-EpisodeSetKey -Parts (Get-TitleParts -Name 'Ocean.s.8.2018 1080p BluRay x264')) -eq 'film')
Check 'and so is an ordinary movie' ((Get-TitleParts -Name 'The Matrix 1999 1080p BluRay x264').IsSeries -eq $false)
Check 'and a channel-only name' ((Get-TitleParts -Name 'Show 5.1 1080p BluRay x264-GRP').IsSeries -eq $false)
Check 'no parts at all means take no part' ((Get-EpisodeSetKey -Parts $null) -eq '')

Write-Host '== the three ways a release is compared, stated as one rule each ==' -ForegroundColor Cyan

# The whole of the rule, in the terms the rule was specified in: individual
# episodes against individual episodes, packs against packs of the SAME range,
# and whole seasons against whole seasons. Nothing is ever weighed against
# anything holding a different set of episodes.
function Key    { param($x) Get-EpisodeSetKey -Parts $x.parts }
function Header { param($set) ((Get-ShowLabel -Parts @($set | ForEach-Object { $_.parts })) + ' ' + (Get-EpisodeSetLabel -Key (Key $set[0]))).Trim() }
function Group  { param($ms) $g = New-Object System.Collections.ArrayList; foreach ($m in $ms) { [void]$g.Add($m) }; return ,$g.ToArray() }

# -- 1. two singles, one episode: 1080p 5 GB against 480p 1 GB ---------------
$singlesA = @(
    (P 'x1' 'Show X S01E01 1080p WEB-DL x264-GRP [ext.to]' 5.0 1.00),
    (P 'x2' 'Show X S01E01 480p  WEBRip x264-GRP [ext.to]' 1.0 1.00)
)
Check 'both singles land in the same set, S1-E1' `
    (((Key $singlesA[0]) -eq 'S1-E1') -and ((Key $singlesA[1]) -eq 'S1-E1'))
Check 'the header reads show name + season+episode' ((Header $singlesA) -eq 'show x S1E1')
$v = Verdicts @($singlesA)
Check 'the 480p is deleted' ((@($v).Count -eq 1) -and (@($v) -contains 'x2'))

# ... and the smaller one going does not depend on the smaller one being finished
$singlesB = @(
    (P 'x1' 'Show X S01E02 2160p WEB-DL x265-GRP [ext.to]' 20.0 1.00),
    (P 'x2' 'Show X S01E02 480p  WEBRip x264-GRP [ext.to]' 0.6 1.00)
)
Check 'a smaller FINISHED version is still deleted against a bigger finished one' `
    ((@(Verdicts @($singlesB)).Count -eq 1) -and (@(Verdicts @($singlesB)) -contains 'x2'))

# -- 2. two packs, same range: 1080p 50 GB against 480p 10 GB ----------------
$packsA = @(
    (P 'p1' 'Show X S01E01-E05 1080p WEB-DL x264-GRP [ext.to]' 50.0 1.00),
    (P 'p2' 'Show X S01E01-E05 480p  WEBRip x264-GRP [ext.to]' 10.0 1.00)
)
Check 'both packs land in the same set, S1-E1-E5' `
    (((Key $packsA[0]) -eq 'S1-E1-E5') -and ((Key $packsA[1]) -eq 'S1-E1-E5'))
Check 'the header reads show name + season+pack' ((Header $packsA) -eq 'show x S1E1-E5')
$v = Verdicts @($packsA)
Check 'the smaller pack is deleted' ((@($v).Count -eq 1) -and (@($v) -contains 'p2'))

# -- 3. two whole seasons, however spelled: s01 against s1 -------------------
$seasonsA = @(
    (P 's1' 'Show X S01 1080p WEB-DL x264-GRP [ext.to]' 55.0 1.00),
    (P 's2' 'Show X s1  480p WEBRip x264-GRP [ext.to]' 15.0 1.00)
)
Check 'both seasons land in the same set, S1-ALL' `
    (((Key $seasonsA[0]) -eq 'S1-ALL') -and ((Key $seasonsA[1]) -eq 'S1-ALL'))
Check 'the header reads show name + season' ((Header $seasonsA) -eq 'show x S1')
$v = Verdicts @($seasonsA)
Check 'the smaller season is deleted' ((@($v).Count -eq 1) -and (@($v) -contains 's2'))

# -- the boundaries: the three ways must never be weighed against each other --
Write-Host '== and the three ways must not be mixed ==' -ForegroundColor Cyan

$mixed = @(
    (P 'm1' 'Show X S01E01 1080p WEB-DL x264-GRP [ext.to]'      5.0 1.00),
    (P 'm2' 'Show X S01E01-E05 1080p WEB-DL x264-GRP [ext.to]' 50.0 1.00),
    (P 'm3' 'Show X S01 1080p WEB-DL x264-GRP [ext.to]'        55.0 1.00)
)
Check 'a single episode, a pack and a season are three distinct sets' `
    (((Key $mixed[0]) -eq 'S1-E1') -and ((Key $mixed[1]) -eq 'S1-E1-E5') -and ((Key $mixed[2]) -eq 'S1-ALL'))
# m2's file for E01 is 8 GB against m1's 5 GB, so the single goes.
Set-PackFiles -Hash 'm2' -Entries @(
    (File 'Show X S01E01.mkv' 8.0),
    (File 'Show X S01E02.mkv' 8.0)
)
$v = Verdicts @($mixed)
Check 'all three in one room: the single inside the pack goes, the rest stays' `
    ((@($v).Count -eq 1) -and (@($v) -contains 'm1'))
Check 'and the season pack is never a candidate' (-not (@($v) -contains 'm3'))

$overlap = @(
    (P 'o1' 'Show X S01E01-E05 1080p WEB-DL x264-GRP [ext.to]' 50.0 1.00),
    (P 'o2' 'Show X S01E01 480p WEBRip x264-GRP [ext.to]'       0.6 1.00)
)
# o1's E01 file is 9 GB; the 0.6 GB single is the smaller copy.
Set-PackFiles -Hash 'o1' -Entries @(
    (File 'Show X S01E01.mkv' 9.0),
    (File 'Show X S01E02.mkv' 9.0)
)
$v = Verdicts @($overlap)
Check 'a pack beside the episode it contains deletes the smaller one' `
    ((@($v).Count -eq 1) -and (@($v) -contains 'o2'))

$otherRange = @(
    (P 'r1' 'Show X S01E01-E05 1080p WEB-DL x264-GRP [ext.to]' 50.0 1.00),
    (P 'r2' 'Show X S01E01-E10 480p WEBRip x264-GRP [ext.to]'   0.6 1.00)
)
Check 'packs of different ranges are not weighed against each other' (@(Verdicts @($otherRange)).Count -eq 0)

$otherEp = @(
    (P 'e1' 'Show X S01E01 1080p WEB-DL x264-GRP [ext.to]' 5.0 1.00),
    (P 'e2' 'Show X S01E02 480p WEBRip x264-GRP [ext.to]'  1.0 1.00)
)
Check 'singles of different episodes are not weighed against each other' (@(Verdicts @($otherEp)).Count -eq 0)
"checks: $($script:fails) failed"
if ($script:fails -gt 0) { exit 1 }
exit 0
