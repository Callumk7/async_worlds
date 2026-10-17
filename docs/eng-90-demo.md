# ENG-90: private Tensions and descriptive clocks

## Boundary and policy

A Tension is a campaign-owned ongoing situation, not a location, quest, or shared
resource. All Tension names, circumstances, status, associations, and clock
endpoint/influence prose are **DM-only**. There is no player Tension retrieval or
briefing. The shared actor-aware entry point is `AsyncWorlds.DM.Tensions`; it
reauthorizes under the campaign row lock. There is no new HTTP or Discord command
surface in this slice.

Each clock has at most one optional Tension. Standalone clocks remain supported.
New Tension clocks default to hidden. Clock visibility is independent: deliberately
choosing public exposes the clock's existing name/fill projection; known exposes
only its name; hidden exposes neither. Association never changes visibility.
Private prose is not automatically redactable and is not added to any player
projection. Legacy public world-news trigger text remains explicitly public.

Both countdown and tug-of-war are **descriptive modes, not new engine modes**.
Empty/full endpoint text and influences are plain text, never executable rules.
Full clocks still latch during the existing completion phase, races still use
legacy ordering, and triggers/background progression still run as before. Merely
writing “elven victory” at empty does not enact that outcome. A legacy clock can
be associated only within its campaign, while uncompleted and unlocked, using its
loaded expected state. Detach/move operations have those same constraints, are
audited, and cannot circumvent frozen management locks or reset completion.

There is deliberately **no live resolved toggle**. Status is readable as ongoing
or resolved, but create/edit cannot set it. ENG-91 owns staged manual signed
adjustments/endpoints, Event/Resolution bundles, atomic publication and historical
Tension context. This slice does not change snapshot schema, frozen engine
inputs, immutable existing publication/audit rows, or legacy completion semantics.
New clock management audits include descriptive fields and association snapshots;
Tension circumstances are current private working notes, not a published history.

## Reproducible UI demo

Use a disposable configured campaign with a DM OAuth session. Apply migrations
with `mix ecto.migrate`, start the usual console (`mix phx.server`), and sign in as
that campaign's DM. The isolated test container described in the implementation
report uses test mode (server disabled); the automated demo below does not need
OAuth credentials or a browser server.

1. Open **Tensions** in navigation (`/tensions`). Create **Battle in the Reach**.
   Circumstances: “Elves hold the crossing; goblins are pressing from the east.”
2. On the detail page add these clocks (leave visibility hidden):

   | Name | Mode | Segments / fill | Empty | Full | Influences |
   | --- | --- | --- | --- | --- | --- |
   | Battle balance | Tug of war | 8 / 4 | Elven victory | Goblin victory | Ash Company holds the crossing; neighbouring lords may help |
   | Supply exhaustion | Countdown | 6 / 0 | Stores intact | Elves run out of provisions | Blocked roads; local foraging |
   | Reinforcements | Countdown | 4 / 0 | Distant army | Goblin reinforcements arrive | Forced march through the hills |

3. Reload the detail URL. Both battle endpoints and influences are readable in
   the clock card without opening the legacy rule editor. Edit circumstances and
   the battle influence text; save and reload again.
4. Create a standalone clock in **Clocks**. Return to this Tension, select it in
   **Associate an existing standalone clock**, then **Make standalone**. Visibility
   is unchanged. Existing racing/reset/trigger controls remain under **Clocks**.
5. Open and close a tick using the existing dashboard flow. Reload the Tension:
   management is locked. A stale tab's save is rejected too. Inspect existing
   preview/history: hidden clocks and private prose are not public; known clocks
   do not reveal fills.

Automated, disposable reproduction (creates and rolls back its own campaign):

```sh
mix test test/async_worlds_web/live/tension_live_test.exs \
  test/async_worlds/tensions_test.exs
```

The Battle acceptance test creates all three clocks through LiveView forms,
reopens the detail page, edits both circumstances and influences, and verifies
both endpoints remain readable. No publication or resolved toggle is implemented.
