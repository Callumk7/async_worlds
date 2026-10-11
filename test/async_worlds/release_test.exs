defmodule AsyncWorlds.ReleaseTest do
  use AsyncWorlds.DataCase, async: false

  test "setup is idempotent, preserves tick and authorizes only the current DM" do
    attrs = %{discord_guild_id: "123", dm_user_id: "456", public_channel_id: "789"}
    campaign = AsyncWorlds.Release.setup(attrs)
    assert campaign.current_tick_number == 0
    updated = AsyncWorlds.Release.setup(%{attrs | dm_user_id: "999"})
    assert updated.id == campaign.id
    assert updated.current_tick_number == campaign.current_tick_number
    assert {:error, :unauthorized} = AsyncWorlds.Campaigns.authorize_dm("123", "456")
    assert {:ok, _} = AsyncWorlds.Campaigns.authorize_dm("123", "999")
    assert Process.whereis(AsyncWorlds.Discord.Supervisor) == nil
  end

  test "setup rejects invalid input before writing" do
    assert_raise RuntimeError, ~r/Invalid campaign setup/, fn ->
      AsyncWorlds.Release.setup(%{discord_guild_id: "0"})
    end
  end
end
