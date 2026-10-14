# HTTP history

All routes require the configured DM bearer token and current campaign ownership.

- `GET /api/campaigns/:guild_id/ticks/history?page=1`: published ticks, newest first; fixed 20-item pages.
- `GET /api/campaigns/:guild_id/ticks/:id/history`: immutable approved news, revision IDs, results, clocks and exact saved message content. Each section has independent 20-item pagination via `results_page`, `clocks_page`, `messages_page`. Delivery routes, guards and errors are not returned.
- `GET /api/campaigns/:guild_id/characters/:id/history/result`: latest saved character result, including content chunks and publication time.
- `GET /api/campaigns/:guild_id/characters/:id/history/submission`: latest frozen submitted choice.

Personal endpoints explicitly select a campaign character under DM authorization. They do not impersonate an owner or accept player identities. Empty personal history returns `data: null`. Saved history never rerenders live quest definitions or depends on delivery success. Foreign subjects/ticks are concealed as 404; all responses use `Cache-Control: no-store`.
