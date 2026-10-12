# Private tick notifications (ENG-21)

## Player access

- `/quest`: current player-safe quest, with editable controls only during the open tick. Closed/review states expose no draft results.
- `/submission`: current choice/controls while applicable; otherwise the latest closed turn containing this character’s actual submission. A newer world-only turn does not erase the previous personal submission.
- `/result`: latest applicable **published** personal output, including approved narration/dice and the next-node projection. Later open/resolving/review ticks or projection-only published turns without a personal result do not replace it. Completed quests retain their last personal output.

All commands are ephemeral, scoped to the verified guild member. They do not depend on DMs succeeding and do not enqueue outbound messages. Historical reads require both current character ownership and matching historical character ID/Discord owner; transferring a character does not give the new owner its previous owner's private history.

## Durable notifications

Opening a tick atomically records public announcement and private prompts for active quest owners. Publication atomically applies the selected approved draft once, saves exact outgoing output, and records personal result deliveries. No network call runs inside either game-state transaction. Even if every Discord recipient blocks messages, publication succeeds.

Prompts and approved next-node content use shared player-safe rendering from whitelist projections, not quest definitions, effects, hidden clocks, flags, or other characters. Messages split into at most 1,900 Unicode codepoints, with mentions disabled by the worker. Publication chunk numbering restarts at zero for each audience/owner, so one owner's message length cannot change another's keys.

`/tick remind` is DM-only and rechecks the configured DM under the campaign lock. It records intents only for active quests lacking a currently valid choice. There is one durable reminder intent per tick/owner/chunk: repeating commands (even with different interaction IDs) does not create new sends or bypass failed/ambiguous state. The response reports eligible intents, not confirmed deliveries. Changed content for an existing key is a conflict, never an overwrite or implicit resend. Reminders have no game effects and never create/clear submissions or close a tick.

At claim time, reminders recheck current guild/DM authorization, tick openness, ownership, progression/revision/node/version, projected quest content/eligibility, and missing choice. Prompts use the same checks without the DM-actor/missing-only requirements. Personal publication deliveries recheck guild and owning character. Stale intents become visible permanent `stale_notification` failures without a transport attempt; retry cannot bypass these guards.

## Failures and operations

The existing DM dashboard delivery list includes private prompt/result/reminder failures and their recipient/key/error. Use its **targeted** retry controls, never republish a tick to recover a message. Blocked DMs (`forbidden`) are permanent failures; automatic job replay does not resend them. Ambiguous sends and interrupted persisted `sending` claims require explicit confirmation before a new generation can send. Confirmation may duplicate a message. Persisted receipts and generation checks prevent known-sent/old-generation replay.

Migration: `20261012141022_add_private_delivery_guards.exs` adds durable guard metadata. Existing rows retain empty guards; recognizable legacy personal-result keys fail closed as `stale_notification` (including targeted retries) because their ownership/guild guard was never persisted. Players can retrieve those approved results through `/result`. Existing public/DM-admin intents retain their previous policy. No historical intent is rewritten or re-enqueued.

Authorization/staleness is checked immediately before the committed claim; Discord I/O necessarily follows that commit. A concurrent change after this check cannot retract a message already in flight. There is no exactly-once Discord promise. No live Discord validation was performed; the acceptance suite uses fake adapters and manual Oban jobs.
