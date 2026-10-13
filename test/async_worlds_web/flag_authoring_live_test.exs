defmodule AsyncWorldsWeb.FlagAuthoringLiveTest do
  use AsyncWorldsWeb.ConnCase
  use Oban.Testing, repo: AsyncWorlds.Repo
  import Phoenix.LiveViewTest
  import Ecto.Query
  alias AsyncWorlds.{Campaigns, Characters, Quests, Repo, Ticks, WebAuth}
  alias AsyncWorlds.Discord.{Dispatcher, FakeAdapter}

  setup %{conn: conn} do
    {:ok, campaign} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, work} = Quests.create_working_copy(campaign, "456")
    conn = log_in_dm(conn, campaign)
    {:ok, view, _} = live(conn, ~p"/quests/library?draft_id=#{work.id}")
    view |> element("#add-choice-0") |> render_click()

    fill(view, %{
      name: "Flag rehearsal",
      content_id: "flags",
      node_0_text: "A door",
      node_0_choice_0_label: "Enter",
      node_0_choice_0_text: "Entered"
    })

    %{conn: conn, campaign: campaign, work: work, view: view}
  end

  defp fill(view, params),
    do: view |> form("#quest-editor-form", quest: params) |> render_change()

  defp save(view), do: view |> form("#quest-editor-form") |> render_submit()

  defp release(view),
    do: view |> form("#quest-editor-form") |> render_submit(%{"operation" => "release"})

  test "string condition and effect forms preserve imported CRLF bytes and reject unsafe draft text",
       c do
    save(c.view)
    {:ok, work} = Quests.get_working_copy(c.campaign, "456", c.work.id)
    text = "plain \"quoted\"\r\nnext\rline"

    condition = %{
      "type" => "character_flag",
      "key" => "phrase",
      "flag_type" => "string",
      "value" => text
    }

    effect = %{
      "type" => "set_flag",
      "key" => "phrase",
      "flag" => %{"type" => "string", "value" => text, "player_visible" => false}
    }

    d =
      work.definition
      |> put_in(["nodes", Access.at(0), "choices", Access.at(0), "conditions"], [condition])
      |> put_in(
        ["nodes", Access.at(0), "choices", Access.at(0), "outcomes", "fixed", "effects"],
        [effect]
      )

    {:ok, imported} =
      Quests.save_working_copy(c.campaign, "456", work.id, work.version, %{
        name: work.name,
        content_id: work.content_id,
        definition: d
      })

    {:ok, view, _} = live(c.conn, ~p"/quests/library?draft_id=#{work.id}")
    assert has_element?(view, "textarea#choice-0-0-condition-0-value")
    assert has_element?(view, "textarea#choice-0-0-effect-0-value")
    normalized = "plain \"quoted\"\nnext\nline"

    fill(view, %{
      name: "Other edit",
      node_0_choice_0_condition_0_value: normalized,
      node_0_choice_0_effect_0_value: normalized
    })

    save(view)
    {:ok, preserved} = Quests.get_working_copy(c.campaign, "456", work.id)
    assert preserved.definition == imported.definition
    # Bypass HTML parsing, which normalizes NUL. Invalid UTF-8 is rejected by
    # Plug before a form event; lower-level authoring/domain tests cover it.
    render_submit(view, "save", %{"quest" => %{"node_0_choice_0_condition_0_value" => <<0>>}})
    assert has_element?(view, "#draft-errors a[href='#choice-0-0-condition-0-value']")
    assert Repo.get!(Quests.WorkingCopy, preserved.id) == preserved
  end

  test "ordinary typed AND conditions and ordered fixed effects survive reopen and publish only approved acting-character state",
       c do
    v = c.view
    for _ <- 1..2, do: v |> element("#condition-0-0-add") |> render_click()

    fill(v, %{
      node_0_choice_0_condition_0_key: "ready",
      node_0_choice_0_condition_0_value: "false",
      node_0_choice_0_condition_1_key: "phrase",
      node_0_choice_0_condition_1_flag_type: "string"
    })

    fill(v, %{node_0_choice_0_condition_1_value: "unquoted phrase"})

    for type <- ~w(set_flag clear_flag set_flag),
        do: v |> element("#choice-0-0-effect-add-#{type}") |> render_click()

    fill(v, %{
      node_0_choice_0_effect_0_key: "secret",
      node_0_choice_0_effect_0_value: "true",
      node_0_choice_0_effect_1_key: "secret",
      node_0_choice_0_effect_2_key: "secret",
      node_0_choice_0_effect_2_flag_type: "integer",
      node_0_choice_0_effect_2_visible: "false"
    })

    fill(v, %{node_0_choice_0_effect_2_value: "7"})
    v |> element("#choice-0-0-effect-2-up") |> render_click()
    v |> element("#choice-0-0-effect-1-down") |> render_click()
    v |> element("#condition-0-0-1-up") |> render_click()
    v |> element("#condition-0-0-0-down") |> render_click()
    save(v)
    {:ok, saved} = Quests.get_working_copy(c.campaign, "456", c.work.id)
    node = hd(saved.definition["nodes"])
    fill(v, %{node_0_choice_0_destination: node["id"]})
    release(v)
    assert has_element?(v, "#flash-info", "Released revision 1")
    {:ok, %{revisions: [r]}} = Quests.library(c.campaign, "456")
    {:ok, revision} = Quests.get_revision(c.campaign, "456", r.id)
    {:ok, reopened, _} = live(c.conn, ~p"/quests/library?draft_id=#{c.work.id}")
    assert has_element?(reopened, "textarea#choice-0-0-condition-1-value", "unquoted phrase")
    assert has_element?(reopened, "input[type=number]#choice-0-0-effect-2-value[value='7']")

    flags = %{
      "ready" => %{"type" => "boolean", "value" => false, "player_visible" => false},
      "phrase" => %{"type" => "string", "value" => "unquoted phrase", "player_visible" => false}
    }

    characters =
      for user <- ~w(991 992) do
        {:ok, character} =
          Characters.create_character(c.campaign, "456", %{
            name: user,
            discord_user_id: user,
            flags: flags
          })

        {:ok, _} = Quests.assign(c.campaign, "456", character.id, revision.id)
        character
      end

    [acting, other] = characters
    start_supervised!({FakeAdapter, owner: self()})
    opts = [adapter: FakeAdapter, guild_id: "123", application_id: "111"]

    interaction = %{
      type: 2,
      id: 901,
      application_id: 111,
      guild_id: 123,
      member: %{user_id: 991},
      token: "offline-only",
      data: %{name: "quest"}
    }

    {:ok, tick} = Ticks.open_tick(c.campaign.id)
    {:ok, payload} = Dispatcher.handle(interaction, opts)
    refute payload.content =~ "unquoted phrase"
    refute payload.content =~ "ready"

    button =
      payload.components |> Enum.flat_map(& &1.components) |> Enum.find(&(&1.label =~ "Enter"))

    assert button && !button.disabled

    assert {:ok, _} =
             Dispatcher.handle(
               %{
                 interaction
                 | type: 3,
                   id: 902,
                   data: %{custom_id: button.custom_id, component_type: 2}
               },
               opts
             )

    {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)
    # Released edits cannot alter pinned/frozen inputs.
    fill(reopened, %{node_0_choice_0_effect_2_value: "9"})
    release(reopened)
    assert has_element?(reopened, "#flash-info", "Released revision 2")
    assert Repo.get!(Ticks.Snapshot, snapshot.id) == snapshot
    assert {:ok, ^revision} = Quests.get_revision(c.campaign, "456", revision.id)

    assert :ok =
             perform_job(AsyncWorlds.Workers.ResolveTick, %{
               campaign_id: c.campaign.id,
               tick_id: tick.id,
               input_revision: snapshot.revision
             })

    assert Repo.get!(Characters.Character, acting.id).flags == flags

    assert {:ok, "No published personal result yet."} =
             Dispatcher.handle(%{interaction | id: 905, data: %{name: "result"}}, opts)

    {:ok, review, _} = live(c.conn, ~p"/ticks/#{tick.id}/review")
    refute has_element?(review, "#public-preview", "secret")
    refute has_element?(review, "#private-preview", "secret")
    review |> form("#publish-form", publish: %{confirm: "true"}) |> render_submit()
    assert_redirect(review, ~p"/dashboard")

    assert Repo.get!(Characters.Character, acting.id).flags["secret"] == %{
             "type" => "integer",
             "value" => 7,
             "player_visible" => false
           }

    assert Repo.get!(Characters.Character, other.id).flags == flags

    {:ok, character_payload} =
      Dispatcher.handle(%{interaction | id: 903, data: %{name: "character"}}, opts)

    refute character_payload =~ "secret"
    refute character_payload =~ "phrase"

    for {command, id} <- [{"quest", 906}, {"result", 907}, {"submission", 908}] do
      {:ok, response} = Dispatcher.handle(%{interaction | id: id, data: %{name: command}}, opts)
      text = if is_map(response), do: response.content, else: response
      refute text =~ "secret"
      refute text =~ "unquoted phrase"
      refute text =~ "ready"
    end

    assert {:error, :stale_component} =
             Dispatcher.handle(
               %{
                 interaction
                 | type: 3,
                   id: 904,
                   data: %{custom_id: button.custom_id, component_type: 2}
               },
               opts
             )
  end

  test "authored unmet hidden and disabled choices stay safe in real offline Discord commands",
       c do
    v = c.view
    v |> element("#add-choice-0") |> render_click()

    for j <- 0..1 do
      v |> element("#condition-0-#{j}-add") |> render_click()

      fill(v, %{
        "node_0_choice_#{j}_condition_0_key" => "secret_gate",
        "node_0_choice_#{j}_condition_0_value" => "false"
      })
    end

    fill(v, %{
      node_0_choice_0_label: "Hidden spoiler",
      node_0_choice_0_eligibility: "hidden",
      node_0_choice_1_label: "Visible unavailable",
      node_0_choice_1_text: "Done"
    })

    save(v)
    {:ok, work} = Quests.get_working_copy(c.campaign, "456", c.work.id)
    id = hd(work.definition["nodes"])["id"]
    fill(v, %{node_0_choice_0_destination: id, node_0_choice_1_destination: id})
    release(v)
    assert has_element?(v, "#flash-info", "Released revision 1")
    {:ok, %{revisions: [r]}} = Quests.library(c.campaign, "456")

    {:ok, character} =
      Characters.create_character(c.campaign, "456", %{name: "Player", discord_user_id: "991"})

    {:ok, _} = Quests.assign(c.campaign, "456", character.id, r.id)
    {:ok, _} = Ticks.open_tick(c.campaign.id)
    start_supervised!({FakeAdapter, owner: self()})
    opts = [adapter: FakeAdapter, guild_id: "123", application_id: "111"]

    interaction = %{
      type: 2,
      id: 920,
      application_id: 111,
      guild_id: 123,
      member: %{user_id: 991},
      token: "offline-only",
      data: %{name: "quest"}
    }

    {:ok, payload} = Dispatcher.handle(interaction, opts)
    refute payload.content =~ "Hidden spoiler"
    refute payload.content =~ "secret_gate"
    assert payload.content =~ "Visible unavailable — Not available right now."
    buttons = Enum.flat_map(payload.components, & &1.components)
    refute Enum.any?(buttons, &(&1.label =~ "Hidden spoiler"))
    disabled = Enum.find(buttons, &(&1.label =~ "Visible unavailable"))
    assert disabled.disabled

    assert {:error, :stale_component} =
             Dispatcher.handle(
               %{
                 interaction
                 | type: 3,
                   id: 921,
                   data: %{custom_id: disabled.custom_id, component_type: 2}
               },
               opts
             )
  end

  test "stale flag drafts retain conditions and ordered effects for explicit recovery", c do
    save(c.view)
    {:ok, stale, _} = live(c.conn, ~p"/quests/library?draft_id=#{c.work.id}")
    stale |> element("#condition-0-0-add") |> render_click()
    stale |> element("#choice-0-0-effect-add-clear_flag") |> render_click()

    fill(stale, %{
      node_0_choice_0_condition_0_key: "ready",
      node_0_choice_0_condition_0_value: "false",
      node_0_choice_0_effect_0_key: "secret"
    })

    fill(c.view, %{name: "Other tab"})
    save(c.view)
    save(stale)
    assert has_element?(stale, "#draft-conflict")
    assert has_element?(stale, "#choice-0-0-condition-0-key[value='ready']")
    assert has_element?(stale, "#choice-0-0-effect-0-key[value='secret']")
    {:ok, original} = Quests.get_working_copy(c.campaign, "456", c.work.id)
    assert hd(hd(original.definition["nodes"])["choices"])["conditions"] == []
    stale |> element("#reload-draft") |> render_click()
    stale |> element("#recover-draft") |> render_click()
    assert has_element?(stale, "#choice-0-0-condition-0-key[value='ready']")
    assert has_element?(stale, "#choice-0-0-effect-0-key[value='secret']")
    assert Repo.get!(Quests.WorkingCopy, original.id) == original
  end

  test "published authored set enables the later gate and published clear disables it with visible whitelist",
       c do
    v = c.view
    for _ <- 1..2, do: v |> element("#add-choice-0") |> render_click()

    fill(v, %{
      node_0_choice_0_label: "Acquire debt",
      node_0_choice_1_label: "Repay debt",
      node_0_choice_1_text: "Repaid",
      node_0_choice_2_label: "Guild entrance",
      node_0_choice_2_text: "Entered",
      node_0_choice_2_eligibility: "disabled"
    })

    for _ <- 1..2, do: v |> element("#choice-0-0-effect-add-set_flag") |> render_click()

    fill(v, %{
      node_0_choice_0_effect_0_key: "owes_the_guild",
      node_0_choice_0_effect_0_value: "true",
      node_0_choice_0_effect_0_visible: "false",
      node_0_choice_0_effect_1_key: "rank",
      node_0_choice_0_effect_1_flag_type: "integer",
      node_0_choice_0_effect_1_visible: "true"
    })

    fill(v, %{node_0_choice_0_effect_1_value: "7"})
    v |> element("#choice-0-1-effect-add-clear_flag") |> render_click()
    fill(v, %{node_0_choice_1_effect_0_key: "owes_the_guild"})
    for _ <- 1..2, do: v |> element("#condition-0-2-add") |> render_click()

    fill(v, %{
      node_0_choice_2_condition_0_key: "owes_the_guild",
      node_0_choice_2_condition_0_value: "true",
      node_0_choice_2_condition_1_key: "rank",
      node_0_choice_2_condition_1_flag_type: "integer"
    })

    fill(v, %{node_0_choice_2_condition_1_value: "7"})
    save(v)
    {:ok, work} = Quests.get_working_copy(c.campaign, "456", c.work.id)
    id = hd(work.definition["nodes"])["id"]

    fill(v, %{
      node_0_choice_0_destination: id,
      node_0_choice_1_destination: id,
      node_0_choice_2_destination: id
    })

    release(v)
    assert has_element?(v, "#flash-info", "Released revision 1")
    {:ok, reopened, _} = live(c.conn, ~p"/quests/library?draft_id=#{c.work.id}")
    assert has_element?(reopened, "input[type=number]#choice-0-2-condition-1-value[value='7']")
    {:ok, %{revisions: [r]}} = Quests.library(c.campaign, "456")

    {:ok, character} =
      Characters.create_character(c.campaign, "456", %{name: "Player", discord_user_id: "991"})

    {:ok, _} = Quests.assign(c.campaign, "456", character.id, r.id)
    start_supervised!({FakeAdapter, owner: self()})
    opts = [adapter: FakeAdapter, guild_id: "123", application_id: "111"]

    interaction = %{
      type: 2,
      id: 950,
      application_id: 111,
      guild_id: 123,
      member: %{user_id: 991},
      token: "offline-only",
      data: %{name: "quest"}
    }

    for {label, expected_enabled, n} <- [{"Acquire debt", false, 0}, {"Repay debt", true, 1}] do
      {:ok, tick} = Ticks.open_tick(c.campaign.id)
      {:ok, payload} = Dispatcher.handle(%{interaction | id: 950 + n * 10}, opts)
      buttons = Enum.flat_map(payload.components, & &1.components)
      gate = Enum.find(buttons, &(&1.label =~ "Guild entrance"))
      assert gate.disabled == !expected_enabled
      refute payload.content =~ "owes_the_guild"
      button = Enum.find(buttons, &(&1.label =~ label))

      assert {:ok, _} =
               Dispatcher.handle(
                 %{
                   interaction
                   | type: 3,
                     id: 951 + n * 10,
                     data: %{custom_id: button.custom_id, component_type: 2}
                 },
                 opts
               )

      {:ok, %{snapshot: snapshot}} = Ticks.close_tick(c.campaign.id, tick.id)

      assert :ok =
               perform_job(AsyncWorlds.Workers.ResolveTick, %{
                 campaign_id: c.campaign.id,
                 tick_id: tick.id,
                 input_revision: snapshot.revision
               })

      {:ok, review, _} = live(c.conn, ~p"/ticks/#{tick.id}/review")
      review |> form("#publish-form", publish: %{confirm: "true"}) |> render_submit()
      assert_redirect(review, ~p"/dashboard")

      {:ok, personal} =
        Dispatcher.handle(%{interaction | id: 952 + n * 10, data: %{name: "character"}}, opts)

      assert personal =~ "rank"
      assert personal =~ "7"
      refute personal =~ "owes_the_guild"
    end

    {:ok, _} = Ticks.open_tick(c.campaign.id)
    {:ok, final} = Dispatcher.handle(%{interaction | id: 980}, opts)

    final_gate =
      final.components
      |> Enum.flat_map(& &1.components)
      |> Enum.find(&(&1.label =~ "Guild entrance"))

    assert final_gate.disabled
    refute Map.has_key?(Repo.get!(Characters.Character, character.id).flags, "owes_the_guild")
  end

  test "expired and revoked DM controls cannot change or save flags", c do
    for mode <- [:expired, :revoked] do
      conn = log_in_dm(c.conn, c.campaign)
      {:ok, view, _} = live(conn, ~p"/quests/library?draft_id=#{c.work.id}")
      token = get_session(get(conn, ~p"/dashboard"), :web_session_token)
      {:ok, scope} = WebAuth.authorize_session(token)
      {:ok, before} = Quests.get_working_copy(c.campaign, "456", c.work.id)

      case mode do
        :expired ->
          Repo.update_all(from(s in WebAuth.Session, where: s.id == ^scope.session_id),
            set: [expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
          )

          render_click(view, "choice-list", %{
            "node" => hd(before.definition["nodes"])["id"],
            "choice" => "forged",
            "list" => "conditions",
            "action" => "add"
          })

        :revoked ->
          WebAuth.revoke_session(token)
      end

      assert_redirect(view, "/login")
      assert Repo.get!(Quests.WorkingCopy, before.id) == before
    end
  end

  test "rolled success partial failure effects and critical bonuses use the same ordinary typed controls",
       c do
    v = c.view
    v |> element("#choice-0-0-convert") |> render_click()
    v |> element("#confirm-choice-conversion") |> render_click()

    for kind <- ~w(success partial failure) do
      v |> element("#choice-0-0_#{kind}-effect-add-set_flag") |> render_click()

      fill(v, %{
        "node_0_choice_0_#{kind}_effect_0_key" => kind,
        "node_0_choice_0_#{kind}_effect_0_flag_type" => "string",
        "node_0_choice_0_#{kind}_effect_0_visible" => "true"
      })

      fill(v, %{"node_0_choice_0_#{kind}_effect_0_value" => "plain #{kind}"})
      assert has_element?(v, "textarea#choice-0-0_#{kind}-effect-0-value", "plain #{kind}")
    end

    v |> element("#critical-0-0-add-clear_flag") |> render_click()
    fill(v, %{node_0_choice_0_critical_0_key: "success"})
    save(v)
    {:ok, saved} = Quests.get_working_copy(c.campaign, "456", c.work.id)
    authored = hd(hd(saved.definition["nodes"])["choices"])

    for kind <- ~w(success partial failure),
        do:
          assert(
            hd(authored["outcomes"][kind]["effects"])["flag"] == %{
              "type" => "string",
              "value" => "plain #{kind}",
              "player_visible" => true
            }
          )

    assert authored["critical_effects"] == [%{"type" => "clear_flag", "key" => "success"}]
    {:ok, reopened, _} = live(c.conn, ~p"/quests/library?draft_id=#{c.work.id}")

    assert has_element?(
             reopened,
             "#choice-0-0_failure-effect-0-visible option[value='true'][selected]"
           )
  end

  test "field errors retain invalid draft values; add remove and forged list controls are bounded",
       c do
    v = c.view
    v |> element("#condition-0-0-add") |> render_click()

    fill(v, %{
      node_0_choice_0_condition_0_key: "ready",
      node_0_choice_0_condition_0_flag_type: "integer"
    })

    render_change(v, "change", %{
      "quest" => %{"node_0_choice_0_condition_0_value" => "not an integer"}
    })

    release(v)
    assert has_element?(v, "#draft-errors a[href='#choice-0-0-condition-0-value']", "explicit")
    assert has_element?(v, "#choice-0-0-condition-0-value[value='not an integer']")
    save(v)
    assert has_element?(v, "#flash-info", "saved")
    {:ok, saved} = Quests.get_working_copy(c.campaign, "456", c.work.id)

    for node <- ["foreign", [], nil], choice <- ["foreign", [], nil] do
      render_click(v, "choice-list", %{
        "node" => node,
        "choice" => choice,
        "list" => "conditions",
        "action" => "remove",
        "index" => "0"
      })
    end

    save(v)
    {:ok, unchanged} = Quests.get_working_copy(c.campaign, "456", c.work.id)
    assert unchanged.definition == saved.definition
    v |> element("#condition-0-0-0-remove") |> render_click()
    refute has_element?(v, "#choice-0-0-condition-0")
    v |> element("#choice-0-0-effect-add-clear_flag") |> render_click()
    v |> element("#choice-0-0-effect-0-remove") |> render_click()
    refute has_element?(v, "#choice-0-0-effect-0")
  end
end
