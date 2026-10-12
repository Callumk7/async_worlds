# Quest JSON import (ENG-15)

Import is a **trusted DM/operator** tool, not a player upload endpoint. No new
web authoring UI is added. Operator tasks and future interfaces share
`AsyncWorlds.Quests.import_json(campaign, dm_id, json, clock_refs: bindings)`.
It re-fetches the campaign and authorizes its current DM while holding the
campaign row lock. Supplying an old campaign struct cannot restore revoked
access. It never assigns, swaps, moves, or publishes a character.

## Bootstrap without SQL

Run from the repository with dependencies installed and PostgreSQL configured
(`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`; see README for normal setup). No
Discord token/network is needed; leave the bot disabled for local bootstrap.
Replace the example Discord IDs with your campaign's IDs:

```sh
mix ecto.create
mix ecto.migrate
mix campaign.setup --guild-id 123 --dm-user-id 456 --public-channel-id 789
mix clock.create --guild-id 123 --dm-user-id 456 --name "Harbor alarm" --segments 6 --visibility hidden
# The preceding command prints the actual clock ID. Substitute it for 1 below:
mix quest.import --guild-id 123 --dm-user-id 456 --file priv/quests/harbor.json --clock alarm=1
# Repeat the SAME import: each quest reports `unchanged`, with the same revision ID.
```

`clock.create` is deliberately **not idempotent**; run it once, keep its ID, and
reuse it. It uses `Quests.create_clock/3`, a freshly authorized wrapper over the
existing audited, campaign-serialized `Clocks.create_clock/3`. Clock creation
is rejected during resolving/review. The trusted bootstrap wrapper requires a
nonempty name of at most 200 UTF-8 bytes and rejects NUL before persistence
(`:invalid_clock_name`). A source label alone in the lower-level
Clocks API is not authorization; operator callers must use the wrapper.
`quest.import` accepts repeated `--clock alias=id` arguments; duplicate aliases
are rejected. Bindings refer to existing clocks only and never create clocks.
An integer `clock_id` in JSON may be used instead. In either case the clock must
belong to the selected campaign. Aliases are converted to integer IDs before
validation/persistence; the immutable revision contains no unresolved aliases.
A clock in another campaign (or a missing/unbound clock) gets the same error.

Manage characters and assign the printed revision ID through the existing
`/characters` and `/quests` DM pages (or shared `Characters.create_character/3`
and `Quests.assign/4` operations). See [quest-operations.md](quest-operations.md).
The fixture offers a fixed entry/exit, a cyclic retreat/partial result, two
explicit endings, typed flags, a clock threshold, clamped clock deltas, a
2d6 roll, and ordered critical bonus effects. Normal tests execute the fixture
through import, assignment, submission, close/freeze and draft resolution,
plus controlled pure cyclic/rolled/ending transitions. Existing quest
publication is intentionally still blocked by ENG-20; import does not bypass
that boundary.

## Version 1 contract

Root is exactly `{"version": 1, "quests": [...]}` (nonempty quests). Every quest
is exactly `{"content_id": "stable-id", "name": "Display name", "definition": ...}`.
`content_id` is unique in the document and within the campaign; names are
nonempty, at most 200 bytes. Definition is exactly `start_node`, `nodes`.

All objects are strict: unknown/missing fields, duplicate JSON object keys,
duplicate IDs, incorrect types and unsupported variants fail. IDs are 1–100
ASCII letters/digits/underscore/hyphen. Text/labels/outcome text are nonempty
valid strings, at most 8000 bytes, with no NUL. Array order is retained.

- Node: `id`, `text`, `ending` (boolean), `choices` (array). Node IDs are unique
  per quest. Endings require no choices; non-endings require at least one.
- Choice: `id`, `label`, `eligibility` (`hidden`/`disabled`), `conditions` (ANDed
  array), `mode`, `outcomes`. Choice IDs are unique across all nodes of a quest.
- Fixed: `mode: "fixed"`, `outcomes` exactly `fixed`; no dice/critical fields.
- Rolled: `mode: "rolled"`, integer `dice` 1–3, `critical_effects` array,
  `outcomes` exactly `success`, `partial`, `failure`.
- Outcome: `text`, `next_node`, `effects` array. Start/next node references are
  **local to this quest definition**, never another quest/revision/campaign.
  Cycles are allowed; explicit endings are not inferred from reachability.
- Condition `clock_threshold`: `type`, `clock_id` (integer ID or bound alias),
  `operator` (`gte`/`lte`), integer `value` between zero and current clock size.
- Condition `character_flag`: `type`, `key`, `flag_type`
  (`boolean`/`integer`/`string`), `value` matching that type.
- Effect `clock_delta`: `type`, `clock_id`, integer `delta` within ±1,000,000.
- Effect `set_flag`: `type`, `key`, `flag` exactly `type`, `value`,
  `player_visible` (boolean). Effect `clear_flag`: `type`, `key`.

Flag keys/values follow [characters.md](characters.md) and existing ENG-13
validation. Flags target only the acting character. No resource conditions,
effects, declarations, grants or other resource mechanics are accepted.
See [quest-domain.md](quest-domain.md) for execution semantics/privacy.

## Atomicity and revision semantics

The whole document is decoded and validated before writes, inside one freshly
authorized transaction. Any error leaves **all** quest/revision/node rows
unchanged, including earlier entries or renames. Writes serialize on the same
campaign lock as authoring and tick close. The result is
`{:ok, [%{action: :created | :appended | :unchanged, revision: revision}, ...]}`.

A new `content_id` creates quest + revision 1. A repeat whose resolved
**definition and name equal the latest** stored definition/name returns the
same revision with `:unchanged`, inserting nothing. JSON whitespace/object
key order do not matter; array order does. A changed definition (or name)
appends a revision, preserving the stable quest row; it never rewrites old
revisions or node indexes. Reimporting an older definition after a newer one
appends again, rather than selecting the historical revision. No removals are
performed for quests omitted from the document. The name is a current quest
label, not a historical revision field. All imports validate references and
thresholds against **current** campaign clocks, including repeat imports.

Authoring/import may append during resolving/review, just like existing quest
authoring. Pinned assignments and already-frozen tick inputs are unchanged;
new revisions become available only for intentional later assignment/swap.
No revision or live progression is deleted, updated or silently repinned.

Failures return `{:error, [%{path: "$.quests[0].definition.nodes[1]...", message: ...}]}`
(first structural/content error, zero-based array indexes). JSON syntax errors
report `$` and the decoder's byte-position detail. Authorization/campaign
failures retain shared domain atoms such as `:unauthorized`, `:invalid_id`,
`:not_found`. The task prints the path and exits nonzero; never a success with
partial content.

## Offline regression commands

```sh
mix test test/async_worlds/quest_import_test.exs
mix precommit
```

Use an isolated PostgreSQL database for tests. The normal suite uses fake
Discord delivery and manual Oban jobs; it does not make Discord requests.
