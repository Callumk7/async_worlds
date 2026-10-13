defmodule AsyncWorlds.CharacterEditingConcurrencyTest do
  use ExUnit.Case, async: false
  alias AsyncWorlds.{Campaigns, Characters, Repo}
  alias AsyncWorlds.Campaigns.Campaign
  alias Ecto.Adapters.SQL.Sandbox

  defp db(fun), do: Sandbox.unboxed_run(Repo, fun)

  setup do
    {campaign, character} =
      db(fn ->
        {:ok, campaign} =
          Campaigns.setup_campaign(%{
            discord_guild_id: to_string(800_000_000 + System.unique_integer([:positive])),
            dm_user_id: "456",
            public_channel_id: "789"
          })

        {:ok, character} = Characters.create_character(campaign, "456", %{name: "Rook"})
        {campaign, character}
      end)

    on_exit(fn -> db(fn -> Repo.delete!(Repo.get!(Campaign, campaign.id)) end) end)
    %{campaign: campaign, character: character, supervisor: start_supervised!(Task.Supervisor)}
  end

  test "campaign serialization gives stale profile/flag racers exactly one winner", c do
    parent = self()

    operations = [
      fn ->
        Characters.update_character(c.campaign, "456", c.character.id, %{name: "Changed"},
          expected_character: c.character
        )
      end,
      fn ->
        Characters.set_flag(
          c.campaign,
          "456",
          c.character.id,
          "ready",
          %{"type" => "boolean", "value" => true, "player_visible" => false},
          expected_character: c.character
        )
      end
    ]

    tasks =
      Enum.map(operations, fn operation ->
        Task.Supervisor.async_nolink(c.supervisor, fn ->
          db(fn ->
            send(parent, {:ready, self()})

            receive do
              :go -> operation.()
            end
          end)
        end)
      end)

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}, 5000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    results = Enum.map(tasks, &Task.await(&1, 10000))
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :stale_character})) == 1

    db(fn ->
      {:ok, current} = Characters.get_character(c.campaign, "456", c.character.id)
      assert current.state_version == c.character.state_version + 1

      assert (current.name == "Changed" and current.flags == %{}) or
               (current.name == "Rook" and Map.has_key?(current.flags, "ready"))
    end)
  end
end
