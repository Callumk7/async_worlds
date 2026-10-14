# Shared DM operation boundaries (ENG-49)

DM interfaces use these actor-aware APIs:

- `AsyncWorlds.DM.Ticks`: lifecycle/status, snapshots/drafts, review edits,
  previews/publication, resolution job inspection and reminders.
- `AsyncWorlds.DM.Clocks`: clock/audit reads, create/edit, fill adjustment,
  reset, pause/resume (edit), racing pair/unpair.
- `AsyncWorlds.DM.Deliveries`: inspection/filtering and targeted retries.

The first argument is an authenticated scope containing `campaign` (a campaign
struct) and `discord_user_id` (the verified actor). WebAuth and API bearer
authentication already produce this shape. Discord builds it from the dispatcher’s
verified campaign and member identity. Neither actor nor campaign should be
assembled from untrusted request-body fields.

Every operation returns `{:ok, value}` or `{:error, reason}`. Reads also return
these tuples, including `{:ok, nil}` when there is no active tick.

`DMAccess.run/2` re-fetches the campaign with `FOR UPDATE`, authorizes the current
DM and checks the scope's guild/DM/channel configuration. It holds that same lock
through the operation. A revoked actor returns `:unauthorized`; changed
configuration for a still-authorized actor returns `:stale_campaign`. Invalid
scopes/identities fail closed. The callback’s result is unwrapped, not returned
as nested success tuples. Callback failure rolls back the whole transaction.

Clock writes derive audit source from the verified actor and an interface label
(`:web`, `:http`, `:discord`, `:operator`). Default HTTP source is
`dm:http:<actor>`; existing LiveView writes remain `dm:web:<actor>`. An arbitrary
source string cannot stand in for authorization. Review edits likewise obtain
their audit actor from scope, not operation parameters.

The wrappers delegate existing semantics, preserving campaign isolation, tick
locks, optimistic clock/draft/delivery checks, audit reasons, immutable snapshots,
atomic publication/outbox writes and explicit ambiguous-retry confirmation.
Discord closes the active tick under the same lock used for authorization and
selection, avoiding a separate unprotected read-before-close sequence.

## Trusted internal APIs

The lower-level `AsyncWorlds.Ticks`, `Clocks`, and `Deliveries` APIs remain for
resolvers, workers and domain code already holding the campaign authorization
lock. They are **not** safe HTTP/LiveView/Discord DM entry points by themselves.
Do not expose tick draft storage, custom publication callbacks, clock lock toggles,
clock completion, delivery enqueue/claim/settle through controllers. The DM
wrappers deliberately do not include these engine/worker primitives.

Characters, Quests and quest submissions already have actor-aware boundaries;
continue using them directly. Published history uses `Ticks.History`'s DM
boundary. Player projections and Discord’s player-visible clock reads are
separate from DM administrative access and remain unchanged.

HTTP endpoint implementation comes in subsequent issues. Controllers should pass
`conn.assigns.current_scope` to these wrappers, not call the lower-level APIs with
only a database campaign ID. Reminders still require their existing request ID;
transport-neutral request identifiers are a separate issue.
