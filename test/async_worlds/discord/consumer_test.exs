defmodule AsyncWorlds.Discord.ConsumerTest do
  use AsyncWorlds.DataCase, async: false

  alias AsyncWorlds.Campaigns
  alias AsyncWorlds.Discord.{Consumer, FakeAdapter}

  setup do
    start_supervised!({FakeAdapter, owner: self()})
    start_supervised!(Nostrum.ConsumerGroup)
    start_supervised!({Task.Supervisor, name: AsyncWorlds.Discord.Tasks, max_children: 100})
    consumer = start_supervised!({Consumer, name: Consumer})
    previous = Application.fetch_env!(:async_worlds, :discord)
    on_exit(fn -> Application.put_env(:async_worlds, :discord, previous) end)

    Application.put_env(:async_worlds, :discord,
      adapter: FakeAdapter,
      guild_id: "123",
      application_id: "111"
    )

    %{consumer: consumer}
  end

  test "supervised consumer dispatches a real Nostrum-converted event without a gateway", %{
    consumer: consumer
  } do
    Campaigns.setup_campaign(%{
      discord_guild_id: "123",
      dm_user_id: "456",
      public_channel_id: "789"
    })

    interaction =
      Nostrum.Struct.Interaction.to_struct(%{
        id: "1000",
        application_id: "111",
        type: 2,
        guild_id: "123",
        member: %{user: %{id: "456", username: "dm"}},
        token: "private-token",
        data: %{name: "tick", type: 1, options: [%{type: 1, name: "status"}]}
      })

    assert interaction.member.user_id == 456
    Nostrum.ConsumerGroup.dispatch({:INTERACTION_CREATE, interaction, nil})
    _ = :sys.get_state(consumer)
    assert_receive {:discord, :defer, %{id: "1000"}}
    assert_receive {:discord, :edit_response, {_, content}}
    assert content =~ "No ticks yet."
    assert Process.whereis(Nostrum.Supervisor) == nil
  end

  test "ignores unrelated gateway events", %{consumer: consumer} do
    Nostrum.ConsumerGroup.dispatch({:MESSAGE_CREATE, %{content: "secret"}, nil})
    _ = :sys.get_state(consumer)
    refute_receive {:discord, _, _}
  end
end
