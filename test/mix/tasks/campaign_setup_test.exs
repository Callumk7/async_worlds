defmodule Mix.Tasks.Campaign.SetupTest do
  use AsyncWorlds.DataCase, async: false

  alias AsyncWorlds.Campaigns
  alias AsyncWorlds.Campaigns.Campaign
  alias Mix.Tasks.Campaign.Setup

  setup do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)
    :ok
  end

  test "setup task is repeatable and updates the guild's campaign" do
    args = ~w(--guild-id 123 --dm-user-id 456 --public-channel-id 789)
    Setup.run(args)
    assert_receive {:mix_shell, :info, [message]}
    assert message =~ "Configured campaign"
    assert {:ok, first} = Campaigns.fetch_campaign_by_guild("123")

    Setup.run(~w(--guild-id 123 --dm-user-id 654 --public-channel-id 987))
    assert_receive {:mix_shell, :info, [_]}
    assert {:ok, updated} = Campaigns.fetch_campaign_by_guild("123")
    assert updated.id == first.id
    assert updated.dm_user_id == "654"
    assert updated.public_channel_id == "987"
    assert Repo.aggregate(Campaign, :count) == 1
  end

  test "missing and malformed IDs give field-specific errors without writing" do
    assert_raise Mix.Error, ~r/dm_user_id can't be blank/, fn ->
      Setup.run(~w(--guild-id 123 --public-channel-id 789))
    end

    assert_raise Mix.Error,
                 ~r/discord_guild_id must be a positive unsigned 64-bit Discord ID/,
                 fn ->
                   Setup.run(~w(--guild-id nope --dm-user-id 456 --public-channel-id 789))
                 end

    assert Repo.aggregate(Campaign, :count) == 0
  end

  test "unknown, positional, incomplete and repeated options are rejected" do
    for args <- [
          ~w(--unknown value),
          ~w(positional),
          ~w(--guild-id),
          ~w(--guild-id 123 --guild-id 321 --dm-user-id 456 --public-channel-id 789)
        ] do
      assert_raise Mix.Error, ~r/Expected only/, fn -> Setup.run(args) end
    end
  end
end
