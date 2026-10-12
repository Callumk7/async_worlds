# Discord debug personas and accountless characters

## Context
One real Discord DM account cannot currently exercise multiple players' interactions. The dispatcher verifies the gateway member, then passes that Discord ID directly into player operations. Characters require a unique Discord owner per campaign. The goal is realistic player testing without weakening normal ownership or exposing private content to other members.

## Approach
Separate the authenticated actor from the effective gameplay character, and add an explicitly enabled, DM-only Discord testing persona. Reuse ordinary player projections and submission rules rather than inventing a privileged player renderer. Keep administrative authority tied to the real actor.

### Discord experience
- `/debug status` privately shows mode, selected character, message-copy setting and a catalogue of supported interactions. Build the catalogue from the same command metadata used for registration/routing, with DM/player availability; this is discoverability, not disclosure of hidden quest choices.
- `/debug player character:<internal ID>` enables player mode for any character in the campaign, linked or accountless. Use a paginated private character picker from `/debug status` as the convenient alternative to entering IDs; no gateway intents or autocomplete required.
- `/debug dm` returns to DM role; `/debug off` disables testing and clears the persona. `/debug messages enabled:<boolean>` explicitly enables/disables copies of linked players' personal messages. Copies default off. Debug management is always restricted to the actual, current DM, including while acting as a player.
- In player mode, `/character`, `/quest`, `/submission` and `/clocks` behave as ordinary player commands. `/tick` and `/admin` deny access until switching back. Each testing response has a compact `Testing as <character> · player · changes are real` banner; retain existing message-size limits.
- Accountless characters always receive personal results through the campaign DM, labelled by character, even if another persona is selected or debug mode is off. They are explicitly DM-controlled characters, not silently undeliverable records. Linked owners always keep their normal delivery; optional DM copies are labelled and additive.
- Web administration retains normal DM access. Persona selection affects Discord only, not OAuth sessions or web authorization.

### Identity and authorization
Introduce a shared gameplay access boundary (for example `AsyncWorlds.PlayerAccess`) that resolves `{verified actor, campaign, role, subject character, session generation}`. A character ID is a locator, never proof of ownership. Ordinary members resolve only their existing linked character; arbitrary character selectors are rejected. A testing subject requires fresh current-DM authorization and matching persisted debug state under the campaign lock. Preserve existing verified-user APIs as wrappers while migrating interfaces to explicit context.

Persist one debug session per campaign/current DM with enabled flag, role, selected character FK, linked-message-copy flag and generation. Check the actual DM and guild on every access; old sessions become unusable after campaign reconfiguration. Increment generation on switch/disable; bind both open and read-only controls to subject and generation so A → B → A does not revive old controls. Recheck inside submit/clear transactions, not just at dispatch, to prevent switch races. Emit minimal structured audit events for mode changes and debug mutations (actor, campaign, character, operation), never tokens, payloads or hidden content.

### Persistence and delivery
Allow null `characters.discord_user_id`; keep canonical snowflake validation and uniqueness for non-null linked owners. Null means DM-controlled/accountless; multiple null owners are valid. Do not change existing linked ownership semantics. Keep character-edit lifecycle locks and ownership-change submission invalidation.

Freeze explicit per-character delivery routes and labels at tick close in a new v3 snapshot contract: linked owner delivery, accountless fallback to the frozen DM, and optional copies to the frozen DM (deduplicated when owner equals DM). Preserve v1/v2 validation and rendering exactly. Carry v3 routes through deterministic resolution into the draft and shared preview/output renderer. Debug switching must not mark a frozen world stale; exclude only delivery-only configuration from live gameplay comparison, while retaining existing gameplay/ownership stale-state checks. Changing copy settings affects future closes, not already-frozen ticks. Publication persists exact previewed outputs and queues them atomically; workers never consult the current persona or rewrite old outbox recipients. Use stable character/audience/chunk delivery keys so multiple characters delivered to one account cannot collide.

Confirmed requirements: available in live campaigns; interactions persist real changes; switch DM/player roles; create characters without Discord accounts; the real DM can act and receive messages as those players. No separate-account setup should be necessary.

Recommended scope: make Discord ownership optional while retaining uniqueness for linked owners. Use character IDs as gameplay subjects; do not manufacture Discord IDs or relink ownership when switching personas. Add a durable campaign-scoped DM testing session with a generation used to invalidate old buttons. A player role should hide/deny administrative interactions while preserving a real-DM-only escape to switch back.

Further discovery: quests and submissions already use internal character IDs for gameplay, so a wholesale player-account schema is unnecessary. Discord coupling sits in player authorization, required character ownership, frozen snapshot validation, and personal delivery recipients. Debug mode must address all four—not just replace the dispatcher user ID. Frozen inputs currently require unique string Discord IDs, and publication sends directly to those frozen IDs. `Ticks.Output.render/2` is shared by preview and publication; route decisions must remain frozen and visible in preview, never depend on whichever persona happens to be selected when a worker sends. A versioned snapshot extension is needed; existing snapshots/drafts/outbox records must retain their original meaning.

## Files to modify
- New `lib/async_worlds/player_access.ex`, `lib/async_worlds/discord/debug_sessions.ex`, `lib/async_worlds/discord/debug_session.ex`, and `lib/async_worlds/discord/debug_interactions.ex`: shared access resolution, persisted persona and private controls.
- `lib/async_worlds/discord/{dispatcher,commands,quest_interactions}.ex`: actor/subject separation, command catalogue, role filtering and generation-bound buttons.
- `lib/async_worlds/characters.ex`, `lib/async_worlds/characters/character.ex`, `lib/async_worlds/quests.ex`, `lib/async_worlds/quests/submissions.ex`: common freshly authorized character access and optional ownership.
- `lib/async_worlds_web/live/character_live.ex`: optional Discord input, accountless explanation, character IDs and delivery destination labels.
- New migration under `priv/repo/migrations/` for nullable ownership and debug sessions; generate with `mix ecto.gen.migration` during implementation only.
- `lib/async_worlds/quests/frozen_inputs.ex`, `lib/async_worlds/ticks.ex`, `lib/async_worlds/ticks/{world_resolver,output}.ex`: v3 frozen routes, compatibility, preview and outbox identity. Inspect `quest_dice.ex` / `quest_review.ex` and other schema-version consumers for compatibility.
- Tests under `test/async_worlds/discord/`, player/domain and tick publication tests, and `test/async_worlds_web/character_live_test.exs`; new focused access/debug-session tests.
- `docs/{discord,characters,quest-submissions,quest-review}.md`: debug commands, actor trust contract, accountless routing and live verification.

## Reuse
- Dispatcher application/guild/member verification, private defer and response handling.
- `Campaigns.authorize_dm/2` for real-actor authorization.
- `Characters.player_character/2` / `player_payload/1` whitelist projection; expose internally through the authorized access boundary rather than duplicating it.
- `Quests.player_quest/2`, `Rules.project/2`, `Submissions.player_state/2`, `submit/4`, `clear/3`: existing eligibility, projection and lifecycle logic, factored behind shared subject resolution.
- Existing campaign `FOR UPDATE` locking, `Submissions.invalidate_open/2`, quest position identities/digests, button pagination and read-only view freshness.
- `Ticks.Output.render/2`, `Ticks.freeze/2`, frozen validation and atomic publication enqueue; preserve preview/delivery parity and existing transport/outbox semantics.
- Character LiveView streams/forms and authenticated DM live-session hooks.
- Existing fake Discord adapter, fixtures, sandbox concurrency tests and registration tests for offline coverage.

## Steps
- [x] Add migration, accountless-character validation and editor changes; preserve linked-owner constraints and lifecycle locks.
- [x] Implement locked debug-session transitions and shared actor/subject access with ordinary-owner compatibility wrappers; audit debug operations safely.
- [x] Refactor character/quest/submission APIs to reuse the same projections and gameplay transactions for normal and DM-controlled access.
- [x] Add `/debug` commands, private character picker, role-aware catalogue and testing banners. Keep the verified gateway actor unchanged and use the existing private acknowledgment/transport path.
- [x] Bind controls to subject and debug generation, verify Discord's 100-character IDs and pagination limits, and reject controls after switch/off/reconfiguration. Handle concurrent switch/submit under the same lock.
- [x] Introduce v3 frozen delivery routes and carry them through resolution, preview and publication; preserve old snapshots and pending deliveries. Ensure persona changes cannot affect deterministic dice or world resolution.
- [x] Add offline regression/concurrency tests, update documentation, migrate the local DB and re-register guild commands during implementation.
- [ ] Run `mix precommit` and complete the one-account live checks.

## Verification
### Offline automated coverage
- Multiple accountless characters succeed; malformed linked IDs and duplicate non-null owners fail; existing owner lookup still returns exactly one character. Link/unlink remains DM-authorized and clears affected open submissions.
- Only the current DM in the configured application/guild can enable/switch/copy messages. Forged character IDs, foreign campaigns, top-level user IDs and ordinary-member debug requests fail. DM reassignment revokes old persona access.
- Same player projections in ordinary and debug paths: hidden flags/choices/conditions remain absent. DM-only commands deny in player role; `/debug dm` remains usable. Disabled mode restores ordinary Discord identity behavior.
- Two characters independently submit/revise/clear real choices. Closed tick, reassignment, eligibility changes, A → B → A, disable/re-enable and switch/submit races reject stale controls without changing the wrong character.
- Banner and picker pagination respect content/component limits. Failed acknowledgment executes nothing; final-response failure never retries mutations. Catalogue/registration stay aligned.
- v1/v2 snapshots and old pending outbox records retain existing semantics. v3 supports multiple null owners; accountless messages reach the frozen DM with labels. Linked messages are unchanged by default, copies are opt-in, and identical owner/DM recipients are deduplicated. Multiple characters/chunks have distinct idempotency keys.
- Preview equals queued output; toggling persona/copies after close does not reroute or invalidate the draft. Repeated publish/retries neither duplicate application of state nor recompute recipients. Dice identities and hidden-data filtering are unchanged.
- Character LiveView assertions use existing DOM IDs plus accountless-state/destination IDs. Finish with `mix precommit` (offline fake transport, PostgreSQL).

### One-account live checklist
1. Create two accountless characters in `/characters`, give them different flags/quests and open a tick.
2. Use `/debug status` to discover commands; select A, check `/character`, `/quest`, `/submission`, and submit/revise/clear. Verify hidden content stays absent and `/tick` denies.
3. Switch to B and submit a different choice. Click an old A control, including after switching back to A: private stale-control response, no accidental mutation.
4. Return to DM, close, review and publish. Confirm both labelled personal messages reach the same real DM account alongside the usual DM summary, regardless of selected persona.
5. Verify linked-character copies are off by default and additive when explicitly enabled; the genuine owner's route is never redirected. Inspect exact preview destinations before approving.
6. Disable debug and verify ordinary behavior resumes. Check blocked DMs through the existing outbox failure/retry UI; slash commands/buttons remain usable.

## Execution evidence
- `mix ecto.migrate` applied the new migration to the local development database.
- `mix discord.register_commands` successfully registered all seven commands in the configured guild.
- Final `mix precommit` passed: 321 tests, zero failures; warnings-as-errors, dependency checks and formatting passed.
- Added tests for real independent persona submissions, accountless privacy and picker pagination, open/read-only control generations, deleted-character escape, configuration-change/reversion revocation, switch/submit concurrency, and frozen multi-character delivery/preview/outbox behavior.
- Step 8 remains partially complete: offline checks and live registration passed; actual slash-command/button and personal-message checks require the user to invoke them from their Discord DM account. No campaign tick was opened/closed/published in the development database for testing. Restart the running app/bot after upgrade, then follow the live checklist above.

## ENG-21 integration after PR #26
- Combined `/debug` with `/result`, historical `/submission` fallback, `/tick remind` and shared `PlayerContent` rendering.
- Notifications resolve by character; accountless prompts/reminders and opt-in DM copies have subject/audience-aware routing and send-time guards. Persona selection never controls queued message destinations.
- Historical reads use `PlayerAccess`: normal owners retain historical ownership restrictions; actual DM personas retrieve only the selected character's primary output, including legacy history, without duplicate copies or other characters sharing the DM recipient.
- Publication guards use v3 character metadata instead of inferring character identity from the Discord recipient. Existing legacy guards and stale-intent policy remain in force.
- `mix precommit` passed after integration: 341 tests, zero failures. Added actual fake-transport delivery, reminder, persona-history, relink and DM-revocation coverage.
- Applied the ENG-21 private delivery guard migration locally and registered the combined eight-command guild set. Real Discord interaction/message smoke checks remain pending.

## Boundaries
This is real campaign control, not a sandbox or undo feature. Accountless characters participate in ordinary readiness/resolution. Do not bypass eligibility, lifecycle locks or approval. No multi-character ownership for ordinary Discord users, dice-control changes, new OAuth roles, automatic public announcements, automatic message redirection or separate transport simulator is included.
