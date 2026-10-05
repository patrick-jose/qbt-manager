# Commands

Every command in this project, and what each one is for.

Run from the project folder. All examples assume Windows PowerShell 5.1, which is
what the scheduled task uses — plain `powershell`, not `pwsh`.

## The two commands you actually use

```powershell
# Live panel, refreshing every 30 seconds. Read-only: deletes nothing.
.\status.ps1 -Watch

# One snapshot, then exit. Same panel, no refresh.
.\status.ps1
```

`status.ps1` never deletes, moves, or pauses anything, so `-Watch` is safe to
leave open all day. Press `Ctrl+C` to stop.

## Running the manager

```powershell
# See what it would do. Changes NOTHING - no deletion, no move, no category.
.\qbt-manager.ps1 -DryRun

# Actually run it.
.\qbt-manager.ps1

# Restrict the dedup pass to titles containing this text.
# Useful for staging a first run against a single title.
.\qbt-manager.ps1 -DryRun -Only "ted lasso"

# Use a different configuration, without touching the real one.
.\qbt-manager.ps1 -DryRun -ConfigPath .\config.test.json
```

`-DryRun` is the one to reach for first. It prints every decision it *would* make
and touches nothing at all — no API write, no file, no state.

If qBittorrent is not running, the run exits `0` and says nothing was changed.
That is normal, not a failure to investigate — see the exit-code table below.

## status.ps1 options

| Command | What it does |
|---|---|
| `.\status.ps1` | One snapshot, action-first summary. |
| `.\status.ps1 -Watch` | Keeps refreshing. The one you use most. |
| `.\status.ps1 -Full` | The whole queue and every magnet, unbounded. With 200+ torrents this is thousands of lines. |
| `.\status.ps1 -All` | Include the low-value log lines (`INFO`, `ACTION`), not just deletions, moves, warnings and errors. |
| `.\status.ps1 -Tail 40` | How many log lines to show. Default `8`. |
| `.\status.ps1 -Watch -RefreshSeconds 10` | Refresh faster than the default 30 seconds. |
| `.\status.ps1 -Full -Tail 60` | Everything at once. Rarely what you want. |

They combine:

```powershell
# Everything, refreshing, generous log history.
.\status.ps1 -Watch -Full -All -Tail 60

# More log history, default caps elsewhere.
.\status.ps1 -Tail 40
```

There is no switch to suppress the queue section — `-Tail` only controls the log
tail. The queue is always shown, capped by default.

The default view leads with what the next run will delete and which magnets are
close to expiring, and caps the rest with `+N more`. `-Full` removes the caps.
That ordering is deliberate: with a few hundred torrents the full listing buries
the three or four rows that matter.

## Tests

One command runs everything:

```powershell
# Everything, full output.
.\test-all.ps1

# One line per suite. The right choice before a change you expect to be quiet.
.\test-all.ps1 -Quiet

# Only some suites, fast feedback on one area.
.\test-all.ps1 -Quiet -Suite dedup,queue-window
.\test-all.ps1 -Suite phantom        # the 'test-' prefix is optional

# Name the failing checks instead of just the count.
.\test-all.ps1 -Quiet -ShowFailures

# What is available, without running it.
.\test-all.ps1 -List
```

Exit codes: `0` all passed, `1` something failed, `2` the test folder is missing
or a `-Suite` name matched nothing.

`-Suite` accepts a comma-separated list even under `-File`, where every argument
otherwise arrives as a single string.

Each suite in `.\test\` is standalone and exits non-zero on failure, so you can
run any of them directly with no runner at all:

```powershell
.\test\test-dedup.ps1
```

`test-all.ps1` gives each suite its own child process, with a per-suite timeout
(`-TimeoutSeconds`, default 300, `0` disables it) so a hung suite cannot wedge
the run. A suite that **throws before printing anything** is reported as a
failure, not as a pass — silence is not success.

Run them after touching `qbt-manager.ps1`. The suites reach the rules by
*slicing the manager's source and evaluating the slice*, so an edit that moves a
function across a slice boundary shows up as a failing check rather than as a
suite that quietly stops testing anything.

The suites that touch the real machine, and what they do about it:

| Suite | Touches |
|---|---|
| `test-api.ps1` | The **real** qBittorrent — drives real failures (dead port, unroutable address, held lock). Runs from a throwaway directory with its own config and log, and every case that would otherwise act is neutralised, so your real `state.json` is never written. |
| `test-log-reap.ps1` | Plants files in a `%TEMP%` tree, deletes only those. |
| `test-reap.ps1` | Plants leftovers in a `%TEMP%` tree. |
| `test-library-dedupe.ps1` | Builds a real folder tree in `%TEMP%`, in KB not MB, and removes it. |
| the rest | Pure computation. No disk, no API, no network — except `test-stall-cleanup.ps1`, which makes **one** live HTTP call at the very end to confirm the internet probe really answers `True`. |

## Configuration

Two files, split so the project can be published without publishing your user
name:

| File | Committed? | Holds |
|---|---|---|
| `config.json` | **yes** | Every tunable, paths as placeholders. This doubles as the template — there is no `config.example.json`, because a second identical copy is a file that drifts. |
| `config.local.json` | **no**, git-ignored | Your paths only. Overrides `config.json` per key. |

If you ever delete `config.json`, it comes back with `git checkout config.json` —
which is why no separate copy is kept.

`config.local.json` is read after `config.json` and wins on every key it
mentions. The merge is **shallow**: one level of keys, no nesting. Only the
location keys belong in it — `moviesDir`, `seriesDir`, `reapRoots`, and the two
category names. Every other setting belongs in `config.json`, so there is exactly
one place to look for it.

A `"//"` key is a comment and is skipped, so the file can explain itself.

A missing `config.local.json` is not an error. That is the normal case for
anyone who cloned the repository, and for a first run before the paths are filled
in.

### First-time setup on a new machine

`config.json` is committed, so after cloning it is already there, with
placeholder paths. Create `config.local.json` with only the keys you want to
override:

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
notepad .\config.local.json      # paste the above, put your own paths in
.\qbt-manager.ps1 -DryRun        # confirm it sees what you expect
```

**Save it as UTF-8.** PowerShell 5.1 reads a BOM-less file as ANSI, which turns
`Séries` into mojibake and makes the folder look absent — the same trap that
made every accented library path look missing until the API reads were fixed.
Both scripts read the file with an explicit UTF-8 encoding, so the file itself is
what matters.

The template is inline here rather than in a `config.local.json.example` file on
purpose: **no code reads a template file**, so it would drift from the prose
around it with nothing to notice.

## The scheduled task

Runs every 15 minutes, and at logon. You rarely need to touch it, but:

```powershell
# Is it there, and when does it next run?
Get-ScheduledTask -TaskName 'qbt-manager' | Get-ScheduledTaskInfo

# Run it now instead of waiting for the next tick.
Start-ScheduledTask -TaskName 'qbt-manager'

# Stop it while you work by hand, so it cannot collide with your own run.
Disable-ScheduledTask -TaskName 'qbt-manager'
Enable-ScheduledTask  -TaskName 'qbt-manager'

# What it actually runs.
(Get-ScheduledTask -TaskName 'qbt-manager').Actions
```

### Recreating the task

The task is **not committed** — it points at absolute paths on your machine.
Recreate it after cloning:

```powershell
$here    = 'C:\path\to\qbt-manager'
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$here\qbt-manager.ps1`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 15)
$logon   = New-ScheduledTaskTrigger -AtLogOn

Register-ScheduledTask -TaskName 'qbt-manager' -Action $action -Trigger @($trigger, $logon) `
    -Description 'Automated qBittorrent curator'
```

`-WindowStyle Hidden` matters: without it the task flashes a console window every
15 minutes. This matches the task as it is actually registered here — one
15-minute time trigger plus one at-logon trigger.

## Logs

```powershell
# Today's decisions, newest last.
Get-Content .\logs\manager-$(Get-Date -Format 'yyyy-MM-dd').log -Tail 40

# Every log file still present, newest first.
Get-ChildItem .\logs\manager-*.log | Sort-Object Name -Descending

# Just the deletions, across all logs.
Select-String -Path .\logs\manager-*.log -Pattern '\[DELETE\]' | Select-Object -Last 20

# Count them per day - a quiet sanity check that the rules are not over-firing.
Get-ChildItem .\logs\manager-*.log |
    ForEach-Object { [pscustomobject]@{
        Day   = $_.BaseName -replace 'manager-', ''
        Deletes = (Select-String -Path $_.FullName -Pattern '\[DELETE\]').Count
    } } | Format-Table -AutoSize
```

Logs are kept **7 days** and then destroyed, along with `.bak` backups. The sweep
covers everything in `logs\`, so the `deleted-*.csv` worksheets go on the same
clock.

```powershell
# What the reaper would remove right now.
.\qbt-manager.ps1 -DryRun | Select-String -Pattern 'reaper' -Context 0,3
```

## Other things worth knowing

```powershell
# Is the state file there, and how big has it grown?
Get-Item .\state.json | Select-Object Length, LastWriteTime

# Safe to delete - every clock re-seeds from the client on the next run.
Remove-Item .\state.json

# A stale lock never wedges the schedule: the PID inside it is checked and a lock
# whose owner is gone is cleared. This is only to look at it.
Get-Content .\manager.lock
```

### Exit codes

`qbt-manager.ps1` uses these, so a wrapper or CI can tell what happened:

| Code | Meaning |
|---|---|
| `0` | Finished — **or** qBittorrent is not running. A closed app exits `0`, quietly, because that is normal and not a failure. |
| `1` | An **unexpected** failure while reading the torrent list. This is the net for anything unforeseen, not the expected closed-app case. |
| `2` | The API failed and retries did not help, or `config.json` is missing. |
| `3` | The API dropped part way through; the run stopped rather than repeating the timeout for every remaining torrent. |
| `4` | Another run holds `manager.lock`. This run changed nothing. Safe, and expected when a scheduled run overlaps your own. |

That `0` for a closed app is deliberate and worth knowing before you wire this
into anything: **a closed qBittorrent is indistinguishable from a clean run by
exit code alone.** If you need to tell them apart, check for the log line
`nothing listening on` instead.

`status.ps1` does not use these codes for status; it exits `2` only when
`config.json` is missing.

### Why a dry run and a real run can disagree

`status.ps1` reuses the manager's own detection functions, lifted from its
source, so a preview cannot disagree with the real thing by being a second
separately-maintained copy of the rules. `test-parsing.ps1` compares the two
copies state by state.

They can still differ in one respect: a real run **moves** completed torrents
into the library, which changes what the next run sees. A dry run never does, so
repeated dry runs show the same queue.
