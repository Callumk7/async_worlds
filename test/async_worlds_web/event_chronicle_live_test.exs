defmodule AsyncWorldsWeb.EventChronicleLiveTest do
  use AsyncWorldsWeb.ConnCase
  import Phoenix.LiveViewTest
  alias AsyncWorlds.{Campaigns, Repo, Tensions, Ticks}
  alias AsyncWorlds.Ticks.WorldResolver

  setup %{conn: conn} do
    {:ok, c} =
      Campaigns.setup_campaign(%{
        discord_guild_id: "123",
        dm_user_id: "456",
        public_channel_id: "789"
      })

    {:ok, tension} =
      Tensions.create_tension(c.id, %{name: "Battle in the Reach", audience: :public}, "456")

    location = Repo.insert!(%AsyncWorlds.Locations.Location{campaign_id: c.id, name: "Reach"})
    {:ok, tick} = Ticks.open_tick(c.id)
    {:ok, %{snapshot: s}} = Ticks.close_tick(c.id, tick.id)
    {:ok, p} = WorldResolver.resolve(s)
    {:ok, %{draft: d}} = Ticks.put_draft(c.id, tick.id, s.revision, p)
    %{conn: log_in_dm(conn, c), c: c, tick: tick, draft: d, tension: tension, location: location}
  end

  test "author connected Event, publish, explore canonical detail and origin", x do
    {:ok, empty, _} = live(x.conn, ~p"/events")
    assert has_element?(empty, "#chronicle-empty")
    {:ok, review, _} = live(x.conn, ~p"/ticks/#{x.tick.id}/review")

    review
    |> form("#manual-world-form",
      world: %{
        key: "crossing",
        title: "The Ash Company holds the crossing",
        text: "The captain is wounded.",
        kind: "event",
        audience: "public",
        action: "replace",
        reason: "Reviewed account",
        changes_json:
          Jason.encode!([
            %{entity: "tension", id: nil, attrs: %{name: "Wounded captain", audience: "public"}}
          ]),
        references_json:
          Jason.encode!([
            %{entity: "tension", id: x.tension.id},
            %{entity: "location", id: x.location.id}
          ]),
        follow_on_json: Jason.encode!(["new:crossing:0"])
      }
    )
    |> render_submit()

    assert has_element?(review, "#manual-world-preview", "Reach")
    {:ok, draft} = Ticks.fetch_draft(x.c.id, x.tick.id)
    {:ok, _} = Ticks.publish_tick(x.c.id, x.tick.id, draft.id)
    {:ok, listing, _} = live(x.conn, ~p"/events")
    assert has_element?(listing, "#read-event-#{x.tick.id}-crossing")

    {:ok, filtered, _} =
      live(x.conn, ~p"/events?#{%{"entity" => "location", "entity_id" => x.location.id}}")

    assert has_element?(filtered, "#read-event-#{x.tick.id}-crossing")
    {:ok, detail, _} = live(x.conn, ~p"/events/#{x.tick.id}?event=crossing")
    assert has_element?(detail, "#event-narrative", "The captain is wounded.")
    assert has_element?(detail, "#event-references a", "Reach")
    assert has_element?(detail, "#event-follow-on a", "Wounded captain")
    assert has_element?(detail, "#event-tick[href='/ticks/#{x.tick.id}/history']")
    target = detail |> element("#event-follow-on a") |> render_click()
    {_, origin, _} = follow_redirect(target, x.conn)
    assert has_element?(origin, "#read-event-#{x.tick.id}-crossing")
  end

  test "page controls retain filters and publication boundary; detail navigation is filtered",
       x do
    d =
      Enum.reduce(1..22, x.draft, fn n, d ->
        {:ok, %{draft: d}} =
          Ticks.edit_draft(
            x.c.id,
            x.tick.id,
            d.id,
            %{
              type: "world",
              key: "e#{String.pad_leading(to_string(n), 2, "0")}",
              event: %{
                title: "Account #{n}",
                text: "Narrative",
                audience: "public",
                kind: "event",
                changes: [],
                references: [%{entity: "location", id: x.location.id}]
              }
            },
            "456",
            "Reviewed"
          )

        d
      end)

    {:ok, _} = Ticks.publish_tick(x.c.id, x.tick.id, d.id)

    {:ok, view, _} =
      live(x.conn, ~p"/events?#{%{"entity" => "location", "entity_id" => x.location.id}}")

    assert has_element?(view, "#chronicle-next")
    view |> element("#chronicle-next") |> render_click()
    assert has_element?(view, "#read-event-#{x.tick.id}-e01")
    refute has_element?(view, "#chronicle-next")
    assert has_element?(view, "#chronicle-previous")

    {:ok, detail, _} =
      live(
        x.conn,
        ~p"/events/#{x.tick.id}?#{%{"event" => "e02", "entity" => "location", "entity_id" => x.location.id}}"
      )

    assert has_element?(detail, "#event-earlier", "Account 1")
    assert has_element?(detail, "#event-later", "Account 3")
  end
end
