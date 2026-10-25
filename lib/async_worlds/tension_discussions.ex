defmodule AsyncWorlds.TensionDiscussions do
  @moduledoc "Transactional public discussion intents. Transport creation is separately claimed and conservatively recovered."
  import Ecto.Query
  import Ecto.Changeset
  alias AsyncWorlds.{DMAccess, Deliveries, Repo, Tensions}
  alias AsyncWorlds.Tensions.{Discussion, DiscussionIntent}
  alias AsyncWorlds.Workers.OpenTensionDiscussion

  # Called only while the opening/publication transaction holds the campaign lock.
  def opened(campaign, tick) do
    for t <- Tensions.list_tensions(campaign.id), t.audience == :public do
      clocks = Tensions.list_clocks(campaign.id, t.id) |> elem(1)
      lines = ["## Tick #{tick.number} · #{t.name}", t.description || ""]

      lines =
        if t.status == :resolved do
          lines ++ ["**Historical — resolved.** This is not an ongoing call for participation."]
        else
          lines ++
            Enum.flat_map(clocks, &clock_lines/1) ++
            [
              "### Take part\n" <>
                "- Discuss plans, questions and coordination here for this period.\n" <>
                "- Discussion is **not a confirmed commitment or an established outcome**; the DM adjudicates after closing.\n" <>
                "- Use `/intent view tick:#{tick.id}` privately to view your efforts.\n" <>
                "- Record an effort with `/intent edit tick:#{tick.id} tension:#{t.id} version:0 intention:<broad effort>`, then `/intent confirm` with the saved version.\n" <>
                "- **Revise or withdraw until close.** Intentions are private to owner and authorized DM; readiness is informational.\n" <>
                "- Public discussion posts cannot be promised retractable."
            ]
        end

      intent!(
        campaign,
        tick,
        t,
        "opening",
        lines |> Enum.reject(&(&1 == "")) |> Enum.join("\n\n"),
        "Tick #{tick.number} · #{t.name}#{if t.status == :resolved, do: " · historical (resolved)", else: " · ongoing"}"
      )
    end
  end

  def published(campaign, tick, payload) do
    ids = payload["published_entity_ids"] || %{}

    for event <- payload["events"] || [], event["audience"] == "public" do
      relevant =
        event["changes"]
        |> Enum.flat_map(fn c ->
          if c["entity"] == "tension",
            do: [c["id"]],
            else: Enum.map([c["before"], c["after"]], &(&1 && &1["tension_id"]))
        end)
        |> Kernel.++(for r <- event["references"] || [], r["entity"] == "tension", do: r["id"])
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&Map.get(ids, &1, &1))
        |> Enum.uniq()

      for id <- relevant do
        {:ok, t} = Tensions.get_tension(campaign.id, id)

        if t.audience == :public do
          text =
            "## Published tick #{tick.number} · #{event["title"]}\n\n#{event["text"]}" <>
              if(t.status == :resolved,
                do: "\n\n**Historical — resolved.** No ongoing participation requested.",
                else: ""
              )

          intent!(campaign, tick, t, "event:#{event["id"]}", text, nil)
        end
      end
    end

    # Public Tension status is explicitly public even when the Resolution's prose
    # is DM-only. Project only that structured fact, never redact private prose.
    for event <- payload["events"] || [],
        event["audience"] == "dm",
        event["kind"] == "resolution",
        change <- event["changes"],
        change["entity"] == "tension",
        change["after"]["status"] == "resolved",
        change["after"]["audience"] == "public" do
      {:ok, t} = Tensions.get_tension(campaign.id, Map.get(ids, change["id"], change["id"]))

      if t.audience == :public do
        intent!(
          campaign,
          tick,
          t,
          "resolved-status:#{t.id}",
          "## Published tick #{tick.number} · #{t.name}\n\n**Historical — resolved.** No ongoing participation requested.",
          nil
        )
      end
    end
  end

  defp clock_lines(%{visibility: :hidden}), do: []
  defp clock_lines(%{visibility: :known} = c), do: ["### #{c.name}"]

  defp clock_lines(c),
    do: [
      "### #{c.name}: #{AsyncWorlds.Discord.ClockProgress.render(c.filled, c.segments)}",
      c.influences || "",
      c.empty_description || "",
      c.full_description || ""
    ]

  defp intent!(campaign, tick, tension, key, content, overview) do
    d =
      Repo.get_by(Discussion, tension_id: tension.id) ||
        Repo.insert!(%Discussion{
          campaign_id: campaign.id,
          tension_id: tension.id,
          parent_id: campaign.public_channel_id,
          guild_id: campaign.discord_guild_id,
          name: tension.name
        })

    if d.parent_id != campaign.public_channel_id or d.guild_id != campaign.discord_guild_id,
      do: Repo.rollback(:discussion_route_changed)

    Repo.insert!(%DiscussionIntent{
      discussion_id: d.id,
      tick_id: tick.id,
      key: "#{tick.id}:#{key}",
      content: content,
      overview: overview
    })

    job!(d)
  end

  defp job!(d) do
    %{discussion_id: d.id} |> OpenTensionDiscussion.new() |> Oban.insert!()
  end

  def claim(id) do
    Repo.transaction(fn ->
      d = lock!(id)

      case d.status do
        "ready" ->
          {:ready, d}

        "pending" ->
          {:create, Repo.update!(change(d, status: "creating"))}

        "creating" ->
          Repo.update!(change(d, status: "ambiguous"))
          :skip

        _ ->
          :skip
      end
    end)
  end

  def settle(%Discussion{} = claim, result) do
    Repo.transaction(fn ->
      d = lock!(claim.id)

      if d.generation != claim.generation or d.status not in ["creating", "ambiguous"],
        do: Repo.rollback(:stale_attempt)

      case result do
        {:ok, thread_id} -> Repo.update!(change(d, status: "ready", thread_id: thread_id))
        {:error, :retryable} -> Repo.update!(change(d, status: "pending"))
        {:error, :permanent} -> Repo.update!(change(d, status: "blocked"))
        _ -> Repo.update!(change(d, status: "ambiguous"))
      end
    end)
  end

  # Enqueue exact saved text, never re-read mutable world state at send time.
  def dispatch(id) do
    Repo.transaction(fn ->
      d = lock!(id)
      if d.status != "ready", do: Repo.rollback(:not_ready)

      for i <- Repo.all(from i in DiscussionIntent, where: i.discussion_id == ^id, order_by: i.id) do
        enqueue_chunks!(d, i, "thread", d.thread_id, i.content)

        if i.overview do
          url = "https://discord.com/channels/#{d.guild_id}/#{d.thread_id}"
          enqueue_chunks!(d, i, "overview", d.parent_id, "#{i.overview}\n#{url}")
        end
      end

      :ok
    end)
  end

  defp enqueue_chunks!(d, i, kind, recipient, content) do
    for {chunk, index} <- Enum.with_index(AsyncWorlds.Discord.Content.chunks(content)) do
      case Deliveries.enqueue(d.campaign_id, i.tick_id, %{
             key: "discussion:#{d.id}:#{i.key}:#{kind}:#{index}",
             kind: :public,
             recipient_id: recipient,
             content: chunk
           }) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  @doc false
  def send_public(delivery, payload, adapter) do
    if String.starts_with?(delivery.key, "discussion:") do
      case Repo.get_by(Discussion,
             campaign_id: delivery.campaign_id,
             thread_id: delivery.recipient_id
           ) do
        nil ->
          adapter.send_public(delivery.recipient_id, payload)

        d ->
          case adapter.inspect_thread(d.thread_id) do
            {:ok, %{guild_id: guild, parent_id: parent, type: 11, archived: false}}
            when guild == d.guild_id and parent == d.parent_id ->
              adapter.send_public(d.thread_id, payload)

            {:ok, %{archived: true}} ->
              {:error, {:permanent, :thread_archived}}

            {:error, _} = error ->
              error

            _ ->
              {:error, {:permanent, :invalid_request}}
          end
      end
    else
      adapter.send_public(delivery.recipient_id, payload)
    end
  end

  def get(scope, tension_id) do
    DMAccess.run(scope, fn c, _ ->
      case Repo.get_by(Discussion, campaign_id: c.id, tension_id: tension_id) do
        nil -> {:error, :not_found}
        d -> {:ok, d}
      end
    end)
  end

  @doc "Explicit recovery of unbound creation only. Bind a verified existing thread, or confirm a potentially duplicate new create. Never replaces a bound thread."
  def recover(scope, tension_id, expected, action, adapter) do
    with {:ok, ^expected} <- get(scope, tension_id),
         {:ok, thread_id} <- recovery_target(expected, action, adapter) do
      DMAccess.run(scope, fn c, actor ->
        d = lock!(expected.id)

        if d.campaign_id != c.id or d != expected or d.thread_id != nil or
             d.status not in ["ambiguous", "blocked"],
           do: Repo.rollback(:stale_recovery)

        changeset =
          change(d,
            thread_id: thread_id,
            generation: d.generation + 1,
            status: if(thread_id, do: "ready", else: "pending"),
            recovery: %{
              "entries" =>
                Map.get(d.recovery, "entries", []) ++
                  [
                    %{
                      "actor" => actor,
                      "action" => inspect(action),
                      "at" => DateTime.to_iso8601(DateTime.utc_now())
                    }
                  ]
            }
          )
          |> unique_constraint(:thread_id)

        updated =
          case Repo.update(changeset) do
            {:ok, updated} -> updated
            {:error, _} -> Repo.rollback(:thread_already_bound)
          end

        job!(updated)
        {:ok, updated}
      end)
    else
      {:ok, _} -> {:error, :stale_recovery}
      error -> error
    end
  end

  defp recovery_target(_, :confirm_duplicate_create, _), do: {:ok, nil}

  defp recovery_target(d, {:bind, id}, adapter) do
    with {:ok, id} <- AsyncWorlds.Discord.Snowflake.cast(id),
         {:ok, %{guild_id: guild, parent_id: parent, type: 11}} <- adapter.inspect_thread(id),
         true <- guild == d.guild_id and parent == d.parent_id do
      {:ok, id}
    else
      _ -> {:error, :invalid_thread}
    end
  end

  defp recovery_target(_, _, _), do: {:error, :confirmation_required}

  defp lock!(id) do
    # Match domain lock order before touching outbox rows.
    d = Repo.get!(Discussion, id)

    Repo.one!(
      from c in AsyncWorlds.Campaigns.Campaign, where: c.id == ^d.campaign_id, lock: "FOR UPDATE"
    )

    Repo.one!(from d in Discussion, where: d.id == ^id, lock: "FOR UPDATE")
  end
end
