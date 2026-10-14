# ENG-38 — comment-ready verification note

Implemented consequence-first DM tick review with frozen player roster states
(submitted/missing/ending/no active quest), before/after positions and flags,
recorded rolls/outcomes, source-labelled clock contributions and shared downstream
trigger traces. World-clock overrides explicitly replace **background delta only**.
Existing domain resolution, dice preservation, audit and atomic publication
semantics remain unchanged.

Private previews are grouped by recipient/character/delivery route; public output
is separate. Numbered chunks preserve exact renderer content and ordering. Preview
failure blocks publication and empty sections are explicit. DM diagnostics are
labelled separately from owner messages. Authored narration/news are not magically
redacted: the DM remains responsible for their intended audience.

Actions are bound to the draft loaded by this LiveView, not a browser-selected
revision. Accepted edits reset approval. Stale edit/publication attempts retain
old content with a blocking warning; **Reload review** is required before another
edit/approval. Fresh LiveAuth and DMAccess authorization/scoping remain in place.

## Manual verification checklist (disposable campaign)

1. Assign a rolled quest to two players; submit for only one. Close/resolve and
   open `/ticks/:id/review` as the DM. Inspect submitted/missing rows, positions,
   flags, dice and next-node text. Force an ending outcome with an audit reason.
2. Include a quest clock delta of +3 on a four-segment clock with background +1
   and a world-news trigger. Inspect quest/background/completion/trigger traces.
   Override background to 0: final fill should be 3, not 0; the trigger disappears.
   Live clock/character state must remain unchanged before publication.
3. Check approval, then reroll one die, change/clear outcome, edit/clear narration,
   edit/restore generated news and override/clear background delta, each with a
   reason. Approval clears on edits; other recorded dice remain unchanged.
4. Use long Unicode narration to produce multiple private chunks. Compare each
   numbered chunk with the exact preview API/renderer output. Inspect a second
   player's route and public output: neither should contain the first player's
   private narration, hidden flags, hidden-clock diagnostics or known-clock fills.
5. Open two tabs. Edit in one, then edit/publish in the other. The stale tab must
   remain blocked with its old preview until explicit reload. Even submitting a
   newer UUID must not approve unseen content. Reload, inspect, confirm and publish.
6. Attempt publication from the second tab after the first publishes. Confirm
   delivery count and published state do not change. Compare saved publication
   outputs and outbox contents with the approved preview. Retry failed deliveries
   via existing delivery controls rather than republishing.
7. Reconfigure the DM or revoke the session; existing review tabs must redirect to
   login. Foreign campaign tick IDs must not be inspectable.

## Observed results

- These flows were exercised through authenticated Phoenix LiveView interaction
  tests and domain tests against local PostgreSQL, with controlled initial dice
  and the configured offline fake Discord adapter. Exact chunk text was compared
  using DOM text extraction, then against stored publication/outbox content.
- Tests cover all five edit types, ending/missing states, downstream recomputation,
  approval reset, preserved unselected dice, forged fresh tokens, explicit stale
  reload, duplicate publication, preview validation failure, campaign scoping and
  fresh authorization. Pure projection tests cover downstream cycles and separate
  recipient routes while retaining exact content/order.
- No real Discord sends, OAuth login or visual browser walkthrough was performed.
  The checklist above is supplied for that final disposable-campaign rehearsal;
  automated results are not a claim of real transport/visual verification.
- Final `mix precommit`: **660 tests, 0 failures** (seed 288417), run in the
  official `elixir:1.18` container with local PostgreSQL. This repository's alias runs warnings-as-errors compilation, unused
  dependency checks, formatting and tests; it does **not** include Credo and the
  repository has no Credo dependency. No new dependency was added.
- Formatting also normalized two pre-existing expressions in `clocks.ex` and
  `journals.ex`; those changes have no engine behavior impact.

Unresolved functional defects: none identified by the offline suite. Real Discord
transport and visual/keyboard rehearsal remain unverified, as noted above.
