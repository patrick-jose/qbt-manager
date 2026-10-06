# qbt-manager

An automated curator for [qBittorrent](https://www.qbittorrent.org/), driven
through its Web API. Runs unattended on a schedule, deletes what you have decided
should not be downloaded, files what should be kept, and tells you what it did
and why.

It is written for one specific person's rules rather than for everyone, so it is
opinionated. The opinions are the point: a smaller version of this that deleted
"probably duplicates" would eventually delete the only copy of something.

```powershell
# See what it would do. Changes nothing.
.\qbt-manager.ps1 -DryRun

# Watch it work. Read-only, refreshes every 30 seconds.
.\status.ps1 -Watch
```

## What it does

Nine rules, run in this order:

| # | Rule | In one line |
|---|---|---|
| 1 | **Dolby Vision** | A torrent advertising DoVi is deleted with its files, in any state. |
| 1b | **Disc rip** | A full Blu-ray disc structure is deleted. Transcodes and REMUXes are not disc rips and are left alone. |
| 2 | **No availability** | A magnet reporting no size is deleted after being *really* trying — see below. |
| 2b | **Stalled** | An unfinished torrent whose byte count has not moved for 7 days. |
| 2c | **The drain** | One dead magnet per run, from just behind the queue window. |
| 2d | **Stalled client** | If global velocity is 0 for over a minute while the internet is up, the queue is stalled rather than slow, and the front of it goes immediately. |
| 3 | **Categories** | Identified torrents are filed under `Movies` or `Series`. |
| 4 | **Dedup** | Within one title, the largest *finished* version wins and every smaller version is deleted. |
| 4b | **Library duplicates** | The same episode twice in one season folder: the larger copy stays. |
| 4c | **Phantom** | A finished entry whose data is gone is removed — but only if the library really does hold a replacement. |
| 4d | **Redundant download** | A download whose final size is within 10% of an episode already in the library is stopped and removed. |
| 5 | **Library** | Surviving completed torrents are moved into the library, then the move is *verified*. |
| 6 | **Reaper** | Download leftovers no torrent claims any more. |
| 7 | **Retention** | Backups, and everything in `logs\`, are destroyed after 7 days. |

**Finished torrents are never removed merely for being finished.**

How each of these decides, and the measurements that forced the design, is in
[RULES.md](docs/RULES.md).

## Two ideas that shape everything

**A magnet that has not been given a turn has not "tried".** qBittorrent works its
queue in order, so a magnet at position 150 is waiting, not failing. "Unavailable
after trying" is only true of a torrent the client is actually working on. So
that rule is judged only inside the first 10 queue positions, and its clock runs
only for the time it spends in there.

This is not theoretical. An earlier version of the rule read `priority` as a
0–7 "how much do I want this" tier and deleted **205 queued torrents in one run**,
none of which had been handed a single peer connection.

**Judging by the title fails across release groups.** One episode of one show is
routinely published as `Its.Always.Sunny.in.Philadelphia.S18E03...`,
`It s Always Sunny in Philadelphia...` and `Its Always Sunny In Philadelphia
s18 WEB-DL...`. Grouping by show name makes those three different shows, and the
duplicates invisible. The fix that does work is the **library folder**: the
manager filed them together itself, so the folder is a grouping already proven by
a different route. Two files in the same season folder claiming the same episode
are the same episode by construction.

That fix found **7 duplicated episodes and 10,5 GB** sitting finished in the
library.

**A name is a claim, and two of them outlived their truth.** Comparing packs means
knowing which episodes each one holds, and that was read off the release name. A
name saying `S03` with no episode keys `S3-ALL` — a value no range can equal, so
`Euphoria.S03.COMPLETE` (finished, 40,37 GB, actually `S03E01`–`E08`) was invisible
to the 15,69 GB `Euphoria US S03e01-08` holding those same eight episodes, which
sat downloading at 96,5% until both were removed. Two causes, both needed fixing:
the set key was a guess where the release's own **file list** was available, and
grouping by title kept two packs of one show apart whenever their names differed.

`S3-ALL` is now checked against the file list, and the comparison is made across a
show's title variants. Both changes only ever *narrow* what a name may claim: a
real ten-episode season pack still refuses an eight-episode one, and a pack still
never meets a single episode.

**An errored torrent is left alone** — with three exceptions, each deliberate.
Deleting one destroys whatever it fetched, and an error is usually a disk, a path
or a tracker rather than a verdict on the torrent. DoVi and disc-rip decide from
the name and the disk, so an error cannot affect them. Dedup deletes an errored
torrent only when a **finished** copy of the **identical** episodes is bigger —
at which point it is a spare copy that failed, not data held once.

## Install

Requires Windows PowerShell 5.1 and qBittorrent with its Web UI enabled
(`Preferences → Web UI`). No modules, no package manager.

```powershell
git clone <your-fork-url> qbt-manager
cd qbt-manager
```

`config.json` is committed and already contains every setting, with placeholder
paths. Create `config.local.json` with just your own paths:

```json
{
  "//": "Your paths only. Every key here overrides config.json. ONLY location keys belong here.",
  "moviesDir": "C:\\Users\\you\\Downloads\\Filmes",
  "seriesDir": "C:\\Users\\you\\Downloads\\Séries",
  "moviesCategory": "Movies",
  "seriesCategory": "Series",
  "reapRoots": [
    "C:\\Users\\you\\Downloads\\temp"
  ]
}
```

```powershell
notepad .\config.local.json
.\qbt-manager.ps1 -DryRun     # read this output before anything else
```

Save it as **UTF-8**. PowerShell 5.1 reads a BOM-less file as ANSI, which turns
`Séries` into mojibake and makes the folder look absent.

If you skip that step the manager says so, naming the keys, and matches nothing —
safe, but nothing will be found, deduplicated or moved.

### Scheduling it

The scheduled task is **not** committed, because it names absolute paths.
[COMMANDS.md](COMMANDS.md#the-scheduled-task) has the exact
`Register-ScheduledTask` that recreates it — a 15-minute trigger plus one at
logon.

## Configuration

Two files, so this can be published without publishing anyone's user name:

| File | Committed? | Holds |
|---|---|---|
| `config.json` | yes | Every tunable, with placeholder paths. Also the template. |
| `config.local.json` | **no**, git-ignored | Your paths. Wins on any key it mentions. |

The merge is deliberately **shallow** — one level, no nesting — so the local file
stays a short list of "my paths are these" rather than a second copy of the
configuration that can drift. Only location keys belong in it; everything else
stays in `config.json` so there is one place to look for it. A `"//"` key is
treated as a comment.

Most things you would want to change are in [Tuning](docs/RULES.md#tuning):
`metadataTimeoutMinutes` (how long a magnet may report no size),
`metadataPriorityRankLimit` (the window width), `stalledDeleteDays`,
`libraryRedundantTolerancePercent`, `reapMinAgeHours`, and the `doviPatterns` and
`discRipPatterns` lists.

## Commands

Full reference in [COMMANDS.md](COMMANDS.md). The ones that matter:

```powershell
.\status.ps1 -Watch                     # live panel, read-only
.\qbt-manager.ps1 -DryRun                # what it would do, changes nothing
.\test-all.ps1 -Quiet                    # every test, one line per suite
.\test-all.ps1 -Suite dedup,phantom      # just some of them
```

`status.ps1` never deletes, moves or pauses anything, so `-Watch` is safe to
leave open. It reports what the manager recorded and reuses the manager's own
detection functions, so a preview cannot disagree with the real thing by being a
second, separately-maintained copy of the rules.

## Tests

```
767 checks across 14 suites, about 80 seconds.
```

```powershell
.\test-all.ps1              # everything
.\test-all.ps1 -Quiet       # one line per suite
.\test-all.ps1 -List        # what exists, runs nothing
```

The suites reach the rules by **slicing the manager's source and evaluating the
slice**, so a change that moves a function across a slice boundary fails a check
instead of quietly leaving a suite testing nothing. A suite that throws before
printing anything is reported as a failure, not as a pass.

Only `test-api.ps1` touches the real qBittorrent, and only to drive real failures
— a dead port, an unroutable address, a held lock — from a throwaway directory
with its own config and log.

## Layout

```
qbt-manager.ps1          the manager
status.ps1               live read-only panel
test-all.ps1             test runner
config.json              every tunable, committed
config.local.json        your paths, git-ignored
COMMANDS.md              every command, with what each is for
docs/RULES.md            how each rule decides, and why
test\                    14 standalone suites
logs\                    one file per day, destroyed after 7 days
```

## Notes for anyone reading this

**The API is read as explicit UTF-8, always.** Letting curl stream into the
PowerShell pipeline decodes native output with the console code page, which turns
`é` into two Latin-1 characters. That corruption is silent, it makes every
accented library path look absent, and it was the cause of a bug that looked like
a folder-detection failure for a long time.

**A 200 from `torrents/setLocation` does not mean the move happened.** It answers
when the move is *queued*. On this box it returned 200 for a torrent whose files
never left temp. Anything that moves data re-reads the torrent afterwards and
checks.

**Nothing here trusts a status code, a filename pattern, or a folder name without
checking.** Most of the bug history in this project is a rule that was confident
on the first sample and wrong on the second.
