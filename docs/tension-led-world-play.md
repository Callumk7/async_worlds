# Tension-led world play

**Status:** agreed product direction; proposed incremental delivery plan. No implementation is implied by this brief. Repository companion: `docs/tension-led-world-play.md`.

## Purpose

Shift from progressing through authored content to participating in a world that is already moving. The mechanical toolkit should be small; richness comes from discussion, DM interpretation, fictional consequences, and explorable history. The app gathers intentions, supports adjudication, and preserves an understandable account of what happened. It does not need to understand every possible player action.

This replaces the quest-centred participation direction, not completed infrastructure or existing quest/history support. Do not automatically cancel or move older Linear issues.

## Agreed concepts

### Tensions

A Tension is an unsettled situation: a battle, threatened harvest, uneasy succession, or developing settlement. It explains current circumstances and stakes. The Reach is a location; the struggle for control of the Reach is a Tension. A situation may involve existing locations, characters, and factions without a general-purpose relationship graph.

Tensions continue without player engagement. They may develop across many ticks, change substantially, or give rise to other Tensions without resolving. Do not rebuild the quest graph under another name.

### Clocks and influences

Several clocks may describe different pressures within a Tension. Make position, influences, and possible consequences understandable. Clocks may advance or recede; a tug-of-war can have meaningful outcomes at both empty and full. Reaching an endpoint can prompt the DM to adjudicate rather than execute an authored outcome tree.

Begin with descriptive influences, manual signed adjustments, and existing background progression where appropriate. Calculated modifiers and resource allocation are not prerequisites. Inspect legacy full-clock latching, race ordering, triggers, and frozen snapshot contracts before integrating new manual behaviour; do not inherit an arbitrary clock-ID or submission-order winner rule or silently change older resolutions.

### Broad player intentions

Players describe what they want to accomplish in their own words. Discussion includes coordination, questions, plans, and fictional detail. A separate confirmation identifies committed intent; neither discussion nor confirmation establishes success.

A minimal entry has intention text and optional approach/resource text. It is not a prescribed action menu or tactical form. Commitments can be revised or withdrawn before closing. Characters may contribute to several Tensions when the fiction permits; the DM judges attention and conflicting commitments. No universal one-action-per-character limit or action-point economy.

### Events and Resolutions

An Event records an established change: a death, resource change, agreement, discovery, territorial change, or other meaningful development. A Resolution is an Event settling a Tension. One DM-written title and short description can explain several mechanical changes; an Event can also matter without moving a clock.

Permanent means the occurrence remains part of history, not that its consequences are irreversible. A destroyed bridge can be rebuilt; the destruction still happened. Published context must not silently change when current entities are renamed or edited. Events need not snapshot the whole world, and the application need not become event-sourced.

Routine background progression remains inspectable without mandatory prose. The chronicle leads with meaningful developments rather than a wall of +1 entries; mechanical details sit underneath.

## The tick is the unit of play

**Discuss the coming period → confirm broad commitments → close/freeze → DM adjudicate/review → publish the period's established changes.**

* Opening shows ongoing Tensions and current visible circumstances, clocks, and influences in persistent Tension threads.
* Players coordinate and confirm broad efforts over the abstract period, not individual combat manoeuvres or dialogue exchanges. The DM may clarify feasibility without resolving outcomes early.
* Readiness is a signal to the DM, not a mandatory action quota. Missing and unresolved commitments are visible and deliberately handled. The DM can close without every player submitting; absence does not stop background world progression.
* Closing freezes commitments and world inputs. The DM considers all intentions and ongoing pressures together. Submission order does not decide fictional order or outcomes.
* Review stages clock/Tension changes and Event bundles. Publication establishes them together and carries unresolved situations into the next tick.

No real-time or mid-tick consequence engine. Preserve the existing close → resolving → in review → published lifecycle, frozen inputs, authorized operations, review controls, and atomic publication. Staged review operations must not bypass clock management locks.

## Small DM toolkit and workspace

* Move a clock forward/backward.
* Create/change a clock and its ongoing progression or influence description.
* Record an Event and optionally attach the changes it explains.
* Open, develop, or resolve a Tension.

Freeform intentions do not need conversion into released quest choices, executable action templates, or a dice DSL. Existing quest/dice tools can remain without gating new play.

The DM workspace groups current circumstances, all relevant intentions and resources, background pressures, clocks, and draft Events by Tension. It supports synthesis, not a tactical initiative queue.

## History is gameplay

Maintain one connected set of Events viewed through:

* Campaign chronicle.
* Tick recap.
* Tension history.
* Existing location, character, and faction histories.

Show what happened, when, who/what was involved, what changed, and what it led to. One Event may concern several entities/Tensions without duplicate journal entries. A new Tension can link back to the Event that opened it.

Start with a simple campaign/tick/Tension list and readable detail. Add typed existing-entity links, filtering/pagination, and follow-on navigation as the next layer. Player retrieval should work through Discord without requiring a new player web app. No graph editor, semantic search, or full legacy-history backfill.

Preserve publication and privacy throughout. Hidden clocks, unpublished outcomes, and private references must not leak through titles, links, counts, or thread briefings. Start with a minimal explicit audience policy; per-character knowledge and secret-thread infrastructure are not required. Prose is not automatically redactable.

## Resources: descriptive first

The fiction may include consumables such as gold/provisions and persistent assets such as mercenaries/ships. An asset can become unavailable elsewhere or face risk without behaving like spendable points.

Initially record commitments as text and adjudicate them manually. No inventory, automated spending, allocation solver, or calculated bonuses. Add named assets/availability or structured ongoing influences only after a playtest reveals a concrete tracking problem. This conditional follow-up is not required to accept the core project.

## Worked example

**Battle in the Reach** has a balance-of-battle clock (empty: elven victory; full: goblin victory), elven supply exhaustion, and arriving goblin reinforcements. Begin the balance away from either endpoint.

A player commits: “I devote my efforts to strengthening the elven position, committing the Ash Company and seeking support from neighbouring lords.”

At resolution, the DM considers all commitments and background pressures and drafts **The Ash Company holds the crossing**: mercenaries repel assaults and buy time for villagers to escape, but their captain is wounded.

This one Event can explain backward goblin progress, a completed evacuation clock, and a new Tension around the captain. Everything becomes established at publication. The battle can continue next tick. Players can follow the same account through the battle, the Reach, involved entities, the tick recap, or the follow-on Tension.

## Incremental delivery and verification

### 1. Manual world loop

1. DM-manage Tensions and their clocks: create/edit/detail, current circumstances, endpoint/influence text, and active/resolved presentation; retain standalone clocks.
2. Stage manual end-of-tick changes and Event bundles, preview and publish atomically, and read basic campaign/tick/Tension history. Demonstrate two ticks with no player submissions, one continuing situation and one Resolution.

### 2. Player discussion and resolution

3. Persistent Discord threads and opening briefings, plus published developments. Reuse durable delivery and controlled recovery; do not promise exactly-once external delivery.
4. Character-owned freeform confirmations across Tensions, revisions/withdrawals, optional resource text, readiness, DM retrieval, and frozen close inputs. No quest requirement.
5. Consolidated Tension-centred resolution workspace over the same staged review/publication operations, not a second rules engine.

### 3. Connected history and adoption

6. Extend the basic chronicle with existing-entity links, filters/pagination, and navigation into follow-on Tensions.
7. Rehearse a multi-tick disposable Discord campaign. Record evidence and a short DM/player guide; expose quest-free participation without damaging existing campaigns or published records.

### Conditional follow-up

8. Only if the rehearsal demonstrates a need, add the smallest useful named-resource/availability or ongoing-influence layer. Keep the manual route. No mandatory economy or rules engine.

Every implementation slice includes automated acceptance tests and a reproducible demonstration. Verify campaign isolation, fresh authorization, public/known/hidden clock projections, frozen-input safety, no draft leakage, atomic rollback, retry-safe publication, and controlled external delivery. Use focused tests and `mix precommit`; process tests use supervised processes and message/monitor coordination, not sleeps.

## Explicitly deferred

Automatic natural-language interpretation, AI adjudication, tactical actions, automatic outcome graphs, a generic modifier/economy system, individual knowledge permissions, destructive quest replacement, full historical imports, and automatic cancellation of older projects/issues. Reconcile quest-centred proposal/adaptation work and separate lore retrieval explicitly when adopting this direction.

## Tracked delivery chunks

| Issue | Deliverable | Dependency |
| -- | -- | -- |
| [ENG-90](<https://linear.app/warp-monster/issue/ENG-90>) | Manage Tensions and clocks | Start here |
| [ENG-91](<https://linear.app/warp-monster/issue/ENG-91>) | Manual tick Events and basic chronicle | [ENG-90](https://linear.app/warp-monster/issue/ENG-90/manage-tensions-and-their-clocks-through-the-dm-console) |
| [ENG-92](<https://linear.app/warp-monster/issue/ENG-92>) | Persistent Discord threads and briefings | [ENG-91](https://linear.app/warp-monster/issue/ENG-91/publish-manually-adjudicated-tick-events-and-a-basic-world-chronicle) |
| [ENG-93](<https://linear.app/warp-monster/issue/ENG-93>) | Freeform commitments and readiness | [ENG-92](https://linear.app/warp-monster/issue/ENG-92/open-persistent-discord-tension-threads-with-tick-briefings-and) |
| [ENG-94](<https://linear.app/warp-monster/issue/ENG-94>) | Tension-centred DM workspace | [ENG-93](https://linear.app/warp-monster/issue/ENG-93/confirm-freeform-tension-commitments-and-readiness-without-quest-or) |
| [ENG-95](<https://linear.app/warp-monster/issue/ENG-95>) | Connected history exploration | [ENG-91](https://linear.app/warp-monster/issue/ENG-91/publish-manually-adjudicated-tick-events-and-a-basic-world-chronicle), [ENG-92](https://linear.app/warp-monster/issue/ENG-92/open-persistent-discord-tension-threads-with-tick-briefings-and) |
| [ENG-96](<https://linear.app/warp-monster/issue/ENG-96>) | Multi-tick rehearsal and adoption | [ENG-94](https://linear.app/warp-monster/issue/ENG-94/resolve-broad-tick-commitments-in-a-tension-centred-dm-workspace), [ENG-95](https://linear.app/warp-monster/issue/ENG-95/explore-one-connected-event-history-through-tensions-ticks-and-world) |
| [ENG-97](<https://linear.app/warp-monster/issue/ENG-97>) | Conditional resources/influences | [ENG-96](https://linear.app/warp-monster/issue/ENG-96/rehearse-and-adopt-the-tension-led-loop-in-a-multi-tick-discord) plus evidence |

The first seven issues form the three core milestones. [ENG-97](https://linear.app/warp-monster/issue/ENG-97/conditional-follow-up-add-named-resources-or-explicit-influences-only) is deliberately outside them and is not an acceptance dependency. All are initially Backlog, with no invented owners or dates. Each issue contains scope boundaries, observable acceptance, test expectations, and a concrete demo.
