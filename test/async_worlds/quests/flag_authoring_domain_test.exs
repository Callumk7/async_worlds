defmodule AsyncWorlds.Quests.FlagAuthoringDomainTest do
  use AsyncWorlds.DataCase
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Quests, Repo}
  alias AsyncWorlds.Quests.{Authoring, WorkingCopy}

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    %{campaign: campaign}
  end

  test "opaque imported targets and mismatched types are retained in drafts but never released",
       c do
    for {effect, index} <-
          Enum.with_index([
            %{
              "type" => "set_flag",
              "key" => "secret",
              "flag" => flag(),
              "target" => "other_character"
            },
            %{"type" => "clear_flag", "key" => "secret", "target" => "party"},
            %{
              "type" => "set_flag",
              "key" => "secret",
              "flag" => %{"type" => "integer", "value" => "wrong", "player_visible" => false}
            }
          ]) do
      # Seed a legacy/future imported draft; current strict JSON import correctly rejects these.
      d = replace_choice(definition(), choice("act", "hub", [effect]))

      work =
        Repo.insert!(%WorkingCopy{
          campaign_id: c.campaign.id,
          name: "Imported",
          content_id: "legacy_#{index}",
          definition: d,
          source_definition: d
        })

      applied =
        Authoring.apply_form(work, %{"node_0_choice_0_text" => "Edited ordinary narration"})

      assert hd(hd(applied.definition["nodes"])["choices"])["outcomes"]["fixed"]["effects"] == [
               effect
             ]

      assert {:ok, saved} =
               Quests.save_working_copy(
                 c.campaign,
                 "456",
                 work.id,
                 work.version,
                 Map.take(applied, [:name, :content_id, :definition])
               )

      assert {:error, {:validation, errors}} =
               Quests.release_working_copy(
                 c.campaign,
                 "456",
                 saved.id,
                 saved.version,
                 Map.take(saved, [:name, :content_id, :definition])
               )

      assert Enum.any?(errors, fn {path, _} -> String.contains?(path, "effects[0]") end)
      assert Repo.get!(WorkingCopy, saved.id) == saved
      assert {:ok, %{revisions: []}} = Quests.library(c.campaign, "456")
    end
  end

  test "forged campaign/actor identity cannot authorize flag definition changes", c do
    {:ok, work} = Quests.create_working_copy(c.campaign, "456")

    {:ok, foreign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "124",
        dm_user_id: "457",
        public_channel_id: "790"
      })

    attrs = Map.take(work, [:name, :content_id, :definition])

    assert {:error, :not_found} =
             Quests.save_working_copy(foreign, "457", work.id, work.version, attrs)

    assert {:error, :unauthorized} =
             Quests.release_working_copy(
               %{c.campaign | dm_user_id: "999"},
               "999",
               work.id,
               work.version,
               attrs
             )

    assert Repo.get!(WorkingCopy, work.id) == work
  end
end
