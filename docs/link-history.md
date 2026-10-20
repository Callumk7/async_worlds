# Retained link state changes (ENG-81)

`AsyncWorlds.LinkHistory` is the DM-only history foundation used by
[membership](memberships.md) and [location containment](locations.md) writers.
Those contexts provide current-state operations, DM console controls and HTTP
endpoints. LinkHistory itself retains and queries timeline data; it has no timeline UI,
history HTTP endpoint or Discord command.

## Writer contract

Use `LinkHistory.transact(scope, callback)` from trusted domain code. The scope
contains a server-loaded campaign and a verified `discord_user_id`, following
`DMAccess`. Authorization and all callback work share the campaign row lock and
transaction.

The callback receives the reloaded campaign and returns either:

- `{:ok, value, changes}`: persist the changes and return `{:ok, value}`.
- `{:error, reason}`: roll back current-state writes and return that error.

A callback exception also rolls back and propagates; it is not converted to a
successful operation. At most 100 changes may be returned per call.

Each descriptor contains:

```elixir
%{
  kind: :faction_membership,
  link_id: membership.id,
  entity_refs: %{"character" => [character.id], "faction" => [faction.id]},
  before: nil,
  after: %{
    "character_id" => character.id,
    "faction_id" => faction.id,
    "role" => membership.role
  }
}
```

`link_id` is optional (containment has no separate link row). `before`/`after`
are string-keyed JSON objects or nil for absence. Equal states produce no record;
an empty change list is also allowed. Snapshot objects are bounded to 16 KiB and
8 levels, and accept strings, integers, booleans, nil, lists and objects. They
reject invalid UTF-8, NUL, atom keys, structs, and other unsupported values.

The trusted writer must load old state, validate its domain rules, and mutate the
current link **inside the callback**. It must derive descriptors from those
records rather than accepting caller-supplied snapshots, tick numbers, actors,
or endpoint identities as authoritative. There is no separate append-history
API: failures during history validation/insertion roll back the callback's writes
and any earlier history inserts in the batch. No external effects are allowed
inside a callback, since database rollback cannot undo those effects.

`entity_refs` is a typed endpoint index:

- Membership: exactly one character and one faction.
- Containment: one to three distinct location IDs, covering the child and any
  old/new parent. Include all affected endpoints so history is queryable from
  either side. Snapshots identify the child and old/new parent explicitly.

All indexed entities must exist in the authorized campaign at write time. A
writer removing an entity itself needs separate deletion integration; this
foundation is intended for changes to links between existing entities. History
queries do not require those live entities or current link rows to survive.

## Tick attribution

Tick attribution is server-assigned while holding the campaign lock:

| Lifecycle | Attributed tick number |
| --- | --- |
| Open tick N | N |
| Resolving/in-review tick N | N + 1 |
| No active tick, latest published N | N + 1 |
| New campaign | 1 |

The existing campaign `current_tick_number` advances only on publication.
Consequently resolving/review attribution must use the active tick number plus
one, not simply the campaign counter plus one.

`(campaign_id, tick_number)` is the durable association. The next tick row need
not exist, so records deliberately have no tick foreign key to backfill. Opening
that tick does not rewrite history. Tick numbers can later join to `ticks` on
campaign and number. Attribution to a nonexistent future tick is valid; a null or
missing tick number is not. Exceeding the supported tick-number range fails
before invoking the writer callback.

Recording changes does not open ticks, create deliveries, modify character
state versions, or add data to resolution snapshots/publications. Descriptive
link writes remain possible while gameplay inputs are locked.

## Retention and attribution

`link_changes` retains kind, optional link ID, typed endpoint identities,
before/after state, tick number, authenticated actor, stable ID order, and UTC
recording time. It is DM-only; there is no visibility editor or member projection.

The database rejects updates and individual deletes. Link/entity IDs are retained
values, not foreign keys to current records: removing a current link cannot erase
its transitions. Whole-campaign deletion can cascade these records, matching the
existing campaign lifecycle. No archival or general retention-policy framework
is introduced.

## DM queries

```elixir
LinkHistory.list_changes(scope)
LinkHistory.list_changes(scope, tick_number: 3)
LinkHistory.list_changes(scope, entity: {"character", character_id})
LinkHistory.list_changes(scope,
  tick_number: 3,
  entity: {"faction", faction_id},
  limit: 20,
  after_id: cursor
)
```

All queries freshly authorize the DM and scope to the campaign. Supported entity
types are `"character"`, `"faction"`, and `"location"`. A deleted or foreign entity
ID returns no matching records in the authorized campaign; queries never fetch
another campaign's history. Malformed or overflowing filters return
`{:error, :invalid_filters}`.

Results are `{:ok, %{items: changes, more?: boolean, next_cursor: id_or_nil}}`.
Changes are ordered by ascending ID, including within a tick. Page size defaults
to 50 and is limited to 100; `after_id` defaults to 0. The cursor is the last
returned ID when another page exists. Endpoint containment uses a GIN-indexed
JSONB map, and campaign/tick/ID indexes support bounded ordered retrieval.

Historical snapshots are evidence of recorded link state changes, not executable
events, author-authored narration, or automatically approved player messages.
Future timeline rendering must apply its own audience projection.

## Verification

`test/async_worlds/link_history_change_test.exs` covers descriptor validation.
`test/async_worlds/link_history_test.exs` covers lifecycle attribution, immutable
retention, queries, authorization, current-state/history rollback, and no-ops.
A temporary test-only link table exercises the transaction contract without
introducing the membership implementation from ENG-83.

See [World model design](world-model-design.md) for the agreed scope and deferred
work.
