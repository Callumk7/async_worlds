defmodule AsyncWorldsWeb.ClockTriggerLiveTest do
  use AsyncWorldsWeb.ConnCase
  import Phoenix.LiveViewTest
  import AsyncWorlds.QuestFixtures
  alias AsyncWorlds.{Campaigns, Characters, Clocks, Quests, Repo, Ticks, WebAuth}
  alias AsyncWorlds.Clocks.Clock

  setup %{conn: conn} do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "11001",
        dm_user_id: "22002",
        public_channel_id: "33003"
      })

    {:ok, other} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "11002",
        dm_user_id: "22003",
        public_channel_id: "33004"
      })

    {:ok, a} = Characters.create_character(campaign, "22002", %{name: "A"})
    {:ok, b} = Characters.create_character(campaign, "22002", %{name: "B"})
    {:ok, foreign} = Characters.create_character(other, "22003", %{name: "Foreign"})

    {:ok, revision} =
      Quests.create_quest(campaign, "22002", %{content_id: "quest", name: "Quest"}, definition())

    {:ok, foreign_revision} =
      Quests.create_quest(
        other,
        "22003",
        %{content_id: "foreign", name: "Foreign quest"},
        definition()
      )

    {:ok, clock} = Clocks.create_clock(campaign.id, %{name: "Storm", segments: 4}, "dm:test")

    %{
      conn: log_in_dm(conn, campaign),
      campaign: campaign,
      a: a,
      b: b,
      foreign: foreign,
      revision: revision,
      foreign_revision: foreign_revision,
      clock: clock
    }
  end

  test "configure and reopen all flag types through ordinary inputs, then unlock a quest", c do
    {:ok, view, _} = live(c.conn, ~p"/clocks")

    for {type, value, expected} <- [
          {"boolean", "false", false},
          {"integer", "-42", -42},
          {"string", "  \"quoted\"\nwords  ", "  \"quoted\"\nwords  "}
        ] do
      view |> element("#edit-clock-#{c.clock.id}") |> render_click()

      if not has_element?(view, "#trigger-0"),
        do: view |> element("#add-trigger") |> render_click()

      change_type(view, "set_flag")

      view
      |> form("#clock-form", clock: %{triggers: %{"0" => %{flag: %{type: type}}}})
      |> render_change()

      assert has_element?(view, "#clock_triggers_0_flag_value")

      view
      |> form("#clock-form",
        clock: %{
          triggers: %{
            "0" => %{
              character_id: to_string(c.a.id),
              key: "memory",
              flag: %{type: type, value: value, player_visible: "true"}
            }
          }
        }
      )
      |> render_submit()

      assert [%{type: :set_flag, character_id: id, flag: flag}] =
               Repo.get!(Clock, c.clock.id).triggers

      assert id == c.a.id
      assert flag == %{"type" => type, "value" => expected, "player_visible" => true}
      view |> element("#edit-clock-#{c.clock.id}") |> render_click()
      view |> form("#clock-form") |> render_submit()
      assert hd(Repo.get!(Clock, c.clock.id).triggers).flag == flag
    end

    view |> element("#edit-clock-#{c.clock.id}") |> render_click()
    change_type(view, "unlock_quest")
    assert has_element?(view, "#unlock-explanation-0")
    assert has_element?(view, "#clock_triggers_0_character_id option[value='#{c.b.id}']")
    refute has_element?(view, "#clock_triggers_0_character_id option[value='#{c.foreign.id}']")

    refute has_element?(
             view,
             "#clock_triggers_0_quest_id option[value='#{c.foreign_revision.quest_id}']"
           )

    view
    |> form("#clock-form",
      clock: %{
        triggers: %{
          "0" => %{character_id: to_string(c.b.id), quest_id: to_string(c.revision.quest_id)}
        }
      }
    )
    |> render_submit()

    view |> element("#edit-clock-#{c.clock.id}") |> render_click()
    view |> form("#clock-form") |> render_submit()

    assert [%{type: :unlock_quest, character_id: id, quest_id: quest_id, flag: nil, key: nil}] =
             Repo.get!(Clock, c.clock.id).triggers

    assert id == c.b.id
    assert quest_id == c.revision.quest_id
    assert Repo.get!(AsyncWorlds.Characters.Character, c.a.id).flags == %{}

    assert Enum.any?(
             Clocks.list_audits(c.campaign.id),
             &(&1.source == "dm:web:22002" && &1.operation == "edit")
           )
  end

  test "forged targets and invalid flags are rejected with field errors and no writes", c do
    {:ok, view, _} = live(c.conn, ~p"/clocks")
    view |> element("#edit-clock-#{c.clock.id}") |> render_click()
    view |> element("#add-trigger") |> render_click()
    change_type(view, "set_flag")
    baseline = length(Clocks.list_audits(c.campaign.id))
    flag = %{"type" => "integer", "value" => "12nope", "player_visible" => "false"}

    render_submit(view, "save", %{
      "clock" => %{
        "triggers" => %{
          "0" => %{
            "type" => "set_flag",
            "character_id" => to_string(c.a.id),
            "key" => "memory",
            "flag" => flag
          }
        }
      }
    })

    assert has_element?(view, "#trigger-0 .text-error")
    assert has_element?(view, "#clock_triggers_0_flag_value[value='12nope']")
    # Editing the ordered list must not erase invalid field values/errors.
    view |> element("#add-trigger") |> render_click()
    assert has_element?(view, "#clock_triggers_0_flag_value[value='12nope']")

    for trigger <- [
          %{
            "type" => "set_flag",
            "character_id" => to_string(c.foreign.id),
            "key" => "memory",
            "flag" => %{flag | "value" => "12"}
          },
          %{
            "type" => "unlock_quest",
            "character_id" => to_string(c.a.id),
            "quest_id" => to_string(c.foreign_revision.quest_id)
          },
          %{
            "type" => "unlock_quest",
            "character_id" => "999999999",
            "quest_id" => to_string(c.revision.quest_id)
          },
          %{"type" => "unlock_quest", "character_id" => to_string(c.a.id)},
          %{
            "type" => "set_flag",
            "character_id" => to_string(c.a.id),
            "key" => "Bad Key",
            "flag" => %{flag | "value" => "12"}
          },
          %{
            "type" => "set_flag",
            "character_id" => to_string(c.a.id),
            "key" => "memory",
            "flag" => %{flag | "value" => %{"bad" => "shape"}}
          }
        ] do
      render_submit(view, "save", %{"clock" => %{"triggers" => %{"0" => trigger}}})
      assert has_element?(view, "#trigger-0 .text-error")
      assert Repo.get!(Clock, c.clock.id).triggers == []
    end

    assert length(Clocks.list_audits(c.campaign.id)) == baseline
  end

  test "stored triggers retain invalid inputs across validate, add, repeated moves and remove",
       c do
    {:ok, _} =
      Clocks.edit_clock(
        c.campaign.id,
        c.clock.id,
        %{
          triggers: [
            %{
              type: :set_flag,
              character_id: c.a.id,
              key: "memory",
              flag: %{"type" => "integer", "value" => 12, "player_visible" => false}
            },
            %{type: :world_news, text: "Original news"}
          ]
        },
        "dm:test"
      )

    original = Repo.get!(Clock, c.clock.id)
    audits = length(Clocks.list_audits(c.campaign.id))
    {:ok, view, _} = live(c.conn, ~p"/clocks")
    view |> element("#edit-clock-#{c.clock.id}") |> render_click()

    view
    |> form("#clock-form",
      clock: %{triggers: %{"0" => %{flag: %{value: "12nope"}}, "1" => %{text: "Edited news"}}}
    )
    |> render_change()

    view |> element("#add-trigger") |> render_click()
    view |> element("#move-trigger-0-down") |> render_click()
    view |> element("#move-trigger-1-down") |> render_click()
    view |> element("#remove-trigger-1") |> render_click()
    assert has_element?(view, "#trigger-1 input[value='12nope']")
    assert has_element?(view, "#trigger-1 .text-error")
    refute has_element?(view, "#trigger-2")
    assert has_element?(view, "#trigger-0 textarea", "Edited news")
    assert Repo.get!(Clock, c.clock.id) == original
    assert length(Clocks.list_audits(c.campaign.id)) == audits

    view
    |> form("#clock-form", clock: %{triggers: %{"1" => %{flag: %{value: "13"}}}})
    |> render_submit()

    assert [%{text: "Edited news"}, %{flag: %{"value" => 13}}] =
             Repo.get!(Clock, c.clock.id).triggers
  end

  test "stored triggers reject foreign references with renderable field errors and no audit", c do
    {:ok, _} =
      Clocks.edit_clock(
        c.campaign.id,
        c.clock.id,
        %{triggers: [%{type: :world_news, text: "Original news"}]},
        "dm:test"
      )

    original = Repo.get!(Clock, c.clock.id)
    audits = length(Clocks.list_audits(c.campaign.id))
    {:ok, view, _} = live(c.conn, ~p"/clocks")
    view |> element("#edit-clock-#{c.clock.id}") |> render_click()

    for {field, trigger} <- [
          {"character_id",
           %{
             "type" => "set_flag",
             "character_id" => to_string(c.foreign.id),
             "key" => "memory",
             "flag" => %{"type" => "integer", "value" => "12", "player_visible" => "false"}
           }},
          {"quest_id",
           %{
             "type" => "unlock_quest",
             "character_id" => to_string(c.a.id),
             "quest_id" => to_string(c.foreign_revision.quest_id)
           }},
          {"clock_id", %{"type" => "start_clock", "clock_id" => "999999999"}}
        ] do
      render_submit(view, "save", %{"clock" => %{"triggers" => %{"0" => trigger}}})
      assert has_element?(view, "#clock_triggers_0_#{field}.admin-input-error")
      assert has_element?(view, "#trigger-0 .text-error")
      refute has_element?(view, "#trigger-1")
      assert Repo.get!(Clock, c.clock.id) == original
      assert length(Clocks.list_audits(c.campaign.id)) == audits
    end
  end

  test "ordered edits preserve mixed trigger payloads and exact stored strings", c do
    flag = %{"type" => "string", "value" => "first\r\nsecond", "player_visible" => false}

    {:ok, _} =
      Clocks.edit_clock(
        c.campaign.id,
        c.clock.id,
        %{
          triggers: [
            %{type: :notify_dm, text: "Private text"},
            %{type: :set_flag, character_id: c.a.id, key: "memory", flag: flag},
            %{type: :unlock_quest, character_id: c.b.id, quest_id: c.revision.quest_id},
            %{type: :world_news, text: "Public text"}
          ]
        },
        "dm:test"
      )

    {:ok, view, _} = live(c.conn, ~p"/clocks")
    view |> element("#edit-clock-#{c.clock.id}") |> render_click()
    view |> element("#move-trigger-2-up") |> render_click()
    view |> form("#clock-form") |> render_submit()
    stored = Repo.get!(Clock, c.clock.id).triggers
    assert Enum.map(stored, & &1.type) == [:notify_dm, :unlock_quest, :set_flag, :world_news]
    assert Enum.at(stored, 2).flag == flag
    assert hd(stored).text == "Private text"
    assert List.last(stored).text == "Public text"
    view |> element("#edit-clock-#{c.clock.id}") |> render_click()
    view |> element("#remove-trigger-1") |> render_click()
    view |> form("#clock-form") |> render_submit()

    assert Enum.map(Repo.get!(Clock, c.clock.id).triggers, & &1.type) == [
             :notify_dm,
             :set_flag,
             :world_news
           ]
  end

  test "stale saves, frozen management and revoked authorization cannot persist targeted triggers",
       c do
    {:ok, view, _} = live(c.conn, ~p"/clocks")
    view |> element("#edit-clock-#{c.clock.id}") |> render_click()

    trigger = %{
      "type" => "unlock_quest",
      "character_id" => to_string(c.a.id),
      "quest_id" => to_string(c.revision.quest_id)
    }

    params = %{"clock" => %{"triggers" => %{"0" => trigger}}}
    {:ok, _} = Clocks.edit_clock(c.campaign.id, c.clock.id, %{name: "Other tab"}, "dm:other")
    render_submit(view, "save", params)
    assert has_element?(view, "#flash-error", "changed in another window")
    assert Repo.get!(Clock, c.clock.id).triggers == []
    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, _} = Ticks.close_tick(c.campaign.id, tick.id)
    render_submit(view, "save", params)
    assert has_element?(view, "#clock-form fieldset[disabled]")
    assert Repo.get!(Clock, c.clock.id).triggers == []
    :ok = WebAuth.revoke_session(get_session(get(c.conn, ~p"/dashboard"), :web_session_token))
    assert_redirect(view, ~p"/login")
  end

  test "UI-authored triggers use frozen racing resolution and apply once only on publication",
       c do
    {:ok, active} = Quests.assign(c.campaign, "22002", c.a.id, c.revision.id)

    {:ok, _} =
      Clocks.edit_clock(c.campaign.id, c.clock.id, %{filled: 3, background_rate: 1}, "dm:test")

    {:ok, loser} =
      Clocks.create_clock(
        c.campaign.id,
        %{
          name: "Racing loser",
          segments: 4,
          filled: 3,
          background_rate: 1,
          triggers: [%{type: :set_flag, character_id: c.b.id, key: "loser", flag: flag()}]
        },
        "dm:test"
      )

    {:ok, _} = Clocks.pair_clocks(c.campaign.id, c.clock.id, loser.id, "dm:test")
    {:ok, view, _} = live(c.conn, ~p"/clocks")
    view |> element("#edit-clock-#{c.clock.id}") |> render_click()
    view |> element("#add-trigger") |> render_click()
    change_type(view, "set_flag")

    view
    |> form("#clock-form",
      clock: %{
        triggers: %{
          "0" => %{
            character_id: to_string(c.a.id),
            key: "memory",
            flag: %{type: "boolean", value: "true", player_visible: "false"}
          }
        }
      }
    )
    |> render_change()

    view |> element("#add-trigger") |> render_click()

    view
    |> form("#clock-form", clock: %{triggers: %{"1" => %{type: "unlock_quest"}}})
    |> render_change(%{"_target" => ["clock", "triggers", "1", "type"]})

    view
    |> form("#clock-form",
      clock: %{
        triggers: %{
          "1" => %{character_id: to_string(c.a.id), quest_id: to_string(c.revision.quest_id)}
        }
      }
    )
    |> render_submit()

    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)
    frozen = Enum.find(snapshot.data["clocks"], &(&1["id"] == c.clock.id))
    assert Enum.map(frozen["triggers"], & &1["type"]) == ["set_flag", "unlock_quest"]
    {:ok, payload} = AsyncWorlds.Ticks.WorldResolver.resolve(snapshot)

    assert Enum.find(payload["characters"], &(&1["id"] == c.a.id))["flags"]["memory"]["value"] ==
             true

    assert Enum.find(payload["characters"], &(&1["id"] == c.b.id))["flags"] == %{}
    {:ok, %{draft: draft}} = Ticks.put_draft(c.campaign.id, tick.id, snapshot.revision, payload)
    assert Repo.get!(AsyncWorlds.Characters.Character, c.a.id).flags == %{}
    assert Repo.aggregate(AsyncWorlds.Quests.Unlock, :count) == 0
    assert Repo.get!(AsyncWorlds.Quests.Progression, active.id) == active

    render_submit(view, "save", %{
      "clock" => %{"name" => "Forbidden", "segments" => "4", "triggers" => []}
    })

    assert has_element?(view, "#clock-lock-notice")

    {:ok, _} = Ticks.publish_tick(c.campaign.id, tick.id, draft.id)

    assert Repo.get!(AsyncWorlds.Characters.Character, c.a.id).flags["memory"] == %{
             "type" => "boolean",
             "value" => true,
             "player_visible" => false
           }

    assert Repo.get!(AsyncWorlds.Characters.Character, c.b.id).flags == %{}
    assert Repo.get!(AsyncWorlds.Quests.Progression, active.id) == active
    assert Repo.aggregate(AsyncWorlds.Quests.Unlock, :count) == 1
    assert {:error, _} = Ticks.publish_tick(c.campaign.id, tick.id, draft.id)
    assert Repo.aggregate(AsyncWorlds.Quests.Unlock, :count) == 1
  end

  defp change_type(view, type) do
    view
    |> form("#clock-form", clock: %{triggers: %{"0" => %{type: type}}})
    |> render_change(%{"_target" => ["clock", "triggers", "0", "type"]})
  end
end
