# Discord bot, world-tick and private player commands (ENG-3 / ENG-10 / ENG-19)

Nostrum **0.10.4**, a stable Hex release, runs as an included OTP application
inside the optional `AsyncWorlds.Discord.Supervisor`. The bot, bounded task
supervisor and consumer use `:rest_for_one`: replacing the bot also replaces its
consumer so it rejoins the new consumer group. The Phoenix application starts
normally without a bot or token. No external bot service is required.

## Create and install the bot

1. Create a dedicated application in the [Discord Developer Portal](https://discord.com/developers/applications).
2. In **Bot**, create/reset the bot token. Keep it in your secret manager or local
   environment; never commit it, put it in a URL, or paste it into logs.
3. Copy the **Application ID** from General Information. This is not the token.
4. Keep all privileged gateway intents **off** (members, presence and message
   content). Slash commands arrive without gateway intents; this application
   explicitly configures an empty intent list and ignores ordinary messages.
5. Use Guild Install with the `bot` and `applications.commands` scopes, installing
   into your development guild. Do not grant Administrator. For public
   announcements, grant **View Channel** and **Send Messages** in the configured
   public channel. Tick-open announcements and approved publication output use
   this channel. Approved DM output needs the configured DM to accept bot DMs.
6. Leave the application's **Interactions Endpoint URL** unset: interactions
   arrive through the gateway, not a public HTTP endpoint. Discord command
   visibility/permission settings are optional UX restrictions, never the
   server-side DM authorization boundary. Ensure the configured DM can invoke
   the commands even if you customize those settings.

## Configure and run locally

Start PostgreSQL and run `mix setup` as described in [the README](../README.md).
Enable Discord Developer Mode to copy IDs, then configure a campaign:

```sh
mix campaign.setup \
  --guild-id 123456789012345678 \
  --dm-user-id 234567890123456789 \
  --public-channel-id 345678901234567890
```

Set these in your terminal or deployment secret environment:

| Variable | Meaning |
| --- | --- |
| `DISCORD_ENABLED` | Exactly `true` or `false`; defaults to `false`. |
| `DISCORD_BOT_TOKEN` | Bot secret, required only when enabled. |
| `DISCORD_APPLICATION_ID` | Application ID from the portal. |
| `DISCORD_GUILD_ID` | Development guild ID, matching a configured campaign. |

IDs are canonical positive unsigned 64-bit decimal strings. Enabled startup
rejects missing IDs/token; Nostrum additionally validates the token format. The
guild is an allowlist: even another guild with its own campaign cannot use this
bot's commands. Only one guild is enabled in this milestone.

```sh
export DISCORD_ENABLED=true
export DISCORD_APPLICATION_ID="your_application_id"
export DISCORD_GUILD_ID="your_development_guild_id"
# Supply DISCORD_BOT_TOKEN via your secret manager/environment, without logging it.
mix discord.register_commands
mix phx.server
```

Registration boots the supervised bot and bulk-overwrites **this application's**
commands in the configured guild. Re-running updates/replaces the same commands,
not duplicates. It deletes that application's guild commands not in this set;
use a dedicated development application. It never registers global commands,
never accepts another guild as a CLI argument, and requires an existing campaign.
Registration is explicit, not repeated on every reconnect or deploy.

The registered command set is:

- `/help` — private command names, descriptions and argument placeholders from the
  live command catalogue. Players see player commands; DMs also see DM commands.
  In player-testing mode, DM-role commands are hidden but real-DM debug controls
  remain visible. No linked character is required for ordinary player help.
- `/clocks` — private reply available to guild players: live public clock fills
  and known clock names only. Hidden clocks and known fills never appear. Draft
  state is never read. Large lists continue in private followups.
- `/faction list`, `/faction show faction:<id>` — available to every verified
  server member, including members without characters. List shows campaign faction
  IDs and names; show includes the description. Names and descriptions are
  campaign-readable, not DM secrets. Replies and long-content followups are private,
  mentions are suppressed, and foreign IDs never reveal other campaigns. These
  commands do not use a DM debug persona. Manage factions at `/factions`; see
  [factions.md](factions.md). Re-register commands after deploying this addition.
- `/location list`, `/location show location:<id>` — available to every verified
  server member without a character. List shows campaign location IDs and names;
  show includes the description. Names and descriptions are campaign-readable,
  not DM secrets. Replies and followups are private with mentions suppressed.
  These commands do not use a DM debug persona or reveal other campaigns.
  Manage locations at `/locations`; see [locations.md](locations.md).
  Re-register commands after deployment.
- `/tick open` — configured DM only; opens the next tick and atomically saves and
  queues a public roster briefing with `/quest` instructions and existing private
  prompts. No optional narration setup is required. Repeated opens do not create
  another tick or logical announcement. Web opens use the same transaction, with
  exact reviewed narration/chunks when prepared. See [tick opening](tick-opening.md).
- `/tick close` — configured DM only; freezes the world and queues resolution
  into a **private draft**, without publication. Repeated closes reuse the same
  snapshot/job. Review and approve in the web console.
- `/tick remind` — configured DM in DM role only; queues guarded private reminders for characters missing choices.
- `/result` — privately retrieves the latest applicable approved personal result for the owner or selected DM persona, even when outbound DMs fail.
- `/tick status` — configured DM only; reports open/resolving/in-review/published
  world readiness and informational quest submission counts; never automatically closes.
- `/debug` — current DM only; private testing persona, character picker and command catalogue.
  See single-account testing below.
- `/character` — private character name and explicitly visible typed
  flags. Normally identity comes from the interaction member; DM testing uses a freshly authorized character subject.
  Bootstrap characters at `/characters`; see [shared APIs](characters.md).
- `/quest` — private current node, eligible choices and generic disabled-choice hints.
  Buttons submit/revise your own choice; Clear removes it. Completed and unassigned
  quests have explicit empty/ending states. No resource assignment UI.
- `/intent view/edit/confirm/withdraw/ready` — private, version-checked broad
  Tension intentions, independent of quests; `/intent roster` retrieves the same
  participation state for the current DM. Opening threads provide tick/Tension
  IDs. No public posting or automatic outcomes; readiness is informational.
  See [commitment flow and rehearsal](tension-commitments.md).
- `/submission` — private current tick choice with the same revise/clear controls.
  Both commands remain usable when proactive bot DMs are blocked; run them in the
  configured guild, not in a direct message.
- `/journal new`, `/journal list`, `/journal open`, `/journal delete` — persistent
  character-owned journals, default private, with campaign-public discovery,
  paginated Open controls and confirmed hard deletion. DM-role `list scope:character`
  inspects a selected campaign character without a linked DM character. All replies
  are private; public visibility never posts automatically. See [journals.md](journals.md).
- `/admin` — configured DM only; privately links to `/dashboard`. This is a
  normal URL, **not** a bearer login token; web Discord OAuth verifies the DM.

Command discovery uses `AsyncWorlds.Discord.Commands.catalogue/0`, the same source
used for Discord registration and routing permissions. Add, edit or remove commands
there (or in a delegated definition such as `DebugInteractions.definition/0`); `/help`
and the `/debug status` listing update automatically without help-specific changes.
Subcommands inherit permission metadata from their parent. Help lists role-appropriate
commands regardless of tick/quest state; it does not promise an action is currently
executable. Re-register Discord commands after changing the registered definitions.

Only opening and explicit approved web publication enqueue public messages.
Closing, status, admin, character/clock queries, and draft edits never announce draft
content. Publication uses the existing audited domain API and privacy-filtered
renderer; the review preview is DM-only, while approved personal results/next
choices use frozen per-character private delivery routes. See
[quest-review.md](quest-review.md). Delivery failures never
reapply world state. Inspect/retry individual outbox records in the console;
ambiguous sends require explicit confirmation. See [delivery semantics](durable-work.md)
and [review/publication](tick-review-publication.md).
Quest buttons use the same application/guild/member authorization as commands.
Unknown components get a private unsupported reply; autocomplete and unrelated
modals are ignored. Journal modal submissions are handled through a namespaced
production path. [ENG-44](journal-modal-spike.md) is historical compatibility evidence,
not an opt-in feature; the spike flag is removed.

## Single-account player testing (including live campaigns)

Create characters at `/characters`. Discord ownership is optional: a blank account creates a
DM-controlled character whose labelled personal results go to the configured DM. Linked
characters retain their real owner and one-character-per-account uniqueness.

- `/debug status`: mode, selected character, linked-message-copy setting and role-aware
  command catalogue. Use its paginated buttons to select a character.
- `/debug player character:<internal ID>`: act as any character in this campaign. The ID
  is shown in `/characters`; it is not a Discord account ID.
- `/debug dm`: return to DM role. `/debug off`: clear the persona and turn off message copies.
- `/debug messages enabled:true`: explicitly copy linked players' personal messages to the
  DM as well as their real owners. Default off; `enabled:false` disables copies.

Player mode uses ordinary player privacy, eligibility and lifecycle rules. `/character`,
`/quest`, `/submission`, `/result`, `/journal` and `/clocks` work as player interactions; `/tick` and `/admin` deny
until you return to DM mode. `/debug` always remains available to the actual current DM.
Testing responses identify the character and warn that **changes are real**. There is no
sandbox, undo or resolution bypass. Accountless characters participate in readiness and
resolution exactly like linked characters. The web console stays DM-authorized independently
of the Discord persona. These controls are persisted across bot restarts.

The actual gateway member remains the actor; only the gameplay character changes.
Changes to the selected character, role or enabled mode increment a generation: old quest controls fail even after A → B → A. Toggling linked-message copies does not expire gameplay controls.
Other members cannot select characters or invoke `/debug`. Campaign reconfiguration invalidates
old debug state. The character picker always reauthorizes its target; picker buttons are
selectors, not gameplay controls or credentials.

Personal delivery destinations and character labels are frozen at tick close in v3 snapshots.
Accountless results always go to the frozen DM, regardless of selected persona or debug mode.
Linked owners are never redirected; opt-in copies are additive, deduplicated when owner equals
DM. Tick-open prompts and reminders also support these character routes, captured when each
intent is created. Send-time guards suppress stale ownership/DM identities without consulting
the selected persona. `/result` and historical `/submission` retrieve only the selected character;
normal linked players cannot inherit previous owners' history. Copy-setting changes apply to future closes only. Review shows the exact destinations and
messages that publication will enqueue. Existing v1/v2 snapshots and pending outbox records
retain their original destinations. Blocked bot DMs still use existing outbox failure/retry
handling; slash commands/buttons remain usable.

Single-account smoke check: create two accountless characters, assign distinct quests/flags,
open a tick, select each through `/debug status`, and submit different choices. Check hidden
flags/choices remain hidden; `/tick` is denied in player mode. Click an old quest button after
switching away and back: expect a refresh instruction. Return with `/debug dm`, close, review
and publish: both labelled personal results should reach your account. Verify copies are off
by default, and `/debug off` restores ordinary owner-based interaction behavior.

After upgrading, run `mix ecto.migrate`, restart the running bot/server, and run
`mix discord.register_commands` to register the new command set.

## Boundary, privacy and failure handling

`Consumer → Dispatcher → shared domain operations`, with Discord REST calls
behind `AsyncWorlds.Discord.Adapter`. Guild interactions use the gateway's
`member.user_id`, not usernames, command arguments or untrusted web form fields.
The dispatcher checks the application and configured guild, loads current
campaign configuration, and uses `Campaigns.authorize_dm/2` for DM commands.

Ordinary slash commands, journal submits and components defer with response type 5 and ephemeral flag 64 **before**
database work. Denials, unknown commands and failures edit that private original
response. Edits and ephemeral followups suppress automatic mentions. Responses
split at 1,900 Unicode codepoints, keeping every message within Discord's 2,000
codepoint limit without splitting UTF-8 characters. If any reply fails, later
chunks stop; no automatic response or command retry occurs. A failed/ambiguous initial response
never executes a domain command. A final response failure does not rerun it.
Journal modal opening is the exception: callback type 9 is the initial acknowledgment,
never after a defer. Read-only preparation has a hard 1,500 ms local queue/DB/lock
budget; ambiguous callback failure never sends a second acknowledgment.
Application errors are logged by stage only; payloads, tokens, exceptions and
API error bodies are never inspected. Nostrum rate-limiter logs are redacted
because their route/bucket URLs can contain webhook tokens. Avoid enabling
packet tracing or dumping library/process state in production: those diagnostic
dumps can include credentials and private player content.

Quest pages use at most 15 choice buttons (three rows) plus a navigation/clear
row. Long node text and full choice labels paginate in 1,400-codepoint chunks;
button labels truncate to 80 codepoints and include choice numbers. All text is
preserved across pages. No-tick, completed and closed views also paginate one
private message per click, with navigation only (no submit/clear controls).
Read-only navigation binds to the verified owner and fresh projected state;
changed views require a refresh. Webhook followup creates omit the `components`
key when there are no controls; response edits may use `[]` to clear controls.
Submission components encode tick, quest instance, pinned revision,
position version and 96-bit node/choice ID digests in under 100 characters.
These are locators, not authorization tokens: the handler compares them to the
verified owner's freshly projected state, then shared submission operations
recheck lifecycle and eligibility transactionally. Stale controls after close,
progression, reassignment or eligibility changes fail privately with instructions
to refresh via `/quest` or `/submission`. No conditions, hidden flags, hidden
choices, outcome definitions or draft results are included in responses.

Discord is not the idempotency authority. Duplicate delivery normally fails its
second acknowledgment, but another interaction ID, bot restart or transport
ambiguity must still be safe. Command handlers receive the authorized campaign,
verified user ID and interaction ID, and use shared domain transactions with
lifecycle/idempotency constraints. Open announcements and publication deliveries
are committed with their respective transitions and delivered by Oban, never by
the command handler. Reconnects do not replay announcements.
Do not automatically retry state-changing commands on Discord errors; inspect
the domain state first. Nostrum handles its own REST rate limits and gateway
reconnects. Event task concurrency is capped at 100; saturation logs a safe
failure rather than starting unbounded workers.

## Tests and live smoke test

```sh
mix precommit
```

In `MIX_ENV=test` the bot is disabled, the transport is fake, and Discord runtime
variables are ignored even if credentials are inherited from your shell. Tests
cover a real Nostrum-converted interaction through the supervised consumer,
repeat registration, authorization, duplicate/failure paths and redaction,
without opening a gateway or making Discord API requests.

After supplying real credentials, verify manually:

1. Register twice and confirm there is one copy of each guild command.
2. Start the server and confirm Nostrum reports a ready gateway connection.
3. As the configured DM, invoke `/admin`; follow the private link and sign in.
4. As another member, invoke a tick command; expect a private denial. `/clocks`
   should show only public fills and known names (or the empty state).
5. As DM, `/tick open` twice: one tick and one public announcement. `/tick status`
   reports open. `/tick close` twice: one private draft, no public world news.
6. Review in the console; verify public preview excludes hidden clocks and known
   fills. Publish once and confirm approved output arrives publicly and DM output
   privately. Repeated publication must not send again.
7. Invoke from another guild (if installed there); expect a private denial.
8. With two assigned players, use `/quest` and `/submission` to submit, revise
   and clear independently. Close the tick or reassign a quest, then click an old
   button: expect a private refresh instruction. Block bot DMs and verify slash
   commands still work. Verify long quests paginate without missing labels.
9. Restart the application and invoke again; campaign state and pending outbox
   records must persist. Test blocked DMs and inspect the failed delivery record.

No real Discord credentials are required or provisioned by the automated suite.
Production also needs Phoenix's existing database/endpoint secrets in
`config/runtime.exs`; configuring Discord does not replace those requirements.
