# Tension-led loop: rehearsal record and adoption (ENG-96)

Operating guide: [tension-led-operating-guide.md](tension-led-operating-guide.md).

## Status, stated plainly

| Evidence | State |
| --- | --- |
| Executable two-publication, three-opening rehearsal through the Discord dispatcher, domain, PostgreSQL and outbox (fake transport) | **Done**: passes, see below |
| Explicit adoption path and quest-free entry points | **Done**, automated LiveView/dispatcher coverage |
| Live disposable Discord server rehearsal (real gateway, real threads, real players) | **Not run.** No disposable server, bot token, guild/application IDs or player accounts were available to this run. Nothing here is live Discord evidence |

The live rehearsal is still required before adoption sign-off (issue acceptance 1–3).
The checklist at the end lists exactly what to run and record.

## Defect found and fixed: quest-free players were not invited to play

Before this change, the opening overview in every campaign:

- listed every quest-free character as `Name: No quest decision required.`;
- told everyone only to `Run /quest … for your private quest`;
- never mentioned Tension threads, `/intent` or `/chronicle`.

`/quest` without a quest replied `No quest assigned yet. Try /quest again after
your DM assigns one.`, which implies waiting. Tension thread briefings themselves
were already correct (they explain discussion vs `/intent` confirmation).

Fix: the smallest explicit cutover. A DM-only, per-campaign
`tension_participation` flag (migration default `false`) is toggled on the
dashboard. When it is adopted:

- the opening overview (renderer v3) says anyone can take part without a quest,
  points to threads, `/intent` and `/chronicle`, and lists only characters with an
  outstanding quest decision (with the existing `/quest` guidance);
- `/quest` without a quest says none is needed and points to `/intent view`.

Not adopted (default): wording is byte-identical to before. No campaign is
reinterpreted, no quest is removed, no history is migrated; saved briefings stay as
sent. Toggling changes the opening input digest, so stale previews cannot be opened.

## Executable rehearsal (automated; not live)

`test/async_worlds/tension_rehearsal_test.exs`. Commands go through
`Discord.Dispatcher.handle/2` with real interaction envelopes. Domain, PostgreSQL,
close/review/publication and `DeliverDiscord`/`OpenTensionDiscussion` workers
are real; the Discord transport is the supervised `FakeAdapter`.

```sh
MIX_ENV=test mix test test/async_worlds/tension_rehearsal_test.exs --trace
```

Cast: Rook (quest-free, contributes to several Tensions), Wren (revises, then
withdraws), Absent (never participates). Tensions: **Battle in the Reach**
(public tug-of-war balance 4/8, known *Elven supply*, hidden reinforcements +1/tick)
and **Threatened harvest** (public Blight +1/tick, nobody tends it at first).

| # | Step | Expected | Observed (automated) |
| --- | --- | --- | --- |
| 1 | Legacy campaign prepares opening; `/quest` as Rook | Old wording unchanged | Old wording; "after your DM assigns one" |
| 2 | Non-DM adopts; DM adopts; open the earlier preview | Unauthorized; adopted; stale | As expected |
| 3 | Prepare + open tick 1 (adopted) | "without a quest", `/intent`; no "No quest decision required" | As expected; `/quest` says none is needed |
| 4 | Battle thread create returns unknown result | Stops as ambiguous; no blind second create | `recovery_required`, `ambiguous` |
| 5 | DM binds the real thread via recovery API | Bound, briefing posts | Thread `9101` bound; harvest gets `9102` |
| 6 | Battle briefing content | Public fill, known name only, no hidden clock | `4/8`, "Elven supply", no `3/4`, no hidden name |
| 7 | Rook confirms Battle (Ash Company + lords) and Harvest | Two confirmed efforts, no cap | As expected |
| 8 | Wren confirms, revises, stale confirm, reconfirms; confirms + withdraws Harvest | Stale write rejected; withdrawal recorded | "Nothing changed: stale version"; "withdrawn" |
| 9 | DM `/intent roster` | Revised text visible, Absent shown absent | As expected |
| 10 | Thread post fails (forbidden), DM retries | Failed then sent; tick still open | As expected |
| 11 | Before close | No clock moved | `4, 0, 0` |
| 12 | Close; late edit | Frozen roster incl. absent; late edit rejected | `tick_closed`; absent frozen |
| 13 | Synthesis note + deferral; Event *The Ash Company holds the crossing* (balance −2, opens public *The wounded captain* as follow-on); narrative-only *Crows gather over the lowlands* | Draft only: no live change, empty player chronicle | `4, 0`; chronicle empty |
| 14 | Publish; publish again | Applied once; `already_published` | balance 2, reinforcements 1, blight 1, supply 3 |
| 15 | Restart transport process; drain outbox | All pending deliveries sent from DB | All `sent`; player chronicle has both Events, no DM note |
| 16 | Open tick 2 | Battle thread reused (no create); captain gets own thread; briefing shows 2/8 | As expected; overview still Tension-led |
| 17 | Rook commits to captain + battle; Wren missing; Resolution *The harvest is brought in*; Event *A healer reaches the captain* | Harvest resolved, battle ongoing, unattended pressure continues | reinforcements 2, blight 2 and paused, balance 2 |
| 18 | Open tick 3 | Harvest thread historical; battle still asks for discussion | "Historical — resolved"; "Discuss plans" |
| 19 | Chronicle by captain / harvest / Rook; `/chronicle show` as another player | Origin → development chain; involvement; follow-on link | As expected |
| 20 | Every public delivery and thread intent | No private intent, asset text, DM note, hidden clock or known fill | No leaks |

Result on this run: `2 tests, 0 failures`. Full gate: see the handoff for the
`mix precommit` count.

## Resources (acceptance 4, ENG-97 gate)

In the scripted rehearsal, descriptive commitments ("the Ash Company and the
neighbouring lords", "my own coin") were enough for the DM to write the Events.
The same company in two Tensions shows up through the existing **Also contributing**
links. **No concrete tracking problem was observed.** That is weak evidence because
a script cannot forget an asset. Keep ENG-97 deferred. Re-check it only after the
live rehearsal, recording any asset the DM lost track of.

## Residual limitations and observations

- **Live Discord unverified:** real thread permissions, archive behaviour, rate
  limits, mobile slash-command ergonomics and how lively it feels need the live run.
- **ID friction:** players type tick/Tension IDs and version numbers from the
  briefing. It works and is safe, but a live run should judge whether it is too clunky.
- **Inconsistent option types:** `/chronicle … tick:` is a string option while `/intent … tick:`
  is an integer; harmless, but noticeable to players.
- "Restart" here restarts the transport process and replays durable outbox state,
  not a whole BEAM/container restart. The live checklist covers a real restart.
- The fake adapter returns fixed thread IDs unless told otherwise; distinct IDs were
  injected per Tension.

## Reconciliation with older plans (recommendations only)

No issues were moved or cancelled. Disposition for Callum to decide:

| Issue / plan | Relationship to Tension-led loop | Recommendation |
| --- | --- | --- |
| ENG-67 Announce authored selections/revisions publicly | Public quest-choice announcements; Tension intentions are deliberately private, and discussion already happens in threads | **Cancel or park.** Revisit only if legacy quest campaigns need it |
| ENG-68 Custom proposals against authored choices | Superseded: freeform `/intent` + DM adjudication covers "propose another approach" without nodes | **Cancel (superseded)** |
| ENG-69 One-off fixed/rolled custom actions | Superseded by Events with staged clock/Tension changes; dice are optional | **Cancel (superseded)** |
| ENG-70 / ENG-71 Character-specific quest path adaptation | Quest-only authoring depth; nothing in the Tension loop needs it | **Park** in a quest-maintenance backlog; don't schedule |
| ENG-72 Rehearse improved (quest) interactions | Its live-rehearsal intent is covered by ENG-96's live checklist | **Cancel**, linking here |
| [flexible-actions-plan.md](flexible-actions-plan.md) | Already marked superseded by [tension-led-world-play.md](tension-led-world-play.md) | Keep as history |
| "Separate lore retrieval work" | No dedicated Linear issue found (searched lore/knowledge/notes). Closest: ENG-77 (empty), lore notes idea in [entity-consolidation-evaluation.md](entity-consolidation-evaluation.md). `/chronicle` now covers explorable *history*, not static lore | Write a scoped issue only if players ask for static lore during the live run |
| ENG-97 Named resources/influences | Conditional; gate not met | **Keep deferred** |

## Live rehearsal checklist (still to run)

Prerequisites: a disposable Discord server and bot application, `DISCORD_ENABLED=true`,
`DISCORD_BOT_TOKEN`, `DISCORD_GUILD_ID`, `DISCORD_APPLICATION_ID`, OAuth settings,
a disposable database, and the migration plus command registration (see
[operations.md](operations.md)). Use 2–3 real player accounts, or `/debug player` personas.

Record for each item: time, expected, actual, a screenshot or message link (only
from the disposable server), and any defect.

1. Adopt on dashboard; prepare + open tick 1; read the overview and threads as a quest-free player; `/quest`.
2. One player confirms in two Tensions; another revises, then withdraws; one stays absent.
3. Remove the bot's thread permission, let a post fail, restore it, retry from Deliveries.
4. Archive a thread mid-tick, then unarchive and retry.
5. Restart the app container between close and publish; confirm drafts, roster and pending deliveries survive.
6. Adjudicate the Reach battle plus a narrative-only Event and a follow-on Tension; publish; click publish again.
7. Tick 2: thread reuse, follow-on thread, Resolution of the unattended Tension, a known and a hidden clock.
8. After a second restart, players use `/chronicle` and confirm nothing private appears.
9. Note whether any committed asset was hard to track (ENG-97 gate) and whether it felt alive.
