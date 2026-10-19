# Manual world loop (ENG-91)

## Boundaries and semantics

The DM can close a tick without any characters, quests, or submissions. Background
rates resolve from the frozen world. `/ticks/:id/review` adds manual intentions to
the existing audited review pipeline; it does not unlock live management.

* A `world` operation has a stable `key` and an `event` containing `kind`
  (`event`, `resolution`, `routine`), `audience` (`dm`, `public`), `title`, `text`,
  and `changes`. Each change has `entity` (`clock` or `tension`), `id` (nil creates),
  and schema-validated `attrs`. Clock `delta` is signed and clamped.
* An operation **replaces** the intentions for its key. A nil event removes that
  bundle. The console appends attached changes to the selected key. Remove and
  rebuild a bundle to correct its attachments. All edits require an audit reason.
* Recompute always starts from the original snapshot and recorded dice, runs the
  existing legacy phases, then applies manual bundles once in alphabetical key
  order. Within a bundle, explicit changes run in their listed order. This is an
  inspectable mechanical ordering, **not** fictional initiative or a winner rule.
* Legacy background-delta overrides remain available. They replace background
  progression. The new signed manual adjustment is **additional**, after legacy
  resolution. Manual additions do not retroactively execute authored triggers;
  legacy standalone latching/races/triggers and older frozen snapshots retain
  their existing phase rules. Final quest availability is projected from the
  approved final clock values.
* In newly closed ticks, a Tension clock at either endpoint prompts adjudication.
  It does not latch completion or fire its authored full triggers. A racing group
  containing a Tension clock cannot automatically select either participant as
  winner. Moving back from an endpoint is allowed. Standalone-only groups retain
  the existing legacy winner rule. Older snapshots without `manual_world` retain
  legacy semantics, even when replayed by the new engine.
* A Resolution must settle at least one Tension; non-Resolution bundles cannot
  resolve Tensions. Resolution automatically stages pausing its running,
  incomplete pressures, visible in the same before/after bundle. Completed
  clocks cannot be manually rewritten. Direct management still cannot resolve a
  Tension.
* New entities use stable `new:<bundle-key>:<change-index>` draft references.
  Later changes can reference them. Publication allocates database IDs and saves
  an immutable `published_entity_ids` mapping alongside the approved payload;
  the original draft references and before/after context are retained.

## Publication, privacy, history

No migration is required: frozen Tension/context inputs, intentions, Events and
manual changes use existing immutable snapshot, draft, review-edit and publication
JSON storage. New v3 snapshots explicitly carry `manual_world: true`; older
v1/v2/v3 snapshots are not upgraded or backfilled.

Every revision is replay-verified against frozen inputs and the immutable review
chain. The selected draft token and campaign/tick locks guard edits and publish.
Live frozen inputs must still match at publication, including Tension descriptions
and clock influences/configuration. Clock state, Tensions, Events, attribution,
clock audits, publication, tick transition, management unlock, delivery records
and delivery jobs commit or roll back together. Publication retry cannot apply
an already-published tick again. Network delivery remains the existing durable
outbox with explicit ambiguous-send recovery, not exactly-once delivery.

Tensions default to DM-only; ENG-92 adds an explicit campaign-visible audience
in management and frozen inputs (see [discussion semantics and recovery](tension-discussions.md)).
Events still default to DM-only in the console. A public Event may attach only
explicitly public Tensions/public clocks; both before and after context and clock
associations must be public. Private-to-public changes cannot declassify the
private before-context through a public Event. A public narrative-
only Event is permitted: the DM explicitly authors that prose for public release;
the application cannot infer secrets in natural language. No partial prose
redaction, private Event counts or private links enter public output. Existing
explicit public world-news/trigger policy is unchanged. Known clocks remain name-
only and hidden clocks are omitted from public messages.

`/ticks/history` is the campaign chronicle: meaningful Events lead each tick.
Tick details lead with Events and retain saved before/after context and attribution
under expandable details. Routine changes have a separate inspectable section,
without mandatory prose. `/tensions/:id/history` shows the same immutable Events
through a Tension (including Events opening newly created Tensions). The Tension
management detail links there. These web archives are freshly DM-authorized;
player delivery sees only the filtered public narration/clock projection. ENG-92 adds persistent Discord discussions and public developments; no new
Discord retrieval command, typed entity graph, or historical backfill is introduced.

## Reproducible two-tick walkthrough

The executable walkthrough is
`test/async_worlds/ticks/manual_world_test.exs:68`. It creates disposable data in
Ecto's SQL sandbox; no application database or Discord API is used.

1. Create private **Battle** (circumstances: “Unsettled banks”) and **Harvest**.
   Battle has a hidden four-segment **Balance**, fill 2, background +1,
   tug-of-war mode. No characters or submissions exist.
2. Open, close/freeze and resolve tick 1. Frozen Balance remains 2; proposed
   background result is 3. Stage **The crossing holds** with two changes:
   Balance signed +1 and ongoing rate -1; Battle circumstances become
   “The crossing holds”. The title/short account explains both changes.
3. Before publication, assert live Balance is still 2, circumstances unchanged,
   public history empty, and live clock management locked. Reject a stale draft.
   Reload and recompute from the frozen snapshot: identical approved payload,
   without applying the manual delta twice. Exact public preview omits private
   Event prose. Publish: Balance becomes 4, rate -1; full is only a prompt.
4. Open/close/resolve tick 2. Battle continues unattended: Balance recedes to 3.
   Stage a Resolution settling Harvest; publish. Battle remains ongoing and
   Harvest is resolved. There were no player submissions in either tick.
5. Rename Battle. Its chronicle still reports the original published name and
   before/after circumstances. An unauthorized reader cannot retrieve it.

To repeat through the console, create the above Tensions/clocks at `/tensions`,
then use the existing dashboard open/close controls. In review choose one bundle
key (for example `crossing`), DM audience and Event kind. Attach a signed +1 to
Balance, attach clock configuration with ongoing rate -1 (retain name, mode,
visibility and segments), then attach Battle's updated circumstances. This is
three form attachments equivalent to the test's two multi-attribute changes.
Inspect the exact staged changes and public/private previews, confirm and publish.
For the second tick choose Resolution, attach Harvest's existing ID/name, and
publish. Follow campaign/tick/Tension history links. To create an entity during
review, leave the target blank; use its displayed `new:…` reference for further
attachments before publication. Routine kind allows blank title/account.

### Actual validation evidence

Executed in this checkout with a dedicated `eng91-isolated` Docker network,
`eng91-db` (`postgres:16-alpine`) and `eng91-app` (`eng6-elixir`, Elixir 1.18.4),
not any existing host/shared database. The app container mounts this checkout at
`/app` and has `MIX_ENV=test PGHOST=eng91-db PGUSER=postgres
PGPASSWORD=postgres ERL_FLAGS='+S 4:4'`. `mix deps.get` completed successfully.

Command:

```sh
docker exec eng91-app mix test test/async_worlds/ticks/manual_world_test.exs:68 --trace
```

Actual output excerpt (progress-control characters removed):

```text
Running ExUnit with seed: 318952, max_cases: 1
Excluding tags: [:test]
Including tags: [location: {"test/async_worlds/ticks/manual_world_test.exs", 68}]
* test two unattended ticks: bundled Event, continued pressure, Resolution, immutable history (172.6ms) [L#68]
Finished in 0.6 seconds (0.6s async, 0.00s sync)
9 tests, 0 failures, 8 excluded
```

The remaining tests in that file separately exercise signed replacement/recompute,
legacy snapshots, no race winner, resolution pressure pausing, fresh authorization,
campaign isolation, private-reference policy, creation/configuration and a forced
outbox conflict after state/history writes. The conflict transaction is rolled
back, then publication succeeds once without duplicate entities or Events.
Console tests exercise bundling, reload, configured creations and temporary
references, publication and readable campaign/tick/Tension history.

Final focused command and actual result:

```sh
docker exec eng91-app mix test \
  test/async_worlds/ticks/manual_world_test.exs \
  test/async_worlds_web/tick_review_live_test.exs \
  test/async_worlds_web/controllers/tick_review_controller_test.exs \
  test/async_worlds/ticks/review_publication_test.exs \
  test/async_worlds/ticks/world_resolver_test.exs \
  test/async_worlds/ticks/history_test.exs \
  test/async_worlds/tensions_test.exs
```

```text
Running ExUnit with seed: 966102, max_cases: 8
Finished in 3.4 seconds (2.4s async, 1.0s sync)
62 tests, 0 failures
```

```sh
docker exec eng91-app mix precommit
```

```text
Finished in 45.9 seconds (18.1s async, 27.7s sync)
888 tests, 0 failures
```

The full suite emits existing migration-module redefinition warnings and expected
negative-path OAuth/connection logs; compilation with warnings-as-errors succeeds.
