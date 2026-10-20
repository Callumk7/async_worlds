# Tension-led play: DM and player operating guide (ENG-96)

A short guide to running a period of world change without quest nodes. Background
and rules: [direction](tension-led-world-play.md). Evidence and open gaps:
[rehearsal record](tension-led-rehearsal.md).

## Adopt it (once per campaign)

Dashboard → **Player participation** → **Adopt Tension-led participation**.

- This is an explicit DM choice; it is never inferred from Tensions existing.
  Existing campaigns keep their quest-centred wording until you adopt.
- It changes only future opening briefings and the `/quest` reply for characters
  without a quest. It changes no quests, Tensions, saved briefings, deliveries or
  published history. Quests keep working for characters who have them.
- A prepared opening preview goes stale when you toggle; prepare it again.
- **Return to quest-centred guidance** reverses it for future openings.
- `/intent` and `/chronicle` work in either mode; adoption only makes them discoverable.

## DM: one period

1. **Set the situation.** At `/tensions`, create or update each ongoing Tension
   (circumstances, stakes) and its clocks: position, influences, what each end
   means. Mark it **public** to give players a thread; public prose cannot be
   redacted later. Use known clocks to show a pressure exists, hidden clocks for
   secrets; background rate moves unattended pressure every tick.
2. **Open.** Dashboard → prepare the opening (optional narration), inspect every
   chunk, open. Each public Tension's thread receives a briefing with the tick and
   Tension IDs. Check **Deliveries** for failures (see Recovery below).
3. **Discuss.** Answer feasibility questions in threads. Do not establish outcomes
   in chat. Use `/intent roster tick:<id>` to see who has confirmed, revised,
   withdrawn, or not taken part. Readiness is informational.
4. **Close** whenever you choose. Absent and unresolved participation stays
   visible; nobody is penalised automatically. Late changes are rejected.
5. **Adjudicate** at `/ticks/:id/review`. For each Tension read the frozen
   commitments together with background movement. Record a private interpretation and
   any deliberate deferrals. Write Events: a title and short account, plus the clock
   moves, Tension developments, Resolution, or new follow-on Tension they explain.
   An Event can be narrative only. Submission order is never initiative.
6. **Publish** after inspecting the exact previews. Changes, Events and
   deliveries are established together. A repeat publish returns
   `already_published` and applies nothing twice.

Resolving a public Tension that still has known/hidden clocks: pause those clocks in a
separate DM-only routine bundle first ([details](tension-discussions.md)).

## Player: one period

1. Read the opening post and your Tensions' threads. You do not need a quest.
2. Discuss plans in the thread. **Chat is not a commitment.**
3. Record what your character is trying to achieve, privately:

   ```text
   /intent view tick:<tick ID>
   /intent edit tick:<id> tension:<id> version:0 intention:<broad effort> approach:<people, assets, method>
   /intent confirm tick:<id> tension:<id> version:<saved version>
   ```

   Contribute to several Tensions if the fiction allows. Describe committed assets
   in `approach`; there is no inventory or spending. Editing clears confirmation, so
   confirm again. `/intent withdraw` removes an effort. `ready` is optional.
   If a reply is ambiguous, run `view` again instead of retrying a write.
4. After publication, read the thread or `/chronicle list` and
   `/chronicle show tick:<id> event:<key>` to see what happened. Confirmation never
   guarantees success.

## Recovery without rewriting history

- **Failed message:** Dashboard → Deliveries → retry that message. Ambiguous sends
  require explicit duplicate-risk confirmation. Retrying never reopens a tick.
- **Thread creation ambiguous/blocked:** inspect Discord first, then bind the real
  thread or explicitly accept a duplicate via the
  [recovery API](tension-discussions.md#authorized-creation-recovery-api).
- **Archived thread:** unarchive it in Discord, then retry the failed message.
- **Restart:** saved intentions, frozen inputs, drafts and pending deliveries live
  in PostgreSQL; workers resume from them. Players can always re-read state with
  `/intent view` and `/chronicle`, even if a DM or post failed.
