defmodule AsyncWorldsWeb.TensionSynthesisLiveTest do
  use AsyncWorldsWeb.ConnCase
  import Phoenix.LiveViewTest
  alias AsyncWorlds.{Campaigns, Characters, Clocks, Repo, TensionCommitments, Tensions, Ticks}
  alias AsyncWorlds.Ticks.{History, Publication, WorldResolver}
  alias AsyncWorlds.Tensions.{Discussion, Tension}

  test "Reach rehearsal: combined DM outcome is identical with reversed character/submission order",
       %{conn: conn} do
    results =
      for order <- [["Rook", "Wren"], ["Wren", "Rook"]] do
        guild = Integer.to_string(System.unique_integer([:positive]))
        dm = guild <> "456"

        {:ok, c} =
          Campaigns.setup_campaign(%{
            discord_guild_id: guild,
            dm_user_id: dm,
            public_channel_id: "789"
          })

        people =
          for name <- order, into: %{} do
            user = if name == "Rook", do: "991", else: "992"

            {:ok, character} =
              Characters.create_character(c, dm, %{name: name, discord_user_id: user})

            {name, character}
          end

        {:ok, missing} =
          Characters.create_character(c, dm, %{name: "Missing", discord_user_id: "993"})

        {:ok, withdrawn} =
          Characters.create_character(c, dm, %{name: "Withdrawn", discord_user_id: "994"})

        {:ok, battle} =
          Tensions.create_tension(
            c.id,
            %{
              name: "Battle in the Reach",
              description: "The crossing is contested",
              audience: :public
            },
            "dm"
          )

        {:ok, elsewhere} =
          Tensions.create_tension(c.id, %{name: "Relief elsewhere", audience: :public}, "dm")

        {:ok, unattended} = Tensions.create_tension(c.id, %{name: "Unattended pressure"}, "dm")

        {:ok, balance} =
          Tensions.create_clock(
            c.id,
            battle.id,
            %{
              name: "Goblin advance",
              mode: :tug_of_war,
              segments: 8,
              filled: 3,
              background_rate: 1,
              visibility: :public
            },
            "dm"
          )

        {:ok, evacuation} =
          Tensions.create_clock(
            c.id,
            battle.id,
            %{name: "Evacuation", segments: 4, filled: 1, visibility: :public},
            "dm"
          )

        {:ok, pressure} =
          Tensions.create_clock(
            c.id,
            unattended.id,
            %{name: "Hidden hunger", segments: 8, background_rate: 1},
            "dm"
          )

        {:ok, tick} = Ticks.open_tick(c.id)
        # Bound locator is transport metadata, never a source of inferred intent.
        discussion = Repo.get_by!(Discussion, campaign_id: c.id, tension_id: battle.id)

        Repo.update!(
          Ecto.Changeset.change(discussion, thread_id: guild <> "777", status: "ready")
        )

        for name <- order do
          user = people[name].discord_user_id

          assert {:ok, _} =
                   TensionCommitments.change(guild, user, tick.id, battle.id, 0, :edit, %{
                     "intention" => "PRIVATE #{name} effort",
                     "approach" => "Ash Company"
                   })

          assert {:ok, _} =
                   TensionCommitments.change(guild, user, tick.id, battle.id, 1, :confirm)
        end

        assert {:ok, _} =
                 TensionCommitments.change(guild, "991", tick.id, elsewhere.id, 0, :edit, %{
                   "intention" => "Relieve the granary",
                   "approach" => "Ash Company"
                 })

        assert {:ok, _} =
                 TensionCommitments.change(guild, "994", tick.id, battle.id, 0, :edit, %{
                   "intention" => "Withdraw this"
                 })

        assert {:ok, _} =
                 TensionCommitments.change(guild, "994", tick.id, battle.id, 1, :withdraw)

        {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.id, tick.id)
        frozen = snapshot.data["tension_commitments"]
        assert {:error, :tick_locked} = Clocks.adjust_clock(c.id, balance.id, 1, "dm")

        assert {:error, _} =
                 TensionCommitments.change(guild, "991", tick.id, battle.id, 2, :withdraw)

        {:ok, payload} = WorldResolver.resolve(snapshot)
        assert payload["events"] == []
        {:ok, %{draft: original}} = Ticks.put_draft(c.id, tick.id, snapshot.revision, payload)
        scope = %{campaign: c, discord_user_id: dm}
        {:ok, view, _} = live(log_in_dm(conn, c), ~p"/ticks/#{tick.id}/review")

        assert has_element?(
                 view,
                 "#thread-#{battle.id}[href='https://discord.com/channels/#{guild}/#{guild}777']"
               )

        assert has_element?(
                 view,
                 "#intent-#{battle.id}-#{people["Rook"].id}-v2 a[href='#intent-#{elsewhere.id}-#{people["Rook"].id}-v1']"
               )

        assert has_element?(view, "#intent-#{battle.id}-#{missing.id}-v0", "absent")
        assert has_element?(view, "#intent-#{battle.id}-#{withdrawn.id}-v2", "withdrawn")
        assert has_element?(view, "#intent-#{elsewhere.id}-#{people["Rook"].id}-v1", "unresolved")

        {:ok, stale_view, _} = live(log_in_dm(conn, c), ~p"/ticks/#{tick.id}/review")

        form(view, "#synthesis-form-#{battle.id}",
          synthesis: %{
            interpretation: "PRIVATE DM: Ash Company cannot be everywhere",
            deferred: Jason.encode!([missing.id, withdrawn.id]),
            reason: "Explicitly leave absence and withdrawal unresolved"
          }
        )
        |> render_submit()

        {:ok, notes} = Ticks.fetch_draft(c.id, tick.id)

        form(stale_view, "#synthesis-form-#{battle.id}",
          synthesis: %{interpretation: "Stale overwrite", deferred: "[]", reason: "Stale tab"}
        )
        |> render_submit()

        assert has_element?(stale_view, "#stale-review")
        assert has_element?(stale_view, "#synthesis-form-#{battle.id} fieldset[disabled]")
        assert {:ok, unchanged} = Ticks.fetch_draft(c.id, tick.id)
        assert unchanged.id == notes.id

        assert has_element?(
                 view,
                 "#intent-#{battle.id}-#{missing.id}-v0",
                 "Deliberately deferred by DM"
               )

        assert notes.payload["clocks"] == original.payload["clocks"]

        assert get_in(notes.payload, ["review", "synthesis", to_string(battle.id), "deferred"]) ==
                 [missing.id, withdrawn.id]

        assert {:error, :stale_draft} =
                 AsyncWorlds.DM.Ticks.edit_draft(
                   scope,
                   tick.id,
                   original.id,
                   %{
                     type: "synthesis",
                     tension_id: battle.id,
                     interpretation: "stale",
                     deferred: []
                   },
                   "Stale tab"
                 )

        assert {:error, :unauthorized} =
                 AsyncWorlds.DM.Ticks.fetch_draft(%{scope | discord_user_id: "991"}, tick.id)

        assert {:error, :invalid_edit} =
                 AsyncWorlds.DM.Ticks.edit_draft(
                   scope,
                   tick.id,
                   notes.id,
                   %{
                     type: "synthesis",
                     tension_id: battle.id,
                     interpretation: "bad",
                     deferred: [999_999]
                   },
                   "Foreign participant"
                 )

        {:ok, foreign} =
          Campaigns.setup_campaign(%{
            discord_guild_id: guild <> "999",
            dm_user_id: dm <> "999",
            public_channel_id: "789"
          })

        foreign_scope = %{campaign: foreign, discord_user_id: foreign.dm_user_id}
        assert {:error, :not_found} = AsyncWorlds.DM.Ticks.fetch_draft(foreign_scope, tick.id)

        assert {:error, :not_found} =
                 AsyncWorlds.DM.Ticks.edit_draft(
                   foreign_scope,
                   tick.id,
                   notes.id,
                   %{
                     type: "synthesis",
                     tension_id: battle.id,
                     interpretation: "Foreign",
                     deferred: []
                   },
                   "Cross campaign"
                 )

        # Cached console scope does not retain authority after revocation.
        Repo.update!(Ecto.Changeset.change(c, dm_user_id: dm <> "888"))
        assert {:error, :unauthorized} = AsyncWorlds.DM.Ticks.fetch_draft(scope, tick.id)

        Repo.update!(
          Ecto.Changeset.change(Repo.get!(AsyncWorlds.Campaigns.Campaign, c.id), dm_user_id: dm)
        )

        changes = [
          %{entity: "clock", id: balance.id, attrs: %{delta: -2}},
          %{entity: "clock", id: evacuation.id, attrs: %{delta: 3}},
          %{
            entity: "tension",
            id: nil,
            attrs: %{
              name: "The wounded captain",
              description: "Who leads next?",
              audience: "public"
            }
          }
        ]

        form(view, "#manual-world-form",
          world: %{
            key: "crossing",
            title: "The Ash Company holds the crossing",
            text: "Mercenaries repel assaults and villagers escape, but the captain is wounded.",
            audience: "public",
            action: "replace",
            changes_json: Jason.encode!(changes),
            reason: "Combined interpretation, not submission priority"
          }
        )
        |> render_submit()

        assert has_element?(view, "#event-bundles", "The Ash Company holds the crossing")

        assert has_element?(
                 view,
                 "#world_context-#{battle.id} a[href='#event_bundles-crossing']",
                 "The Ash Company holds the crossing"
               )

        assert Repo.get!(AsyncWorlds.Clocks.Clock, balance.id).filled == 3
        refute Repo.get_by(Tension, campaign_id: c.id, name: "The wounded captain")
        assert {:ok, %{items: []}} = History.list(guild, dm)
        {:ok, reloaded, _} = live(log_in_dm(conn, c), ~p"/ticks/#{tick.id}/review")
        assert has_element?(reloaded, "#synthesis-form-#{battle.id} textarea", "PRIVATE DM")
        element(reloaded, "#load-bundle-crossing") |> render_click()

        assert has_element?(
                 reloaded,
                 "#manual-world-form textarea[name='world[changes_json]']",
                 "delta"
               )

        # Revise the entire bundle without appending/double-applying its changes.
        form(reloaded, "#manual-world-form",
          world: %{
            text: "Mercenaries repel assaults; villagers escape, but the captain is wounded.",
            reason: "Revised recap"
          }
        )
        |> render_submit()

        {:ok, draft} = Ticks.fetch_draft(c.id, tick.id)
        {:ok, recomputed} = WorldResolver.resolve(snapshot, draft.payload["review"])
        assert recomputed == draft.payload
        {:ok, preview} = Ticks.preview_draft(c.id, tick.id, draft.id)
        public = Enum.map_join(preview["public"], "\n", & &1["content"])
        assert public =~ "The Ash Company holds the crossing"
        refute public =~ "PRIVATE"
        refute public =~ "Hidden hunger"
        assert has_element?(reloaded, "#public-preview", "The Ash Company holds the crossing")
        assert {:ok, _} = AsyncWorlds.DM.Ticks.publish_tick(scope, tick.id, draft.id)

        assert {:error, :already_published} =
                 AsyncWorlds.DM.Ticks.publish_tick(scope, tick.id, draft.id)

        assert Repo.aggregate(Publication, :count, :id) ==
                 if(order == ["Rook", "Wren"], do: 1, else: 2)

        {:ok, published} = Ticks.fetch_publication(c.id, tick.id)
        assert published.outputs == preview
        {:ok, again} = Ticks.fetch_snapshot(c.id, tick.id)
        assert again.data["tension_commitments"] == frozen
        assert Repo.get!(AsyncWorlds.Clocks.Clock, pressure.id).filled == 1

        assert Repo.get_by!(Tension, campaign_id: c.id, name: "The wounded captain").status ==
                 :ongoing

        {Repo.get!(AsyncWorlds.Clocks.Clock, balance.id).filled,
         Repo.get!(AsyncWorlds.Clocks.Clock, evacuation.id).filled}
      end

    assert results == [{2, 4}, {2, 4}]
  end
end
