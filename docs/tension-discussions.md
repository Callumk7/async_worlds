# Persistent Tension discussions (ENG-92)

## Audience and lifecycle

A Tension is an unsettled circumstance, independent of player actions. Existing
and newly created Tensions default to `audience: dm`. `/tensions/:id` and the
freshly authorized `DM.Tensions.create_tension/edit_tension` API expose `dm` versus
`public` (campaign-visible). Choosing public releases its name and circumstances;
public clock influence/endpoint prose is also public. **Prose cannot be automatically
redacted.** Do not put secret or foreign-campaign references in public prose.
Changing back to DM-only stops future briefings; it cannot retract saved posts.

The audience participates in revisions, opening preparation stale checks, frozen
close inputs, review changes and publication stale checks. Old snapshots without
an audience mean private and retain their previous JSON shape. Public Events
validate both sides of every attached change: a Tension must be explicitly public,
a clock public, and its associated Tensions public. Known/hidden changes cannot
be bundled into public prose as an implicit declassification. Public narrative
Events without attachments remain allowed but have no inferred thread routing.
There is no natural-language routing or automatic redaction.

Opening atomically records one immutable briefing intent per public Tension,
even with no characters, quests, commitments or attendees. Ongoing briefings show
current circumstances, public clock fill/segments and influence/endpoint text;
known clocks show **name only**, hidden clocks contribute nothing (not even counts).
Instructions distinguish discussion from confirmed commitment and adjudication.
ENG-93 commitments are not implemented here; do not infer commitments from chat.

There is one logical discussion mapping per Tension, across ticks. A worker creates
a public Discord thread under the configured campaign public text channel. Once
bound, it dispatches the saved briefing and a tick-labelled overview link through
the existing delivery outbox. Thus the link may arrive after the main overview;
creation failure does not block the tick. Subsequent openings reuse the ID.
Only publication enqueues Event/Resolution developments, only explicitly public
Events, and only to Tensions explicitly attached directly or through changed
clocks. One Event can reach several relevant discussions. Routine/DM-only bundles
and drafts do not post narrative developments. No current entity lookup can
rewrite already saved developments.

Public Resolutions append an explicit historical/resolved notice. A DM-only
Resolution of a public Tension posts only its explicitly public structured status
and Tension name, **never** the private Event's title, prose, clocks or references.
This is a status projection, not automatic prose redaction. It prevents a thread
from continuing to solicit participation after publication settles its situation.
Subsequent opening links say historical and their briefings do not ask for
participation. The thread and old posts remain discoverable; no deletion,
automatic rename, replacement, or historical backfill occurs. To publish Resolution
prose for a Tension with running private pressures, pause those in a separate
DM-only routine bundle ordered before the public Resolution: the automatic pause
must not smuggle hidden clock references into a public bundle. The focused demo
exercises this strict policy, and a separate test checks DM-only Resolution status.

## Transactions and transport

Opening/publication, discussion intents, jobs, world changes and ordinary delivery
intents commit or roll back together. Discord requests never run in those domain
transactions. Creation has a separately committed `creating` claim **before** the
request. A confirmed thread ID is durable; each saved intent expands transactionally
into stable-key existing `Deliveries` messages and overview links. Message/channel
IDs, partial failure and retries use the existing outbox and DM delivery tools.
Duplicate jobs cannot create a second bound discussion or enqueue different text
under an existing key. Creation recovery advances a generation; a late response
from an older attempt cannot bind a recovered mapping.

This is **not exactly-once external delivery**. A timeout/crash can leave a real
thread or message without a recorded ID. A second job finding `creating` marks it
ambiguous rather than creating another thread. Unknown create responses stop;
only a confirmed rate-limit rejection automatically retries. Permission/invalid
channel failures stop creation as `blocked`. If settling the result fails, another
job conservatively detects the interrupted create. Do not delete mappings to retry.

A bound thread is never automatically replaced. Before posting, the worker checks
its guild, parent, public-thread type and archived state. Archived threads stop
with `thread_archived`; deleted/permission failures stop the affected message.
Repair permissions or explicitly unarchive in Discord, then retry the failed
message through the existing authorized delivery UI/API. The preflight and send
are separate Discord requests, not an atomic remote lock; Discord itself may race
an archive change. Already sent overview links remain sent during partial failure.
Ambiguous message sends require the existing explicit duplicate-risk confirmation.
No retry opens/closes a tick or reapplies game outcomes.

The mapping pins its original guild/channel. A changed campaign destination fails
new intent creation with `discussion_route_changed`, rolling back that opening or
publication, rather than leaking to an old audience or silently replacing history.
Cross-server migration is deliberately an operator/product decision, not recovery.

## Authorized creation recovery API

The management detail shows creation state and a bound history link. Recovery is
an explicit trusted application API (not a new unauthenticated HTTP endpoint):

```elixir
alias AsyncWorlds.TensionDiscussions
# scope is the existing verified DM scope, not request-supplied actor identity.
{:ok, expected} = TensionDiscussions.get(scope, tension_id)
adapter = AsyncWorlds.Discord.NostrumAdapter
# Inspect Discord first. Prefer binding the thread actually created:
TensionDiscussions.recover(scope, tension_id, expected, {:bind, "THREAD_ID"}, adapter)
# Only after inspection, explicitly accept that a duplicate/orphan may result:
TensionDiscussions.recover(scope, tension_id, expected, :confirm_duplicate_create, adapter)
```

Only unbound `ambiguous`/`blocked` records are recoverable. Binding verifies the
thread's guild, parent and public type outside a domain transaction, then freshly
reauthorizes the DM, compares the expected record and commits recovery + job.
A foreign guild/channel, revoked actor, stale expected state or bound mapping is
rejected. Recovery entries retain actor/action/time. Even explicit recovery cannot
replace a bound deleted thread. Keep the historical mapping and investigate rather
than manufacturing another ongoing conversation. If a confirmed retry creates a
duplicate, reconcile orphan threads manually in Discord; no automatic deletion.

## Reproducible evidence (not a live Discord recording)

No explicitly authorized disposable Discord destination/credentials were supplied
for this run. No operational Hermes channel, existing bot container credential or
external destination was used. **Live disposable-server recording is blocked**
until a disposable server/channel identity and authorized credentials are provided.
Automated transport simulation below is not evidence of live Discord behavior.

Owned Docker environment: network `eng92-v4gu`, app `eng92-v4gu-app`
(`eng6-elixir`, checkout mounted `/app`), DB `eng92-v4gu-db`
(`postgres:16-alpine`). `MIX_ENV=test`, `PGHOST=eng92-v4gu-db`, `PGUSER=postgres`,
`PGPASSWORD=postgres`, `ERL_FLAGS='+S 4:4'`. No shared database was used.

Exact focused adapter/demo command:

```sh
docker exec eng92-v4gu-app mix test test/async_worlds/tension_discussions_test.exs --trace
```

The sandbox demo opens an unattended Battle with public, known and hidden clocks,
creates one conversation, publishes a development, opens again with changed
circumstances and the same thread ID, then publishes a Resolution (separately
pausing private pressures). Assertions inspect saved public payloads, durable IDs,
overview URLs and historic text. Separate scenarios exercise resolved openings,
foreign campaign privacy, frozen audience/preparation checks, transactional
rollback/retry, duplicate jobs, partial sends, permission/deleted/archived threads,
rate limits, interrupted/ambiguous creation, explicit recovery and late results.
Tests use supervised adapters and message assertions, never sleeps.

Actual final results: focused adapter demo **13 tests, 0 failures**;
focused adapter + management LiveView tests **22 tests, 0 failures**;
`mix precommit` **904 tests, 0 failures** (Elixir 1.18.4 / OTP 28).
The suite emits existing migration-module redefinition warnings and expected
negative-path connection/OAuth logs; warnings-as-errors compilation succeeds.

Validation logs are in the workspace parent, not committed secrets or fake
recordings: `eng92-focused.log`, `eng92-ui-focused.log`, `eng92-precommit.log`,
`eng92-migration-cycle.log` and `eng92-migration-final.log`. Migration up/down/up
was executed on the owned test DB, including a final down/up of the delivered
migration. The companion handoff report records the commit and rerun details.
