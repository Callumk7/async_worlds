# Tension-led world play

Status: **Agreed product direction; incremental delivery in progress.**

The manual world loop (ENG-90/ENG-91) is implemented; see
[the Tension demo](eng-90-demo.md) and [manual world loop](manual-world-loop.md).
[Connected Event history (ENG-95)](connected-history.md) extends that same chronicle
with typed context, pagination and Discord retrieval. ENG-96 adds explicit
per-campaign adoption, an [operating guide](tension-led-operating-guide.md) and a
[rehearsal record](tension-led-rehearsal.md); the live-server rehearsal is still
outstanding. The slices below are the
incremental delivery plan; consult each implementation guide for shipped scope.

- [Linear project: Tensions, Intentions & Living History](https://linear.app/warp-monster/project/async-worlds-tensions-intentions-and-living-history-6d32d6af4c50)
- [Linear product and delivery brief](https://linear.app/warp-monster/document/tension-led-world-play-agreed-direction-and-incremental-delivery-760f20be8007)

## 1. Purpose

Shift Async Worlds from progressing through authored quest nodes to participating
in an evolving world. Keep the mechanical vocabulary small; put the richness in
player discussion, DM interpretation, fictional consequences, and explorable
history.

The app gathers intentions, supports adjudication, and preserves an understandable
history. It does not need to understand or execute every possible player action.

This direction supersedes the quest-centred participation model in
[Flexible actions and visible campaign activity](flexible-actions-plan.md).
Existing quests, published history, and safe tick infrastructure remain supported;
this is not an instruction to delete them or automatically cancel older issues.

## 2. Agreed concepts

### Tensions: unsettled situations

A Tension is an ongoing situation in flux: a battle, a threatened harvest, an
uneasy succession, or a settlement being established. It describes the current
circumstances, what is at stake, and why the situation matters.

A location is not itself a Tension: the Reach is a place; the struggle for control
of the Reach is a Tension. Tensions can involve existing locations, characters,
and factions without requiring a general-purpose relationship graph.

Tensions exist independently of player participation. Players can intervene,
ignore them, or pursue an unexpected approach. Unattended situations still develop.
A Tension can persist across many ticks and can change substantially without
being resolved. Do not replace quest graphs with mandatory Tension graphs.

### Clocks: changing pressures

A Tension can have multiple clocks. They represent progress, pressure, or a
changing balance, not necessarily a task players must complete.

Keep three ideas understandable:

- **Position:** where the clock currently stands.
- **Influences:** what is pushing it in either direction, and why.
- **Consequences:** what an endpoint or threshold might mean.

A clock can be a countdown or a tug-of-war with meaningful outcomes at both ends.
An endpoint can prompt DM adjudication; it need not execute an authored outcome
tree or automatically settle the entire Tension. New Tension play must not
inherit an arbitrary first-submission or clock-ID winner rule.

Begin with descriptions, signed adjustments, and existing background progression
where suitable. Structured, calculated influences are not a prerequisite.

### Intentions: what players want to accomplish

Players write broad intentions in their own words. Discussion can include plans,
questions, coordination, and fictional detail. A separate explicit confirmation
identifies the player's actual commitment; conversation is not automatically an
action, and a confirmed intention is not proof of success.

A useful minimal entry is intention text plus optional approach and resource
commitment text. These are not mandatory tactical forms or prescribed action lists.
Players can revise or withdraw commitments until closing.

There is no universal one-action-per-character-per-tick limit. A character can
contribute to several Tensions when the fiction permits. The DM judges competing
attention and resource commitments; no action-point system is required.

Players are describing efforts over a broad period, not submitting individual
combat manoeuvres, dialogue exchanges, or a queue of smaller executable actions.

### Events: established changes

An Event records what actually happened. Deaths, resource changes, territorial
changes, agreements, and discoveries can all matter. A Resolution is an Event
that settles a Tension. Other Events develop or transform an ongoing Tension.

A DM-written title and short description can bundle several mechanical changes.
An Event can also matter without changing a clock. It need not contain a complete
copy of world state, and this direction does not require event-sourcing the app.

Permanent means the occurrence remains part of history, not that its consequences
can never change. A destroyed bridge can be rebuilt; its destruction still happened.
Published records must not silently change when current names or state are edited.

Routine background movement remains inspectable without mandatory narrative for
every adjustment. The default chronicle shows meaningful developments, not a wall
of +1 entries. Mechanical details explain the account when expanded.

## 3. The tick is the unit of play

A tick represents a fixed but abstract period. Commitments and background pressures
are considered together as a coherent period of world change:

**Discuss the period → confirm broad commitments → close → DM adjudicates and
reviews → publish established changes.**

1. **Open:** show current ongoing Tensions, their visible clocks/influences, and an
   updated briefing in each Tension's persistent discussion thread.
2. **Discuss:** players coordinate and explore approaches; the DM clarifies
   feasibility and likely consequences without establishing outcomes early.
3. **Commit:** players explicitly confirm intentions and resources. A readiness
   signal helps the DM see who is finished, not enforce a mandatory action quota.
4. **Close:** freeze the latest commitments and relevant world inputs. The DM can
   close deliberately without every player submitting; missing or unresolved
   commitments must be visible and explicitly handled rather than silently lost.
5. **Adjudicate and review:** the DM considers the period as a whole, applies the
   small toolkit to a draft, and writes meaningful Events.
6. **Publish:** establish clock/Tension changes and Events together; deliver the
   recap and carry ongoing situations into the next tick.

Submission order must not decide fictional action order or outcomes. A dormant
thread or absent player does not freeze background world progression. No automatic
closing or real-time/mid-tick consequence engine is required.

Keep the useful existing close → resolving → in review → published boundary,
frozen inputs, review controls, and atomic publication. New review-time changes
must be staged through that boundary, not bypass current management locks.

## 4. The DM's small toolkit

- Move a clock forward or backward.
- Create or change a clock, including its ongoing progression/influence description.
- Record an Event, optionally attaching the mechanical changes it explains.
- Open, develop, or resolve a Tension.

The DM interprets freeform intentions directly. Do not require translating them
into released quest choices, executable action templates, a dice DSL, or a new
rules engine. Existing dice and quest tools need not be removed, but are not
prerequisites for this loop.

A resolution workspace should gather, by Tension, current circumstances, relevant
intentions, resource commitments, background influences, clocks, and draft Events.
It is a workspace for synthesis, not a tactical initiative queue.

## 5. History is part of play

Maintain one connected set of published Events with different views:

- Campaign chronicle: what has happened in the world?
- Tick recap: what changed during this period?
- Tension history: how did this situation develop?
- Location, character, or faction history: what happened involving this entity?

An Event should make it possible to understand what happened, when, who/what was
involved, what changed, and what it led to. One Event may concern multiple
Tensions/entities without duplicate copies in separate journals.

Start with a simple campaign/tick/Tension list and readable detail view. Add typed
links to existing entities, filtering, pagination, and follow-on Tension navigation
as the next layer. Keep past context readable if live entities change. Do not
invent a graph editor, semantic search, or a comprehensive legacy-history import.

History must respect publication and visibility. A hidden clock, unpublished
outcome, private reference, or DM-only account must not leak through titles,
counts, links, thread briefings, or search results.

## 6. Resources: begin descriptively

The fiction may include consumables (gold, provisions, favour) and persistent
assets (mercenaries, ships, spy networks). Committing an asset can make it
unavailable elsewhere or expose it to risk, rather than simply spending points.

For the first playable loop, record commitments as text and let the DM adjudicate
them. Do not require an inventory, automated spending, allocation solver, or
calculated clock bonuses. Record relevant resulting changes in Events using the
supported world tools. Add named assets/availability and explicit ongoing
influences only if playtesting shows that descriptive tracking is insufficient.

This is a delivery simplification, not a decision that all resources must remain
unstructured forever.

## 7. Worked example: Battle in the Reach

An ongoing Tension concerns goblins advancing against elven defenders. Its clocks
include a balance of battle (full: goblin victory; empty: elven victory), elven
supply exhaustion, and approaching goblin reinforcements. Begin the balance clock
away from either endpoint so the opening situation is unresolved.

A player commits: “I devote my efforts to strengthening the elven position,
committing the Ash Company and seeking support from neighbouring lords.” Other
players can coordinate, contribute differently, or ignore the battle.

At tick resolution the DM considers all commitments and background pressures,
then drafts **The Ash Company holds the crossing**: the mercenaries repel two
assaults and buy time for villagers to escape, but their captain is wounded.

That single Event can explain a backward movement of goblin advance, completion
of an evacuation clock, and a new Tension concerning the wounded captain. These
become established together at publication. The battle may continue next tick.

Players can later follow the account from the battle, the Reach, an involved
character/faction, the tick recap, or the new Tension without separate journal
entries being maintained.

## 8. Incremental delivery

These are proposed implementation slices, not additional game rules. Each ships a
usable vertical slice with automated coverage and a reproducible demonstration.
No all-at-once rewrite, speculative subsystem, or design-only foundation phase.

### A. Manual world loop

1. **Manage Tensions and their clocks.** DM create/edit/detail, active/resolved
   presentation, clock association, circumstances and endpoint/influence text.
   Verify a multi-clock situation and retain existing standalone clocks.
2. **Adjudicate ticks into Events and basic history.** Stage manual changes and
   Event bundles, preview, publish atomically, and read a simple campaign/tick/
   Tension chronicle. Verify two ticks with no player commitments, including a
   continuing and a resolved Tension. This is the first usable world simulation.

### B. Player discussion and resolution

3. **Persistent Discord Tension threads and briefings.** Create/reuse one logical
   discussion thread per visible ongoing Tension, update at opening, and post
   published developments. Reuse durable delivery and controlled recovery.
4. **Freeform commitments and readiness.** Character-owned confirmations across
   Tensions, revisions/withdrawals, optional resource text, DM retrieval, and
   frozen close inputs. No quest requirement or global single-action limit.
5. **Tension-centred DM resolution workspace.** Bring commitments, background
   movement, clocks, and Event bundles together, using the same staged review and
   publication operations delivered earlier.

### C. Connected history and adoption

6. **Explore connected history.** Extend the existing chronicle with entity links,
   filters/pagination, and causal navigation into follow-on Tensions. Provide
   player retrieval from Discord without requiring a new player web application.
7. **Rehearse and adopt the loop.** Run a multi-tick disposable Discord campaign,
   record acceptance evidence and a short operating guide, and make quest-free
   participation discoverable without damaging existing campaigns/history.

### Conditional follow-up

8. **Named resources and ongoing influences, only if needed.** After rehearsal,
   identify a concrete tracking problem before implementing a minimal asset/
   availability or influence layer. Keep the manual route; no generic rules engine.
   This issue is not a prerequisite for accepting the core project.

### Tracked delivery chunks

| Issue | Deliverable | Depends on |
| --- | --- | --- |
| [ENG-90](https://linear.app/warp-monster/issue/ENG-90) | DM-managed Tensions and clocks | — |
| [ENG-91](https://linear.app/warp-monster/issue/ENG-91) | Manual tick Events and basic chronicle | ENG-90 |
| [ENG-92](https://linear.app/warp-monster/issue/ENG-92) | Persistent Discord threads and briefings | ENG-91 |
| [ENG-93](https://linear.app/warp-monster/issue/ENG-93) | Freeform commitments and readiness | ENG-92 |
| [ENG-94](https://linear.app/warp-monster/issue/ENG-94) | Tension-centred DM resolution workspace | ENG-93 |
| [ENG-95](https://linear.app/warp-monster/issue/ENG-95) | Connected history exploration | ENG-91, ENG-92 |
| [ENG-96](https://linear.app/warp-monster/issue/ENG-96) | Multi-tick rehearsal, guide, and adoption | ENG-94, ENG-95 |
| [ENG-97](https://linear.app/warp-monster/issue/ENG-97) | Conditional named resources/influences | ENG-96; evidence required |

The first seven issues form the three core milestones. ENG-97 is deliberately
outside them and is not an acceptance dependency. The dependency links describe
the delivery order; consult Linear for current issue status, owners, and dates.

## 9. Boundaries, verification, and outstanding choices

Every slice must preserve campaign isolation, fresh authorization, existing
public/known/hidden clock projections, frozen-input safety, inspectable history,
and retry-safe publication/delivery. Verify transaction rollback leaves no partial
world/history/delivery writes and that unpublished drafts do not leak to players.
Drafts are not public facts. Do not promise
exactly-once Discord delivery or rewrite published records to recover a failure.
Run focused tests and `mix precommit`; process tests use supervised processes and
message/monitor coordination rather than sleeps.

The initial visibility proposal is campaign-visible Tensions/Events plus DM-only
drafts/notes, preserving existing clock secrecy. Confirm the smallest explicit
policy before player-facing implementation; per-character knowledge and secret
thread infrastructure are not prerequisites. An Event's text and references must
be safe for its audience; do not assume prose can be automatically redacted.

Before touching resolution, inspect the existing automatic full-clock latching,
race ordering, trigger semantics, and snapshot versions. Introduce explicit
Tension/manual behaviour without silently changing legacy resolution. Existing
clock association should be simple initially; shared-clock semantics across
multiple Tensions are not required.

Older quest-centred proposal/adaptation issues and separate lore retrieval work
need explicit reconciliation when adopted; do not automatically cancel or move
them. Preserve completed opening/delivery/world-model work and legacy published
history. Deprecation, migration, secret knowledge, resource automation, automatic
outcome graphs, AI adjudication, and moment-to-moment play remain out of scope
unless separately agreed.
