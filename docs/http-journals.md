# HTTP journals

DM bearer authentication and fresh campaign ownership apply. HTTP uses explicit DM character selection, not Discord modal controls or a debug player persona.

- `GET /api/campaigns/:guild_id/characters/:id/journals`: all journals for that campaign character, including private entries. Returns summaries with fixed 10-entry pages and opaque `next_cursor`/`previous_cursor`. Pass a cursor in `?cursor=...`; cursors bind campaign, actor and character and retain the original upper bound. New entries do not shift an in-progress browse.
- `POST /api/campaigns/:guild_id/characters/:id/journals`: JSON `{"title":"Notes","body":"Remember this","visibility":"private"}`. Visibility defaults to private; public is supported. Requires `Idempotency-Key`. Reusing a key with identical content/subject returns the retained outcome; changing the subject/content conflicts. Deleted outcomes remain deleted on retry.
- `GET /api/campaigns/:guild_id/journals/:id`: entry content, author attribution, visibility, creation time and signed `delete_token`.
- `DELETE /api/campaigns/:guild_id/journals/:id`: JSON `{"confirm":true,"delete_token":"<from read>"}`. Confirmation binds actor, campaign configuration and target. Tokens expire after 24 hours. Missing tokens fail with 428; forged/stale tokens fail with 409. A repeated successful delete returns `already_deleted` without recreating anything.

Create receipts are transport-neutral, non-expiring and attributed to the verified DM. Journal visibility is preserved for player reads; the DM is authorized to inspect both visibility levels. Foreign subjects/entries and revoked ownership return 404. Private content is never placed in URLs or errors; responses are `no-store`. Cursor tokens expire after 24 hours and are not interchangeable with deletion tokens.
