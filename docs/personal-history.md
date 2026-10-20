# Shared personal history (ENG-50)

`AsyncWorlds.Ticks.PersonalHistory` owns personal result/submission queries and
historical ownership checks. `Discord.PrivateRetrieval` only formats these values
and adds Discord empty-state text and slash-command guidance. Retrieval never
sends messages, creates delivery intents or changes game state.

## Player/validated persona access

- `result(guild_id, verified_access)` returns the latest applicable published
  personal output, independent of outbound delivery status.
- `submission(guild_id, verified_access)` returns the latest frozen actual choice;
  it can be available while resolution/review is pending, before publication.

Both resolve the current character through `PlayerAccess`, under its campaign
lock. Ordinary identities must match the historical owner as well as the current
character. A transferred character's new owner cannot inherit previous private
history. Existing debug personas are freshly validated; forged/stale personas
cannot retrieve history.

## Explicit DM character selection

- `dm_result(authenticated_scope, character_id)`
- `dm_submission(authenticated_scope, character_id)`

These use `DMAccess` to authorize the current DM under the campaign lock, then
select a character belonging to that campaign. DMs may inspect previous owners'
history, including DM-controlled characters, without impersonating a player or
changing the Discord debug persona. Invalid or foreign character IDs return
`{:error, :not_found}`. The implemented [HTTP history endpoints](http-history.md)
use these APIs for explicit DM character result/submission retrieval.

## Return values

All calls return `{:ok, value}` or `{:error, reason}`. Empty applicable history is
`{:ok, nil}`, not Discord-specific prose or an interaction response.

Results contain only:

- `tick_id`, `tick_number`, `published_at`, `character_id`
- `content_chunks`: ordered strings copied from the immutable approved personal
  output. Joining them with no separator reproduces the existing Discord result.

Submissions contain only:

- `tick_id`, `tick_number`, `character_id`, `choice_id`, `choice_label`

The choice label comes from the frozen revision, never the latest live content.
Raw publications/snapshots, definitions, flags, other characters, recipients,
delivery guards and internal routing metadata are not returned.

Modern publications select the character's `owner`/`dm_controlled` primary
output, excluding `dm_copy` and other characters sharing the DM recipient. Legacy
recipient-based output remains supported. Later drafts or world-only turns do
not replace an earlier applicable approved personal result or actual submission.
