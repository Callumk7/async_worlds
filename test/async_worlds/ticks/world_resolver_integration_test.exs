defmodule AsyncWorlds.Ticks.WorldResolverIntegrationTest do
  use AsyncWorlds.DataCase, async: true
  alias AsyncWorlds.{Campaigns, Clocks, Ticks}
  alias AsyncWorlds.Clocks.Clock
  alias AsyncWorlds.Ticks.WorldResolver

  test "a reloaded frozen snapshot resolves into a persisted draft without live-state mutation" do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, clock} =
      Clocks.create_clock(
        campaign.id,
        %{
          name: "Storm",
          segments: 4,
          filled: 3,
          background_rate: 1,
          visibility: :hidden,
          triggers: [%{type: :world_news, text: "A storm arrives"}]
        },
        "dm:test"
      )

    {:ok, tick} = Ticks.open_tick(campaign.id)
    {:ok, %{snapshot: original}} = Ticks.close_tick(campaign.id, tick.id)
    {:ok, snapshot} = Ticks.fetch_snapshot(campaign.id, tick.id)
    audits_before = Clocks.list_audits(campaign.id)
    assert {:ok, payload} = WorldResolver.resolve(snapshot)
    assert payload["input_revision"] == original.revision
    assert payload["world_news"] == ["A storm arrives"]
    assert [%{"filled" => 4, "completed" => true}] = payload["clocks"]

    assert {:ok, %{draft: draft}} =
             Ticks.put_draft(campaign.id, tick.id, snapshot.revision, payload)

    assert draft.payload == payload
    live = Repo.get!(Clock, clock.id)
    assert live.filled == 3
    refute live.completed
    assert Clocks.list_audits(campaign.id) == audits_before
    assert {:ok, ^payload} = WorldResolver.resolve(snapshot)
    assert {:ok, %{status: :in_review}} = Ticks.fetch_tick(campaign.id, tick.id)

    assert {:error, :stale_draft} =
             Ticks.put_draft(campaign.id, tick.id, snapshot.revision, payload)
  end
end
