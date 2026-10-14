# Discord interaction ideas

Status: **Ideas only — not scheduled or approved for implementation.**

These notes capture possible player interaction patterns. They are not a delivery plan and do not change the current application behavior.

## Current foundations

The app already uses slash commands, private interaction replies, quest and journal buttons, pagination, a journal-creation modal, bot DMs, and public announcements. See [Discord integration](../discord.md) for the implemented behavior.

## Threads as scene and discussion spaces

Create a Discord thread for a quest, scene, party discussion, or player/DM conversation, and associate its Discord ID with the relevant game records.

Possible flow:

1. A player clicks **Start scene** on a quest view.
2. The app creates an appropriate public or private thread.
3. Players and the DM discuss or roleplay normally.
4. An explicit **Submit action** or **Submit outcome** interaction retrieves the conversation as supporting context for a structured submission.

The intended separation is **threads for the story; buttons and modals for committing game actions**. Ordinary conversation should not implicitly mutate world state or submit actions for tick resolution.

### Reading thread history

Discord exposes thread messages through its channel-message APIs. Our existing Nostrum dependency has thread and message-history APIs, but the application has not integrated this behavior.

Two possible approaches:

- **On-demand retrieval:** fetch paginated history only when a player explicitly submits or requests it. This is the simpler initial concept and provides a clearer privacy boundary.
- **Continuous ingestion:** listen for messages and potentially edits/deletions, maintaining a local record if durable transcripts become necessary.

Constraints to revisit before implementation:

- The bot needs appropriate thread creation, access, message-history, and sending permissions. Private threads require appropriate membership/access.
- Reading arbitrary player message content requires Discord's privileged **Message Content** intent, including in bot-created threads. Discord approval requirements depend on application status/scale.
- Our current bot disables gateway intents and ignores ordinary message events. Continuous ingestion would require deliberate changes to both configuration and event handling.
- History retrieval only returns surviving, accessible messages. Deleted messages cannot be recovered from Discord after the fact.
- A stored transcript would need an explicit privacy, retention, edit, and deletion policy.
- Thread visibility and game-data authorization must remain aligned; a thread is not automatically private just because its initiating command response was private.

Reference: [Discord threads](https://docs.discord.com/developers/topics/threads), [message resource and Message Content restrictions](https://docs.discord.com/developers/resources/message).

## Navigable entity views inside Discord

Example entry point: `/faction show 2`.

Rather than requiring another slash command for each related entity, render interactive navigation alongside the faction details.

### Links versus actions

Discord distinguishes between:

- **URL links / link buttons:** open a website or jump to a Discord message/thread; they do not invoke an application handler.
- **Command mentions:** provide a clickable slash-command reference, not a way to execute an arbitrary command with arguments such as `2`.
- **Interactive buttons:** send component interactions to our app, carrying identifiers for actions such as viewing a related faction.
- **Select menus:** send the selected option to our app for navigation or another explicit action.

An inline Markdown hyperlink cannot execute a bot command. Buttons and select menus are the relevant native controls for application actions.

Slash commands and component interactions should call the same underlying domain operations rather than simulating one another, with equivalent authorization checks.

## Dynamically generated select menus

Build a select menu from the content and visible relationships returned by `/faction show 2`.

Example:

> **The Ashen Council**
>
> A secretive alliance controlling the northern trade routes.
>
> **Explore…**
> - Rival faction: Silver Company
> - Allied faction: House Vey
> - Leader: Mira Ash
> - Territory: Northern Marches

Selecting an option could replace the current response with the selected entity's details and a newly generated menu, or produce a separate private response.

This would create a lightweight **in-Discord entity browser**, with slash commands as entry points rather than the only navigation mechanism.

Constraints:

- Standard string select menus support up to **25 options**; larger relationship sets need paging, grouping, or another discovery mechanism.
- Option labels and descriptions are plain text, not rich HTML.
- Only expose relationships the current player is allowed to know about.
- Reauthorize and reload relevant state on every selection. An old option is a locator, not an authorization token.
- Handle deleted, changed, or no-longer-visible targets gracefully.
- Keep navigation read-only unless a control explicitly communicates a state-changing action.

## Other possibilities mentioned

- A private `/play` dashboard linking Quest, Character, Submission, Journals, and Results.
- Buttons on quest views that open free-text action or note modals.
- Select menus for journals, targets, locations, and other growing lists.
- Command autocomplete for searchable arguments.
- User/message context commands, such as saving a message to a journal.
- Richer character, quest, and world-status message presentation.
- Actionable tick prompts and reminders, reducing the need to remember commands.

No implementation work is requested by this document. Revisit platform/library compatibility, permissions, privacy, and interaction design if any idea is taken forward.
