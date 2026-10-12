defmodule AsyncWorlds.Discord.QuestInteractions do
  @moduledoc "Private quest presentation and bounded, freshly validated component identities."
  alias AsyncWorlds.Quests
  alias AsyncWorlds.Quests.Submissions

  def show(context, page \\ 0, expected_view \\ nil) do
    guild = context.campaign.discord_guild_id

    case Submissions.player_state(guild, access(context)) do
      {:ok, %{open: true} = state} ->
        if expected_view,
          do: {:error, :stale_component},
          else: {:ok, present(bind(state, context), page)}

      {:ok, state} ->
        selected = Enum.find(state.quest.choices, &(&1.id == state.choice_id))
        latest = if selected, do: truncate(selected.label, 120), else: "None"

        readonly(
          context,
          state,
          "Submissions closed; awaiting publication.\nLatest choice: #{latest}",
          page,
          expected_view
        )

      {:error, reason} when reason in [:no_tick, :no_quest] ->
        case Quests.player_quest(guild, access(context)) do
          {:ok, quest} ->
            suffix =
              if quest.completed,
                do: "Quest completed.",
                else: "No open tick. Choices cannot be submitted yet."

            readonly(context, %{quest: quest}, suffix, page, expected_view)

          {:error, :no_quest} ->
            if expected_view,
              do: {:error, :stale_component},
              else: {:ok, "No quest assigned yet. Try /quest again after your DM assigns one."}

          error ->
            error
        end

      error ->
        error
    end
  end

  def route(%{custom_id: id, component_type: 2}) when is_binary(id) and byte_size(id) <= 100 do
    case String.split(id, ":") do
      ["q1", _, _, _, _, _, action, arg] when action in ["s", "c", "p"] ->
        {:ok, {:quest_component, id, action, arg}, :player}

      ["q2", _, action, arg] when action in ["s", "c", "p"] ->
        {:ok, {:quest_component, id, action, arg}, :player}

      ["qv", view, "p", page] ->
        {:ok, {:quest_page, view, page}, :player}

      _ ->
        {:error, :unknown_command}
    end
  end

  def route(_), do: {:error, :unknown_command}

  def execute({:quest_page, view, arg}, context) do
    with {page, ""} when page >= 0 <- Integer.parse(arg),
         {:ok, _} = result <- show(context, page, view) do
      result
    else
      _ -> {:error, :stale_component}
    end
  end

  def execute({:quest_component, id, action, arg}, context) do
    guild = context.campaign.discord_guild_id

    with {:ok, projected} <- Submissions.player_state(guild, access(context)),
         state = bind(projected, context),
         true <- state.open and String.starts_with?(id, control_prefix(state) <> ":"),
         :ok <- operate(action, arg, state, guild, access(context)) do
      show(context, if(action == "p", do: String.to_integer(arg), else: 0))
    else
      _ -> {:error, :stale_component}
    end
  end

  defp operate("p", arg, state, _, _) do
    case Integer.parse(arg) do
      {page, ""} when page >= 0 ->
        if page < length(pages(state)), do: :ok, else: {:error, :stale_component}

      _ ->
        {:error, :stale_component}
    end
  end

  defp operate("c", "-", state, guild, user) do
    case Submissions.clear(guild, user, state.identity) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp operate("s", arg, state, guild, user) do
    case Enum.find(state.quest.choices, &(digest(&1.id) == arg and &1.enabled)) do
      nil ->
        {:error, :unavailable_choice}

      choice ->
        case Submissions.submit(guild, user, state.identity, choice.id) do
          {:ok, _} -> :ok
          error -> error
        end
    end
  end

  defp operate(_, _, _, _, _), do: {:error, :stale_component}

  # Read-only pages bind to the verified owner and freshly projected view, never
  # expose a submit/clear control, and create only one private reply per click.
  defp readonly(context, state, heading, page, expected) do
    view = digest(:erlang.term_to_binary({context.campaign.id, access(context), state, heading}))
    pages = pages(state)

    if (not is_nil(expected) and expected != view) or page >= length(pages) do
      {:error, :stale_component}
    else
      navigation =
        [{page - 1, "Previous"}, {page + 1, "Next"}]
        |> Enum.filter(fn {index, _} -> index >= 0 and index < length(pages) end)
        |> Enum.map(fn {index, label} ->
          %{type: 2, style: 2, custom_id: "qv:#{view}:p:#{index}", label: label}
        end)

      {:ok,
       %{
         content:
           "#{heading}\nPage #{page + 1}/#{length(pages)}\n\n" <> Enum.at(pages, page).text,
         components: if(navigation == [], do: [], else: [row(navigation)])
       }}
    end
  end

  @doc "Pure bounded presentation of an already authorized open player submission projection."
  def present(%{open: true} = state, page) do
    pages = pages(state)
    page = min(page, length(pages) - 1)
    selected = Enum.find(state.quest.choices, &(&1.id == state.choice_id))
    latest = if selected, do: truncate(selected.label, 120), else: "None"

    current = Enum.at(pages, page)

    choices =
      current.choices
      |> Enum.map(fn {choice, number} ->
        button(
          state,
          "s",
          digest(choice.id),
          truncate("#{number}. " <> choice.label, 80),
          not choice.enabled
        )
      end)

    navigation =
      Enum.reject(
        [
          if(page > 0, do: button(state, "p", to_string(page - 1), "Previous")),
          if(page + 1 < length(pages), do: button(state, "p", to_string(page + 1), "Next")),
          button(state, "c", "-", "Clear choice", is_nil(state.choice_id))
        ],
        &is_nil/1
      )

    %{
      content:
        "Choose below to submit or revise.\nLatest choice: #{latest}\nPage #{page + 1}/#{length(pages)}\n\n" <>
          current.text,
      components:
        Enum.map(Enum.chunk_every(choices, 5), &row/1) ++
          if(navigation == [], do: [], else: [row(navigation)])
    }
  end

  defp pages(state) do
    groups = state.quest.choices |> Enum.with_index(1) |> Enum.chunk_every(15)
    groups = if groups == [], do: [[]], else: groups

    groups
    |> Enum.with_index()
    |> Enum.flat_map(fn {choices, index} ->
      labels =
        Enum.map_join(choices, "\n", fn {c, i} ->
          "#{i}. " <> AsyncWorlds.Discord.PlayerContent.choice_line(c)
        end)

      text = if index == 0, do: state.quest.text <> "\n" <> labels, else: labels

      text
      |> String.codepoints()
      |> Enum.chunk_every(1400)
      |> Enum.map(fn chunk -> %{text: Enum.join(chunk), choices: choices} end)
    end)
  end

  defp button(state, action, arg, label, disabled \\ false),
    do: %{
      type: 2,
      style: 2,
      custom_id: control_prefix(state) <> ":#{action}:#{arg}",
      label: label,
      disabled: disabled
    }

  defp row(buttons), do: %{type: 1, components: buttons}

  # Base36 database identities plus 96-bit content-ID digests fit Discord's 100-character
  # custom_id limit even for maximum bigint IDs and 100-byte authoring IDs. Never
  # trust these as authorization: compare to the authenticated player's fresh state.
  defp prefix(i),
    do:
      Enum.join(
        [
          "q1",
          Integer.to_string(i.tick_id, 36),
          Integer.to_string(i.progression_id, 36),
          Integer.to_string(i.revision_id, 36),
          Integer.to_string(i.position_version, 36),
          digest(i.node_id)
        ],
        ":"
      )

  defp digest(id),
    do: :crypto.hash(:sha256, id) |> binary_part(0, 12) |> Base.url_encode64(padding: false)

  defp bind(state, context) do
    case access(context) do
      %{debug: true} = access ->
        Map.put(
          state,
          :control_prefix,
          "q2:" <> digest(:erlang.term_to_binary({state.identity, access}))
        )

      _ ->
        state
    end
  end

  defp control_prefix(state), do: Map.get(state, :control_prefix, prefix(state.identity))

  defp access(context), do: Map.get(context, :access, context.user_id)

  defp truncate(text, size), do: text |> String.codepoints() |> Enum.take(size) |> Enum.join()
end
