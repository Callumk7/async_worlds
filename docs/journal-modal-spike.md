# Legacy journal modal spike (ENG-44) — historical

The development-only **preview-only** spike has been replaced by the persistent
ENG-47 journal frontend. Its `JournalModalSpike` module and `DISCORD_JOURNAL_SPIKE`
flag are removed. Do not follow old flag/preview registration instructions.
Current commands, policies, deployment and live checklist: [journals.md](journals.md).

## Evidence retained

- Automated tests showed Nostrum **0.10.4** preserves legacy Title and multiline/
  Unicode Entry values through actual `Nostrum.Struct.Interaction.to_struct/1`
  conversion, dispatcher and supervised consumer using fake transport.
- Legacy format: one Text Input per Action Row, Title short style, Entry paragraph.
  Callback type 9 opens the modal with no preceding defer; submission type 5 defers
  ephemerally before parsing/authorization. Private chunks suppress mentions.
- New Label wrappers lose their singular nested `component` field in this installed
  Nostrum version. Raw outbound maps alone would not repair inbound conversion.
- Operator confirmed the development-guild modal opened, submission returned a
  private preview, and title/body presentation looked correct. This basic live
  round-trip is recorded in ENG-44's October 13, 2026 comment. Initial unsupported
  command failure was resolved by restarting the consumer with its old spike flag.
- That preview saved **no** entries. No claim was made for complete desktop/mobile,
  boundary-length Unicode, live stale-persona, rate-limit or contention coverage.

Discord [deprecates legacy Action Row text inputs](https://docs.discord.com/developers/components/reference#action-row)
in favor of Labels. It accepted the operator-tested flow, but there is no longevity
guarantee. Production construction/parsing stays isolated in `JournalInteractions`
for eventual migration without a current dependency upgrade.

The production follow-up retains converted gateway/security/acknowledgment tests,
adds durable receipts, privacy/list/open/delete and bounded pre-modal preparation,
and requires its **own** persistent development-guild live smoke evidence. Spike
compatibility evidence is not evidence that persistent journal behavior is live-tested.
