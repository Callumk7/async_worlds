# Player journals (ENG-42 / ENG-47)

Persistent journals belong to campaign characters. PostgreSQL is the source of
truth; Discord is the creation/retrieval frontend. Journals do not participate in
ticks, snapshots, resolution, quests or the delivery outbox.

## Owner-approved policy

Approved in the implementation handoff and recorded on ENG-42 and ENG-47:

- Default **private**: visible to the current character owner and current campaign
  DM. This is application access control, not encryption against database operators.
- **Public** means campaign-readable, not automatically posted or sent to anyone.
  All interaction replies, including public-entry reads, are ephemeral.
- Journals are **character-owned**. A newly linked owner inherits all of the
  character's private entries and deletion rights. Former owners lose private
  access when unlinked. Original author identity is attribution, not authorization.
- DM player-testing mode follows the selected character's ordinary permissions.
  It can create for accountless characters; later owners inherit those entries.
  Persisted `dm_persona` origin and actual-DM attribution are retained, but origin
  does not require a special historical-private-access exception.
- Current DM **in DM role** may inspect and delete for moderation, without owning
  a character. A player persona never silently gains unrestricted DM access.
- Title: 1–100 Unicode codepoints; body: 1–4,000. Whitespace-only, invalid UTF-8 and
  NUL input are rejected. Body formatting is preserved; duplicate titles and new
  flows with identical content are allowed.
- Confirmed deletion hard-deletes entry content. Separate durable creation receipts
  retain identifiers/outcome/binding, **never title/body or interaction tokens**.
  They prevent delayed submissions from resurrecting content. Do not prune completed
  or deleted receipts. Abandoned expired pending/canceled flows may be pruned.
- Existing database backups have **separate operator-managed retention**. Application
  deletion does not erase existing backups immediately. This feature does not define
  or change the deployment's backup schedule; operators must communicate that policy.

## Commands

- `/journal new [visibility:private|public]`: private defer → persisted expiring flow
  → Write entry button → legacy Title/Entry modal → privately deferred submission
  → atomic insert/completion and an entry-ID receipt. Canceling a modal saves nothing;
  its pending receipt expires after 15 minutes.
- `/journal list [scope:mine|public|character] [character:<ID>]`: mine defaults to
  the trusted player/persona character; public shows campaign-public entries.
  Character scope requires DM role and an explicit campaign character ID. Other
  scope/character combinations are rejected.
- `/journal open entry:<ID>`: full authorized text, character, author/origin, date
  and visibility. Lists also supply Open buttons.
- `/journal delete entry:<ID>`: target-specific Confirm/Cancel. Only Confirm mutates.
  Public readability does not confer deletion rights. Current ownership/DM/persona
  is checked again at confirmation. Duplicate confirmations are idempotent.

IDs are STRING options. No autocomplete, editing, visibility changes, search,
attachments, links, rich-text editor, proactive notifications or web UI.
Missing/foreign/forbidden/deleted entry IDs share a generic unavailable response.
Stale controls instruct the user to refresh journal commands.

## Pagination and controls

Lists select whitelisted metadata only, never entry bodies. ID-descending keyset
pages contain at most ten entries, querying at most eleven candidates. Indexed
existence checks determine Previous/Next; no offsets or full-journal enumeration.

Each navigation sequence freezes its first visible maximum ID as a ceiling.
New insertions appear only after running a fresh list command. Deletions disappear
immediately; pages may shift/fill from remaining records. Previous selects the
nearest ten surviving entries above the boundary, then displays descending order.
If an entire destination window disappears, the opposite navigation control
recovers across the original boundary, inclusively, rather than stranding the user.
There is no promised snapshot of deleted entries.

Controls are compact, authenticated, 15-minute locators bound to actor, campaign
configuration, subject/ownership/state version and persona generation. A→B→A
changes invalidate them. Character profile/flag changes conservatively invalidate
existing controls too. Identifiers/signatures never replace domain authorization.
Creation controls use opaque UUID receipt locators; their bindings/expiry live in
PostgreSQL and survive process restarts. Opening never inserts an entry. Completed
submit replay returns the original ID/outcome, not changed content or another insert.

## Transport, deadlines and logging

Legacy construction/parsing is isolated in `JournalInteractions`, supported by
installed Nostrum 0.10.4 without upgrades. Modal-open callback type 9 is the initial
acknowledgment, never preceded by a defer. Submission type 5 defers privately first.
All normal commands/components defer before DB work; failed initial acknowledgment
prevents persistence. REST calls occur outside transactions.

Pre-modal preparation has a hard **1,500 ms** budget, including task scheduling,
pool checkout and campaign-lock waits. The consumer starts that budget before
launching its interaction worker. A separate bounded supervised read-only task is
canceled on expiry, leaving headroom within Discord's three-second initial-response
window. Deadline/saturation failures take the private failure path, without opening
a modal. Once a modal callback is attempted, ambiguous failure never attempts a
second acknowledgment. The budget bounds local preparation, not Discord network or
rate-limit latency; production latency/client coverage still needs live observation.

Replies split at 1,900 Unicode codepoints and suppress mentions in edits and private
followups. A final-response failure never retries writes: inspect `/journal list`
before starting another flow. Logs use safe stage classification, not payloads,
tokens, text, exceptions or Discord error bodies. Journal SQL writes disable query
logging to avoid Ecto debug logs containing title/body parameters. Do not enable raw
DB/gateway tracing or custom telemetry that logs query parameters in production.

## Deployment and verification

Migration: `20261013183642_create_player_journals.exs`. It adds entries and durable
creation receipts, campaign/composite character FKs, receipt identity uniqueness,
visibility/origin/text checks and keyset indexes. History is not silently cascaded
when a character is deleted. No data conversion, dependency or privileged intent.

1. Run the normal deployment migration process (`mix ecto.migrate`, or the release
   migration command). Restart the bot/server with the updated application.
2. Run `mix discord.register_commands` for the configured development guild; this
   bulk-overwrites this application's guild catalogue. Use a dedicated development
   application and do not run an old preview-only consumer simultaneously.
3. `DISCORD_JOURNAL_SPIKE` is removed and no longer enables/disables anything.
   Production catalogue/help/debug discovery includes journals unconditionally.
4. Run `mix precommit`. Automated tests use sandbox/committed PostgreSQL fixtures,
   fake transport, actual Nostrum gateway conversion and supervised consumers.

### Manual development-guild checklist — pending for ENG-47

The ENG-44 basic legacy modal round-trip was operator-confirmed. That proves neither
persistent ENG-47 behavior nor the following unperformed live checks:

- Create default-private and explicit-public entries; restart and list/open them.
- Check Unicode/multiline/boundary content, complete chunking and no mention pings.
- Open a private entry, cancel deletion, then confirm; list no longer shows it.
- With a second account where available, test private denial/public discovery and
  public-read-only deletion denial. Relink and confirm inherited private history.
- As DM without a character, inspect `scope:character`; switch to player personas
  for linked/accountless creation and verify actual attribution. Switch away/back
  with an open form/confirmation and verify staleness.
- Observe modal-open latency, failure banners and desktop/mobile presentation.

Record **actual** account/client/path coverage on ENG-47, including gaps. Fake-adapter
success is not live Discord success. Legacy Action Row modal inputs are deprecated;
future removal remains a compatibility risk. Do not mark ENG-42 complete until
review and the persistent MVP/live acceptance criteria are satisfied.
