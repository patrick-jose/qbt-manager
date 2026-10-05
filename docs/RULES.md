# Rules, in detail

How each rule decides, and why it decides that way. Every judgement call here was
measured against a real queue at some point, and the measurement is usually the
most interesting part of the entry.

For what the project *is* and how to run it, start with [the README](../README.md).
For every command, see [COMMANDS.md](../COMMANDS.md).

---

## Rules, in the order they run

1. **Dolby Vision** â€” any torrent whose name advertises DoVi (`DV`, `DoVi`,
   `Dolby Vision`) is deleted with its files, in any state. Runs first.
2. **No availability** - a magnet that reports no size (`size == 0` or state
   `metaDL`) is deleted once it has been **really trying** for longer than
   `metadataTimeoutMinutes`. "Really trying" means two things at once:

   - the magnet is inside the queue window `1 <= priority <=
     metadataPriorityRankLimit`, **and**
   - the clock counts only the time it spends inside that window.

   `priority` is qBittorrent's **queue position**, not a "how much do I want
   this" tier. Measured on this client: `QueueingSystemEnabled=true`, and the 19
   torrents split cleanly by priority - priority `0` was all 11 finished ones
   (`stalledUP`/`stoppedUP`), priority `1..8` was exactly the 8 unfinished ones,
   with no gaps. A magnet at position 150 has never been handed a peer
   connection, so it has not tried anything, and deleting it for being
   unavailable is really deleting it for not having been started yet.

   **Priority 0 is excluded from the window.** It means "out of the queue", not
   "at the top of it"; counting it as position 1 would hand the entire window to
   torrents that are already finished. A magnet qBittorrent has dropped out of
   the queue is left alone by this rule.

   The clock lives in `state.json` as `windowSince`, and a magnet found outside
   the window has that entry cleared. So a magnet promoted from position 150
   gets a full tolerance from the moment it reaches the front, instead of being
   deleted on the spot for a queue it had not yet served. A `state.json` entry
   written by an older version carries no `windowSince`, which seeds a fresh full
   tolerance - so the migration can only ever be more patient, never less.

   The sort by `priority` orders the report only; it can never exempt a magnet
   that is inside the window. Ascending is oldest first, which is the right order
   to read this rule in: the magnet that has been waiting longest is listed
   first.

   **The tolerance is 30 minutes**, lowered from 60. Both the window rule and the
   drain read the same key, so they can never disagree about how long a magnet is
   given â€” and because the clock only runs inside the window, halving the
   tolerance does not penalise a magnet that has been promoted from position 150:
   it still gets the full 30 minutes from the moment it reaches the front.

   This window was removed once, on the mistaken reading that `priority` was a
   0..7 want tier. Removing it deleted 205 torrents, none of which had been given
   a turn. `status.ps1` is guarded against drifting from this rule by the test
   "status.ps1 applies the same queue window as the manager".
3. **The drain** â€” one magnet an hour, from just behind the window. The window
   above is a fixed slab, so it never reaches past position 10: a magnet at
   position 11 that has been dead for a week is never cleaned up, because nothing
   promotes it into the window. This rule takes over exactly where the window
   stops. See [The drain](#the-drain) below.
4. **Stalled** â€” an unfinished torrent whose downloaded byte count has not
   moved for `stalledDeleteDays` days is deleted, together with its partial
   data. Set it to `0` to disable the rule entirely.
4b. **Stalled client** â€” when global download velocity has been **0 for over a
   minute** and the internet is verifiably up, up to `stallMaxDeletions`
   magnets from the front of the queue are removed immediately, without waiting
   out rule 2's tolerance. See [The stalled client](#the-stalled-client).
5. **Categories** â€” every identified torrent is put in `Filmes` or `SÃ©ries`
   (series detection is automatic, by `SxxEyy` / `Season N` markers).
6. **Dedup** â€” torrents are clustered by title. Within a cluster the largest
   version that is **100% downloaded** is the keeper, and every other version
   smaller than it is deleted, whether or not it is itself finished. Versions
   *bigger* than the keeper are left alone. Nothing is deleted from a cluster
   with no finished member. Comparison is per SET OF EPISODES, not per group:
   two packs of the same range are rivals and deduplicate, a pack of a different
   range is not (see [Episode sets](#episode-sets-packs-compete-only-on-an-identical-range)).
7. **Library** â€” survivors that are complete are moved to `moviesDir` or
   `seriesDir`. The move is then **verified**, not assumed, and is refused while
   another torrent holds the folder (see [Moving to the library](#moving-to-the-library)).
8. **Orphan reaper** â€” leftovers in `reapRoots` that no torrent claims any more.
9. **Retention** â€” `.bak` backups, and everything in `logs\`, older than **7 days**
   are destroyed. See [Retention](#retention) â€” the one thing spared is the log
   the current run is still writing to.

Finished torrents are never removed merely for being finished.

### The drain

**This is an addition to rule 2, not a replacement for it.** Rule 2 is unchanged
and still runs exactly as before: every expired magnet inside positions 1-10 is
deleted, all of them, on the same run. The drain then contributes at most one more
per hour, from behind the window. A run can therefore delete several torrents from
the window *and* one from the drain; it never deletes only one. `queueDrainEnabled:
false` switches the drain off without affecting rule 2 at all.

The window in rule 2 is a slab of the queue, and it never reaches past position
`metadataPriorityRankLimit`. That is correct while the queue is healthy, but it
leaves a gap: nothing ever promotes a magnet into the window, so a magnet at
position 11 that has been dead for a week is never cleaned up. The drain covers
that gap and nothing else.

**One candidate per run.** It is the *first* torrent with no size at a position
greater than the limit, ascending. Exactly one, always. That is the rate limit:
however many magnets are dead behind the window, an hour passes and one torrent
goes. Priority 0 is excluded, as in rule 2.

**Its own clock, starting when it becomes the candidate.** A new candidate always
starts from zero, so a magnet promoted from position 300 cannot be deleted on
arrival for a queue it never served. Only one clock exists at a time, in
`state.json` as `drain` (`hash` + `since`), and it is repointed whenever the
candidate changes â€” so it cannot grow without bound, and time served by one
torrent is never inherited by another.

**A witness is required, and it must be further down the queue.** Past tolerance,
the magnet is deleted only if some torrent at a *higher position number* is
actively downloading. This is the safety half of the rule and not decoration:

- A magnet past the window is unavailable in two quite different situations â€” the
  torrent is dead, or the client is not getting anywhere. Only the first is this
  rule's business.
- A dead client makes *every* magnet look unavailable, all the way down the queue.
  Without the witness, this rule would answer a broken client by deleting the
  whole queue in hourly instalments.
- Requiring the witness *further down*, not merely *present*, is what makes it a
  proof rather than a coincidence. An unrelated download inside the window would
  be just as likely on a stalled client as on a healthy one. Something past the
  dead magnet means the client got beyond it and found life.

With no witness the magnet is **held**, not deleted, and it is reported as `HELD`.
The clock keeps running: the 60 minutes measure how long the magnet has been
dead, not how long it has waited for a witness, so the time already served counts
the moment one appears.

`actively downloading` is an **allowlist** of states â€” `downloading`, `forcedDL`,
`stalledDL`, `allocating`, `metaDL`, `forcedMetaDL` â€” and it is an allowlist on
purpose. A denylist has to enumerate every state the client can be in that is not
a download, and it eventually meets one nobody thought of, where the default is
the dangerous answer. Measured against qBittorrent 5.2.4's full state set, the
denylist version accepted `uploading`, `stalledUP`, `error` and `unknown`: a
seeding or broken torrent would have authorised deleting a magnet. With an
allowlist, anything unrecognised simply is not a witness, and the worst case is
that a magnet is held another hour.

Two worked examples, straight from the rule as it was specified:

| positions | state | outcome |
|---|---|---|
| 11-17 dead, 18 downloading | candidate 11, witness 18 | 11 deleted after 60 min, then 12 gets its own 60, and so on |
| 11 downloading, 12 dead, 13 downloading | candidate 12, witness 13 | 12 deleted after 60 min |

Set `queueDrainEnabled` to `false` to turn the rule off.

### Moving to the library

Two failures were possible here, and both were live on this box.

**A 200 from `setLocation` is not a move.** It answers as soon as the move is
*queued*, which is why the log used to say `MOVE` every 15 minutes for a move
that never happened â€” and why the destination kept showing up as an empty folder.
After the call the manager now polls `torrents/info` for that one hash until
`content_path` actually sits under the library folder, and logs `MOVED` only when
it does. A move that does not land is logged as `move failed:` with the
`content_path` qBittorrent was still reporting, not as a success.
`/torrents/info` does not expose `move_status`, so this is the only way to tell
the two apart. A move on the same volume is a rename and confirms on the first
ask, so the poll costs one API call in the good case and only burns time in the
bad one. Bounded by `moveVerifySeconds` (default 30) and `moveVerifyPollMs`
(default 500).

**A folder two torrents share cannot be moved at all.** qBittorrent moves a
folder by renaming it, and Windows refuses a rename while another file inside is
open â€” so when two torrents point at one `content_path` they deadlock each other
and every retry fails with `Permission denied` forever. Those moves are now
refused before the request is sent, logged as `move blocked:` naming the torrent
holding the folder. The claim is judged on `content_path`, never on `save_path`,
for the same reason the reaper does it that way: torrents share one `save_path`,
so trusting it would block every move on this box.

The decision is `Get-MovePlan`, which answers `skip` (already in the library),
`block` (something wanted is holding it) or `move` (go ahead, then verify).
It is a pure function so it can be tested without an API or a disk, and
`Test-MoveSettled` is the one predicate both it and `Wait-MoveVerified` agree
on.

### The stalled client

Rule 2 asks **how long a magnet has been trying**. That question is unanswerable
while the client is idle â€” there is no evidence of trying, only of waiting. Rule
4b asks a different and stronger question: **is anything happening at all**.

Measured live when this was written: **206 torrents, 195 of them magnets**,
`dl_info_speed` 0, `up_info_speed` 1,4 MB/s, and queue positions 4 through 20 all
`metaDL` at `dlspeed` 0. The client was plainly capable of traffic and was pulling
nothing down. Every one of those magnets was unavailable and the client had
already said so with its own aggregate figure. Waiting 30 more minutes would have
bought nothing.

Three conditions, all load-bearing:

1. **Global download velocity is zero** â€” `dl_info_speed` from
   `/transfer/info`, the client's own aggregate figure. Not a sum over torrents
   and not a per-torrent `dlspeed`: a per-torrent check would miss the case where
   several torrents each trickle slowly while the link as a whole is fine.
2. **It has been zero for longer than `stallConfirmSeconds`** â€” one sample cannot
   tell a stall from a lull between chunks, so this is proven over time. The
   clock is persisted in `state.json`, so a stall seen at the end of one run and
   still present at the start of the next acts immediately. When the threshold is
   not yet reached the rule **waits out the remainder in-run** (bounded by
   `stallMaxWaitSeconds`) and re-samples, so the deletion happens in the run that
   noticed the stall rather than the one after it.
3. **The internet is up** â€” proven by a probe that does not involve qBittorrent at
   all. Asking the client whether it has network access is circular; the client is
   the thing being doubted. **Fail-closed**: a DNS failure, refused connection or
   timeout all count as "not proven up" and block the deletion. Being unable to
   prove the internet works is never permission to delete.

It removes up to `stallMaxDeletions` magnets from the queue window (`1..limit`, so
position 0 is excluded as everywhere else), in queue order, oldest first. A cap is
not optional: this can fire on a queue of 195 magnets, and an uncapped sweep would
empty it.

It runs **after** the drain, deliberately â€” the drain's witness is "something
further down the queue is downloading", and this rule deletes the torrents that
would be that witness.

**A rate limit is not a stall.** `dl_rate_limit` above zero means the user capped
the client, and a capped client pulling nothing is obeying the cap. Deleting its
queue would be deleting the user's own configuration back at them.

The probe is a plain `GET` with the body discarded, and **no `-f` and no `-I`** â€”
both were tried first and both were measured to be wrong. `-f` fails on an HTTP
error status, and the configured endpoint answers **404 to a HEAD request**, so `-f`
reported the internet as unreachable while it was working fine. The rule would have
been permanently dead, and quietly so. The status code is deliberately not checked:
404, 403 and 405 all still prove the network works, which is the only question
being asked.

`test\test-stall-cleanup.ps1` covers it, including that a **throwing** probe blocks
the deletion, and it ends with one live call confirming the configured URL really
does answer `True` â€” a probe that always returned `False` would pass every other
check in the suite and block the rule forever without ever looking like a failure.

### How "stalled" is judged

Not by qBittorrent's `state` field. `stalledDL` only means "no peers at this
instant" â€” it flips back the moment a tracker reannounces or a leecher
reconnects, so a swarm that is merely between peers is indistinguishable from
one that is dead. Instead the manager keeps its own table in `state.json` under
`stalled`, holding the moment it last saw `completed` go up. If the byte count
has not increased since then, the torrent is stuck.

On first sighting there is no history, so the clock is seeded from
`last_activity`, capped at `added_on` and at now. That is what lets a torrent
that died before the manager existed be caught on the first run instead of
after a week of watching, while a clock skewed into the future still cannot age
a new torrent past its true age.

Two groups are deliberately exempt:

- **paused and stopped** torrents. A torrent parked by hand is not "unable to
  download", and deleting it would quietly undo a decision the user made on
  purpose.
- **magnets with no metadata.** Rule 2 owns those, and removes them on evidence -
  no size reported for longer than the timeout while the magnet sits inside the
  queue window - rather than on a date. This one must not become a way around
  that: it would otherwise sweep every magnet in the client on day seven whatever
  their state.
on day seven whatever their state.

Transient states (`allocating`, `checkingDL`, `moving`, â€¦) are skipped: the
torrent is busy, not stuck.

### Ordering that matters

Dedup runs **before** the library move, so files are never relocated only to be
deleted again. DoVi deletions are excluded from every later rule.

### How dedup decides

One keeper per cluster: the **largest version that is 100% downloaded**. Every
other version smaller than the keeper is then deleted, finished or not. There is
no size ratio below which a smaller copy becomes worth keeping â€” once the
bigger one is complete you already have the episode, so a 1080p sitting at 3% is
exactly as redundant as one at 99%.

### "Bigger" means total size, never progress

Both sides of every comparison are the download's **total** size â€” the size it
would end up at, not the bytes fetched so far. Progress is only ever used to
decide *finished or not*, never *bigger or smaller*.

This matters in one specific direction, and the Ripley pair is the live example:

| Torrent | total | fetched | rule reads | verdict |
|---|---|---|---|---|
| Ripley REMUX 1080p | **38.40 GB** | 4.30 GB (11.2%) | 38.40 GB | kept â€” bigger than the keeper |
| Ripley 1080i x265 | 17.06 GB | 17.06 GB (100%) | 17.06 GB | the keeper |

Read as downloaded bytes instead, the REMUX would show 4.30 GB against 17.06 GB,
look like the *smaller* release, and be deleted at 11% â€” discarding a third of a
38 GB download because of how little of it exists yet. That inversion is the
thing to avoid, and `test-dedup.ps1` pins it with a cluster whose totals and
fetched byte counts run in opposite directions, so the two readings cannot both
pass.

A total size of **0** means the size is *unknown* â€” a magnet that has not fetched
its metadata â€” not that it is the smallest release in the room. Those are skipped
by dedup rather than treated as smallest, so rule 2's availability test and its
60-minute grace period cannot be side-stepped by a size comparison.

Three boundaries are deliberate and must not drift:

- **A version bigger than the keeper survives.** Finishing the small copy is not
  a reason to throw away the large one still downloading. This is what keeps the
  38 GB Ripley REMUX alive while the 17 GB 1080i is the finished one.
- **A cluster with no finished member is untouched.** Downloading two
  qualities of the same episode is not a duplicate problem yet â€” neither copy
  exists to make the other redundant.
- **A version whose total size is unknown is skipped.** See above.

**Equal-sized copies are not "smaller"** and are kept, which is the one case
where the rule declines to act.

The keeper must itself still be alive: a version already removed earlier in the
run by the DoVi or stalled rule cannot go on protecting its group.

> Consequence worth being comfortable with: an incomplete copy at 99% is
> deleted when a bigger version is finished. You lose the partial download and
> keep the finished, larger one. There is no near-complete exemption.

### Episode sets: packs compete only on an identical range

A release covering a **range** of episodes â€” `S01E01-10`, `S01E01-E10`, `1x01-10`,
`E01-E08` â€” is a pack, not a version of one episode. So before the rule runs,
every member of a group is sorted into the exact **set of episodes** it carries,
and the rule is applied inside each set. That key is what the comparison is
allowed to see:

| set | release |
|-----|---------|
| `film` | not a series â€” the group has already decided these are the same work |
| `S3-E7` | one episode |
| `S3-E1-E10` | a pack of episodes 1 to 10 |
| `S3-ALL` | a pack that names a season and no episode: the whole season |

Two releases are only ever weighed against each other when that key reads the
same on both sides.

A group is keyed on the first episode alone, so `its always sunny in philadelphia`
really does hold single episodes *and* packs of every range that begins at
episode 1. Printing those as one block, under a header reading `S18E1-E8`, claims
that two dozen releases cover episodes 1 to 8 when most of them do not.

So the report is printed **one group per episode set**, and judging and printing
are the same loop: a release is only ever weighed against others holding the same
episodes, under a header built from the key it was weighed under. The header is
the show name plus exactly what the set key says:

| set | printed header |
|---|---|
| `film` | `the talented mr ripley` |
| `S3-ALL` | `breaking bad S3` |
| `S3-E7` | `breaking bad S3E7` |
| `S3-E1-E10` | `breaking bad S3E1-E10` |

Sets are walked in episode order rather than as text, because `S1-E1-E10` sorts
before `S1-E1-E2` and that would print a ten-episode pack above a two-episode
one. A header therefore describes its own rows and nothing else: it cannot claim
episodes none of them hold.

**Packs with the same range do deduplicate.** Same range means same episodes, so
one really is a spare copy of the other: a finished 60 GB `S01E01-10` removes a
unfinished 24 GB `S01E01-10`, and the ordinary size rule applies unchanged â€” the
keeper is the largest finished member of that set, and everything smaller goes
whether or not it is itself finished.

**A pack is never comparable with a single episode, nor with a pack of a
different range.** Both comparisons would be wrong, and in the same direction:

- A pack is always the largest thing in the room by a wide margin, so as a
  candidate keeper against a single episode it would delete every finished
  episode standing next to it. A finished 60 GB pack of episodes 1â€‘10 would
  "beat" a finished 8 GB episode 1 and remove it.
- As a deletion candidate it is never redundant. A finished episode 1 does not
  cover a pack of episodes 1â€‘10, and a finished `S01E01-10` does not cover a
  40 GB `S01E01-06` â€” so "a bigger version is already finished" is simply false
  for the episodes the smaller one holds and it alone.

The range is read by the parser, not cleaned up afterwards. That distinction
matters: the pattern used to match only `S01E01` and then remove it, which left
the range end behind as ordinary title text. `S01E01-10` was filed under the
show **`widows bay 10`** and `S01E01-06` under **`widows bay 06`** â€” one series
split into two invented shows, so overlapping packs could never be compared at
all, and every pack printed a different name.

A pack that names a season but no episode â€” `S01`, `s18`, `Season01`,
`Season 1 Complete` â€” covers every episode of that season. There is no episode
to record, so the parser sets episode 0, the season is lifted out of the title,
and the key comes out as `S18-ALL`. That matters twice over. Semantically it
stops such a release being called a film, and in practice it lets two packs of
the same season meet however they spelled it: `Its Always Sunny In Philadelphia
s18 WEB-DL 1080p` and `Its.Always.Sunny.In.Philadelphia.s18.HD1080p.WEBRip` used
to file under two different titles and never see each other. They are genuine
rivals, same episodes, so the ordinary size rule applies to them like any other
pair in the same set.

The digits must form a real number, so a group tag is not mistaken for a season â€”
`-S0NNER` and a trailing `x264-S0` stay films. Leading zeros are allowed, because
seasons are padded as often as not and a padded season is still a season. An
episode number always wins over the bare-season reading, so `S01E01` is episode 1,
`S01E01-10` is a range and `Se5` is a single episode. This branch only runs when
there is no episode marker anywhere in the name.

### What the show name in a header is allowed to contain

A header is `show name + season | episode | pack`, and it has to describe its own
rows. That puts four things outside the show name, and each of them was getting
in:

| Torrent | What it used to be filed as | What it is now |
|---|---|---|
| `Its.Always.Sunny.In.Philadelphia.S18E01-E04.HD1080p.WEBRip.Rus` | `its always sunny in philadelphia hd1080p`, and one group spanning four episode sets | `its always sunny in philadelphia S18E1-E4` |
| `Euphoria.S03.Dub E01-E08` | `euphoria s03 dub`, season 1 | `euphoria S3E1-E8` |
| `Its.Always.Sunny.In.Philadelphia.S18E01E02.1080p.ColdFilm` | `its always sunny in philadelphia s18e01`, season 1 episode 2 | `its always sunny in philadelphia S18E1-E2` |
| `Its.Always.Sunny.In.Philadelphia.S18E03.720p.Ru.Ultradox` | `it s always sunny in philadelphia` | `its always sunny in philadelphia S18E3` |

**The show name is the text in front of the marker.** So the episode title and
every technical tag after it are gone by construction, and a season stated
earlier in the name is honoured even when the marker is a bare `E..`:
`Euphoria.S03.Dub E01-E08` is season 3, and the title is cut at that season, so
`s03 dub` goes with the marker instead of sticking to the show.

**An apostrophe is part of the word, so it is dropped, not turned into a space.**
That matters more than it looks. The clustering pass groups a show family by the
*first word* of the show name, so `it` and `its` were two families, `S18E3`,
`S18E5` and `S18E6` each printed as two groups, and 22 releases could never be
weighed against the better copy sitting in the other one. A few release groups
lose the apostrophe *before* qBittorrent sees the name: `It s Always Sunny in
Philadelphia` carries no apostrophe at all, just a space, and nothing can drop
what is not there. Those are rejoined by exact match, never by resemblance: a
show name that equals **another show name in full** once one internal space is
removed is the same show, and only if exactly one candidate does.

**The compact range `S18E01E02`** gets its own pattern. It cannot be folded into
the `S01E01-10` pattern, which ends at the episode number and then insists the
next character is not a word character, and the `E` of `E02` is one. Matching
nothing at all let the bare-`E` pattern claim the `E02` half instead, which filed
the release as season 1 episode 2 under `its always sunny in philadelphia
s18e01` -- a season welded onto the show name, in a season nobody else was in, so
it could never be compared with anything. The guard on that bare-`E` pattern
refuses a **digit** in front, not any word character: that is what rejects the
`E02` inside `S18E01E02` while still reading a space in `Breaking Bad E05`, a dot
in `Show.Name.E01` and the letter `S` in `Se5` as an episode rather than a season.

**A year printed on one release does not block one that prints none.**
`Its Always Sunny in Philadelphia S18E04 2026 A Virtual Insanity` and
`Its.Always.Sunny.in.Philadelphia.S18E04.1080p.rus` are the same episode, but
demanding equal years split them into two groups that could not see each other,
and the group printed twice: `(2026) S18E4` above three rows and `S18E4` above
two. Two *different* stated years still refuse the match, which is what keeps
`The Office US` from ever meeting `The Office UK`.

**The year appears in a header only when every member states the same one.** It
is there to tell two remakes apart, but taking it from whichever member sorted
first would put `(2026)` above rows that never claimed a year at all.

### One episode, several titles

Dedup only ever compares inside a group, so two copies of the same episode have
to land in the same group first. For series that was not happening, because
releases name the episode inconsistently and sometimes not at all. One season of
one show reached the parser as four different titles:

| Torrent name | What the parser made of it |
|---|---|
| `Ted Lasso S04E08 MULTI 1080p WEB H264-HiggsBoson` | `ted lasso` |
| `Ted.Lasso.S04E08.Follow.the.Anger.2160p...BlackTV` | `ted lasso follow the anger` |
| `Ted.Lasso.S04E09.Mae.sull.autobus.ITA.ENG...MeM` | `ted lasso mae sull autobus ita eng` |
| `Ted.Lasso.S04E09.1080p.WEB-DL.DUAL.5.1` | `ted lasso` |

Four titles means four groups, and a finished 1080p ended up in the library
beside a finished 2160p of the same episode. Note the Italian and English names
for S4E09 â€” they share **no suffix at all**, so nothing that compares the ends of
two titles would ever pair them. Only `ted lasso` is common to both.

A second clustering pass fixes this, for series only. Each group gets a show
name â€” the run of leading words its own members agree on â€” and groups of one
season-and-episode within one show family are joined.

**Different shows cannot merge.** The family is the *first word* of the show
name. `ted lasso` and `its always sunny in philadelphia` fall in different
families, so no rewording of either can produce a merge. Since a family is decided
by a single word, names that merely share an opening word would otherwise be
compared on that word alone â€” `the office` and `the bear` would share family
`the`. A suffix that appears on more than one episode is
read as part of the show's name rather than an episode title and never joins
anything, which keeps `ted lasso spin off` separate from `ted lasso` once two of
its episodes exist. Films never enter this pass, so film grouping is unchanged.

**And it has a known cost.** Translated releases of one show land in different
families and are never compared. On a live queue: `widows bay`,
`widows bay vdovina zÃ¡toka`, `wdowia zatoka widows bay` and
`o segredo de widows bay` are the same show in four languages, and their first
words differ, so the guard keeps all four apart. The dedup rule therefore weighs
`widows bay`'s 21 packs against itself and never against the other three's
contents. Nothing derivable from titles fixes this â€” `zÃ¡toka` means `bay`, and
only a human knows that â€” so the fix is an explicit alias list rather than a
looser rule.

**One name per show, not per episode.** A family has one canonical name â€” the
longest run of leading words all its members agree on â€” and `status.ps1` prints
that for the whole show. It matters because the merge was already correct and the
*label* was not: each merged cluster used to be named after its own first member,
and which cluster won differs per episode, so one show printed as four groups
(`euphoria`, `euphoria us`, `euforia euphoria (2019)`, `euforie euphoria (2026)`)
even though every one of its clusters already held both titles. The rules were
comparing them correctly throughout; a wrong name simply reads as four shows.

Packs are included in this naming even though the merge skips them: a pack must
never merge with a single episode â€” that is a correctness rule â€” but it plainly
belongs to a family for naming. `Set-FamilyLabels` is **display only**: no
verdict, no cluster, no comparison and no deletion reads `showLabel`, and
`test-queue-window.ps1` asserts that the dedup pass never mentions it.

One case stays ambiguous and is not fixable from titles alone: a show named
exactly like another show plus extra words, present for a single episode only.
`ted lasso` and `ted lasso spin off` at S4E8 are indistinguishable from `ted
lasso` and `ted lasso follow the anger` at S4E8, because nothing in either title
says whether the trailing words name the show or the episode. The
repeated-suffix guard catches such a show as soon as a second episode appears.

`test\test-clustering.ps1` covers all of this, including the two bugs that made
this pass look inert while it was in fact merging: arrays unrolled on the way in
(every show name came out empty) and again on the way out (merged groups arrived
as their members). A third, subtler one is covered too â€” measuring a suffix per
pair rather than against one show name made an ordinary episode title look like a
repeated suffix, and blocked the very merge it was meant to police.

### The same episode twice in one season folder

Rule 4 cannot see this, and neither can anything keyed on the show name. A
measured loss: **7 duplicated episodes, 10,5 GB**, every copy finished, every
copy in the library. Rule 4 compares inside a group, and a group's family is the
first word of the show name â€” so `its always sunny in philadelphia`,
`c'Ã¨ sempre il sole a philadelphia` and `www.uindex.org - â€¦` are three groups of
one show that never meet.

The **library folder** is what makes the comparison possible without a heuristic.
The manager put those files in that folder itself: `Get-LibraryTargetDir` already
decided they were one show, so the folder is a grouping already proven, arrived at
by a different route than the family guard. Two files in the same season folder
claiming the same episode are the same episode by construction.

Two files claiming one episode â†’ the **larger is kept**, the smaller deleted. A
tie is **held**, never broken by a coin toss on someone's media. The season comes
from the folder and the episode from the filename, never cross-checked â€” `e01 -
Frank Marries a Corpse.mkv` states no season at all and parses as season 1, so
requiring a match would reject exactly the half of the pair that must be
recognised.

#### A duplicate inside a pack does not delete the pack

The file is the duplicate; the **entry** is not. A pack is the only record of its
other episodes, several of which are usually wanted and sometimes the only copy
anywhere. So deleting the entry to remove one duplicate file would trade a tidy
folder for lost media.

The pack's remaining episodes are counted against the **library**, not against its
own file list:

| the pack's other episodesâ€¦ | outcome |
|---|---|
| not in the library at all | `delete-file-only` â€” the file goes, **the entry stays** |
| in the library, held only by this pack | `delete-file-only` â€” same |
| in the library, another release holds them | `delete` â€” the entry goes with its data |
| unowned, or a single-episode torrent | `delete` â€” the entry goes with its data |

Counting against the library is the direction that errs safe. Deleting an entry
whose episodes exist nowhere else is unrecoverable; leaving one duplicate file
behind is merely untidy.

A pack must be **stopped** before deletion and is never restarted â€” same
discipline as every other deletion here, and it matters most for a pack, because a
running pack re-fetches the file just deleted and the duplicate returns next run.

### Retention

Two things accumulate on their own and are now destroyed on a fixed age:
`backupMaxAgeDays` and `logRetentionDays`, **both 7 days**.

The manager writes a `.bak` beside each file it rewrites, and one
`manager-YYYY-MM-DD.log` **per day**. Nothing rotates or overwrites either, so
without a cap both totals only ever climb. The logs looked harmless at first â€”
one day was 3,9 KB â€” but a busy run logs a line per torrent, and 258 of them is
tens of kilobytes a pass, several passes a day. Small and unbounded is still
unbounded, and it sits on the same volume as the media.

**Everything in `logs\` goes, with one exception.** The sweep is unfiltered:
`manager-*.log` files, `deleted-*.csv` worksheets, anything else in there.
Non-recursive on purpose â€” `logs\` holds flat files the manager wrote, and a
recursive delete in a directory that also receives writes is a bad shape to leave
lying around.

The single exception is **today's own log**, skipped by name. That is not a
retention opinion: the run doing the deleting is appending to that file as it
goes, and removing it mid-run would take the current run's own record with it.

An earlier version filtered to `manager-*.log` and spared the
`deleted-2026-10-05T0813.csv` worksheet, on the claim that it was the only record
of the **205 torrents deleted on 2026-10-05**. That claim did not survive
checking â€” the file stores `Name`, `HashFirst8`, `Reason`, and **8 hex characters
is not the 40-character infohash**, so it cannot re-add anything by hash or by
magnet. It is a diagnostic list of what was deleted and why, worth 33 KB, and it
now goes on the same clock as everything else.

Both reapers honour `-DryRun`: they print what they would remove and change
nothing. `test\test-log-reap.ps1` plants real file timestamps around the cutoff
and asserts the worksheet **is** destroyed, on a second pass and in a dry run, so
the old filter cannot quietly come back.

### The orphan reaper

This is the one rule that deletes bytes **qBittorrent does not know about**, so
it is fenced in harder than the rest. It exists because removing a torrent by
hand, or a delete that half-failed, leaves its data behind, and that is how
`Downloads\temp` came to hold 82 GB of nothing. It runs **last**, after every
deletion and every move, so it judges the state the run actually left behind.

An entry under `reapRoots` is reaped only if **all** of these hold:

- **No torrent claims it.** A torrent claims a path when its `content_path`
  equals it, sits inside it (a multi-file torrent names the file), or contains
  it. Both sides are compared as strings from the same UTF-8 API read, so the
  decision never depends on `Test-Path` resolving an accented or CJK name
  correctly.
- **It has been untouched for `reapMinAgeHours`.**
- **It is not the library.** `moviesDir` and `seriesDir` are excluded
  regardless of what `reapRoots` says.
- **It is not a link.** A junction could send the recursive delete outside the
  root, and nothing in its name says where it points.

`save_path` is deliberately **not** treated as a claim. Torrents share one
save_path â€” 11 of 18 on this box point at `Downloads` â€” so using it would mark
every entry as in use and the reaper could never fire. `content_path` is the
only per-torrent statement about where its own bytes live.

If any torrent that has actually downloaded bytes reports no `content_path`,
the whole pass is **skipped** for that run, with the reason logged. An
unlocatable download cannot be told apart from an orphan, and leaking a folder
for a day is recoverable while deleting a download in progress is not. A magnet
holding no bytes is exempt: its empty `content_path` proves nothing.

The delete itself re-checks that the path is still strictly inside a reap root,
so a root can never delete itself and a caller cannot pass in an arbitrary path.

`status.ps1` shows the candidates and the total, so the decision is visible
before it is made rather than only in the log afterwards.

## Library folder names

Show folders are **title-cased**: `its always sunny in philadelphia` is stored as
`Its Always Sunny In Philadelphia`. Every word is capitalised, short ones
included, so `in` becomes `In` and `the` becomes `The`. Only the first letter of
each word is touched, which keeps accents intact (`ZÃ¡toka`, never `ZATOKA`) and
leaves any capital that was already there alone. Films are unaffected - a film is
a file named after its own torrent, not a folder.

An existing folder **keeps its own spelling**. `Resolve-LibraryShowDir` returns
the directory that is already on disk, matched case-insensitively, and only falls
back to the capitalised name when no folder exists yet. Both library rules reach
the season folder through that same resolver, so the duplicate rule and the
redundant rule cannot look in a different folder than the mover writes to.

**Apostrophes do not come back.** The parser strips them on purpose, because that
is what lets `It s` and `Its` match one show, so the folder is `Its Always Sunny
In Philadelphia`. Restoring them is not derivable from the title.

### Renaming a show folder

Two steps, and the order matters.

**Rename the directory via a temporary name.** A direct case-only rename is
refused, because Windows compares the two paths case-insensitively and sees the
same path:

```
Rename-Item -LiteralPath $old -NewName 'Ted Lasso'
-> The source and destination paths must be different.
```

Two real renames are not the same thing as one, so go via a throwaway name.

**Repoint qBittorrent with the `save_path`, not the `content_path`.**
`torrents/setLocation` takes the directory the torrent's folder is placed *in*.
For a multi-file torrent at `Season 4\<torrent name>\`, that is `Season 4`.
Passing `content_path` instead moves each torrent's folder **into itself**:

```
before:  Season 4\<TN>\<file>.mkv
after:   Season 4\<TN>\<TN>\<file>.mkv
```

No bytes are lost and the counts still reconcile, so nothing looks broken - the
library is just one level deeper. This happened during the `Its Always Sunny In
Philadelphia` migration and was fixed by repeating the call with the parent.

**Where the move actually relocates data, the new casing sticks** - both `Ted
Lasso` torrents now record the capitalised path. **Where the destination resolves
to where the files already are, the call is a no-op and the recorded casing does
not change**: the five `Its Always Sunny In Philadelphia` torrents still show the
old spelling in the qBittorrent UI. That is cosmetic, not breakage - Windows
opens either spelling, every path comparison here is case-insensitive, and the
file is present either way. Forcing it would mean moving 17 GB to relabel a
string.

A **200 from `setLocation` proves nothing** - it answers when the move is
*queued*. Re-read the torrent and confirm `content_path` exists before believing
any of it. The migration scripts snapshot every file and byte total in the folder
before and after each individual call.

## Title matching

Scene names follow `Title.Year.Source.Resolution.Codec.Audio.Group`, so the
real title is everything before the first technical or year marker. What
survives is compared by **token containment**, not string equality.

Guards, all covered by `test\test-parsing.ps1`:

- year must match;
- sequel numbers must match, so `Terminator 2` never matches `Terminator 3`;
- containment only tolerates extra words when they are *soft* qualifiers
  (country / language codes) **and** the shorter title carries none of its own,
  so `The Office` matches `The Office US` but never `The Office UK`.

Matching is deliberately biased towards false negatives. A missed duplicate is
harmless; a false match deletes the only copy of something.

## Running it by hand

```powershell
cd <your-clone>\qbt-manager

# see what it would do, change nothing
powershell -NoProfile -ExecutionPolicy Bypass -File .\qbt-manager.ps1 -DryRun

# dedup restricted to one title
powershell -NoProfile -ExecutionPolicy Bypass -File .\qbt-manager.ps1 -Only 'some title'

# self-tests
powershell -NoProfile -ExecutionPolicy Bypass -File .\test\run-all.ps1

# live status panel
powershell -NoProfile -ExecutionPolicy Bypass -File .\status.ps1
```

If qBittorrent is not running the script logs the miss and exits non-zero
without touching anything.

## The schedule

```powershell
Get-ScheduledTask      -TaskName 'qbt-manager'
Start-ScheduledTask    -TaskName 'qbt-manager'
Get-ScheduledTaskInfo  -TaskName 'qbt-manager'
Stop-ScheduledTask     -TaskName 'qbt-manager'      # pause
Disable-ScheduledTask  -TaskName 'qbt-manager'      # pause permanently
Enable-ScheduledTask   -TaskName 'qbt-manager'
```

Triggers: every 15 minutes, indefinitely; plus once 45 seconds after logon,
which covers qBittorrent starting with Windows.

## Tuning

Edit `config.json`. Useful changes:

- `stalledDeleteDays` â€” how long a download may make no progress before it is
  deleted. `0` disables the rule. Raising it is the safe direction if a swarm
  you care about gets deleted during a long outage.
- `metadataTimeoutMinutes` - how long a magnet may report no size. Currently `30`.
  Counted only while the magnet is inside the queue window below, and shared with
  the drain so the two never disagree.
- `metadataPriorityRankLimit` - how many queue positions rule 2 may judge. `10`
  means only magnets qBittorrent is actually working can be deleted for having
  no availability. `0` removes the window and makes rule 2 judge every
  metadata-less magnet on its age alone, which is the behaviour that deleted 205
  queued torrents in one run. Raise it if a long queue is starving the front.
  This also sets where the drain starts: it always begins at limit + 1.
- `queueDrainEnabled` - whether the drain runs behind the window. `false` leaves
  magnets past the window untouched, so a dead one at position 11 stays forever.
- `stallCleanupEnabled` - whether rule 4b runs. `false` leaves a stalled client
  and its queue entirely alone.
- `stallConfirmSeconds` - how long global download velocity must read 0 before the
  client counts as stalled. `60`. `0` disables the rule, because a single sample
  cannot distinguish a stall from a lull.
- `stallMaxWaitSeconds` - ceiling on the in-run wait used to prove the stall. `75`,
  above the confirm window so one run can finish the job. Kept under the 15-minute
  schedule so a run can never overlap the next.
- `stallMaxDeletions` - most magnets removed in one stalled-client sweep. `10`. The
  cap is what stops a 195-magnet queue being emptied.
- `stallInternetProbeUrl` - the URL used to prove the internet is up.
  `https://www.cloudflare.com/cdn-cgi/trace`. Must answer **any** HTTP status;
  only a failure to respond counts as down.
- `backupMaxAgeDays` - how long a `.bak` backup survives. `7` now. `0` disables
  the backup reaper.
- `logRetentionDays` - how long a file in `logs\` survives. `7` now, matching the
  backups. `0` disables the log reaper and logs then grow without bound again.
  Everything in that folder is swept â€” logs and `deleted-*.csv` worksheets alike â€”
  except today's own log, which the run in progress is still writing to. See
  [Retention](#retention).
- `apiConnectTimeoutSeconds` / `apiGetTimeoutSeconds` / `apiPostTimeoutSeconds`
  â€” per-call ceilings. The defaults are sized for loopback, which answers in
  about 40 ms when healthy, so there is nothing to gain by making them long.
- `apiAttempts` â€” retries for a call that connected but did not answer. Keep it
  low; a refused connection is never retried at all.
- `apiFailureBudget` â€” consecutive failures that end the run. Lower is safer.
- `deleteDataFiles: false` â€” stop deleting data, remove torrents only. The
  stalled rule deletes partial data regardless, since a week-old partial
  download is what filled `Downloads\temp` with orphans in the first place.
- `moveCompletedToLibrary: false` â€” stop relocating finished downloads.
- `moveVerifySeconds` / `moveVerifyPollMs` â€” how long the library rule waits for
  a move to be confirmed, and how often it asks. A move on the same volume is a
  rename and confirms immediately, so the ceiling only matters when a move is
  genuinely stuck.
- `reapOrphans: false` â€” stop removing download leftovers entirely.
- `reapMinAgeHours` â€” how long a leftover must be untouched before it is
  reaped. Raise it if you ever stage something there by hand.
- `reapRoots` â€” the directories scanned. Keep it to the staging area; anything
  wider increases the cost of a mistake.
- `doviPatterns` â€” extend or narrow what counts as Dolby Vision.

Dedup has no tuning knob. It used to have `duplicateTolerancePct`, which gated
how far apart two sizes could be and still count as duplicates; at 10% an
incomplete copy 50% smaller than a finished one survived, which defeated the
point of the rule. The key is gone from `config.json` and ignoring it is safe â€”
the manager and the status preview no longer read it.

## When the API misbehaves

The manager is unattended, so how it fails matters as much as what it decides.
Three faults are handled differently on purpose, because treating them the same
is what makes an automated job slow and alarming:

| Fault | curl | Response |
|---|---|---|
| qBittorrent is not running | 7 | Reported as a **warning, exit 0**. Nothing was changed. Not an error - the app may simply be closed. |
| API took the connection but did not answer | 28 | Two attempts with a backoff, then **exit 2**. |
| API dropped part way through a run | 28 | **Circuit breaker**: after `apiFailureBudget` consecutive failures the run stops with **exit 3**, rather than repeating the same wait for every remaining torrent. |

The breaker is the important one. Without it a run against a wedged API would
sit out its timeout once per remaining torrent, turning a 15-minute cycle into
something far longer - and the task is `IgnoreNew`, so the cycles after it
would be silently dropped.

On a repeated API failure the run **stops** rather than continuing. Issuing
deletes and moves against an API that is not answering can only leave a
half-applied set of changes, which is worse than none.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Ran to completion - *or* qBittorrent was closed and there was nothing to do. |
| 1 | Unexpected failure. |
| 2 | An API call failed after its retries. |
| 3 | The API stopped responding; the run was stopped early. |
| 4 | Another run already holds the lock. |

### One run at a time

The manager takes `manager.lock` before reading anything, so a run started by
hand cannot overlap a scheduled one - two runs working from the same list can
each decide to delete the same torrent and then each try to move what is left.

A stale lock is not a problem: the PID inside it is checked, and a lock whose
owner is gone is cleared rather than waited on. An abandoned lock therefore
cannot wedge the schedule. The loser of a race exits **4** and changes nothing.

**The log is written independently of the lock**, because the lock cannot cover
it. `Write-Log` fires before the lock is taken â€” it is how the run announces
itself â€” so both processes reach the log before either holds it, and a schedule
that fires every 15 minutes overlaps a manual run routinely.

`Add-Content` holds its handle for the whole run, so the second process threw
`GetContentWriterIOError` on its very first line and died with exit 1, before
doing any work. Logging now opens a fresh handle per line with read/write/delete
sharing, retried once, and is **never fatal**: a run whose log is momentarily
unavailable still does its work and says so once on the console. Losing a log
line is recoverable; crashing before the first decision is not.

## API notes

- Base `http://127.0.0.1:8080/api/v2`, `Referer` header required (CSRF on).
- Loopback auth is bypassed, so no password is needed.
- curl output is read from a temp file as explicit UTF-8. Letting it stream
  into the PowerShell pipeline corrupts accented names, because PS 5.1 decodes
  native output using the console code page.