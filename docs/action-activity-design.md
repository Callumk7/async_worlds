# Versioned public action activity (ENG-66)

**Status: bounded technical design, not implemented.** Builds on ENG-65
(`d59f24b`, present in base) and slice B of the
[agreed flexible-actions plan](flexible-actions-plan.md). ENG-67 must review the
implementation gates below at milestone start. This document specifies behavior
and evidence required, not a database schema, migration, new service, or completed
acceptance tests.

## Scope and decisions

Maintain **one logical activity per (campaign, character, tick)**. Selection,
replacement, withdrawal and visibility changes converge that activity to the
latest accepted intent. Usually it has one Discord message; long content has an
ordered set of physical message chunks. No per-revision announcement stream.
This is intent, not an outcome, action approval, or tick publication.

Keep Phoenix/domain authorization, PostgreSQL transactions, Oban and the Discord
adapter. Do not introduce a standalone reconciliation service. Proposal status
rendering is a future integration seam, not an implementation of custom actions
or quest adaptation in this slice. No live Discord calls are needed for design or
automated verification.

### Public copy release and safe rollout

- Newly authored actions default to action-detail visibility, but detail requires
  explicitly authored, public-safe announcement text released by the DM. Import
  and authoring must validate and preview this public copy separately from the
  private choice label. Public text is not automatically redacted.
- Legacy choices default to **submission-only**, never label-as-public-text.
  Missing/unreleased public copy also falls back to the generic submission-only
  renderer. Action-detail requires an explicit opt-in release of authored public
  text against its immutable content revision. No silent label fallback, bulk
  inferred approval, or extraction from private narrative.
- Preview identifies generic fallback versus authored copy, destination, chunks,
  visibility and release status. An author may deliberately copy a label into a
  public field, inspect it, and explicitly release that revision; the system must
  never do this automatically. Editing public copy requires a new release.
- Release means **permission to disclose that copy**, not adjudication of a
  player's action. Future custom proposals are saved as awaiting DM decision and
  are not resolvable until separately adjudicated. Their entry UI must warn of
  public-by-default text and allow a private request **before** public dispatch;
  requests are held private pending the DM's visibility decision. Public-copy
  approval cannot accept a proposal, roll dice, or apply game effects.
- Enable prospectively at a tick boundary per campaign. Do not scan/backfill old
  submissions, replay historical actions/messages, adopt guessed old messages,
  rewrite saved briefings/publications, or announce existing active-tick choices
  on deployment. Release of copy alone produces no outbound activity. The first
  enabled tick starts with no activity receipts. Existing private labels remain
  available only through their existing private projections.

## Current code versus required change

| Current implementation and evidence | Required change / boundary |
| --- | --- |
| `Quests.Submissions.submit/4` replaces a `Submission`; `clear/3` deletes it. `PlayerAccess.run/3` supplies authorization/transaction and campaign serialization; exact progression identity is revalidated. No persistent submission sequence survives clear. | In the same transaction, maintain durable mutation versions and latest public intent, including a withdrawal tombstone. Keep current ownership, identity, eligibility and open-tick checks. Add no network dependency to submission. |
| `invalidate_open/2` deletes submissions on assignment/ownership changes; eligibility may invalidate at read/close. | Audit every supported invalidation path: atomically retire/update the associated intent when invalidation becomes known, including close-time invalidations. Never let queued text imply a still-current selection after known invalidation. |
| `Deliveries.enqueue/3` deduplicates a campaign/key with identical tick, kind, recipient, content and guard; different content returns `:delivery_conflict`. `Delivery` has one content string and one message/channel receipt. | Do not reuse this immutable-content API as mutable activity storage or enqueue independent creates for revisions. Add a bounded activity reconciliation contract in the existing domain/outbox architecture with ordered persistent receipts and latest-intent checks. Physical representation is an ENG-67 decision. |
| `claim/2` commits `sending`, generation and attempt count; `settle/2` checks generation/attempt. Duplicate `sending` claims classify interrupted work as ambiguous. | Preserve conservative interruption handling, but add one durable exclusive dispatch gate for the entire activity, across chunks and revisions. A duplicate job is not permission to dispatch a successor. |
| `retry_delivery/4` increments a delivery retry generation; `DeliverDiscord` jobs contain IDs/generation only, use ten attempts, and snooze when disabled. | Separate retry/attempt identity from intent/submission versions. Activity retry must reconcile latest state, not send saved obsolete text. Do not expose generic confirmed-ambiguous retry as an activity replacement shortcut. |
| `Adapter.send_public/2`, `send_private/2` create messages. `edit_response/2` edits an interaction response, not a persistent channel message. `NostrumAdapter` wraps `Message.create`, canonicalizes IDs and disables mentions. | Add channel-message edit, fetch and delete capabilities with operation-specific normalized results; do not use interaction tokens. A message-specific Unknown Message result must be distinguishable from missing channel/forbidden/unknown outcome. Keep payload/error redaction and mention suppression. |
| `Ticks.open_tick/2` atomically saves the ENG-65 briefing and queues `opened:<chunk_index>` plus guarded private prompts. `publish_tick/3` saves approved outputs/game state and queues exact chunks. | Leave these immutable intents and retry semantics alone. Activity is an additional pre-publication public exception, never raw draft output. |
| `DM.Deliveries` freshly authorizes reads/retries via `DMAccess`; private notification guards check owner/route/current prompt state. | Add authorized, version-checked activity inspection/recovery controls without weakening private guards or rerouting existing saved outputs. |

Existing evidence is narrower than the new contract:

- `test/async_worlds/deliveries_test.exs` covers enqueue conflicts, transaction
  rollback, saved receipts, stable bounded nonces, stale retry settlement,
  interrupted sends, disabled bots and restart. Its old-generation test does
  **not** prove an already-dispatched edit cannot arrive late at Discord.
- `quest_submissions_test.exs` covers replace/clear, ownership, identity,
  eligibility and frozen close. Its “submit, replace, clear are private” contract
  must be refined: private action data remains private except deliberately
  projected public intent. Preserve per-player reads and non-driving readiness.
- `quest_submissions_concurrency_test.exs` races submit/replace/clear with close
  and persona changes. Add intent atomicity assertions to both possible orders;
  existing races alone do not exercise transport scheduling.
- `ticks/opening_delivery_test.exs`, `public_activities_test.exs` and
  `private_tick_notifications_test.exs` protect exact safe opening bytes, legacy
  public-summary fallbacks, rollback, guarded prompts and blocked-DM independence.
  `discord/transport_test.exs` protects mentions and error classification. Retain
  these regressions; they are not activity-edit tests.
- `test/support/discord_fake_adapter.ex` currently returns fixed create IDs and
  has no channel-message store or controlled edit scheduling. Extend the fake
  for deterministic activity evidence rather than claim existing tests prove it.

## Durable identities and atomic acceptance

These are logical persistence requirements, **not proposed tables/columns**:

1. The activity key is stable and unique across all revisions, withdrawals,
   channel changes and chunk replacements for that character/tick.
2. A monotonic **submission version S** survives deletion/clear. Actual accepted
   changes advance S; an exact duplicate request/no-op does not. Clear then
   resubmit cannot recreate an old version (ABA). Request deduplication is scoped
   to verified actor, operation and expected context; conflicting reuse rejects.
3. A monotonic **intent generation I** identifies exact rendered desired public
   state: source S, public-copy release/version, visibility, destination,
   renderer version and ordered exact chunks. Visibility, release revocation or
   route changes may advance I without changing S. Same effective intent is a
   no-op. Withdrawal/invalidation is durable even with no live Submission row.
4. A **delivery-attempt generation A**, plus attempt identity, identifies a
   particular reserved external operation, its I, chunk slot and receipt
   incarnation. Retrying transport does not advance S or imply fresh intent.
   A new physical create has a distinct incarnation/nonce identity.
5. Persist ordered receipts: slot, incarnation, channel ID, message ID, confirmed
   applied I/content digest, operation outcome and retirement/deletion status.
   Retain retired receipts for cleanup/audit; never overwrite an old channel ID
   with a newly configured destination. Store uncertain operations even when
   there is no receipt. A logical activity is confirmed only when **all** desired
   slots and retired-slot cleanup are confirmed for current I.

Under campaign-before-tick/activity lock order, submission mutation, S increment,
intent I/rendered content (or explicit suppressed state), audit and durable work
wake-up commit together. Persistence/job insertion failure rolls back **both**
submission and intent. Never rescue an intent failure and return action accepted.
No Discord I/O happens in this transaction. After commit, offline bot, forbidden,
timeout or worker crash cannot reject/undo the accepted action. Private
`/submission` retrieval and close/freeze use committed domain state independently
of notification success. Workers never change choices, resolve or publish.

Only IDs/versions belong in job args. A job is a wake-up, not authority to send
its historical payload. Coalescing jobs is an optimization; durable latest intent
and dispatch checks are the correctness mechanism. A bounded pending-intent scan
can recover missed wake-ups without regenerating historical actions.

## Serialization, including the external fence limit

Reserve one external operation at a time **per whole logical activity**, across
nodes, jobs, chunks, channels and intent generations. Use short DB transactions
for reservation/results, not a campaign lock held over network I/O. Before each
operation, reload latest I and receipt set; only the current desired operation
may reserve the gate. Duplicate/stale jobs exit or wake current reconciliation.
Persist reservation before dispatch. Compare A/attempt on settlement; do not mark
current I applied based on a response for older I. However, retain a definitive
old create receipt as an external fact so it can be edited/removed, not lost.

A new submission can commit while I1 is dispatched. It records I2 but does **not**
start another external mutation. When I1 definitively completes, reconcile I2
against the resulting receipt before dispatching more work. Intermediate
unsent intents may be skipped. No queued I1 job can later send I1 after I2 is
confirmed. A partially applied older generation stops between operations when
superseded; the latest intent drives all remaining operations.

**Database generation checks cannot fence a Discord request already dispatched.**
Discord channel edits do not accept our compare-and-swap generation. A timeout,
worker termination, lease expiry, Oban rescue or process restart does not prove a
request (including Nostrum internal requeues) has stopped. Therefore an unresolved
operation keeps the activity gate blocked; never auto-expire the gate and let I2
race an unknown I1 request. This deliberately sacrifices availability. Merely
ignoring I1's late DB settlement would not prevent I1 overwriting I2 at Discord.

Ambiguity requires controlled reconciliation below. A fetch is an observation,
not proof no old write can still arrive. If transport quiescence cannot be
established, remain blocked; an operator risk override must explicitly record
that ordering/privacy guarantees no longer hold. No finite sleep is proof of
quiescence. The normal contract prevents old-job overwrite through serialization,
not a false external generation fence or exactly-once promise.

## State transitions

States below describe reconciliation; desired I may advance in any state without
altering accepted game state. “Current” means rechecked under the durable gate.

| State / event | Durable transition | Allowed external operation |
| --- | --- | --- |
| No activity + accepted enabled submission | Save S/I and pending or suppressed intent | None in submission transaction |
| Pending + stale/duplicate wake-up | No historical payload dispatched; schedule current I if needed | None for stale I |
| Pending current I, no receipt, public output | Reserve create with A/slot/incarnation | One create |
| Pending current I, known receipt, same channel | Reserve edit with A and exact receipt | One edit, never create because text changed |
| Sending + new I | Save latest intent; gate remains occupied | No successor operation |
| Sending + definitive receipt/success | Save operation fact; release gate; recheck latest I | Next current operation only |
| All current slots applied and cleanup confirmed | Confirm applied I | None until intent changes |
| Explicit rate rejection / proven no dispatch | Retryable, bounded backoff/attempts; release gate | Reconcile current I, not historical text |
| Forbidden/auth/invalid request/channel missing | Blocked with bounded reason | None until diagnosed authorized retry |
| Timeout/unknown 5xx/malformed receipt/crash after reservation | Ambiguous, retain gate and operation identity | No automatic resend, edit, delete or replacement |
| Late definitive result for still-unresolved A | Save receipt/outcome even if I superseded; then reconcile latest | No historical follow-on chunks |
| Definitive message-specific deletion evidence | Mark that receipt missing; recovery-required | No automatic create |
| Private with known public receipts | Pending removal at latest I | Serialized neutralize/delete; confirm only when all public receipts are absent |
| Submission-only with detailed receipts | Pending generic replacement at latest I | Neutralize detail across all slots, edit retained slot to generic submitted text, delete surplus; confirm only after both |
| Withdrawn with posted receipts | Pending generic withdrawn state at latest I | Neutralize old detail, edit retained slot to generic withdrawn text, delete surplus; never-posted withdrawal creates nothing |
| Authorized reconciliation after evidence/quiescence | Adopt verified receipt, confirm missing, or retain block; audit | Fetch/targeted cleanup; replacement only with explicit authorization |
| Paused/disabled | Intent remains durable; no new reservation | None |

Retry exhaustion leaves visible blocked work, not silently “delivered.” Bounded
error atoms and metadata only; no raw Discord bodies, tokens or private payloads
in logs/Oban errors.

## Reconciliation, deletion and channel routing

For ambiguous **create**, do not call create again, even with the same nonce.
Inspect the persisted attempted channel/operation. Prefer a late definitive
receipt. An authorized operator may attach a specific message ID only after
fetch verifies channel, bot authorship and an exact discriminator persisted
before dispatch: the create nonce bound to that activity/slot/incarnation must
match the fetched message nonce (or an equivalently verifiable persisted
incarnation marker). Author/channel alone never suffice: same-channel opening,
publication and other activity messages must reject. If the fetched object omits
the discriminator, adoption remains blocked; do not infer identity from content
or a supplied ID. Content similarity alone is insufficient. Ambiguous or multiple candidates stay
blocked for inspection and targeted cleanup. A bounded channel-history inspection
may assist the operator; absence from a page/search is not proof of absence and
must not authorize an automatic replacement.

For ambiguous **edit/delete**, retain the known receipt and fetch that exact
message. Establish transport quiescence before applying latest I; otherwise a
late old edit can undo the correction. Delete of an already absent exact message
can count as cleanup only on definitive message-specific evidence. Forbidden,
missing channel and generic 404 do not prove a message was deleted.

Deleted-message recovery is an explicit operation against latest I, expected
activity/receipt version and confirmed missing slot. It creates only the missing
slot/incarnation after authorized confirmation, never replays prior revisions or
recreates confirmed surviving chunks. Ambiguous replacement creates block just
like initial creates. A private latest intent must never be recreated publicly.

Creates use a stable operation-specific nonce with `enforce_nonce: true`, bounded
to Discord's 25-character limit (the existing worker uses 24 ASCII hex bytes).
Reuse for a safe retry of that same create; not across slots/incarnations. Discord
only deduplicates for the past few minutes, not across arbitrary outages; neither
nonce nor content hash is a durable receipt or exactly-once guarantee.

Controls, through fresh `DMAccess` authorization and optimistic I/A/receipt
versions, must support: inspect desired/applied state and ordered receipts,
pause/resume dispatch, diagnose/retry known failures, reconcile exact IDs, confirm
missing-slot replacement, and targeted cleanup. Record actor, reason, evidence,
versions and explicit risk acknowledgments without logging private copy. Concurrent
or stale confirmations reject. Resume never blindly replays saved jobs. Ambiguous
activity recovery must not be reachable through generic `confirm_ambiguous: true`
create retry alone. Existing immutable outbox retry retains its documented policy.

Campaign channel configuration changes do not silently move an existing activity.
New activities use the configured route; existing activities require explicit
reroute preview/confirmation. Reroute advances I, retains old receipts, neutralizes
or removes old-channel chunks first, and only then creates current chunks in the
new channel. Permission loss or unknown old-channel cleanup blocks the move;
operator may explicitly abandon old receipts with an exposure warning and audit,
not falsely report a clean move. Never edit an old message ID using a new channel
ID. Rerouting does not redirect saved opening/publication/private intents.

## Visibility, withdrawals and multi-chunk partial failure

- **Action detail:** render released public action text and an unambiguous selected
  status, not success. Future proposal renderers distinguish awaiting decision,
  accepted custom action, declined/revised/withdrawn without private feedback or
  unpublished resolution data.
- **Submission-only:** generic “has submitted an action,” with no private choice,
  quest identity, reason, condition, flags or effects.
- **Private:** no public post if nothing was sent. If receipts exist, neutralize
  and remove them; do not publish “is taking a secret action.” Withdrawal updates
  an existing public activity to a generic withdrawn state, removing prior detail;
  if never posted, suppress rather than create a new withdrawal announcement.
- Changes toward less disclosure cancel unsent old operations immediately. Any
  already-dispatched operation must settle/reconcile before cleanup can finish.
  Show cleanup pending/blocked to the DM, and never claim immediate privacy.
  Discord readers, notifications, caches and screenshots cannot be recalled.

Render deterministically and persist exact chunks with a renderer version, using
`Content.unicode_chunks/1` (1900 UTF-16 units), canonical newlines and no blank
chunks as in ENG-65. Preview uses those same bytes and ordering. Bound authored
input and maximum chunk count in ENG-67 before enablement; overflow rejects the
public-copy release, not an already accepted player's network delivery. Never
truncate private text into a supposedly safe fallback. Disable mentions on every
create/edit and clear stale components/embeds if those ever become supported.

Use stable ordered slots, not independent concurrent jobs per chunk. Edit existing
slots in order, create growth slots sequentially, persisting each receipt before
the next operation. Shrink neutralizes/deletes surplus slots before confirming the
new shorter set. For a privacy reduction, neutralize **all** known old chunks
first, before posting replacement public copy. A failure on chunk 2 preserves
chunk 1's receipt/progress; no restart from chunk 1 create. An ambiguous growth
slot blocks further mutation; a failed surplus deletion prevents “fully applied.”
Superseding I rerenders neither historical content nor old jobs; it reconciles
latest exact chunks against confirmed/uncertain slot facts. Multi-message changes
are not atomic on Discord: mixed generations and temporary gaps are possible,
with explicit partial/cleanup status. One logical activity does not promise one
physical message or uninterrupted message ordering after a missing-slot repair.

## Required deterministic evidence (future tests, not executed tests)

Implement a supervised fake with unique IDs, an ordered channel-message store,
request-dispatched and server-applied barriers, separately releasable responses,
fetch/delete/forbidden/unknown-message outcomes, and a controllable clock. Use
explicit messages/monitors and DB transaction barriers, never sleeps or live
Discord. Assert exact call traces, message-store content, receipt order, S/I/A,
accepted choice and job state. Exercise separate database connections for races.

| Case | Controlled schedule | Required assertions |
| --- | --- | --- |
| Old queued job | Commit S1/I1; commit S2/I2; run I1 job then duplicate jobs | Only latest I2 may create; one receipt set; no I1 payload dispatched. |
| In-flight old edit | Seed receipt; dispatch I1 edit, hold before server apply; commit I2; run I2 job; apply/respond I1; resume | No I2 dispatch before I1 settlement; I1 fact saved but not current-applied; final edit is I2; late duplicate I1 job cannot overwrite. |
| Unknown old edit | Dispatch I1; lose response; commit I2; rescue/restart workers; fetch old content; later apply I1 | Gate remains blocked, zero I2 writes while unknown; fetch alone does not unlock. After controlled quiescence and reconciliation, only latest correction runs. |
| Accepted action survives transport | Commit submission and intent; fail create with forbidden, timeout, then restart/disabled bot | `/submission` still returns accepted choice, S/I survive, close freezes it; no undo or publication call. |
| Intent DB failure | Fail intent/job persistence between submission mutation and commit, including clear | Entire transaction rolls back: previous submission, S/I/audit/jobs unchanged; caller receives failure; zero network calls. |
| Submit versus close | Force submission lock first, then separately close lock first | First order freezes submitted choice and committed intent together; second rejects late mutation with no intent. Known close invalidations retire intent atomically. |
| Clear/ABA/dedup | Submit; exact duplicate request; clear twice; resubmit; run delayed first job | Duplicate/no-op does not increment; withdrawal survives row deletion; resubmit has greater S/I; old work cannot resurrect it. Conflicting request-key reuse rejects. |
| Ambiguous create | Server creates M1, drops response; restart, drain repeatedly, advance clock beyond nonce window | Exactly one create call; ambiguous gate remains; no blind duplicate. Verify/adopt M1 under authorization then edit to latest I. |
| No receipt / uncertain absence | Lose create response, history scan returns empty or several plausible messages; try adopting same-bot same-channel opening, publication and another activity; omit nonce, then supply wrong nonce, then exact persisted nonce | No replacement create; unrelated messages and absent/wrong discriminator reject even with matching author/channel/content. Only exact persisted activity/slot/incarnation evidence permits adoption after quiescence; otherwise remain blocked. |
| Deleted message | Confirm exact Unknown Message for one known slot; run duplicate jobs; authorize recovery twice concurrently | No automatic create; one version-checked replacement for latest public I, surviving slots unchanged; stale confirmation rejects. Private latest I creates nothing. |
| Growth/shrink | Grow 1 to 3; create slot 2 succeeds, slot 3 rate rejects; retry; then shrink to 1 with deletion failure | Slot 2 never recreated; sequential trace; shrink not confirmed until surplus cleanup; retained retired receipts. Unknown slot 3 response blocks further writes. |
| Privacy transition | Separately seed 3 detailed chunks for private, submission-only and posted-withdrawal targets; dispatch old edit; commit target I; fail middle-slot neutralization, then resume; also withdraw a never-posted intent | No new old-detail dispatch; outstanding request serialized; partial exposure flagged until cleanup succeeds. Private ends with all public receipts removed and no secrecy post. Submission-only ends with one generic submitted message; posted withdrawal with one generic withdrawn message; both require confirmed surplus removal and retained-slot edit before applied I. Never-posted withdrawal sends nothing. No private reason/proposal in public bytes. |
| Reroute | Seed old channel; change config; request move; fail old cleanup, then reconcile and resume | No implicit move/new-channel create; explicit confirmation required; old channel receipts retained; latest copy only after cleanup or audited exposure override. |
| Approval/rollout | Enable with legacy private labels and old submissions; release new copy without submitting; submit next enabled tick | No historical jobs or label exposure; generic legacy fallback; release alone sends nothing; released copy only on new eligible intent. No action adjudication side effects. |
| Authority/isolation/regression | Revoke DM between inspect/confirm, change persona/owner, use foreign campaign IDs; replay existing opening/publication tests | Stale/foreign controls reject; invalidations update intent; exact opening/private/publication outputs and guards unchanged. Unicode boundaries and mention suppression hold on edits too. |

## Limitations and ENG-67 milestone-start gates

Normal-operation ordering is conditional on definitive transport completion; a
crash or unknown response can block an activity indefinitely. No exactly-once
Discord delivery, external transaction, instantaneous privacy, semantic secret
redaction, or atomic multi-chunk switch is promised. Operators may need Discord
inspection and transport shutdown/drain evidence; if such evidence is unavailable,
remaining blocked is valid. Risk overrides explicitly weaken guarantees.

At milestone start, confirm the following bounded implementation slices rather
than plan later custom-action/adaptation milestones:

1. **Contract gate:** approve public-copy release/fallback and prospective rollout
   policy, renderer/input/chunk bounds, operation-specific Discord errors, and a
   credible transport-quiescence/operator runbook. If transport cannot establish
   safe recovery, ship fail-closed ambiguity controls, not timed auto-resends.
2. **Atomic domain slice:** choose persistence representation only now; implement
   S/I/tombstones, dedup and all supported invalidation writers with submission
   transaction/freeze tests. Keep dispatch feature-disabled until evidence passes.
3. **Transport/reconciliation slice:** adapter create/edit/fetch/delete and durable
   whole-activity gate, ordered receipts and controlled fake schedules. Prove the
   queued, dispatched and ambiguous old-job cases separately; existing retry
   generation tests are insufficient.
4. **Operator/rollout slice:** authorized inspection/recovery/reroute, visibility
   cleanup and partial-failure UX; regression-check ENG-65 opening, publication and
   private retrieval/notifications. Enable only for a newly opened opted-in tick
   after deterministic evidence and review. Any later disposable-server rehearsal
   needs separate authorization and recorded evidence, not a claim from unit tests.

No speculative migration or production test stubs accompany ENG-66. Future proposal
adjudication plugs into versioned intents only when its own domain contract ships.
See [durable work](durable-work.md), [quest submissions](quest-submissions.md), and
[tick opening](tick-opening.md) for the shipped behavior this design preserves.
