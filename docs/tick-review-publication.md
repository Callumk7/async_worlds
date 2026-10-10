# Audited world review and atomic publication (ENG-8)

Interfaces authorize the current campaign DM with `Campaigns.authorize_dm/2`.
Snapshot/draft/edit/publication reads and previews are DM-only. Player-facing
interfaces consume only the public projection or approved public output, never
raw payloads, full history, or the `dm` output. ENG-9/ENG-10 own UI/commands.

## Review operations

Use `Ticks.edit_draft(campaign_id, tick_id, expected_draft_id, operation,
actor_id, reason)`. Actor must be the campaign's current DM ID; reason must be
nonblank and at most 2000 characters. Operations accept string or atom keys:

```elixir
%{type: "clock_delta", clock_id: clock.id, delta: 2}
%{type: "world_news", text: ["The gates open.", "The city prepares."]}
```

A clock delta **replaces** its signed background delta for this tick, rather
than adding to the resulting draft fill. It is clamped to clock bounds. An
explicit override can adjust a paused clock; completed frozen clocks cannot be
adjusted or resurrected. Nil clears the selected override and restores the frozen
rate/pause behavior. Unknown/foreign clocks and unsupported fields are rejected.

Each edit re-resolves the original snapshot with all current overrides, never
uses the prior draft's resulting clocks as inputs, and appends both a new draft
revision and an audit record linking old/new UUIDs. The audit includes actor,
reason, and operation. Effects, completion, race winners, starts, notifications,
and generated news are recomputed. Existing initial-full latches remain: lowering
an initially full clock's delta does not undo its eligibility to fire. Rates and
latches still use the ENG-4 deterministic order.

World-news overrides are explicit approved narration: a list of up to 100
nonblank paragraphs, each at most 2000 characters. An empty list suppresses news;
nil restores generated news. Narration persists across clock edits until cleared;
the underlying trigger log still records generated intent. Authored trigger news
and DM-authored narration are deliberately public text, even when the originating
clock is hidden. Do not include secrets in public narration.

`list_review_edits/2` returns campaign-scoped audit history. All edits require
`in_review` and the current draft UUID; concurrent edits/publish fail rather than
silently overwriting an approved revision. `put_draft/5` remains the trusted engine
storage primitive, not the interface's review API. Arbitrary low-level payloads
cannot pass the canonical preview/publication check.

## Preview and publication

`preview_draft/3` checks the selected current revision and returns exact outgoing
`%{"public" => messages, "dm" => messages}`. `Ticks.Output` is the shared renderer:
public output omits hidden clocks, shows known-clock names without fill/completion
or pause details, and shows public clock fills. The DM gets all clocks and private
notifications. Deterministic Unicode-safe chunks are at most 1900 codepoints;
each message includes kind, recipient ID, and content.

`publish_tick/3` runs under the campaign/tick row locks and in one transaction:

1. Require `in_review`, current draft UUID, and matching snapshot revision.
2. Reconstruct overrides from the append-only audit trail and verify that the
   complete draft matches canonical resolution of frozen inputs.
3. Require live clock inputs, frozen Discord routing/DM configuration, previous
   published number, and management lock to match. Drift returns
   `:stale_live_state`, without partial writes. Restore compatible live state
   through authorized administration; do not rewrite frozen inputs/history.
4. Apply ordered clock effects and source-labelled clock audits.
5. Persist one immutable publication with the approved payload/log and exact
   outputs, then enqueue each message and its Oban job. Keys include tick,
   audience, recipient, and deterministic chunk index.
6. Mark published, advance the campaign number, and unlock clock management.

`fetch_publication/2` returns immutable approved history. Review edits and
publications reject database updates and direct deletes; campaign/tick cascade
cleanup remains possible. Published content does not change with later clock or
campaign edits. No published rollback is implemented.

Repeated publication returns `:already_published`; competing stale approvals
return `:stale_draft`. Failed transactions roll back clock state, clock audits,
publication, delivery rows/jobs, tick transition, counter, and unlock. Delivery
failures after commit use ENG-7 targeted retries, never publication again. No
network I/O occurs during publication. Exactly-once logical outbox creation is not
an exactly-once Discord send guarantee.

`publish_tick/4` is the trusted internal transaction primitive retained for engine
extensions; interfaces must call `/3` and must not supply a custom callback.
