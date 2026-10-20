# Public tick opening (ENG-64 / ENG-65)

## Shipped boundary

The authenticated DM dashboard has **Prepare / reload exact preview** before the
next tick. It shows the next number, the exact public channel ID and **every**
numbered message chunk. Optional public opening narration is independent of
world news: it never reads or writes resolution drafts, trigger news or published
outcomes. Preparation and preview perform no delivery, job, tick, progression,
audit or other game-state writes. There is no schedule or automatic open.

**Opening atomically saves and queues the public briefing** plus the existing
guarded private quest prompts. The inspected-open button queues exactly the
reviewed chunks; it does not also send the legacy `Tick N is now open.` message.
The existing quick-open flow is now **Open with default briefing** (browser
confirmation), as are Discord `/tick open` and HTTP opening: they capture the
current public roster and `/quest` instructions with empty narration, requiring
no narration configuration. Existing close/review/publication is unchanged.

## Context API

Use `AsyncWorlds.DM.Ticks` with a verified authenticated scope, not IDs from forms:

- `prepare_opening(scope, %{"narration" => text})` (default `%{}`) returns
  `{:ok, preparation}`. Unknown fields, non-text, invalid UTF-8, control characters
  and more than 8000 bytes reject as `:invalid_opening`. Blank narration is omitted.
- `preview_opening(scope, preparation.token)` returns the **same exact content**
  only if authorization, readiness and input version still match.
- `open_prepared_tick(scope, preparation.token)` revalidates under the same campaign
  lock and opens with that exact briefing, its durable outbox intents and jobs.
- `open_tick(scope)` captures a default briefing under the same authorization lock.
- `fetch_briefing(scope, tick_id)` reads the saved immutable briefing under fresh
  authorization, scoped to the campaign. Legacy ticks without a briefing return
  `:not_found`. No new HTTP routes or player access to this record are introduced.

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

`Ticks.OpeningOutput.render/5` is the shared pure renderer for preview and opening
capture. Delivery workers send stored content, never render live inputs. Its roster comes from ENG-63's `Quests.public_activities/2`,
using pinned public summaries, never private quest/node text or latest-library
narration. It renders every character, including legacy-summary fallbacks,
unassigned, ended/completed and DM-controlled characters, plus an explicit empty
roster. Ownership IDs never enter public messages. A DM-controlled active quest
is labelled as handled by the DM rather than asking an unlinked player to submit.

Renderer v3 adds the explicitly adopted **Tension-led** variant (campaign
`tension_participation`, set from the dashboard; see the
[operating guide](tension-led-operating-guide.md)). It tells everyone they can
take part without a quest through Tension threads and `/intent`, omits
"No quest decision required" lines, and keeps lines plus `/quest` guidance only
for characters with an outstanding quest decision. The default text is unchanged.

`/quest` instructions describe guild invocation, private current choices and
submit/revise/Clear buttons while open. They do not promise resource assignment,
public quest inspection, automatic submission, scheduling or penalties for missing
choices. Eligibility details stay private; public activity does not imply that a
choice is currently eligible. Authors must keep public summaries, character names
and opening narration safe for everyone in the public channel; semantic secret
redaction is not possible for deliberately authored public text.

The opening renderer canonicalizes CRLF and standalone CR to LF across all public
text (narration, names and summaries) before chunking. Signed and stored narration retain their trimmed submitted value; preview and
transport use the same canonical message chunks. Spacing-only chunks are omitted
by the shared renderer before numbering and preview, since Discord rejects blank
content-only messages. Nonblank chunks retain their exact whitespace, including
leading newlines. Outbox workers never drop or rewrite reviewed chunks.

`Discord.Content.unicode_chunks/1` bounds new opening chunks to 1900 UTF-16 units,
preserves ordinary Unicode graphemes, and splits only pathological oversized
graphemes at codepoint boundaries. It is lossless and rejects invalid UTF-8.
Existing `Content.chunks/1` and existing command pagination remain unchanged.
Preview displays the exact chunk text, without truncation or reflow into a single
approximate message. The shared delivery worker suppresses mentions, as existing Discord adapters do.

## Durable opening and retries

`tick_briefings` stores one immutable record per tick: narration, renderer version,
input digest, public destination and `outputs["messages"]` in reviewed order with
one-based chunk indexes, public kind, recipient and exact content. Tokens and
private input records are not saved in the briefing. There is no edit/regenerate
operation, and existing ticks are not backfilled. Future renderer changes must
bump `OpeningOutput.version/0`; they invalidate outstanding preparations, not
rewrite saved briefings or queued deliveries.

The same database transaction inserts the tick, briefing, all public intents,
private prompt intents and Oban jobs. Any persistence failure rolls back all of
these writes. Public keys are `tick:<tick_id>:opened:<chunk_index>`; private prompt
keys and fresh-state guards are unchanged. Repeated/concurrent opens return
`:active_tick`, never create another turn, briefing or logical announcement.
Ordered indexes represent content order; separate Oban jobs are not a guarantee
of network arrival order.

No network I/O runs while opening. Offline delivery is paused; failed or ambiguous
sends do not undo opening. Use the existing delivery inspection and targeted retry
controls (`AsyncWorlds.DM.Deliveries`, dashboard or HTTP delivery routes). Retry
checks the selected delivery generation under the authorization/campaign lock,
queues only that saved chunk and does not open a tick, render again or resend
unrelated public chunks/private prompts. Sent deliveries cannot be retried;
interrupted sends become ambiguous rather than blindly resent. Explicit ambiguous
retry confirmation retains the existing possible-duplicate warning.

`/quest` remains the private guild retrieval path when a prompt DM is blocked.
An opening briefing is immutable history, not a delivery receipt: inspect delivery
status separately. No deadlines, resources, automatic close, or durable public
activity-message edit/update contract is added.

The [ENG-66 action activity design](action-activity-design.md) plans mutable
per-character intent messages separately from these immutable briefings. It
preserves opening/publication/private prompts and does not replay saved history.

See [tick lifecycle](tick-lifecycle.md), [DM boundaries](dm-domain.md),
[DM console](dm-console.md), [quest submissions](quest-submissions.md),
[Discord capabilities](discord.md), and [durable work](durable-work.md).
