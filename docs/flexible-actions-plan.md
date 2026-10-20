# Flexible actions and visible campaign activity

**Status: superseded as the next product direction by
[Tension-led world play](tension-led-world-play.md). Retained as the historical
quest-centred plan; implemented slices remain supported.**

The new direction removes quest-node participation and a universal one-action
limit as requirements for Tension play. This notice does not cancel existing
Linear issues, remove quests, or invalidate completed briefing/delivery work.

This document supersedes the [original MVP outline](archive/project-outline.md) and
[implementation plan](archive/project-plan.md) as the next delivery priority. Their
requirements remain historical reference, not an instruction to finish resources
before starting this work.

## Goal

Players can choose or propose meaningful actions entirely in Discord. The campaign
publicly reports their activity, and the DM can adjudicate unexpected approaches
and adapt personal storylines without developer tools.

Keep the proven quest/world tick loop. Prioritise interaction flexibility and
campaign visibility over the originally planned resource strategy layer.

## Agreed product decisions

- Public activity announcements reveal the selected or proposed action by default.
  The DM can make an action private; secrecy is an explicit exception.
- Every non-ending quest node offers a custom-action path alongside authored choices.
  No per-node enablement is required. Endings have no new decision to submit.
- A character still submits one action per tick: an authored choice or a custom
  proposal, not both. Players can change or withdraw it until closing.
- Each tick opens with a public briefing and an optional DM-written message.
- Selection, proposal, revision, and withdrawal update one public activity message
  per character per tick rather than posting a stream of revisions.
- Custom proposals require DM adjudication before becoming resolvable actions.
- Quest adaptations apply to the selected character only by default, preserving
  other characters' paths and already-frozen turns.
- Announcing intent is not approving an action or publishing its outcome. Game
  consequences still require resolution, DM review, and approved publication.

## 1. Tick-opening briefing

The DM prepares and previews a briefing before opening the tick. It contains:

- Tick number.
- Optional DM-written opening message, separate from post-resolution world news.
- Each character's public activity summary and whether a decision is required.
- Explicit no-decision states for characters without an active quest or at an ending.
- Instructions to use `/quest` for private choices or a custom proposal.

Example:

> **Tick 12 — Trouble at the harbour**
>
> The harbour gates remain closed, and rumours of sabotage are spreading.
>
> **Mira:** Investigating the missing cargo — choose your next approach.
> **Tovin:** Seeking an audience with the guild — choose how to proceed.
> **Ash:** No quest decision required this tick.
>
> Use `/quest` to view your options privately.

Public activity summaries are separate authoring fields, not copies of private
node narrative, flags, conditions, or outcomes. Existing content needs a safe
fallback, such as “A quest decision is required,” until a public summary is supplied.
A secret quest must be able to use a generic summary without revealing its identity.

Opening atomically records the briefing delivery intent alongside the tick and
existing notifications. Delivery failure must not undo opening. The preview and
saved outgoing content use the same renderer, including Discord chunk boundaries.
Opening from Discord must also work without a prepared optional message.

## 2. Public action announcements

Authored choices support public announcement text and a DM-controlled visibility
policy: action detail (default), submission-only, or private. Any fallback from a
private choice label must be explicit and visible in authoring; do not silently
reveal legacy labels when enabling this feature for existing content.

Examples:

> **Mira** has chosen to question the dockworkers.

> **Mira proposes:** Follow the cargo trail through the tunnels.
> Awaiting DM approval.

Public messages distinguish selected authored actions, pending proposals, accepted
custom actions, revisions, and withdrawals. They must never imply success or reveal
unpublished dice, outcomes, effects, or DM review content.

Custom-action entry must tell players that their proposal is public by default.
Provide a way to request private handling before sending; the DM controls the
exception. A previously public action cannot be made unseen retroactively, even
if its message is edited or removed.

Accepting a submission and queueing its announcement happen atomically. Network
failure does not reject the action. Durable updates track message identifiers and
submission versions so retries cannot overwrite newer activity with older text.
Do not promise exactly-once Discord delivery. Missing/deleted messages and ambiguous
sends need deliberate recovery, not uncontrolled replacement posts.

## 3. Custom proposals and DM adjudication

`/quest` includes **Propose another approach** on every active non-ending node.
The player writes their intended action and sees its current status through
`/quest` and `/submission`, independently of successful proactive delivery.

Logical proposal states:

- **Awaiting DM decision:** saved intent, not a resolvable choice.
- **Accepted:** bound to an existing eligible choice or a configured custom action.
- **Declined:** private feedback explains the decision; the player may submit again.
- Revision or withdrawal invalidates the previous proposal's adjudication. A
  changed proposal requires a fresh decision; stale DM tabs cannot approve it.

The DM inbox shows player intent, current node, pinned content revision, submission
version, and public visibility. It links directly to contextual authoring tools.
The DM can:

- Map the proposal to an existing eligible choice.
- Configure a one-off fixed or rolled action, including outcome text, effects,
  and validated destinations using the existing rules vocabulary.
- Revise the proposed handling with feedback and explicitly approve the configured
  action; record both original player intent and DM adjudication.
- Decline with feedback or explicitly exclude the proposal from this tick.

This does not introduce arbitrary executable rules, automatic natural-language
resolution, or automatic changes to shared quest content. Acceptance prepares an
input; it does not roll dice, apply effects, or progress the character immediately.

Before closing, show unresolved proposals distinctly from missing submissions.
Closing cannot silently discard them: the DM must adjudicate or explicitly exclude
and audit each unresolved proposal. Excluded characters stay in place without a
penalty. Ordinary missing submissions still do not prevent closing.

Accepted custom actions freeze with their configured resolution and destination
identities. Review, rerolls, outcome overrides, exact previews, publication, and
history must work for them just as they do for authored choices.

## 4. Adapt this character's quest

From a proposal or character's quest context, the DM can start an adaptation from
the currently pinned revision and node, edit/add future nodes through forms,
validate references, preview the path, and apply it at an explicitly selected node.

- Produce immutable revised content; never mutate an existing released revision.
- Apply to this character only by default. Another character following the original
  quest remains on their original revision.
- Preserve typed conditions/effects, cycles, endings, and graph diagnostics.
- Show affected submission and progression before confirmation. Revalidate or clear
  stale submissions explicitly; never reinterpret an earlier choice silently.
- Before close, adaptations can affect the upcoming turn through authorized,
  version-checked operations.
- During resolving/review, save adaptations as staged content only. Explicitly
  apply after publication against the character's then-current progression;
  if that context changed, require fresh inspection rather than automatic rebasing.
- Audit who adapted the path, why, and the before/after revision and position.

A one-off action and a persistent path adaptation are distinct tools. A custom
approach does not require rewriting the whole quest if existing destinations suffice.

## Retained architecture and safety boundaries

Keep Phoenix LiveView, Nostrum, PostgreSQL/Ecto, Oban, shared authorized domain
operations, and the testable Discord adapter. Keep the manual lifecycle:

`open → resolving → in review → published`

Frozen inputs, deterministic recorded rolls, immutable revisions, audited review,
atomic publication, stale-editor checks, campaign ownership checks, and targeted
retry controls remain requirements. Draft results stay DM-only; public intent
messages are the deliberate exception to the old pre-publication silence policy.

Hidden clocks, known-clock fill values, non-visible flags, other players' private
results, and audit reasons remain excluded from public payloads. Authored public
text and player proposals are deliberately public text, not automatically redacted.

## Delivery slices and acceptance

### A. Opening briefings

Add public node summaries, optional DM opening text, preview, and durable posting.
Accept when web and Discord opening produce a safe briefing, no-decision states
are explicit, repeated opens cannot create another tick, and failed delivery is
retryable without reopening. Existing private prompts continue working.

### B. Action activity messages

The [ENG-66 technical design](action-activity-design.md) resolves public-copy
release/legacy rollout, durable intent versions, serialization, and controlled
message recovery for this slice. It is a design, not shipped behavior.

Add visibility-aware authored announcements and versioned message updates.
Accept when selecting, changing, and clearing update the same logical message;
private exceptions reveal no action detail; old jobs cannot overwrite newer intent;
and failed sends do not lose submissions.

### C. Custom proposals and adjudication

Add player proposal controls, DM inbox, mapping/custom resolution, feedback, and
explicit close handling. Accept when every non-ending node supports proposals,
stale decisions reject, unresolved proposals cannot silently disappear, and an
accepted custom action completes the existing review/publish loop with controlled
dice and immutable history.

### D. Character-specific path adaptation

Integrate contextual authoring, isolated revisions, and staged application.
Accept when two characters on the same quest can diverge without affecting each
other, broken references block application, adaptations invalidate stale inputs
explicitly, and changes during review cannot alter frozen or approved output.

Finish with a disposable real-server rehearsal covering public/private actions,
proposal revision/decline/acceptance, individual path adaptation, missing players,
and delivery failure/recovery. Record evidence separately from automated tests.

## Out of scope for this phase

Resource ownership/assignment/strain, automated ticks, AI adjudication/narration,
combat, shared party progression, inventory/currency/trading, drag-and-drop graph
editing, published rollback, and self-service multi-campaign onboarding. Preserve
existing journals, HTTP APIs, and testing tools without expanding them merely to
complete this direction. No target dates or implementation tickets are assigned here.

## Implementation decisions to refine

- Proposal text limits and Discord modal/pagination presentation.
- How private-action requests reach the DM without leaking public intent.
- Implement the [ENG-66](action-activity-design.md) safe legacy opt-in/public-copy
  release policy and controlled deleted/ambiguous-message recovery contract.
- Data representation for one-off actions versus character-specific content forks.
- Staged adaptation storage, application ordering, and submission invalidation UX.

These refine the implementation, not the agreed public-by-default and
custom-actions-on-every-non-ending-node product direction.
