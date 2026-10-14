# Transport-neutral journal creation (ENG-51)

Journal persistence lives in `AsyncWorlds.Journals`. Discord's modal initiation,
15-minute expiry, opening, cancellation and stale-component validation live in
`AsyncWorlds.Discord.JournalCreation`. Both use the same trusted persistence
primitive; existing Discord commands and in-flight receipt UUIDs remain valid.

## Direct domain APIs

```elixir
Journals.create_entry(guild_id, verified_access, idempotency_key, attrs, visibility)
Journals.create_dm_entry(authenticated_scope, character_id, idempotency_key, attrs, visibility)
```

`attrs` contains `title` and `body`. Visibility defaults to `"private"`; `"public"`
(or the corresponding atoms) must be chosen explicitly. The existing Unicode,
length, nonblank and NUL validation applies. Client-supplied ownership, campaign,
author, origin and visibility fields in `attrs` cannot override trusted values.

The player API resolves current ownership through `PlayerAccess`, retaining debug
persona checks. The DM API uses `DMAccess` to freshly authorize the actual DM
under the campaign lock, then selects a campaign-owned character explicitly.
It works for linked/accountless characters without selecting or changing a
Discord persona. DM-authored entries record `origin: :dm` and the actual verified
DM author; player and tested-persona creation retain `:player` / `:dm_persona`.

Results are `{:ok, %{id: request_uuid, entry_id: entry_id, state: :completed,
visibility: visibility}}` or `{:error, reason}`. A deleted replay returns the same
original entry ID with `state: :deleted`, without recreating content. No modal
opening, interaction ID, signed component or Discord callback is required.
These are domain APIs only; HTTP endpoints will be added in ENG-61.

## Idempotency and privacy

Keys are nonblank valid UTF-8 strings of 1–200 bytes, without NUL. UUIDs and ordinary
application request identifiers work; keys do not need to be Discord snowflakes.
Identity is scoped to campaign, verified actor and creation origin. A retry with
the same target, content and visibility returns the original retained outcome.
Reusing a key for different content/visibility/character/configuration returns
`:idempotency_conflict`, including after deletion. Different actors/campaigns and
Discord modal flows do not collide. Request authorization is checked again on
replay; a retained outcome cannot restore revoked access.

The campaign lock serializes concurrent attempts before checking/inserting the
request. Entry and completed outcome commit atomically. Failed validation saves
neither entry nor request; repeated requests from another process work from the
database, not memory. Direct outcomes do not expire. Modal pending receipts still
expire after 15 minutes, and modal submit replay retains its existing behavior.

The existing receipt table holds both kinds of retained outcomes. Direct request
identifiers are namespaced hashes; bindings store a content fingerprint, target,
owner and configuration, never title/body, original keys or interaction tokens.
Completed/deleted outcomes must not be pruned. SQL content writes disable query
logging, and validation returns safe error atoms rather than draft-bearing
changesets. Journal visibility/ownership rules remain unchanged: a newly linked
owner inherits journal content, unlike personal tick-result history.

## Deployment

Run migrations before deploying: `20261014110321_add_dm_journal_creation_origin.exs`
adds the `dm` attribution value to journal entry/receipt constraints. The request
column already stores strings, so existing modal IDs/receipts need no conversion.
Downgrade refuses to silently rewrite DM attribution if such records exist.
