# Documentation-to-implementation audit

## Scope and evidence

Reviewed the README and current operating/domain/API contracts against routes,
controllers, shared domain boundaries and automated tests. Historical plans and
explicitly unimplemented designs are not treated as shipped requirements. This is
an implementation/automated-test review, not a live Discord or production
infrastructure certification.

Baseline: `mix test` — **936 tests, 0 failures**.

## Findings addressed

- **Journal cursor configuration binding:** HTTP journal cursors bound actor,
  campaign ID and character, but not guild/DM/channel configuration, contrary to
  the shared HTTP contract. A regression test demonstrated an old cursor still
  returning 200 after a channel change. Journal pagination now uses `ApiTokens`
  for validated, collection/subject/configuration-bound, 24-hour tokens. The
  regression now expects 422 `invalid_cursor`; a fresh browse still succeeds.
  Existing journal cursor tokens must be discarded after this upgrade: restart
  browsing without `cursor`. Entries, creation receipts and deletion tokens are
  unchanged.
- **Stale feature status:** the README pointed to the superseded flexible-actions
  plan and described shipped commands, quest authoring, memberships and location
  hierarchy as future work. Updated it and related domain guides to match the
  implemented interfaces, keeping unimplemented resource accounting distinct.
- **Snapshot and resolution guidance:** current closes use v3, not v2. Quest
  execution/publication is implemented. Added explicit links/caveats distinguishing
  legacy standalone-clock latching/triggers from Tension endpoint adjudication.
- **HTTP wire contract:** pagination metadata is directly under `meta`, not
  `meta.pagination`. Delivery continuation uses `before_id`/`next_before_id`, not
  journal cursor tokens. Manual-world review fields retain domain-native numeric
  IDs and draft references. Documented the shipped `world` edit operation and
  the fact that private synthesis authoring remains LiveView/domain-only. Kept
  established HTTP response shapes unchanged.

## Contract coverage map

Paths below identify representative implementation and regression evidence; the
full suite also covers concurrency, malformed inputs and negative paths.

| Documented capability | Implementation | Automated evidence (`test/`) |
| --- | --- | --- |
| Campaign setup and canonical Discord IDs | `campaigns.ex`, `discord/snowflake.ex`, `Mix.Tasks.Campaign.Setup` | `async_worlds/campaigns_test.exs`, `mix/tasks/campaign_setup_test.exs` |
| OAuth DM console and bearer API isolation | `web_auth.ex`, web `auth.ex`, `live_auth.ex`, `api_auth.ex` | `async_worlds_web/auth_controller_test.exs`, `api_auth_test.exs`, `http_api_coverage_test.exs` |
| Typed character flags, ownership, stale writes | `characters.ex`, `characters/flags.ex`, `CharacterLive` | `async_worlds/character_editing_concurrency_test.exs`, `async_worlds_web/character_live_test.exs` |
| Clock management and legacy resolution | `clocks.ex`, `ticks/world_resolver.ex` | `async_worlds/clocks_test.exs`, `ticks/world_resolver_test.exs` |
| Quest authoring, immutable revisions, submissions and review | `quests/authoring.ex`, `quests/submissions.ex`, `ticks/quest_review.ex` | `async_worlds/quest_authoring_test.exs`, `quest_submissions_test.exs`, `ticks/quest_review_publication_test.exs` |
| Exact opening preview and stale-safe atomic opening | `ticks/opening.ex`, `ticks/opening_output.ex` | `async_worlds/ticks/opening_test.exs`, `opening_delivery_test.exs`, `async_worlds_web/tick_opening_live_test.exs` |
| Tension threads, private intentions, frozen close and adjudication | `tension_discussions.ex`, `tension_commitments.ex`, `ticks/manual_world.ex`, `ticks/synthesis.ex` | `async_worlds/tension_discussions_test.exs`, `tension_commitments_concurrency_test.exs`, `ticks/manual_world_test.exs`, `async_worlds_web/tension_synthesis_live_test.exs` |
| Explicit adoption and quest-free multi-tick play | `DashboardLive`, `ticks/opening_output.ex`, Discord quest interactions | `async_worlds/tension_rehearsal_test.exs` |
| Atomic publication, delivery generations and recovery | `ticks/publication.ex`, `deliveries.ex`, delivery/discussion workers | `async_worlds/ticks/review_publication_test.exs`, `deliveries_test.exs`, `tension_discussions_test.exs` |
| Immutable connected Events and private personal history | `ticks/chronicle.ex`, `ticks/personal_history.ex` | `async_worlds/ticks/chronicle_test.exs`, `personal_history_test.exs`, `async_worlds/discord/chronicle_commands_test.exs` |
| Character-owned journals, retained creation and confirmed deletion | `journals.ex`, Discord journal adapters, `JournalController` | `async_worlds/journals/creation_test.exs`, `journals_test.exs`, `async_worlds_web/controllers/journal_controller_test.exs` |
| Descriptive memberships and location hierarchy/history | `memberships.ex`, `locations.ex`, `link_history.ex` | `async_worlds/memberships_concurrency_test.exs`, `location_hierarchy_concurrency_test.exs`, `async_worlds_web/controllers/world_relationship_controller_test.exs` |
| HTTP envelopes, preconditions, privacy and example routes | web `api_response.ex`, `api_params.ex`, `api_tokens.ex`, controllers | `async_worlds_web/api_conventions_test.exs`, `api_examples_test.exs`, `http_api_coverage_test.exs` |
| Runtime config, health and release helpers | `config/runtime.exs`, `release.ex`, web `health.ex` | `async_worlds/runtime_config_test.exs`, `release_test.exs`, `async_worlds_web/health_test.exs` |

## Remaining verification boundaries

- **Live Discord rehearsal remains outstanding**, as already recorded in
  [the Tension rehearsal record](tension-led-rehearsal.md) and
  [journal acceptance checklist](journals.md). Fake adapters cannot establish
  real permissions, gateway behavior, thread/archive races, mobile ergonomics,
  modal compatibility or end-to-end delivery latency. No live credentials or
  real campaign mutations were used for this audit.
- Container rollout, provider TLS and backup/restore drills in
  [operations](operations.md) require their own disposable infrastructure checks;
  they were not rerun here.
- Public quest-action announcements, quest custom-proposal adjudication and
  character-specific path adaptation remain unimplemented historical-plan work.
  Private Tension intentions plus manual Event adjudication are the shipped
  alternative, not an implementation of those quest-specific designs.
- Resource inventory/spending, automatic interpretation/closing, public player
  web access, published rollback and a link-history timeline UI remain outside
  shipped scope. No such features were added just to satisfy older plans.

## Validation

- New cursor regression: failed before the fix (200 instead of 422).
- Focused journal/API-convention tests: **15 tests, 0 failures**.
- Final gate: `mix precommit` passed — **937 tests, 0 failures**, including
  compilation with warnings as errors, dependency check and formatting. Existing
  migration-module redefinition warnings and expected negative-path logs remain.
- Local Markdown file targets were checked; no broken relative file links found.
