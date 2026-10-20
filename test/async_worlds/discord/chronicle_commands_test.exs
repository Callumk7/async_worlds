defmodule AsyncWorlds.Discord.ChronicleCommandsTest do
  use AsyncWorlds.DataCase, async: false
  alias AsyncWorlds.{Campaigns, Repo, Ticks}
  alias AsyncWorlds.Discord.{Commands, Dispatcher, FakeAdapter, NostrumAdapter}

  setup do
    start_supervised!({FakeAdapter, owner: self()})

    {:ok, c} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    Repo.insert!(%AsyncWorlds.Characters.Character{
      campaign_id: c.id,
      discord_user_id: "111",
      name: "Reader"
    })

    %{c: c, opts: [adapter: FakeAdapter, guild_id: "123", application_id: "222"]}
  end

  defp data(name, opts \\ []),
    do: %{name: "chronicle", options: [%{type: 1, name: name, options: opts}]}

  defp option(name, value),
    do: %{name: name, value: value, type: if(is_integer(value), do: 4, else: 3)}

  defp interaction(data),
    do: %{
      type: 2,
      id: System.unique_integer([:positive]),
      application_id: 222,
      guild_id: 123,
      member: %{user_id: 111},
      token: "test-only",
      data: data
    }

  test "dispatcher retrieval is private, published-only and shares the public projection", x do
    assert {:ok, empty} = Dispatcher.handle(interaction(data("list")), x.opts)
    assert empty =~ "No published Events"
    {:ok, tick} = Ticks.open_tick(x.c.id)
    {:ok, %{snapshot: s}} = Ticks.close_tick(x.c.id, tick.id)
    {:ok, p} = AsyncWorlds.Ticks.WorldResolver.resolve(s)
    {:ok, %{draft: d}} = Ticks.put_draft(x.c.id, tick.id, s.revision, p)

    d =
      Enum.reduce(
        [
          {"public", "crossing", "The Ash Company holds the crossing"},
          {"dm", "secret", "Secret title"}
        ],
        d,
        fn {audience, key, title}, d ->
          {:ok, %{draft: d}} =
            Ticks.edit_draft(
              x.c.id,
              tick.id,
              d.id,
              %{
                type: "world",
                key: key,
                event: %{
                  title: title,
                  text: "@everyone Account",
                  kind: "event",
                  audience: audience,
                  changes: []
                }
              },
              "456",
              "PRIVATE REVIEW REASON"
            )

          d
        end
      )

    assert {:ok, ^empty} = Dispatcher.handle(interaction(data("list")), x.opts)
    {:ok, _} = Ticks.publish_tick(x.c.id, tick.id, d.id)

    assert {:ok, listing} =
             Dispatcher.handle(
               interaction(data("list", [option("tick", to_string(tick.id))])),
               x.opts
             )

    assert listing =~ "The Ash Company holds the crossing"
    refute listing =~ "Secret"
    assert listing =~ "scope_tick:#{tick.id}"

    assert {:ok, detail} =
             Dispatcher.handle(
               interaction(
                 data("show", [option("tick", to_string(tick.id)), option("event", "crossing")])
               ),
               x.opts
             )

    assert detail =~ "@everyone Account"
    refute detail =~ "PRIVATE REVIEW REASON"
    assert_receive {:discord, :edit_response, _}
    assert NostrumAdapter.followup_data(detail).flags == 64

    assert NostrumAdapter.followup_data(detail)
           |> Nostrum.Api.Helpers.prepare_allowed_mentions()
           |> Map.fetch!(:allowed_mentions) == %{parse: []}

    refute_receive {:discord, :send_public, _}
    refute_receive {:discord, :send_private, _}

    assert {:error, :not_found} =
             AsyncWorlds.Discord.ChronicleCommands.execute(
               {:chronicle, :show, %{"tick" => tick.id, "event" => "secret"}},
               %{campaign: x.c, user_id: "111"}
             )
  end

  test "routing rejects forged, duplicate, missing and mistyped options" do
    assert {:ok, {:chronicle, :list, %{}}, :player} = Commands.route(data("list"))

    for command <- [
          data("unknown"),
          data("show"),
          data("list", [option("guild", "321")]),
          data("list", [option("page", "2")]),
          data("list", [option("tick", "1"), option("tick", "2")])
        ] do
      assert {:error, :unknown_command} = Commands.route(command)
    end
  end
end
