# World Games — Implementation Plan

[Linear project](https://linear.app/warp-monster/project/world-games-a72f48eaa32c) · [Linear implementation plan](https://linear.app/warp-monster/document/world-games-implementation-plan-86860ffca648)

## Purpose and scope

Build Tick & Clock, the Discord campaign engine described in [project-outline.md](project-outline.md), initially for the DM's own campaign.

Players act entirely in Discord. The DM authors content and reviews results in a Phoenix web admin. Ticks are game turns, not units of real-world time: the DM opens, closes, and publishes them manually, usually closing once everyone has submitted. Missing submissions do not prevent closing and carry no penalty.

The outline remains the gameplay specification. This plan records the agreed architecture, implementation milestones, and delivery boundaries. It moves a minimal web review/publish interface into the first milestone because DM approval is fundamental to the game loop.

## Agreed architecture

- **One Phoenix application:** LiveView admin and a supervised Nostrum bot in the same application/container. No separate frontend or bot service.
- **Discord integration:** use a stable Nostrum Hex release for gateway interactions, REST API calls, and rate limiting. Slash commands, buttons, and menus call shared application functions. Avoid unnecessary gateway intents.
- **Web admin:** Phoenix LiveView, Discord OAuth login, access restricted to the configured DM Discord account. Enforce authorization server-side for both interfaces.
- **Database:** PostgreSQL through Ecto. Production uses `DATABASE_URL`; local development uses local PostgreSQL.
- **Game engine:** plain Elixir rules operating on frozen inputs and recorded rolls, independent of LiveView, Discord, and message delivery.
- **Background work:** Oban for durable resolution and outbound delivery jobs. Adding Nostrum and Oban is part of foundation implementation.
- **Deployment:** one persistent application container initially, with separately provisioned PostgreSQL. Include release migrations, runtime secrets, health checks, and documented setup.
- **Campaign setup:** a setup task configures the Discord guild, DM user, and public channel. Campaign-owned records carry `campaign_id`; no self-service onboarding or multi-DM administration in the MVP.
- **Shared application boundary:** Discord consumers and LiveViews call the same domain operations; neither implements its own game rules. Discord delivery sits behind an adapter that can be replaced in tests.

## State, resolution, and publication

### Tick lifecycle

`open → resolving → in review → published`

The DM controls transitions. One active tick per campaign; a new tick cannot open until the previous one is published. Readiness counts are informational, not an automatic close condition.

1. Opening a tick makes submissions available and queues notifications.
2. Closing atomically freezes submissions and relevant campaign/quest inputs. Late or stale interactions cannot alter closed submissions.
3. Resolution records rolls and creates a draft without mutating published game state.
4. Review edits are audited. Changing outcomes or rolls recomputes downstream effects while preserving unrelated rolls.
5. Publishing atomically applies the approved draft, records the published log, and creates outbound delivery records. Duplicate requests or job retries must not apply game effects twice.
6. Delivery jobs send notifications independently of publication. Failures are visible and retryable without republishing.

Players see the last published state during resolution/review. Draft content is DM-only. Campaign edits made during review cannot silently change frozen tick inputs; intentional changes to the result go through review.

### Engine rules

- Use the outline's resolution order: quest choices, resource assignments, background rates, filled-clock triggers, then next-node choice conditions.
- Define and test a stable ordering of characters, resource assignments, clocks, and effects.
- Racing-clock winners latch when the first clock fills in resolution order. At the trigger phase, only the winner fires; the loser completes without firing. Specify deterministic tie-breaking before implementing simultaneous or chained effects.
- A re-roll replaces only the selected roll. Other recorded rolls remain unchanged as downstream results are recomputed.
- Persist input snapshots, individual rolls, draft revisions/review edits, and published resolution records. Do not build a full event-sourced application.
- Published-tick rollback remains deferred; audit records are groundwork, not a rollback feature.
- Define resource strain timing explicitly in milestone 4: a resource strained by tick N sits out tick N+1 and is available again for tick N+2.

### Discord reliability and privacy

Player-initiated private commands use ephemeral responses. Proactive private notifications use DMs, which can fail if a player blocks them. Commands must provide access to the latest applicable quest, submission, and published result without depending on successful DM delivery.

A blocked DM never prevents publication. Record delivery state and support targeted retries. Do not promise exactly-once Discord delivery: a timeout after a successful send can make delivery ambiguous, so persist message identifiers where available and handle ambiguous retries deliberately.

Filter hidden clocks, known-clock fill values, private results, and non-visible flags in all player-facing views and payloads. Respect Discord message/component limits and promptly acknowledge interactions before long-running work.

## Linear project structure

Use the existing **World Games** project with this plan as a project document and the four milestones below as actual project milestones. Do not create speculative implementation issues yet. At the start of each milestone, break its deliverables into actionable issues with acceptance criteria and dependencies; use sub-issues where a parent issue represents a coherent feature.

Milestones are sequential, but each should deliver a working end-to-end loop. No target dates are assigned yet.

## Milestone 1 — Foundation and world-only ticks

**Goal:** Run a complete DM-approved world tick in the real Discord server.

### Deliverables

- Campaign configuration and setup task; campaign-scoped persistence and authorization.
- Discord OAuth and DM-only LiveView shell/dashboard.
- Supervised Nostrum integration, development-guild command registration, DM command authorization, and testable Discord adapter.
- Clock model and management: size/fill constraints, visibility, rates, pause/reset, supported triggers, racing pairs, and source-labelled changes.
- Manual tick state machine and frozen inputs; world-only draft resolution with deterministic ordering.
- Minimal review screen to inspect/adjust clock results, write world news, preview public output, and publish.
- `/clocks`, `/tick open`, `/tick close`, `/tick status`, and `/admin`; public tick-open and world-news messages.
- Durable publication/delivery jobs, failure visibility, retry controls, and transition/concurrency protections.
- Container release, PostgreSQL connection-string configuration, migrations, runtime secrets, local setup, and operational basics.
- Trigger types that depend on quests or characters may be completed with milestone 2, but the world-only clock loop must work here.

### Acceptance

The DM can open a tick, advance background clocks, review and adjust a private draft, and publish world news and permitted clock state to Discord without editing the database. Repeated close/publish requests cannot duplicate effects. Restarting the application does not lose pending work, and failed Discord delivery can be retried without republishing.

## Milestone 2 — Playable personal quests

**Goal:** Players complete personal quest turns entirely in Discord.

### Deliverables

- Characters linked to Discord users; one character per player per campaign.
- Quest-lines, nodes, choices, outcomes, conditions, flags, and fixed/rolled resolution. One active quest-line per character; support cycles and endings.
- Validated JSON quest import with a documented format, references, and representative sample campaign content.
- DM operations to assign/swap/end quests and move characters between nodes.
- Tick submissions that players can change or clear until closing; stale component and eligibility validation.
- `/quest`, `/submission` for quest choices, `/character`, and manual `/tick remind`.
- Private tick prompts and results, with command-based retrieval when DMs fail.
- Quest effects on clocks and flags; quest/character-dependent clock triggers.
- Review of individual rolls/outcomes with recomputation, preserved unrelated rolls, private previews, and audited edits.
- Resource-dependent conditions/effects are completed in milestone 4 rather than exposing unusable resource mechanics here.

### Acceptance

Multiple players can independently follow the same quest-line, submit or revise one choice, and receive only their approved private results. The DM can close with missing submissions, re-roll one result without changing unrelated dice, and publish quest progression plus consistent world-clock changes.

## Milestone 3 — DM authoring and administration

**Goal:** Manage campaign content and review ticks without editing JSON or using developer tools.

### Deliverables

- Quest-line and node forms for text, choices, conditions, outcomes, and effects.
- Read-only graph view supporting cycles; validation for broken references and unreachable nodes. No drag-and-drop editor.
- Full clock, character, flag, and quest assignment management in LiveView.
- Expanded review grouped by player and world: outcome overrides, clock-delta edits, player narration, public world news, and exact outgoing-content previews.
- Dashboard submission readiness, all DM-visible clocks, recent fills, and delivery status.
- Read-only published-tick history and audit details.
- JSON import no longer required for routine authoring; retain it as an optional bootstrap/test tool.

### Acceptance

The DM can author a branching/cyclic quest, identify broken links, assign it to a character, run a tick, edit and preview results, publish, and inspect historical records entirely through the web admin and Discord commands.

## Milestone 4 — Resources and complete MVP

**Goal:** Add resource strategy to the proven quest/world loop and complete the outline's MVP.

### Deliverables

- Resource ownership, ratings, and available/committed/strained/burned lifecycle.
- `/resources` and complete `/submission` with resource assignment/change/clear controls.
- Advance/hinder assignments against eligible public/known clocks; one assignment per resource per tick.
- Recorded dice, criticals, clock deltas, strain, one-tick recovery, and DM-only burn overrides.
- Resource quest conditions/effects, grants, restoration, and authoring controls.
- Resource management and results integrated into review, previews, history, and private delivery.
- End-to-end regression coverage across quests, resources, clocks, triggers, review edits, privacy, and publication retries.
- A real-campaign rehearsal and short DM/player operating guide.

### Acceptance

Players submit a quest choice and multiple eligible resource assignments in Discord. Resolution follows the specified order, strain removes a resource for exactly the next tick, the DM can override results, and approved publication consistently updates state and delivers private/public output.

## Quality and scope boundaries

- Test the rules engine with controlled dice and explicit edge cases; test application transactions, authorization, and concurrent/repeated transitions.
- Exercise LiveView forms/review through DOM selectors and Discord handlers through the adapter, not live API calls in the normal test suite.
- Run `mix precommit` after implementation changes and fix failures.
- Prefer a small working vertical slice over building every schema or UI up front.
- Deferred: scheduled ticks, AI narration, combat, shared party position, inventory/currency, trading, drag-and-drop graph editing, published rollback, and self-service multi-campaign onboarding.

## Decisions to refine during implementation

These do not block the agreed architecture or milestones:

- Stable ordering and tie-breaking for chained clock triggers and racing-clock edge cases.
- Typed condition/effect representation, validation, and quest content revision strategy.
- Review override semantics when an upstream change removes or creates a downstream roll.
- Handling manual state edits between opening and closing a tick, including submission revalidation.
- Discord presentation/pagination limits, message recovery, and ambiguous delivery handling.
- Whether players see resource dice (the outline already includes quest roll display).
- Container hosting provider and backup/restore procedure.
