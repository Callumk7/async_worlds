# HTTP delivery inspection and retry

DM bearer authentication and fresh campaign ownership apply to all routes.

- `GET /api/campaigns/:guild_id/deliveries`: newest first, 50 records per page. Filters: `status` (pending/sending/sent/failed/ambiguous), `kind` (public/private), `tick_id`, `recipient_id`. Pass `meta.next_before_id` as `before_id` with the same filters for the next page. Unknown/invalid filters fail rather than widen the search.
- `GET /api/campaigns/:guild_id/deliveries/:id`: approved content, recipient, status, attempts, generation, safe error classification and timestamps. Internal guards, keys and raw exceptions are excluded.
- `POST /api/campaigns/:guild_id/deliveries/:id/retry`: JSON `{"generation": 0, "confirm_ambiguous": true}`. Generation is required (428 if absent); stale generations fail with 409. Only failed or ambiguous records can be retried. Ambiguous sends require the explicit boolean confirmation because a retry may duplicate a message.

Retries enqueue a new generation of that delivery only. They never republish ticks, reapply effects or regenerate messages. A repeated old-generation request fails safely; inspect the delivery before deciding whether another retry is appropriate. Sent records are never retryable. All reads are DM-only and `no-store`.
