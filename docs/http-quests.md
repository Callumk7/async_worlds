# Quest library and authoring HTTP API (ENG-55)

These DM-only routes use `/api/campaigns/:guild_id/quests` as their base. They
share bearer [authentication](http-api.md), [HTTP conventions](http-conventions.md),
and the existing [quest authoring domain](quest-operations.md).

| Method | Relative path | JSON body | Success |
| --- | --- | --- | --- |
| GET | (base) | none | 200, `data: {revisions: [...], working_copies: [...]}` |
| GET | `/revisions` | none | 200, `data: [...]` revision summaries |
| GET | `/revisions/:id` | none | 200, `data: revision` including definition |
| GET | `/working-copies` | none | 200, `data: [...]` working-copy summaries |
| POST | `/working-copies` | `{}` or `{"revision_id":"123"}` | 201, `data: working_copy` |
| GET | `/working-copies/:id` | none | 200, `data: working_copy` including definition |
| PUT | `/working-copies/:id` | full editable snapshot plus `version` | 200, `data: working_copy` |
| POST | `/working-copies/:id/release` | full editable snapshot plus `version` | 200, `data: {working_copy: ..., revision: ...}` |
| POST | `/working-copies/:id/recover` | full editable snapshot, no version | 201, `data: new_working_copy` |

`POST /import` remains unchanged, including its original response shape/status
and numeric IDs. See [quest import](quest-import.md). Imports and HTTP authoring
use the same campaign lock, released library, validation and immutable revisions.

## Request snapshots

Mutations require JSON objects with `Content-Type: application/json`; query
parameters and unknown body fields are rejected. Actors come only from verified
scope; callers cannot set campaign IDs, quest/base IDs, source definitions or
other internal fields. Route IDs and `revision_id` are positive database IDs;
missing/foreign/malformed resource IDs are concealed as 404 `not_found`.

Save, release and recovery take **all three** editable fields: `name`,
`content_id`, and the full `definition` JSON object. Save/release additionally
require the `version` returned by GET/create/previous save. This is a full authoring
snapshot, not a partial patch or HTML form. The adapter never fills in omitted
content from the latest persisted draft.

```json
{
  "version": 1,
  "name": "Example quest",
  "content_id": "quest_00000000-0000-4000-8000-000000000001",
  "definition": {
    "start_node": "node_00000000-0000-4000-8000-000000000001",
    "nodes": [{
      "id": "node_00000000-0000-4000-8000-000000000001",
      "text": "The journey ends here.",
      "ending": true,
      "choices": []
    }]
  }
}
```

A blank working copy receives a unique content identity and initial node from the
domain. Copy its identity and definition before editing. New node/choice IDs use
`node_<UUID>` / `choice_<UUID>`; retain stable IDs and all opaque imported fields
for existing content. Structural edits, modeled conditions/effects and rolled
choices follow `Quests.Authoring.safe_edit?/2`, not arbitrary JSON replacement.
A supplied definition may remove/reorder nodes or choices, but cannot rewrite
retained opaque fields or reparent retained choices. Unsupported edits return 422
`unsupported_edit`; released content identities cannot change (`immutable_content_id`).

## Content versus resource metadata

Revision summaries contain `id`, current quest `name`, `content_id`, and revision
`number`. Names are current library labels, not historical per-revision names.
Working-copy summaries contain `id`, `campaign_id`, nullable `quest_id` and
`base_revision_id`, `name`, `content_id`, integer `version`, `inserted_at`, and
`updated_at`. Detail responses additionally include `definition`. Revision details
contain `id`, `campaign_id`, `quest_id`, integer `number`, and `definition`.

Resource IDs are decimal strings and UTC timestamps use ISO 8601. The `definition`
field is the **existing versioned quest content format**, preserved losslessly:
embedded clock references remain native integers as required by `Definition`,
while node/choice/content identities remain their authored strings. The HTTP
adapter does not recursively stringify IDs or discard opaque content. This is
an explicit content-format exception to the resource-ID wire convention, allowing
GET/save/release roundtrips without altering imported semantics.

The internal creation `source_definition`, schemas, associations, clock snapshots
and raw validation errors are never included. Library ordering follows the domain:
revision summaries by quest name then descending revision number, working copies
by descending update time and ID. These collections are unpaginated; no new
pagination/query contract is invented. Responses use `Cache-Control: no-store`.

## Conflict, release and recovery behavior

Missing save/release versions return 428 `precondition_required`; malformed values
return 422, and changed versions return 409 `stale_working_copy`. If an import or
another editor released a newer revision of the same quest, save/release returns
409 `stale_base_revision`, even with the current draft version. Checks and writes
happen together under the existing domain lock. No stale operation is retried.

Save permits incomplete text/references but preserves safe authoring structure
and database-compatible content. Release validates the entire definition against
current campaign clocks, appends an immutable revision, and increments the draft
version atomically. Failure rolls back **all** draft/library writes. Shared nested
validation errors return the safe 422 `invalid_document` envelope; changeset
errors expose only allowed field names and fixed codes. Releasing creates/appends
content; it does not repin existing assignments, mutate live progression, or alter
frozen tick inputs. Authoring remains available during tick resolution/review,
as in the existing domain; gameplay interventions have separate tick locks.

Recovery is deliberately a **creation**, not an overwrite: submit the original
client-preserved local `name`, `content_id`, and `definition` without a version.
`Quests.recover_working_copy` validates against the original creation snapshot,
then creates independent work with a new recovered identity and ` (recovered)`
name suffix. The original working copy and released quest are untouched even if
another tab saved/released newer content. Recovered work can be reviewed/saved/
released as a separate quest. No endpoint promises creation/recovery idempotency;
repeated requests create additional working copies.

## Yaak examples

`yaak/quest-authoring.json` contains all authoring endpoints, version failures,
and an incomplete-release failure. The existing import examples remain separate.

```sh
yaak import yaak/quest-authoring.json --workspace-id YOUR_WORKSPACE_ID
```

Select **Quest authoring examples**, then configure `BASE_URL`, `GUILD_ID`, and
`DM_API_TOKEN` locally; no credentials are exported. Create or get a working copy,
then copy its fields into `QUEST_WORKING_COPY_ID`, `QUEST_WORKING_COPY_VERSION`,
`QUEST_NAME`, `QUEST_CONTENT_ID`, and `QUEST_DEFINITION` (the complete JSON object).
Set `QUEST_REVISION_ID` for revision retrieval or revision-based creation. The
example definition is a small ending-node demo for new work; replace it with your
full local content before editing existing/imported quests.

Save/release templates insert version as a JSON integer and definition as a JSON
object, not a quoted string. Refresh the version after a successful write. Tokens
are not automatically fetched, so conflicts remain visible. Recovery uses your
explicit local snapshot, not a fresh upstream GET. Send requests individually in
a development campaign: create/recover make new work, and release permanently
appends content. Do not run the folder blindly.
