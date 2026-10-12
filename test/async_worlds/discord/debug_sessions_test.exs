defmodule AsyncWorlds.Discord.DebugSessionsTest do
  use AsyncWorlds.DataCase, async: true
  alias AsyncWorlds.{Campaigns, Characters, PlayerAccess}
  alias AsyncWorlds.Discord.DebugSessions

  setup do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, a} = Characters.create_character(campaign, "456", %{name: "A"})
    {:ok, b} = Characters.create_character(campaign, "456", %{name: "B"})
    %{campaign: campaign, a: a, b: b}
  end

  test "only the current DM selects a campaign-scoped subject and old generations fail", c do
    assert {:error, :unauthorized} = DebugSessions.transition("123", "999", {:player, c.a.id})
    assert {:ok, first} = DebugSessions.transition("123", "456", {:player, c.a.id})
    assert {:ok, context} = PlayerAccess.context(c.campaign, "456")
    assert context.user_id == "456"

    assert {:ok, "A"} =
             PlayerAccess.run("123", context.access, fn _, character -> character.name end)

    assert {:ok, _} = DebugSessions.transition("123", "456", {:player, c.b.id})
    assert {:ok, last} = DebugSessions.transition("123", "456", {:player, c.a.id})
    assert last.generation > first.generation

    assert {:error, :stale_component} =
             PlayerAccess.run("123", context.access, fn _, _ -> :never end)

    assert {:ok, _} = DebugSessions.transition("123", "456", :off)
    assert {:ok, %{access: "456", role: :dm}} = PlayerAccess.context(c.campaign, "456")
  end

  test "reconfiguration revokes subjects and message copies", c do
    assert {:ok, _} = DebugSessions.transition("123", "456", {:player, c.a.id})
    assert {:ok, _} = DebugSessions.transition("123", "456", {:messages, true})
    assert {:ok, context} = PlayerAccess.context(c.campaign, "456")

    {:ok, updated} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "457",
        public_channel_id: "789"
      })

    refute DebugSessions.current(updated).enabled
    refute DebugSessions.current(updated).copy_messages

    assert {:error, :stale_component} =
             PlayerAccess.run("123", context.access, fn _, _ -> :never end)

    assert {:error, :unauthorized} = DebugSessions.transition("123", "456", :dm)
    assert {:ok, session} = DebugSessions.transition("123", "457", :dm)
    refute session.copy_messages

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    assert {:error, :stale_component} =
             PlayerAccess.run("123", context.access, fn _, _ -> :never end)

    {:ok, _} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "457",
        public_channel_id: "789"
      })

    assert {:error, :not_found} = DebugSessions.transition("123", "457", {:player, -1})
  end
end
