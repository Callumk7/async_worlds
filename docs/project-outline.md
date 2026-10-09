# Tick & Clock — Discord Campaign Engine: MVP Spec

9 Oct 2026 · @Callum

## Overview

A Discord bot plus a DM-only web admin that moves a D&D campaign forward between sessions in discrete **ticks**. Each tick, players make choices in personal quest-lines and assign resources against world **clocks**; the engine resolves everything, the DM reviews and edits, then results are published.

**Goals for the MVP**

- Players can take one meaningful quest action and commit their resources each tick, entirely from Discord.
- The world advances on its own through background clocks, so the setting feels alive between sessions.
- The DM keeps final say: nothing reaches players until the DM approves it.
- Quest content can be authored and edited without touching code.

**Non-goals for the MVP**

- Replacing live sessions or running combat.
- Automated scheduling of ticks.
- AI-generated narration.
- Supporting more than one campaign per Discord server.

## Core concepts and data model

Seven entities carry the whole system; everything else is derived from them.

|               |                                                                                                        |                                                 |
| ------------- | ------------------------------------------------------------------------------------------------------ | ----------------------------------------------- |
| Entity        | Key fields                                                                                             | Notes                                           |
| Campaign      | id, Discord guild id, DM user id, public channel id, current tick number                               | One per Discord server.                         |
| Tick          | number, status (open / resolving / in review / published), opened at, closed at                        | Status drives what players and the DM can do.   |
| Clock         | name, segments (4/6/8), filled, visibility (public / known / hidden), background rate, on-fill trigger | The shared world state.                         |
| Character     | name, Discord user id, current quest node, flags                                                       | One character per player in the MVP.            |
| Quest-line    | name, start node, active                                                                               | A directed graph of nodes.                      |
| Node / Choice | node: text, choices. choice: label, condition, outcome mode, outcomes, effects                         | Choices are the only way to move between nodes. |
| Resource      | name, owner character, rating (1–3), status (available / committed / strained / burned), description   | Allies, contacts, assets.                       |

Each tick also produces **Submissions** (one quest choice and any resource assignments per character) and a **Resolution log** (every roll, effect and clock change, with the DM's edits). The log is the source of truth for what was published and makes rollback possible.

**Flags** are simple key-value facts on a character (e.g. `owes_the_guild = true`). They let choices remember earlier decisions without adding a full inventory system.

## The tick lifecycle

Every tick runs the same five steps, and the DM triggers each transition by hand in the MVP.

1. **Open.** The DM opens the tick. The bot posts a public "Tick N is open" message and sends each player their current quest node and available resources.
2. **Collect.** Players submit one quest choice and any resource assignments. They can change their submission until the tick closes. The DM can see who has and hasn't submitted.
3. **Resolve.** The DM closes the tick. The engine runs resolution in a fixed order (below) and writes a draft Resolution log. Nothing is visible to players yet.
4. **Review.** The DM reviews the draft in the web admin. They can re-roll any roll, override any outcome, adjust any clock, add narrative text per player, and add a public world-news summary. Edits are recorded in the log.
5. **Publish.** The DM publishes. Players get their private results and next node; the public channel gets the world news and public clock states. The next tick can now open.

**Resolution order** (so results are predictable):

1. Quest choices resolve, in character order. Their clock effects apply.
2. Resource assignments resolve. Their clock changes apply.
3. Background clock rates apply.
4. Filled clocks fire their triggers, once each.
5. Quest conditions are checked against the final clock state, so the next node's available choices reflect this tick's changes.

**Missed submissions:** a player who submits nothing stays on their node; their resources stay available. No penalty in the MVP.

## Clocks

Clocks are the only shared world state in the MVP: everything that changes the world does so by filling or emptying a clock.

- **Size and fill.** A clock has 4, 6 or 8 segments. Fill can't go below 0 or above the size.
- **Visibility.** _Public_ shows name and fill to everyone. _Known_ shows the name but not the fill ("the cult is up to something"). _Hidden_ is DM-only.
- **Background rate.** An optional amount added (or removed) each tick, e.g. +1 per tick. A clock can be paused, which skips its rate.
- **Triggers.** When a clock fills, it fires once. MVP trigger actions: notify the DM, add text to the world news, start another clock, set a flag on characters, or unlock a quest-line. After firing, the clock is marked complete; the DM can reset it.
- **Racing clocks.** Two clocks can be linked so whichever fills first wins (e.g. _Ritual completes_ vs _Ritual disrupted_). The winner fires; the loser is marked complete without firing.
- **Change sources.** Each clock change is logged with its source (quest choice, resource, background, DM), so players can be told _why_ a clock moved.

## Quest-lines

A quest-line is a graph of nodes; each tick a character makes one choice at their current node, and resolution moves them to the next node.

**Nodes** hold narrative text (what the character sees) and 2–4 choices. A node with no choices is an _ending_; reaching it completes the quest-line for that character.

**Choices** have:

- **Label** shown to the player, e.g. "Bribe the harbourmaster".
- **Condition** (optional) that hides or disables the choice: a clock threshold (`Harbor Unrest >= 4`), a flag (`owes_the_guild`), or a resource the player must commit. Players see disabled choices greyed out with a hint, unless the DM marks the choice as hidden.
- **Outcome mode**, set per choice by the DM:
  - _Fixed_: always leads to one outcome.
  - _Rolled_: a Blades-style roll. The DM sets the dice pool (1–3 d6, keep highest). 6 = success, 4–5 = partial, 1–3 = failure. A critical (two 6s) uses the success outcome plus an optional bonus effect.
- **Outcomes**: one for fixed, or three (success / partial / failure) for rolled. Each outcome has result text, a next node, and effects.

**Effects** an outcome can apply: move a clock up or down, set or clear a flag, change a resource's status (gain, burn, restore), or grant a new resource.

**Rules for the MVP**

- A character is on at most one quest-line at a time. Assigning, swapping and ending quest-lines is a DM action.
- Multiple characters can run the same quest-line independently; there is no shared party position in the MVP.
- Cycles are allowed (e.g. a hub node you return to), so the editor must not assume a tree.

## Resources

Resources are each player's strategic layer: they commit allies and assets to push world clocks forward or back, separate from their own quest.

**Assignment.** During an open tick, a player assigns any available resource to a public or known clock with an intent: _advance_ or _hinder_. Each resource can take one assignment per tick. Hidden clocks can't be targeted. Several resources (from one or many players) can target the same clock.

**Resolution.** Each assignment rolls d6 equal to the resource's rating and keeps the highest.

|                   |              |                                               |
| ----------------- | ------------ | --------------------------------------------- |
| Highest die       | Clock change | Side effect                                   |
| Two 6s (critical) | 3 segments   | None                                          |
| 6                 | 2 segments   | None                                          |
| 4–5               | 1 segment    | None                                          |
| 1–3               | 0 segments   | Resource is _strained_: unavailable next tick |

The DM can turn a 1–3 into _burned_ (lost until restored) during review, but the engine never burns a resource on its own.

**Status.** _Available_ can be assigned. _Committed_ is assigned this tick. _Strained_ sits out one tick, then returns to available. _Burned_ is out until a quest outcome or the DM restores it.

**Gaining resources.** In the MVP, resources come from the DM directly or from quest outcomes.

## Player experience in Discord

Players never leave Discord: they act through a few slash commands, and buttons and menus on the bot's messages.

|               |                                                                                        |                 |
| ------------- | -------------------------------------------------------------------------------------- | --------------- |
| Command       | What it does                                                                           | Visible to      |
| `/quest`      | Shows current node text and choices as buttons; clicking one submits it                | The player only |
| `/resources`  | Lists resources and status; a select menu assigns one to a clock with advance/hinder   | The player only |
| `/submission` | Shows this tick's current choice and assignments, with buttons to change or clear them | The player only |
| `/clocks`     | Shows public clocks with fill, and known clocks by name only                           | Everyone        |
| `/character`  | Shows the player's character, quest-line, flags the DM marked as visible               | The player only |

Player-only responses use Discord's private (ephemeral) replies or a DM thread, so choices stay secret until published.

**Messages the bot sends**

- **Tick opened** (public channel): tick number, the deadline if the DM set one, a nudge to submit.
- **Reminder** (private, optional): sent by the DM to anyone who hasn't submitted.
- **Your results** (private): the outcome text, any roll shown as dice, clock changes the player caused, resource status changes, and the next node.
- **World news** (public channel): the DM's summary plus public clock changes and any filled clocks.

## DM experience

The DM runs ticks from Discord and does everything else in the web admin: Discord for quick actions, the web for authoring and review.

**DM commands in Discord** (restricted to the DM's user id)

- `/tick open [deadline]`, `/tick close`, `/tick status` (who has submitted).
- `/tick remind` pings players who haven't submitted.
- `/admin` posts a private link to the web admin.

**Web admin pages**

- **Login.** Discord sign-in; only the campaign's DM can access the admin.
- **Dashboard.** Current tick and status, submission count, all clocks including hidden ones, recent clock fills.
- **Clocks.** Create, edit, pause, reset, link racing clocks, set triggers, adjust fill by hand.
- **Quest editor.** A list of nodes per quest-line, each edited as a form: text, choices, conditions, outcome mode, outcomes and effects. A read-only graph view shows how nodes connect and flags broken links (choices pointing to missing nodes) and unreachable nodes.
- **Characters and resources.** Link Discord users to characters, assign quest-lines, move a character to any node, set flags, grant, burn or restore resources.
- **Tick review.** The draft Resolution log, grouped by player then world. Per item: re-roll, pick a different outcome, edit text, change clock deltas. A world-news text box. A preview of exactly what each player and the public channel will see. A Publish button.
- **History.** Published ticks and their logs, read-only.

**Keep the editor lean.** A form-per-node editor plus a read-only graph view covers authoring. A drag-and-drop graph editor is the single biggest scope risk and is deferred.

## MVP scope and build order

The MVP is everything above. Build it in four milestones, each playable on its own, so a real tick can run as early as milestone 2.

|                                                              |                                              |
| ------------------------------------------------------------ | -------------------------------------------- |
| In the MVP                                                   | Deferred                                     |
| One campaign per server, one character per player            | Multiple campaigns, multiple characters      |
| Manual tick open / close / publish                           | Scheduled ticks and auto-close               |
| Clocks with rates, visibility, triggers, racing pairs        | Factions as their own objects                |
| Quest-lines with fixed and rolled choices, conditions, flags | Shared party quests, inventory, currency     |
| Resource assignment with dice and strain                     | Combining resources, trading between players |
| Web admin: forms, read-only graph, tick review               | Drag-and-drop graph editor                   |
| Resolution log and history                                   | Rollback of a published tick, AI narration   |

**Build order**

1. **Clocks and ticks.** Data model, clock rules, the tick state machine, `/clocks` and `/tick` commands. The DM can run a world-only tick using clocks and background rates.
2. **Quests.** Quest data, the resolution engine for choices, `/quest`, private results. Quest content is seeded from a JSON file at this stage so the engine can be tested before the editor exists.
3. **Web admin.** Discord login, dashboard, tick review and publish, quest editor, characters and clocks pages. JSON seeding is retired.
4. **Resources.** Resource data, `/resources` and `/submission`, dice resolution and strain, resources in the review screen.

Resources come last because quests and clocks already prove the full loop; resources add a second input to an engine that works.

## Open questions

- Tick cadence: roughly how often will ticks run (daily, weekly, between sessions)? This sets how long a tick stays open and whether reminders matter.
- Can a player see other players' quest results, or only their own plus world news?
- Should resources ever affect a player's own quest rolls (e.g. +1d), or stay strictly on world clocks?
- Do players see the dice for resource rolls, or only the clock outcome?
- Is one character per player enough, or do some players run multiple characters or NPC agents?
- Hosting and stack preferences (language, database, where the bot runs).
