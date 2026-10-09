# Discord bot foundation (ENG-3)

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
   into your development guild. Do not grant Administrator. For the later public
   announcements, grant **View Channel** and **Send Messages** in the configured
   public channel. This foundation uses ephemeral interaction replies only; it
   does not yet send announcements or proactive DMs.
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

- `/clocks` — available to guild players.
- `/tick open`, `/tick close`, `/tick status` — configured DM only.
- `/admin` — configured DM only.

**ENG-3 registers and secures these commands, but does not implement gameplay or
OAuth.** Authorized invocations currently return a private "not implemented yet"
message. `/clocks` does not expose clocks; `/admin` does not yet issue a login
link. Their actual behavior belongs to ENG-10 and the web authentication work.
Unsupported component, autocomplete and modal interactions are ignored; they
must get explicit routing/authorization when those features are implemented.

## Boundary, privacy and failure handling

`Consumer → Dispatcher → shared domain operations`, with Discord REST calls
behind `AsyncWorlds.Discord.Adapter`. Guild interactions use the gateway's
`member.user_id`, not usernames, command arguments or untrusted web form fields.
The dispatcher checks the application and configured guild, loads current
campaign configuration, and uses `Campaigns.authorize_dm/2` for DM commands.

All slash commands defer with response type 5 and ephemeral flag 64 **before**
database work. Denials, unknown commands and failures edit that private original
response. Edits suppress automatic mentions. A failed/ambiguous initial response
never executes a domain command. A final response failure does not rerun it.
Application errors are logged by stage only; payloads, tokens, exceptions and
API error bodies are never inspected. Nostrum rate-limiter logs are redacted
because their route/bucket URLs can contain webhook tokens. Avoid enabling
packet tracing or dumping library/process state in production: those diagnostic
dumps can include credentials and private player content.

Discord is not the idempotency authority. Duplicate delivery normally fails its
second acknowledgment, but another interaction ID, bot restart or transport
ambiguity must still be safe. Future command handlers receive the authorized
campaign, verified user ID and interaction ID, and must use shared domain
transactions with lifecycle/idempotency constraints. No tick transitions exist
in ENG-3; tests use a guarded stand-in domain operation to exercise this boundary.
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
3. As the configured DM, invoke `/tick status`; expect the private placeholder.
4. As another member, invoke a tick command; expect a private denial. `/clocks`
   should return the private placeholder, not a denial.
5. Invoke from another guild (if installed there); expect a private denial.
6. Restart the application and invoke again; campaign configuration must persist.

No real Discord credentials are required or provisioned by the automated suite.
Production also needs Phoenix's existing database/endpoint secrets in
`config/runtime.exs`; configuring Discord does not replace those requirements.
