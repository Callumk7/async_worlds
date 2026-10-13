# Legacy journal modal spike (ENG-44)

[ENG-44](https://linear.app/warp-monster/issue/ENG-44/spike-journal-implementation)
spikes the input frontend proposed in [ENG-43 strategy](player-journal-strategy.md).
This is **not the journal feature**: nothing is saved, shared with other players,
or delivered to the DM. No schema/migration, new dependency or outbox is introduced.

## Findings

**Automated:** Nostrum 0.10.4 can decode legacy modal submissions with one Text Input
inside each Action Row. Title and multiline/Unicode body values survive actual
`Nostrum.Struct.Interaction.to_struct/1` conversion. Tests drive both the real
dispatcher and supervised consumer with a fake transport. The outbound payload is
callback type 9. Opening sends no preceding defer; submitting defers ephemerally
before parsing/authorization and returns an ephemeral preview.

**Automated:** newer Label wrappers lose their nested singular `component` field
in the installed Nostrum conversion. Using the supported legacy format avoids
that gap without upgrading Nostrum or patching dependencies.

**Documented by Discord:** Action Row text inputs in modals are deprecated in
favor of Labels, not described as removed. See the [official Action Row reference](https://docs.discord.com/developers/components/reference#action-row).
There is no longevity guarantee. The compatibility decision is deliberate: keep
legacy construction/parsing isolated so migrating it later is a small change.

**Not yet verified live:** Discord acceptance, actual desktop/mobile display,
interaction latency under real load, and live rate-limit behavior. Fake transport
success must not be reported as Discord API acceptance. Finish the checklist below
before closing ENG-44.

## Scope and mechanics

- Enabled only when `DISCORD_JOURNAL_SPIKE=true` in the **development** environment.
  Disabled by default and in production/test runtime config. Tests opt in explicitly.
- Catalogue registration/help includes `/journal new [visibility:private|public]`
  only when enabled. No existing command definitions are replaced in application code.
- `/journal new` privately defers, freshly resolves a linked character or authorized
  DM persona, and returns a Write entry button. Default intended visibility is private.
- Button callback opens a legacy modal: Title (short, max 100 codepoints) and Entry
  (paragraph, max 4,000). One Action Row per input. The modal title says “not saved”.
- Buttons and modals carry an HMAC-bound, under-100-byte control: trusted actor,
  campaign/configuration, character ownership/state, selected persona/generation,
  visibility, originating interaction and a 15-minute expiry. No draft text or
  Discord token is encoded. Recheck current identity/subject on open and submit.
- Submission validates exactly two distinct known input IDs. Blank/oversized or
  malformed input fails privately. Row order does not matter. Full bodies preserve
  line breaks and are split with the existing 1,900-codepoint response chunker.
- Even public intent produces only an ephemeral preview. Mentions are suppressed.
  DM visibility is descriptive of the future feature, not implemented by this spike.
- Failed/ambiguous modal acknowledgment never triggers a second acknowledgment or
  automatic retry. Initial submit-ack failure prevents processing the body.
- Disabling the spike ignores existing modal submissions and removes the catalogue
  entry; re-register to remove Discord's cached command definition as well.

Main implementation files:

- `lib/async_worlds/discord/journal_modal_spike.ex`: gated definition/router, legacy
  payload, bounded submit parser and expiring authenticated controls.
- `lib/async_worlds/discord/dispatcher.ex`: narrow modal-open initial-response branch
  and namespaced type-5 submit path; ordinary commands/components still defer first.
- `lib/async_worlds/discord/{adapter,nostrum_adapter}.ex`: injectable `open_modal/2`.
- `test/async_worlds/discord/journal_modal_spike_test.exs`: compatibility/security tests.

## Run the live check

Use the existing local development bot/campaign, not a production bot. Registration
bulk-overwrites **all this application's commands in the configured development
guild**, retaining the current catalogue and adding journal. Never register from a
second process while an old, spike-disabled server is still consuming events: restart
that server with the same flag first/stop it during registration.

With Discord configured per [discord.md](discord.md):

```sh
# Stop the existing development server first.
export DISCORD_JOURNAL_SPIKE=true
mix discord.register_commands
mix phx.server
```

The existing runtime loader supplies untracked local secrets if configured; no
credentials need to be pasted into scripts, tickets or chat. No new gateway intents
or Message Content permission are required.

1. As a linked player, invoke `/journal new`. Expect a private warning and Write
   entry button. Click it: expect a modal with title and multiline entry inputs,
   with no “interaction failed” banner.
2. Enter `A discovery 🌍` and two lines containing emoji plus `@everyone`. Submit.
   Expect a private NOT SAVED preview with exact text/line breaks and no notifications.
3. Repeat with `visibility:public`: preview remains private. Another account must
   not receive a channel post or DM. No delivery/outbox rows are created.
4. Test 100-character title and 4,000-character Unicode body. Check all preview
   chunks appear and preserve content. Check required fields and input limits.
5. As DM, select a character with `/debug player` (or picker), then repeat. An
   accountless character works; preview displays the existing testing banner.
6. Open a form, switch persona away/back using `/debug`, then submit the old form:
   expect a private expiry/refresh response, never another character's preview.
7. Cancel a modal: nothing changes. Try a button after 15 minutes: refresh required.
8. Check desktop and mobile presentation. Record approximate modal-open latency
   and submit outcome, not raw interaction payloads or tokens.

Record observations in ENG-44: Nostrum version, client, command/default/public path,
Unicode/multiline result, persona-staleness result, and any safe failure classification.
A successful manual check is needed to conclude the old modal format works against
Discord today.

Disable after the spike:

```sh
# Stop the server, then remove the cached spike command and restart normally.
unset DISCORD_JOURNAL_SPIKE
mix discord.register_commands
mix phx.server
```

## Remaining production work

The journal context, persistence, read/list/delete, DM retrieval, request idempotency
and deletion policy remain ENG-42 implementation work. The stateless spike deliberately
allows repeated valid submissions to produce another private preview; it does not
claim durable exactly-once creation. A real creation flow needs a persistent request
receipt or unique creation ID, including replay protection after deletion.

Opening a modal requires fresh database reads **before** the initial callback;
Discord's three-second deadline cannot be extended by deferring. The two-step flow
moves initial command work behind a defer but does not eliminate button-path lock
contention. Before promotion, add an explicit pre-callback query/lock/time budget and
measure under load. Do not retry ambiguous callbacks or move Discord REST into a
transaction. Disabling via environment and the signed stateless controls are suitable
for this preview, not a substitute for production quotas, audit/retention decisions
or permanently revoked creation flows.

Run validation:

```sh
mix test test/async_worlds/discord/journal_modal_spike_test.exs
mix precommit
```
