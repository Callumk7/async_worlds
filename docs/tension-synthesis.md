# Tension-centred tick synthesis (ENG-94)

The existing `/ticks/:id/review` workspace now leads with frozen Tension
circumstances, clocks and participation. This is an inspection/authoring layer over
ENG-91's review operations, **not another resolver**. Read
[the world-play direction](tension-led-world-play.md),
[manual operation semantics](manual-world-loop.md), and
[frozen participation](tension-commitments.md) first.

## DM workflow

1. Close the tick using the existing dashboard. Missing, not-ready, unresolved and
   withdrawn participation do not block close or background progression.
2. For each Tension inspect its frozen description, endpoint/influence text, frozen
   fills, proposed progression before manual bundles, and combined draft fills.
   Proposed progression reuses the existing resolver and recorded dice; it is not
   an allocation calculation. Standalone legacy clocks/quests retain their review.
3. Inspect each character's frozen name/ID, version, state, readiness, exact intent
   and descriptive approach/resources. Follow **Also contributing** links to that
   character's confirmed/unresolved entries elsewhere. These links expose possible
   conflicts without detecting resource names, reserving assets or deciding winners.
   Internal commitment anchors include frozen Tension/character/version IDs, even
   for absent entries. The persistent Discord thread link is current transport
   metadata, not a frozen world input. Private slash commitments have no public
   Discord message anchor; the app does not invent one or read discussion.
4. Save a private **DM interpretation** and deliberately deferred character IDs
   (a JSON array, e.g. `[12, 14]`). IDs must belong to this Tension's frozen roster.
   Missing/withdrawn/unresolved states remain visible; deliberate deferral does not
   rewrite them, imply withdrawal, or carry a fabricated action into the next tick.
   Interpretations may also describe why a pressure is left unattended. These
   audited notes persist across reload/revision/publication in the private review
   payload; they produce no Event, bonus, public recap or automatic consequence.
5. Explicitly author a titled Event and short account. Use the same bundle key to
   append clock adjustments/configuration, Tension openings/developments, or (with
   Resolution kind) resolutions. Select audience explicitly. New Tensions default
   to DM-only; public Event attachments must all satisfy the existing public-context
   policy. Routine pressures still need no prose.
6. **Edit entire bundle** reloads its title/account/audience/kind and original
   intention changes into the form. Replace mode edits the whole JSON changes
   array, allowing corrections/deletions without appending or double-applying.
   For example: `[{"entity":"clock","id":42,"attrs":{"delta":-2}}]`.
   Narrative-only append mode can also revise title/account while retaining changes.
   Existing remove/rebuild and stable `new:<key>:<index>` references remain available.
   If removing/reordering creations, revise references to their new indices too.
7. Inspect combined resulting clocks/Tensions, exact before/after Event details,
   endpoint prompts, and **exact outgoing public/private previews**. These are draft
   consequences, not established history. Public prose is explicitly DM-authored;
   the system cannot redact secrets from natural language.
8. Publish the inspected revision using the existing confirmation. The same atomic
   transaction establishes live changes, immutable Event history and outbox work.
   Retrying returns `already_published`, without another application. A stale tab
   must reload; authorization is freshly checked. Management remains close-locked.

Bundle keys and change arrays retain their existing explicit replay order for
mechanical edits. **Neither submission order, character ID nor display order is
initiative or a winner rule.** Intent alone has no effects. There is no mandatory
interpretation/deferral quota, additional approval, resource accounting, natural-
language interpreter, dice template or new initiative system.

No migration or frozen-snapshot rewrite is needed. A `synthesis` review operation
contains `tension_id`, `interpretation`, and `deferred`; canonical replay validates
it against frozen inputs. Immutable review edits retain actor/reason and revision
lineage. Older snapshots without participation remain usable; empty synthesis is
an identity operation. History and player delivery never project these private notes.

## Reproducible Reach rehearsal

Executable scenario: `test/async_worlds_web/tension_synthesis_live_test.exs`.
It uses actual LiveView forms, PostgreSQL and the existing review/publication
pipeline, with no Discord API calls or live campaign data.

It runs twice, reversing both character creation and submission order:

- Rook and Wren contribute to **Battle in the Reach**. Rook describes the same
  **Ash Company** elsewhere in an unresolved commitment. Other characters are
  missing and withdrawn. A private unattended hunger clock continues.
- Close freezes exact commitments; late withdrawal and live clock adjustment fail.
  No Event or winner is inferred. Inspect thread and frozen/cross-Tension anchors.
- Persist private conflict interpretation and deliberate deferral. Reject stale
  console writes, foreign participants, foreign campaign access and revoked DM
  authority. Reload notes without changing original clock results.
- Draft **The Ash Company holds the crossing**: background takes goblin advance
  from 3 to 4, then DM adjustment -2 produces 2; evacuation goes from 1 to 4;
  open public **The wounded captain**. Live state/history remain unchanged.
- Reload and edit the complete bundle's recap without double-applying changes.
  Canonical replay is identical. Exact public preview contains the Event, not
  private intent/DM notes/hidden pressure. Publish it atomically, compare stored
  outputs with the exact preview, reject duplicate publication, verify frozen
  attribution and unattended progression. Both orderings finish at `(2, 4)`.

Companion tests cover synthesis limits/attribution, ENG-91 rollback and legacy
semantics, ENG-93 concurrent close locks, and invalid preview handling.

### Isolated runtime used for validation

Run from this checkout. The host has `/tmp/elixir/bin/mix` and `/usr/bin/erl`;
validation instead uses the existing local `eng6-elixir` image (Elixir 1.18.4,
OTP 28.5.0.7) and a newly created, disposable PostgreSQL 16 service. No shared
service database is touched. An equivalent local Elixir/Postgres setup also works.

```sh
mkdir -p .artifacts
docker network create eng94-vx1mio
docker run -d --name eng94-vx1mio-db --network eng94-vx1mio \
  -e POSTGRES_PASSWORD=postgres postgres:16-alpine
docker run -d --name eng94-vx1mio-app --network eng94-vx1mio \
  -v "$PWD:/app" -w /app -e MIX_ENV=test -e PGHOST=eng94-vx1mio-db \
  -e PGUSER=postgres -e PGPASSWORD=postgres -e 'ERL_FLAGS=+S 4:4' \
  eng6-elixir sleep infinity
# On a fresh checkout, install dependencies first (this run reused copied caches):
# docker exec eng94-vx1mio-app mix deps.get
docker exec eng94-vx1mio-app mix test \
  test/async_worlds_web/tension_synthesis_live_test.exs --trace
docker exec eng94-vx1mio-app mix precommit
# Optional cleanup of ONLY these disposable services:
# docker rm -f eng94-vx1mio-app eng94-vx1mio-db
# docker network rm eng94-vx1mio
```

The `mix test` alias creates/migrates only this service's `async_worlds_test` DB;
SQL sandbox rolls scenario data back. Focused validation: **37 tests, 0 failures**.
Full `mix precommit`: **917 tests, 0 failures**. Existing negative-path connection,
OAuth and migration-module-redefinition logs are expected; compile with
warnings-as-errors passes. Local logs are in `.artifacts/` (git-ignored). No live
Discord rehearsal/browser screenshot is claimed; the scenario is executable
LiveView integration coverage, not an external delivery or deployment exercise.
