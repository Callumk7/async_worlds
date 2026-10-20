# Connected Event history (ENG-95)

## Use it

**History** now opens `/events`, the campaign Event chronicle. The existing
`/ticks/history` archive, publications, journals, clock audits, quest history and
outbox records remain intact. This is one view of the existing published Events,
not another journal or a backfill of low-level changes.

- Filter by tick **ID**, or by a typed Tension/location/character/faction ID.
  Entity editors and Tension history link to these views. A reference remains
  browsable after its live entity is renamed or removed.
- Read an account to see the saved narrative first, involved entities, follow-on
  Tensions, and earlier/later Events within the selected filters. The follow-on
  Tension's history includes its origin Event and later developments.
- Expand saved mechanical details, or follow the tick archive link to inspect
  routine changes and the rest of the original publication. Routine clock movement
  does not generate narrative Events or flood the default chronicle.
- Lists have 20-Event pages ordered by descending tick number, tick ID and bundle
  key. Key ordering is deterministic, not fictional initiative. Navigation keeps
  filters. Pagination carries `through`, the last visible published tick number
  at the start of browsing; later publications cannot shift those pages. Start a
  fresh filtered search to include newer publications. No matching visible Events
  means no next page, regardless of private Events or unpublished drafts.

Players with a linked campaign character (or a valid DM player-testing persona)
can use the existing private Discord reply flow:

```text
/chronicle list
/chronicle list tick:<tick-id>
/chronicle list entity:location entity_id:<location-id>
/chronicle show tick:<tick-id> event:<event-key>
```

List/detail output includes commands for connections, previous/next pages and
Events. Copy the complete suggested command, including filters and `through`, to
retain the same browsing window. Long responses use existing private followups
and suppress mentions. `/help` discovers the commands from the shared catalogue.
Registration must be refreshed through the normal authorized deployment process;
this implementation does not register commands or change any live bot settings.

## Author an account

In tick review, the existing manual Event form now has two JSON inputs:

```json
[{"entity":"tension","id":12},{"entity":"location","id":34},
 {"entity":"character","id":56},{"entity":"faction","id":78}]
```

Use numeric existing database IDs, not Discord IDs. Several Tensions can be
relevant without changing any of them. Do not supply names: the application
captures them from frozen same-campaign inputs. Clock/Tension attachments also
supply relevant Tension context. A narrative-only Event can have references or
none. Replace/edit-bundle reloads retain these inputs; all edits still require a
reason, draft token and normal review/publication.

To open a follow-on Tension in the same Event, create it through the bundle's
existing changes editor, then enter its stable draft reference in the second
input, for example `["new:crossing:0"]`. This explicitly identifies causality;
merely mentioning an existing Tension does not claim to have opened it. Only
Tensions created by this bundle can be its follow-ons. Publication allocates IDs
atomically through the existing saved mapping; navigation uses the real IDs.

## Storage and privacy decisions

- No migration or publication rewrite. Optional `event_context` in newly frozen
  v3 snapshots records only typed IDs/names for locations, characters and factions;
  existing frozen Tensions supply their context. Rename/removal during review
  fails the publication stale-input check. Later live edits never rerender history.
  Older snapshots/reviews retain their exact replay shape when optional fields
  are absent. Legacy Event Tension associations are read from their saved changes;
  absent historical labels are explicitly identified, never invented from live data.
- `Ticks.Chronicle` is the shared read projection for DM screens and Discord.
  SQL expands only publication Event arrays; campaign, publication status, audience
  and reference/tick filters run **before** the bounded 21-row pagination probe.
  Detail and both neighboring Events use the same filters and authorization.
- DM authorization is freshly checked under the campaign lock. Player retrieval
  uses `PlayerAccess.run`, including current ownership and debug generation checks,
  and always selects the **public** projection, even when the actor is the DM.
- Tensions default private; public references require public Tension context.
  Public changes still require both saved sides and their clock associations to
  be public. Locations/factions and character **names** have no separate secrecy
  flag; selecting a name in public prose/context explicitly releases that name,
  never character flags, ownership, memberships or unrelated entity descriptions.
- Public mechanics whitelist safe clock/Tension fields. Clock visibility does not
  expose triggers, race partners or private flags. Review actor/reason metadata is
  DM-only. Legacy public clock references never borrow a later private Tension
  label from the same publication. Hidden/foreign references cannot be attached;
  filters for absent/hidden/foreign entities return indistinguishable empty pages.
- Published public context is historical disclosure, not a lookup of present-day
  visibility. Making a Tension private later cannot retract an already published
  name/account; it cannot leak its later private name either. Prose cannot be
  automatically redacted: the DM must author every public account safely.
- Explicit relevant Tension references also route published developments through
  the existing durable discussion intents. Retrieval never sends public messages,
  republishes ticks, creates threads or retries delivery.

There is no graph engine, legacy import, semantic search, player web app or
personalization. Entity selection is deliberately a small typed JSON editor, not
a graph editor. Query work still scans publication JSON (no new search index);
result memory and response pages are bounded. The old private `History.tension/3`
list remains for compatibility; new screens use the paginated projection.

## Reproducible exploration evidence

This is a sandbox demo and transport simulation, **not live Discord evidence**.
No bot credentials, gateway, real server or external status posts were used.
Owned containers: `eng95-rxq-app` (`eng6-elixir`) and `eng95-rxq-db`
(`postgres:16-alpine`) on network `eng95-rxq`. The checkout is mounted at `/app`;
`MIX_ENV=test PGHOST=eng95-rxq-db PGUSER=postgres PGPASSWORD=postgres
MIX_TEST_PARTITION=_eng95 ERL_FLAGS='+S 4:4'`. Dependencies/build artifacts are local
to this checkout. PostgreSQL is not exposed on a host port.

```sh
docker exec -e ENG95_DEMO=1 eng95-rxq-app \
  mix test test/async_worlds/ticks/chronicle_test.exs --trace
```

Observed output from `../eng95-demo.log` (IDs vary on repetition):

```text
DEMO all six filters -> 1318:crossing: The Ash Company holds the crossing
DEMO follow-on -> The wounded captain (377); recovery 1319:recovery -> earlier 1318:crossing
DEMO after rename/removal: Battle in the Reach, Reach, Captain, Ash Company, The wounded captain
DEMO Discord command handler (no network):
Tick 1 · The Ash Company holds the crossing

Two assaults repelled; villagers escape, but the captain is wounded.
...
Led to: The wounded captain · /chronicle list entity:tension entity_id:377
...
DEMO pagination: 20 + 2 = 22 distinct public Events; private entry-12 omitted; through=1 unchanged after next publication; earlier entry-11 / later entry-14
6 tests, 0 failures
```

The tests assert all six views return the same full Event, publish a second
narrative-only development, follow it back to the origin, rename Reach/delete
Ash Company and assert the original account is unchanged. Other tests cover
empty/draft history, forbidden references, private mechanics, stale publication,
legacy Events, routine changes, complete stable pages and filtered navigation.

The LiveView and dispatcher tests exercise the real review form, shared filters,
readable detail/origin links, private dispatcher replies and mention suppression:

```sh
docker exec eng95-rxq-app mix test \
  test/async_worlds/ticks/chronicle_test.exs \
  test/async_worlds_web/event_chronicle_live_test.exs \
  test/async_worlds/discord/chronicle_commands_test.exs
```

Observed: **10 tests, 0 failures**. Full regression gate: `mix precommit`,
**928 tests, 0 failures**. Baseline before edits: **918 tests, 0 failures**.
Existing migration up/down/up also passed on the separately owned
`async_worlds_test_eng95_cycle` database; there are no new migrations in this slice.
