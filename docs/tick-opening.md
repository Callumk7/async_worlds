# Public tick-opening preparation (ENG-64)

## Shipped boundary

The authenticated DM dashboard has **Prepare / reload exact preview** before the
next tick. It shows the next number, the exact public channel ID and **every**
numbered message chunk. Optional public opening narration is independent of
world news: it never reads or writes resolution drafts, trigger news or published
outcomes. Preparation and preview perform no delivery, job, tick, progression,
audit or other game-state writes. There is no schedule or automatic open.

**Briefing delivery is not shipped.** ENG-65 owns durable opening delivery. The
inspected-open button explicitly says it still uses existing delivery only:
`Tick N is now open.` plus the existing guarded private quest prompts. The
existing **Open without briefing (legacy)** button is an explicit, browser-confirmed
fallback, as are existing Discord/HTTP opening flows. No new opening narration
is persisted or sent by these flows. Existing close/review/publication is unchanged.

## Context API

Use `AsyncWorlds.DM.Ticks` with a verified authenticated scope, not IDs from forms:

- `prepare_opening(scope, %{"narration" => text})` (default `%{}`) returns
  `{:ok, preparation}`. Unknown fields, non-text, invalid UTF-8, control characters
  and more than 8000 bytes reject as `:invalid_opening`. Blank narration is omitted.
- `preview_opening(scope, preparation.token)` returns the **same exact content**
  only if authorization, readiness and input version still match.
- `open_prepared_tick(scope, preparation.token)` revalidates under the same campaign
  lock and delegates the existing open transaction. This is not a briefing publisher.

A preparation contains `campaign_id`, `tick_number`, `public_channel_id`,
`narration`, `version`, `token`, and ordered `messages`. Each message has `kind:
:public`, `recipient_id`, `content`, one-based `chunk_index`, and an `id` for web
streaming. Tokens are signed, actor/campaign-bound and expire after one hour;
foreign, malformed or expired tokens return `:invalid_preparation`. Signing is
not authorization: every operation freshly checks the DM under `DMAccess`'s
campaign lock. A stale scope can return `:stale_campaign` and a revoked DM returns
`:unauthorized`. Active ticks and locked campaigns reject preparation/open.

The input digest covers renderer version, campaign configuration/counter,
characters (including database state generations), quest progressions/position
versions, revisions, availability unlocks, clocks and clock audit identities.
These conservative checks can require reinspection even when a private input
changes without changing public text. Character edits away and back are detected.
Supported writers share the campaign lock; direct uncoordinated SQL writes are
not an interface contract. Digests/tokens never contain private quest definitions,
flags, owners, condition explanations or clock state; narration itself is public.

On `:stale_preparation`, never automatically regenerate and open. The dashboard
retains the old preview, disables the inspected-open action, clears confirmation,
and requires deliberate preparation and inspection again. Editing narration also
invalidates inspection. **Refresh status** checks but does not replace a preview.
The web uses its server-loaded token and rejects extra approval fields; a posted
foreign token or campaign ID cannot select another preparation/campaign.

## Public content and privacy

`Ticks.OpeningOutput.render/4` is the shared pure renderer for preview and the
future delivery path. Its roster comes from ENG-63's `Quests.public_activities/2`,
using pinned public summaries, never private quest/node text or latest-library
narration. It renders every character, including legacy-summary fallbacks,
unassigned, ended/completed and DM-controlled characters, plus an explicit empty
roster. Ownership IDs never enter public messages. A DM-controlled active quest
is labelled as handled by the DM rather than asking an unlinked player to submit.

`/quest` instructions describe guild invocation, private current choices and
submit/revise/Clear buttons while open. They do not promise resource assignment,
public quest inspection, automatic submission, scheduling or penalties for missing
choices. Eligibility details stay private; public activity does not imply that a
choice is currently eligible. Authors must keep public summaries, character names
and opening narration safe for everyone in the public channel; semantic secret
redaction is not possible for deliberately authored public text.

The opening renderer canonicalizes CRLF and standalone CR to LF across all public
text (narration, names and summaries) before chunking. Signed narration retains its
submitted value; preview and future transport use the same canonical message chunks.

`Discord.Content.unicode_chunks/1` bounds new opening chunks to 1900 UTF-16 units,
preserves ordinary Unicode graphemes, and splits only pathological oversized
graphemes at codepoint boundaries. It is lossless and rejects invalid UTF-8.
Existing `Content.chunks/1` and existing command pagination remain unchanged.
Preview displays the exact chunk text, without truncation or reflow into a single
approximate message. A future transport must suppress mentions, as existing
Discord adapters already do.

## ENG-65 integration contract (not implemented)

1. Reuse the signed preparation validation under the campaign authorization lock,
   including readiness, actor/campaign and renderer/input version. Do not accept
   arbitrary rendered chunks or a new version from a stale tab.
2. Within the same transaction as opening, capture the validated preparation and
   persist its **exact ordered chunks and destination** with stable per-tick,
   per-chunk idempotency keys. Replace/integrate the legacy public announcement
   deliberately; do not accidentally send both announcement formats.
3. Enqueue durable outbox/job records atomically. Failure must roll back opening.
   Workers send saved chunks, never re-render live roster/narration after commit.
   Retries must not reopen ticks or regenerate changed content. Mention suppression
   and route guards belong to delivery; no network I/O belongs in the transaction.
4. Define immutable storage/history, delivery failure/retry and renderer migration
   semantics in ENG-65. A preview token is not durable storage or a delivery receipt.
   Bump `OpeningOutput.version/0` for content/chunk contract changes.

See [tick lifecycle](tick-lifecycle.md), [DM boundaries](dm-domain.md),
[DM console](dm-console.md), [quest submissions](quest-submissions.md),
[Discord capabilities](discord.md), and [durable work](durable-work.md).
