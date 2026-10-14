# HTTP tick review and publication (ENG-58)

These are private DM-only routes using [bearer authentication](http-api.md) and
[HTTP conventions](http-conventions.md). Base:
`/api/campaigns/:guild_id/ticks/:id`, where `id` is the database tick ID.

| Method | Path | Result |
| --- | --- | --- |
| GET | `/review` | 200 current canonically validated review projection |
| GET | `/review/preview?draft_id=<UUID>` | 200 exact output for that current draft |
| POST | `/review/edits` | 200 new draft metadata and audit record |
| POST | `/publish` | 200 published tick metadata after atomic commit |

POSTs require `Content-Type: application/json`. Unknown body fields/query
parameters are rejected. Only preview accepts a query parameter (`draft_id`).
No caller-supplied actor, random value, payload, effect, output, routing or
callback is accepted. Tick access is campaign-scoped and freshly authorized.

## Review and preview

Review returns `id` (draft UUID), `tick_id`, `input_revision` (snapshot UUID),
integer `revision`, `inserted_at`, `world_news`, nullable `world_news_override`,
`clocks` and `quests`. It validates canonical audit replay under the same
campaign lock as the read; it never dumps raw draft/snapshot JSON.

Clocks include string `id`, `name`, `visibility`, `segments`, final `filled`,
`paused`, `completed`, `frozen_filled`, `frozen_completed` and nullable
`delta_override`. Hidden clocks are visible to this authorized DM only.

Quest rows include string `character_id`, `name`, frozen `input`, effective
`outcome`, `critical`, `text`, `before`/`after` positions (`node_id`, `status`,
`position_version`), nullable `outcome_override`/`narration_override`, `dice`
and `next` safe node text/choices. Each die includes opaque `identity`, zero-based
`die_index` and effective `value`. Input has string `character_id`,
`progression_id`, `revision_id`, text `node_id`, `choice_id` and integer
`position_version`. Send this exact input back for quest edits; it is not an
editable submission. Dice identities retain their existing opaque JSON-tuple
string format; do not decode/rebuild them.

Preview requires the displayed draft UUID. It returns `draft_id` and `outputs`
with `public`, `dm`, `players` arrays, each message explicitly projected to
`kind`, string `recipient_id`, `content`. These are the exact content and
recipients the shared renderer will enqueue on publication. An absent player
output is an empty array. Routing guards and internal delivery metadata are
not exposed. Private/hidden state is never inserted into the public audience
by the HTTP adapter.

## Audited edits

Body:

```json
{
  "draft_id": "<current UUID>",
  "reason": "Reviewed correction",
  "operation": {"type":"clock_delta", "clock_id":"123", "delta":2}
}
```

Supported strict operation shapes:

- `clock_delta`: `clock_id`, `delta` (integer or null to restore frozen behavior).
- `world_news`: `text` (paragraph array; `[]` suppresses, null restores generated news).
- `outcome`: `input_revision`, exact `input`, `value` (`failure`, `partial`,
  `success`, or null to restore dice-derived outcome). Rolled choices only.
- `player_narration`: `input_revision`, exact `input`, `value` (text or null
  to restore authored narration). Fixed choices also support narration.
- `reroll`: `identity`, `old_value` (integer 1–6). New values are generated only
  by the domain after authorization, current-draft and target validation.

Reasons must be nonblank, NUL-free and at most 2000 graphemes. Domain validation
retains all narration limits, frozen-target checks, critical bonus rules and
re-resolution semantics. See [world review](tick-review-publication.md) and
[quest review](quest-review.md). Effects are recomputed from frozen inputs, not
patched into the previous result; original roll records remain immutable.

Success returns `draft` metadata and `audit` with string audit/actor IDs,
previous/current draft UUIDs, reason, timestamp and explicitly projected
operation (rerolls include the audited old/new values). Reload `/review` and
preview the returned UUID before further edits/publication. Never blind-retry a
mutation using the latest server revision.

## Publication

Body: `{"draft_id":"<reviewed UUID>","confirm":true}`.

Confirmation is the JSON boolean `true`, not a string, and is separate from
concurrency. Success returns `tick_id`, `number`, `status: "published"` and
`published_at`. The shared domain operation validates canonical replay and
frozen/live inputs, applies state, records immutable publication/output, queues
deliveries, advances the counter and unlocks management atomically. No network
I/O happens in the request. A delivery failure after commit must use delivery
retry operations, never another publication.

## Errors

Missing `draft_id` is 428 `precondition_required`; malformed UUIDs are 422
`invalid_parameters`. Stale revisions are 409 `stale_draft`; stale quest/die
identities are 409 `stale_input`/`stale_identity`. Invalid operations/reasons are
422 `invalid_edit`/`invalid_reason`. Missing/false approval returns 409
`confirmation_required`; nonboolean approval is 422 `invalid_parameters`.
Publication drift returns 409 `stale_live_state` with no partial writes;
republication returns 409 `already_published`. Invalid lifecycle states return
409 `invalid_transition`. Missing drafts return 404 `no_draft`; missing/foreign
ticks or revoked ownership are concealed 404 `not_found`. Canonical corruption
returns bounded 500 `internal_error`, never the stored payload or exception.

Review audit history is available at `GET /api/campaigns/:guild_id/ticks/:id/review/audits`. It returns attributed edits with prior/current draft IDs, reason, timestamp and a whitelisted operation. No raw snapshots or internal records are serialized.
