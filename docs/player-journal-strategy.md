# Player journal implementation strategy (ENG-43)

Status: proposal for approval; no persistent journal implementation.
The follow-up [ENG-44 legacy-modal spike](journal-modal-spike.md) now provides an
opt-in, preview-only frontend on Nostrum 0.10.4. Automated conversion/dispatcher
tests pass; live Discord acceptance remains to be checked. Legacy Action Row
wrappers are a deliberate deprecated-format choice, avoiding Label support work.

Source requirements: [ENG-42 — Journal and Notes](https://linear.app/warp-monster/issue/ENG-42/journal-and-notes).
Research ticket: [ENG-43](https://linear.app/warp-monster/issue/ENG-43/research-and-define-implementation-strategy).

## Recommendation

Build one `AsyncWorlds.Journals` context backed by PostgreSQL, with character-owned
entries and explicit public/private visibility. Deliver through the existing
Discord bot, not a separate service. All interaction replies stay ephemeral:
**public means discoverable by campaign players, not automatically posted to a
channel**. Journal writes are independent of ticks and remain available during
resolution/review. Notes are player-written content, never inputs to resolution.

Prefer a title + multiline-body modal for creation, gated by a small Nostrum
compatibility spike. If that requires an unapproved dependency change, ship the
same domain API through slash-command string options instead. Do not let editor
infrastructure expand this into a rich-text, collaboration or document-linking project.

## 1. Scope and proposed product behavior

| Command | Behavior |
| --- | --- |
| `/journal new [visibility:private\|public]` | Defaults to private. Opens a private creation flow for the player's linked character. |
| `/journal list [scope:mine\|public]` | Defaults to mine. Mine lists that character's applicable entries; public lists public entries across the campaign. Paginated newest-first. |
| `/journal open entry:<ID>` | Opens an authorized entry, with complete body and visibility/author/date labels. Also reachable from list buttons. |
| `/journal delete entry:<ID>` | Presents private Confirm/Cancel controls; confirm deletes only an authorized entry. |

Proposed limits: title 1–100 Unicode codepoints; body 1–4,000 codepoints. Reject
whitespace-only input; preserve body formatting. Titles can repeat; display a stable
entry ID rather than using titles as identifiers. Use STRING options for bigint IDs
instead of Discord INTEGER options. Missing/forbidden/deleted IDs share a generic
unavailable response. No autocomplete in MVP: it would introduce another deadline
and privacy-sensitive discovery path.

For the DM, offer `/journal list scope:character character:<ID>` to inspect a
campaign character's public and private entries. This explicit DM view requires
DM role, not just the real actor being the DM. A DM without a linked character
must still be able to inspect private entries. No web journal UI is required by
ENG-42; a future DM console can reuse the same context.

### Authorization policy — confirm before implementation

- Create: linked player subject only, including the existing authorized DM player persona.
- Read public: linked campaign players and current campaign DM. No cross-campaign access.
- Read private: current DM in DM role, or the entry's original player author while
  still linked to its character. Enforce both author identity and current character
  ownership; a new owner must not inherit an old owner's private notes.
- List mine: public entries for the current character plus private entries meeting
  that author/ownership rule. DM-authored debug entries need an explicit exception:
  entries deliberately created as a player persona belong to that character and
  are readable by its current owner. Persist their origin; don't infer it later.
- Delete: original author who still owns the character; selected player persona
  under the same rules; optionally current DM in DM role. DM deletion is a
  recommendation for moderation, not an explicit parent-ticket requirement.
- A DM testing as a player follows player restrictions, not the unrestricted DM
  read path. Accountless characters remain supported through that persona.
- Former owners lose private access after unlinking; current DM retains it. Public
  entries remain campaign-visible. This deliberately does not transfer old private
  entries automatically; an explicit transfer policy can be added later if wanted.

This is **application access control**, not end-to-end encryption: the current DM
and database operators can access stored private notes. Label private creation
clearly: “Visible to you and the campaign DM.” Never imply “only you.”

## 2. Existing implementation fit and gaps

- `lib/async_worlds/discord/commands.ex`: catalogue drives registration and help.
  Its generic router only accepts leaf commands without arguments; add a delegated
  journal definition/router, following `DebugInteractions`, for typed option parsing.
- `lib/async_worlds/discord/dispatcher.ex`: validates application, configured guild,
  gateway member identity, and role/persona context. It currently accepts interaction
  types 2/3 only, defers every request privately, and sends all non-debug components
  to `QuestInteractions`. Add journal namespace routing and type-5 modal submission
  handling without changing existing quest behavior.
- `lib/async_worlds/player_access.ex`: transactionally locks the campaign and freshly
  resolves the linked character or validated debug subject/generation. Reuse for
  player journal operations, including public listing. It requires a character,
  so DM reads need a separate freshly authorized DM path.
- `lib/async_worlds/characters.ex`: demonstrates current-DM checks under campaign
  lock and campaign-scoped fetches. Reuse the authorization pattern, not its
  `mutable!` tick lock: notes do not mutate world state.
- `lib/async_worlds/discord/quest_interactions.ex`: useful bounded rendering,
  navigation and stale-control patterns. Journal controls must reauthorize against
  the journal record, actor and persona, not copy quest lifecycle identifiers.
- `lib/async_worlds/discord/adapter.ex` and `nostrum_adapter.ex`: injectable transport,
  ephemeral responses, suppressed mentions, safe errors. Add `open_modal/2` only
  if the spike succeeds. Fake adapter tests must cover the new callback.
- Existing `Content.chunks/1` splits replies at 1,900 codepoints. Reuse for open;
  list bounded metadata only, not every body. Suppress mentions for all player text.
- Existing character `(id, campaign_id)` unique index supports a composite FK,
  as demonstrated in `20261011174736_create_quest_domain.exs`.

No Oban/outbox delivery is needed: entries persist in the database and are pulled
through interactions. Proactive DM copies/public announcements are out of scope;
“visible to the DM” is satisfied by an authorized retrieval path.

## 3. Data and domain design

New `journal_entries` table / `AsyncWorlds.Journals.Entry` schema:

- `id`, non-null `campaign_id`, non-null `character_id`.
- Immutable `author_discord_user_id` (trusted actor), `origin` (`player` or
  `dm_persona`); origin is assigned server-side after authorization.
- `title` (`:string`), `body` (`:string` in Ecto, PostgreSQL `text`).
- `visibility` (`Ecto.Enum`, `private` / `public`), default private.
- `creation_request_id` (trusted slash interaction ID or modal-flow ID), timestamps.
- `deleted_at` for a tombstone. Exclude deleted entries from every read/list.

Constraints: campaign FK; composite `(character_id, campaign_id)` FK to characters;
allowed visibility/origin; bounded nonblank text; unique
`(campaign_id, creation_request_id)`. Only title/body/visibility enter ordinary
user changeset casts; ownership, origin and request identity are set by the API.
Do not cascade-delete character history silently.

Use partial indexes for active character entries `(campaign_id, character_id, id)`
and public campaign entries `(campaign_id, id) WHERE visibility = 'public' AND
 deleted_at IS NULL`. Use ID-descending keyset pagination with a bounded page size
(e.g. 10), fetching one extra row for Next; never load the whole journal.

Deletion proposal: soft-delete to preserve creation idempotency even if a delayed
create request is replayed after deletion. Deleted content is not retrievable via
application APIs, but remains in storage/backups. This retention policy needs
approval; if deletion must erase content, clear title/body in the tombstone or
use a separate durable creation receipt before hard-deleting. Do not promise
permanent erasure while silently retaining bodies.

Proposed APIs (names are illustrative):

- `create_entry(guild, access, request_id, attrs)`
- `list_entries(guild, access, scope, cursor)`
- `get_entry(guild, access, entry_id)`
- `delete_entry(guild, access, entry_id, expected_control)`
- Separate DM list/get/delete variants using verified actor identity and current-DM
  checks under the campaign lock; no linked-character requirement.

All APIs authorize inside the transaction. Query by campaign AND entry ID and
apply visibility before returning a whitelisted projection. Never fetch globally
and filter after rendering. Player list projections exclude bodies and internal
actor/debug metadata. User-supplied character IDs are allowed only for the explicit
DM inspection route, never as a player subject selector.

Create is idempotent by trusted request/flow identity: duplicates return the same
entry (or an already-deleted result), not another insert. Validate that a reused
request matches its authorized subject and immutable creation payload. Identical
text submitted in a genuinely new flow is allowed. Delete is idempotent after a
successful authorized confirmation. Campaign-lock-first ordering serializes note
operations with ownership/configuration changes; keep Discord REST outside locks.

## 4. Creation UX and Discord compatibility gate

Discord requires an initial response within 3 seconds. Interaction webhook tokens
last 15 minutes. A modal opens via callback type 9, not by editing/following up a
deferred response. Modal submission arrives as interaction type 5. Text inputs
allow up to 4,000 characters; modal titles max 45; `custom_id` max 100.

Current Discord docs recommend Label (type 18) wrappers for modal text inputs.
Installed Nostrum 0.10.4 has modal `data.components`, but its inbound
`Nostrum.Struct.Message.Component` lacks the singular `component` field used by
Label wrappers; conversion drops unsupported fields. Sending raw outbound maps
alone does NOT solve inbound decoding. This is a static code finding, not a live
Discord compatibility test.

First spike: round-trip a representative current Label-wrapped submit fixture
through Nostrum's actual interaction conversion, including multiline/Unicode
values. Check outbound callback payload and a real development-guild modal.
Investigate a compatible maintained Nostrum release if necessary; any dependency
change needs explicit approval. Do not patch `deps/` or ship a new flow built on
obsolete Action Row text-input wrappers without a deliberate compatibility decision.

Recommended modal flow, once compatibility is proven:

1. `/journal new visibility:...` uses existing immediate ephemeral defer.
2. After authorization, persist a small expiring creation flow (no note body yet)
   bound to campaign, actor, character, chosen visibility, origin and debug generation.
   Return an ephemeral “Write entry” button, showing who can read the result.
3. That button has a dedicated initial-response branch: validate the envelope,
   actor/guild and bounded flow, then `open_modal` directly, with a strict deadline
   on pre-response work. Never defer and then attempt type 9. If it cannot safely
   validate/open in time, fail privately; no entry is created.
4. Submit type 5: defer privately FIRST, parse a bounded allowlisted title/body
   shape, reauthorize current ownership/DM/persona and flow, then insert atomically.
   Changes while the form was open invalidate it; never retarget to a new persona.
5. Entry insert and flow completion commit together. Repeated submissions of the
   same completed flow cannot create a second entry, even with different interaction
   IDs. Expired/abandoned flows are cleaned up without storing tokens or draft text.

Use a compact opaque random flow identifier in `custom_id` and persist its binding;
keep the complete identifier under 100 characters. Flow expiry is our policy,
not the original command token's lifetime: button clicks/submits have new tokens.

Fallback (no modal support / no approved dependency change):
`/journal new title:<text> body:<text> visibility:<private|public>` with registered
STRING limits (title 100/body 4,000). It works with the existing deferral pattern,
requires typed journal option routing, and uses slash interaction ID for creation
idempotency. It is less pleasant for multiline writing but meets ENG-42. Choose
one creation frontend for MVP rather than implementing both simultaneously.

## 5. Listing, opening and deleting

Lists show ID, bounded title, character attribution, visibility and date. Use a
small number of buttons per page plus Previous/Next, within legacy message action
row limits. Full bodies are loaded only by an authorized open. Page/cursor controls
bind to actor, campaign, scope, selected character and debug generation. They are
locators, never credentials; recheck everything on every click.

Delete confirmation explicitly names the target, with Confirm/Cancel. Bind the
control to entry, actor, campaign and persona generation. Confirm performs a fresh
authorization check and atomic tombstone write; an entry ID or forged custom ID
alone never permits deletion. Return journal-specific refresh instructions rather
than the dispatcher's currently quest-specific stale-control message. Invalid,
expired or cross-user controls reveal no note metadata.

Keep all replies ephemeral, including public entry reads and errors. Reuse safe
logging: no body/title, interaction token, raw payload or Discord exception body.
A successful insert followed by a failed Discord reply must not trigger an
automatic retry. Tell users to inspect `/journal list` before creating again.

## 6. Implementation sequence and acceptance tests

1. **Confirm policy and spike modal compatibility.** Decide ownership transfer,
   DM deletion, retention, public meaning and frontend. This gates modal work only;
   the shared journal context does not depend on editor technology.
2. **Persistence/context.** Generate migration with `mix ecto.gen.migration`, add
   schema/constraints/indexes, privacy projections, cursor queries, idempotent
   create/delete and player/DM authorization tests.
3. **Discord frontend.** Add delegated journal catalogue/router/handler; implement
   chosen creation flow, list/open and confirmation components. Preserve command
   discovery and existing private transport behavior.
4. **Hardening/docs/release.** Add fake-transport and converted gateway fixture tests,
   update `docs/discord.md`, run `mix precommit`, migrate and explicitly re-register
   guild commands. No real Discord credentials in automated tests.

Test matrix:

- Player A's private title/body/metadata never appears for B or another campaign,
  including direct IDs, list cursors, components and malformed submits.
- A/B see campaign public entries; only an authorized owner/DM can delete them.
- Current DM without a character can list/open private entries; former DM cannot.
  DM persona cannot bypass player restrictions. Accountless persona creation works.
- Character relink does not hand the new owner old private notes; unlinked old
  owner loses access. DM-authored persona notes follow the approved exception.
- Persona A → B → A, role/config changes and ownership changes invalidate open
  forms/controls. Reauthorize deletion after confirmation is displayed.
- Empty journals, duplicate titles, whitespace rejection, unknown visibility,
  title/body bounds, multiline text, emoji and long bodies spanning response chunks.
- Stable bounded pagination while other entries are added/deleted; no private
  bodies returned by metadata list APIs.
- Duplicate and concurrent create/confirm events; replay after deletion; restart
  during a flow; failed initial ack causes no mutation; failed final reply does
  not duplicate a mutation; modal callback is never preceded by defer.
- Resolving/in-review ticks do not block notes. Notes never affect frozen snapshots,
  quest progression or public outbox messages.
- Catalogue registration, help discovery, actual Nostrum-converted modal payload,
  mention suppression, private followups, safe logs and unsupported interactions.

## Decisions required

1. Approve “public = campaign-readable, no automatic channel post”?
2. Approve private default and title/body limits?
3. Approve author + current-character ownership protection on relink, including
   the explicit DM-persona creation exception?
4. Should the DM be allowed to delete, or only read private notes?
5. Is soft-deletion retention acceptable, or must content be erased?
6. After the compatibility spike: modal + extra button, approved library upgrade
   if needed, or simpler slash text options?

## External sources

- [Discord interaction lifecycle and callbacks](https://docs.discord.com/developers/interactions/receiving-and-responding)
  and [raw official reference](https://github.com/discord/discord-api-docs/blob/main/developers/interactions/receiving-and-responding.mdx):
  initial-response deadline, token lifetime, modal callback and submit types.
- [Discord component reference](https://docs.discord.com/developers/components/reference):
  input limits, Label wrappers, custom IDs and button limits.
- [Using modal components](https://docs.discord.com/developers/components/using-modal-components):
  current Label-wrapped modal example.
- [Application commands](https://docs.discord.com/developers/interactions/application-commands):
  typed options and string length bounds for the fallback.
