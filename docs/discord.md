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

- `/clocks` — private reply available to guild players: live public clock fills
  and known clock names only. Hidden clocks and known fills never appear. Draft
  state is never read. Large lists continue in private followups.
- `/tick open` — configured DM only; opens the next tick and atomically queues
  one public `Tick N is now open.` announcement. Repeated opens do not create
  another tick or announcement. Web opens use the same transaction.
- `/tick close` — configured DM only; freezes the world and queues resolution
  into a **private draft**, without publication. Repeated closes reuse the same
  snapshot/job. Review and approve in the web console.
- `/tick status` — configured DM only; reports open/resolving/in-review/published
  world readiness and informational quest submission counts; never automatically closes.
- `/character` — private owner-only character name and explicitly visible typed
  flags. Identity comes from the interaction member, never a command option.
  Bootstrap characters at `/characters`; see [shared APIs](characters.md).
- `/quest` — private current node, eligible choices and generic disabled-choice hints.
  Buttons submit/revise your own choice; Clear removes it. Completed and unassigned
  quests have explicit empty/ending states. No resource assignment UI.
- `/submission` — private current tick choice with the same revise/clear controls.
  Both commands remain usable when proactive bot DMs are blocked; run them in the
  configured guild, not in a direct message.
- `/admin` — configured DM only; privately links to `/dashboard`. This is a
  normal URL, **not** a bearer login token; web Discord OAuth verifies the DM.

Only opening and explicit approved web publication enqueue public messages.
Closing, status, admin, character/clock queries, and draft edits never announce draft
content. Publication uses the existing audited domain API and privacy-filtered
renderer; the review preview is DM-only, while approved personal results/next
choices are routed privately to each frozen player's Discord user ID. See
[quest-review.md](quest-review.md). Delivery failures never
reapply world state. Inspect/retry individual outbox records in the console;
ambiguous sends require explicit confirmation. See [delivery semantics](durable-work.md)
and [review/publication](tick-review-publication.md).
Quest buttons use the same application/guild/member authorization as commands.
Unknown components get a private unsupported reply; autocomplete and modals are ignored.

## Boundary, privacy and failure handling

`Consumer → Dispatcher → shared domain operations`, with Discord REST calls
behind `AsyncWorlds.Discord.Adapter`. Guild interactions use the gateway's
`member.user_id`, not usernames, command arguments or untrusted web form fields.
The dispatcher checks the application and configured guild, loads current
campaign configuration, and uses `Campaigns.authorize_dm/2` for DM commands.

All slash commands and quest components defer with response type 5 and ephemeral flag 64 **before**
database work. Denials, unknown commands and failures edit that private original
response. Edits and ephemeral followups suppress automatic mentions. Responses
split at 1,900 Unicode codepoints, keeping every message within Discord's 2,000
codepoint limit without splitting UTF-8 characters. If any reply fails, later
chunks stop; no automatic response or command retry occurs. A failed/ambiguous initial response
never executes a domain command. A final response failure does not rerun it.
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
