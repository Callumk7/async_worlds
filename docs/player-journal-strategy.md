# Player journal implementation strategy (ENG-43)

**Historical research, superseded by ENG-42/ENG-47 and the owner-approved policy
in [journals.md](journals.md).** ENG-43 established the architecture; it did not
implement persistence. Do not use its original-author/private-history or soft-delete
proposals as the current product contract.

## Findings retained in the production implementation

- One PostgreSQL-backed `AsyncWorlds.Journals` context shared by interfaces.
- Campaign/character scoping and authorization under the campaign-first lock;
  player subject resolution through `PlayerAccess`, explicit current-DM inspection
  without requiring a linked character, and fresh debug-persona validation.
- `/journal new`, bounded metadata-only `/journal list`, full `/journal open` and
  confirmed `/journal delete`. All responses ephemeral; public means campaign
  discovery, never automatic channel announcements.
- Journal operations independent of ticks, world state, snapshots and outbox.
- Durable actor/subject/configuration/persona-bound creation receipts; atomic
  completion and replay protection even after content deletion or process restart.
- STRING IDs, stable keyset navigation, mention suppression, Unicode chunking,
  private generic denials and journal-specific stale-control instructions.
- Separate callback-type-9 modal-opening path, never after a defer. Type-5 submits
  defer privately first. Explicit bounded pre-modal preparation; no REST under locks
  and no mutation retries after ambiguous acknowledgments or failed final replies.

## Decisions resolved after research

- ENG-44 operator-confirmed a basic live legacy modal open/submit/private preview
  using Nostrum **0.10.4**. New Label wrappers lose their singular nested component
  in that version. Keep legacy Action Row parsing/construction isolated; no library
  upgrade, fallback slash editor or new dependency is required.
- Owner approved **character-owned journals**, including private history transfer
  on relink. Author identity/origin are attribution, not private-read restrictions.
- Owner approved current-DM moderation deletion and **hard deletion of content**,
  retaining a separate content-free durable receipt. Backup retention is separate.
- Owner approved private default, campaign-readable public entries and nonblank
  100/4,000 Unicode-codepoint title/body limits, preserving formatting/duplicate titles.

Implementation and current release/live-check guidance: [journals.md](journals.md).
Spike evidence and limitations: [journal-modal-spike.md](journal-modal-spike.md).

## Sources

- [ENG-42](https://linear.app/warp-monster/issue/ENG-42/journal-and-notes)
- [ENG-43](https://linear.app/warp-monster/issue/ENG-43/research-and-define-implementation-strategy)
- [ENG-44](https://linear.app/warp-monster/issue/ENG-44/spike-journal-implementation)
- [ENG-47](https://linear.app/warp-monster/issue/ENG-47/implement-persistent-player-journals-and-discord-createlistopendelete)
- [Discord interaction lifecycle](https://docs.discord.com/developers/interactions/receiving-and-responding)
- [Component/input limits and Action Row deprecation](https://docs.discord.com/developers/components/reference)
- [Modal components](https://docs.discord.com/developers/components/using-modal-components)
- [Application command options](https://docs.discord.com/developers/interactions/application-commands)
