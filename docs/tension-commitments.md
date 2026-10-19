# Broad intentions and informational readiness (ENG-93)

Discussion is freeform coordination in the persistent public Tension thread. It
is **not** a submission, confirmation, Event, or established success. The bot does
not read chat. `/intent` is a separate private slash-command path. Re-register
commands after deployment; run the generated migration first.

## Player flow

Opening briefings include the tick's database ID and the Tension ID. These are
locators, not credentials. `/intent view tick:<id>` lists your current versions
and absent entries for ongoing public Tensions, without requiring an active quest.

- `/intent edit tick:<id> tension:<id> version:0 intention:<broad effort>
  approach:<optional descriptive resources/method>` creates unresolved intent.
- `/intent confirm tick:<id> tension:<id> version:1` explicitly confirms that
  saved version. Confirmation never establishes success.
- `/intent ready tick:<id> tension:<id> version:2` signals that this confirmed
  intention is ready for DM consideration. It is optional, per intention, and
  does not require a quota, auto-close, or prevent the world proceeding.
- Edit again using the current version to revise. Every edit clears confirmation
  **and** readiness, even when text is unchanged. Explicitly confirm again.
- `/intent withdraw ... version:<current>` removes current text/resources and
  records a withdrawn state. A later edit may restart the intention before close.

Every successful operation advances the version, including confirmation, readiness
and withdrawal. Stale/replayed operations fail without modifying the latest state.
Use `view` after an ambiguous response; do not blindly retry a write. Intention and
approach each allow at most 2,000 Unicode characters / 8,000 bytes, valid UTF-8,
without NUL; intention must be nonblank. There is no global submission cap,
one-action limit, inventory/spend system, allocation solver, bonus or clock effect.
Characters may participate in several Tensions; the DM judges feasibility and
conflicting attention, not submission order.

**All intentions are private to the current character owner and authorized DM.**
There is no campaign-public commitment projection or automatic posting. Ordinary
public discussion remains public; changing/withdrawing an intention does not erase
chat, saved posts, or someone's copies. No secret-thread infrastructure is added.
Private/unknown Tensions cannot be discovered by guessed commitment IDs. If an
already-used Tension becomes private/resolved, an owner may retrieve or withdraw
its existing intention, but not create/reconfirm another effort there.

## DM retrieval and close

`/intent roster tick:<id>` is freshly DM-authorized and works without a linked
DM character. It returns each character's same private current state, including
absent, unresolved, withdrawn, confirmed and not-ready participation. Player view
returns only the freshly resolved owned character, including existing debug
persona safeguards. Campaign/ownership changes are checked under the same campaign
row lock as the read/write; cached command context is not authority.

Roster and view are direct domain retrieval, not outbox reads. Blocked thread
creation, failed proactive delivery, and failed interaction responses do not lose
saved intentions. Responses use the existing private defer/edit/followup adapter
and mention suppression. Domain writes enqueue no messages or public text.

Close takes the campaign lock shared by all commitment operations and atomically
saves `snapshot.data["tension_commitments"]` alongside world inputs. A concurrent
revision either commits first and its exact latest version freezes, or close wins
and the revision is rejected. Late confirm/ready/withdraw also fail. Closed views
read the immutable snapshot, not a new roster calculation; DM sees the whole
frozen participation roster, player sees only their freshly authorized character.
Older snapshots without this optional v3 extension remain readable/publishable.
Existing snapshot UPDATE protection applies. Close retries reuse the snapshot.
No all-player submit requirement exists. DM can deliberately handle missing and
unresolved participation while reviewing existing world pressures. Intentions are
not interpreted automatically and do not create Events, clock changes or success.
The full Tension adjudication workspace remains ENG-94; existing quest resolution,
manual review/publication and delivery recovery remain unchanged.

## Reproducible automated rehearsal

No live Discord destination is used. The acceptance test exercises actual
Dispatcher -> Commands -> domain -> PostgreSQL -> close/resolver/publication with
the supervised fake Discord adapter, not a schema-only example.

```sh
docker exec eng93-3og7wo-app mix test \
  test/async_worlds/tension_commitments_test.exs \
  test/async_worlds/tension_commitments_concurrency_test.exs \
  test/async_worlds/tension_discussions_test.exs --trace
```

The documented acceptance flow in `tension_commitments_test.exs`:

1. Create quest-free Rook and an absent player; create public Battle/Harvest,
   a private Tension, and public/known/hidden pressures. Open the tick.
2. As Rook, privately view; edit and confirm both Tensions (versions 1 then 2).
3. Ready Battle (v3), revise (v4, unresolved/not-ready), reject stale confirmation
   and readiness, reconfirm (v5). Withdraw Harvest (v3, text removed).
4. Compare owner view with DM roster; verify absent player and DM-only access.
5. Actually fail an outbox send. Fail the private response after a readiness
   write, then retrieve v6 independently. No clocks/Events/publication changed.
6. Close despite absence/withdrawal. Assert exact frozen participation versions,
   reject late edits/confirmations/withdrawals, compare DM/player frozen views.
   Resolve/review/publish using the existing pipeline; assert no inferred Events,
   clock bonuses, private text, hidden clocks or known fill in public output.

Separate tests exercise invalid UTF-8/NUL/limits, foreign campaigns, revoked
ownership/DM access, unresolved absence, and independent PostgreSQL process
connections with supervised tasks, message barriers and DOWN monitors. Both lock
orders of close versus revision are exercised without sleeps, as is simultaneous
editing of one version. Existing discussion tests retain transport and privacy
coverage. On the owned disposable ENG-93 containers: focused rehearsal **21 tests,
0 failures**; final `mix precommit` **912 tests, 0 failures**. Migration down/up also
passed. No live gateway/API requests were made. See the handoff report for exact
commands, logs and remaining boundaries.
