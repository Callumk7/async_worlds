# Quest assignment and intervention HTTP API (ENG-56)

These are DM-only operations. They use verified bearer [authentication](http-api.md)
and the existing `Quests` management/intervention boundary, not player endpoints.
Definitions/revisions and working-copy authoring remain in [HTTP quests](http-quests.md).

| Method | Path after `/api/campaigns/:guild_id` | Body | Success |
| --- | --- | --- | --- |
| GET | `/quests/management` | none | 200, campaign operational state |
| GET | `/characters/:id/quests` | none | 200, operational state with selected character |
| GET | `/characters/:id/quests/unlocked` | none | 200, `data: [...]` published availability |
| GET | `/characters/:id/quests/interventions` | none | 200, `data: [...]` recent interventions |
| POST | `/characters/:id/quests/assign` | `revision_id`, `reason`, `expected_progression` | 200, `data: progression` |
| POST | `/characters/:id/quests/replace` | `revision_id`, `reason`, `expected_progression` | 200, `data: progression` |
| POST | `/characters/:id/quests/move` | `node_id`, `reason`, `expected_progression` | 200, `data: progression` |
| POST | `/characters/:id/quests/end` | `reason`, `expected_progression` | 200, `data: progression` |

`guild_id` is a Discord guild ID; character and revision IDs are campaign-scoped
database IDs. Mutations require JSON objects and `Content-Type: application/json`.
Unknown body fields and query parameters are rejected. Actors, audit attribution,
character selection, and campaign scope never come from body identity fields.

## Operational reads

Management state explicitly projects `characters`, `revisions`, `selected`,
`interventions`, and `locked` from the freshly authorized domain result. Character
rows contain `id`, `name`, nullable `discord_user_id`, nullable active `progression`,
`quest_name`, and `revision_number`. The selected character additionally includes
its pinned `revision` (`id`, `campaign_id`, `quest_id`, `number`, `definition`), or
null if no active assignment. Without selection, `selected` is null and
`interventions` is empty. Rows are ordered by character ID; revision summaries
follow the domain's quest-name/ID and descending revision ordering. Summaries
contain `id`, `quest_name`, `content_id`, and `number`.

Progressions contain exactly `id`, `campaign_id`, `character_id`, `revision_id`,
`node_id`, integer `position_version`, and string `status` (active/completed/ended).
Only **active** progressions appear in management state; after completion/ending,
the selected progression becomes null. Mutation responses may return the completed
or ended record, but it is not a new active-state precondition.

Unlocked quest rows contain `id`, `campaign_id`, `name`, and `content_id`, ordered
by quest ID. Availability is not assignment and never interrupts an active quest.
DM assignment is not restricted to the unlocked list; this preserves domain policy.

Intervention history is the domain's ten most recent records, newest first. Each
record projects `id`, `campaign_id`, `character_id`, nullable `tick_id`, `actor_id`,
`operation`, trimmed `reason`, `before`, `after`, `invalidated_submissions`, and
`inserted_at`. Before/after positions explicitly include only `id`, `character_id`,
`revision_id`, `node_id`, `position_version`, and `status`; before can be null.
These audits and full definitions are DM-only, not player-safe projections.

Database/Discord IDs are decimal strings, versions/counts remain integers,
timestamps are UTC ISO 8601, and nullable values are explicit. Definition content
retains its native format, including integer clock references, as in HTTP authoring.
No schema/association or raw internal snapshot is serialized. All responses use
`Cache-Control: no-store`; there is no new pagination contract for these domain lists.

## Preconditions and required reasons

Every mutation requires the **presence** of `expected_progression`. Copy the full
`selected.progression` from a prior management read (or a still-active mutation
response). It must be the complete seven-field object above, or explicit JSON null
when no active quest exists. Absence is not inferred from the latest database state.

Example assignment with an explicit absence precondition:

```json
{"revision_id":"12","reason":"Introduce this story","expected_progression":null}
```

Example movement:

```json
{
  "node_id":"end",
  "reason":"Finish this chapter",
  "expected_progression":{
    "id":"42","campaign_id":"1","character_id":"7","revision_id":"12",
    "node_id":"hub","position_version":1,"status":"active"
  }
}
```

Missing preconditions or a missing object `position_version` return 428
`precondition_required`. Malformed preconditions/versions return 422
`invalid_parameters`. Changed identity, campaign/character/revision, node, version,
status or active/absent state returns 409 `stale_progression`. Same-revision replacement
creates a **new progression ID** even though the new position version starts at 1;
old IDs cannot substitute for it. Changed positions retain the domain's monotonic
position version. Explicit null retains the domain's absence check; it is not a
new generation token tracking past assignment/absence cycles.

Precondition maps are never used as records or authorization. The adapter compares
against freshly actor-authorized management state, then passes its **server-loaded
progression** (or explicit absence) to `Quests` as `expected_progression`. The domain
rechecks the full record under its campaign lock, closing the read/write race.
No automatic stale retry or substitution with latest state occurs.

`reason` is mandatory, nonblank text of at most 2000 Unicode characters, without
NUL. Missing/null/invalid reasons return 422 `invalid_reason`; the transport never
uses the domain's trusted-caller default reasons. The domain trims and records the
reason and derives the actor from the verified DM. Callers cannot forge either.

## Mutation behavior

Assignment starts at the selected immutable revision's start node, completing
immediately if that node is an ending. Assignment with a current active precondition
returns 409 `active_quest`. Replacement calls `Quests.swap`: it ends an existing
active progression, invalidates its open choice, and starts an independent assignment
at the supplied revision. The shared domain also allows replacement from explicit
absence, creating an assignment with a swap audit.

Movement uses only the **currently pinned** revision. Invalid destinations return
422 `invalid_node`. Moving to the current node is a no-op: it still requires a valid
precondition/reason, but does not invalidate submissions, change the version or
append an audit. Actual movement increments the position version, clears this
character's open submissions, and completes on an ending node. End stops an active
quest without completing it and clears open submissions. Move/end from explicit
current absence return 404 `no_quest`.

Successful interventions atomically record exact before/after positions, verified
actor, active tick attribution and invalidated-submission count. Other characters'
progressions and choices are unaffected. A bad target revision, invalid reason/node,
stale state or tick lock leaves **all** progression, submission and audit state
unchanged. No endpoint migrates published content, applies player choices or runs
resolution triggers.

Tick resolution/review blocks interventions with 409 `tick_locked`; reads remain
available and report `locked`. Missing/foreign characters or revisions, malformed
resource IDs, and revoked/unauthorized campaign access are concealed as 404
`not_found`. No client-supplied identity or precondition authorizes access.

## Yaak examples

`yaak/quest-interventions.json` includes all eight endpoints plus missing-precondition,
stale-progression and missing-reason examples. The **Quest assignments and interventions**
folder is also saved in the local Async Worlds workspace.

```sh
yaak import yaak/quest-interventions.json --workspace-id YOUR_WORKSPACE_ID
```

Select **Quest intervention examples**. Configure `BASE_URL`, `GUILD_ID`,
`DM_API_TOKEN`, `QUEST_CHARACTER_ID`, and `QUEST_REVISION_ID` locally. Copy
`selected.progression` into `QUEST_EXPECTED_PROGRESSION` as a complete JSON object
(or `null` after reviewing an unassigned character). Templates insert it as JSON,
not a quoted string. `QUEST_REASON` is explicit and `QUEST_NODE_ID` selects a move.

Refresh the precondition from a successful active mutation response or management
read before another write. Completed/ended responses are not active preconditions;
reread management state. After a conflict, review current state before resubmitting.
The examples do not fetch or silently refresh upstream state. Send requests
individually in a development campaign: assignments, replacements, movement and
ending change real state and can clear player choices. Credentials are blank in
the export; do not run the folder blindly as a write suite.
