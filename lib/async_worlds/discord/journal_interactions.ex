defmodule AsyncWorlds.Discord.JournalInteractions do
  alias AsyncWorlds.Discord.JournalCreation
  @moduledoc "Production journal commands and authenticated, freshly authorized controls."
  alias AsyncWorlds.Journals
  alias AsyncWorlds.Journals.Entry

  @prefix "j1:"

  def definition do
    %{
      name: "journal",
      description: "Write and retrieve character journals",
      type: 1,
      permission: :player,
      options: [
        %{
          name: "new",
          description: "Write a journal entry",
          type: 1,
          options: [
            %{
              name: "visibility",
              description: "Who can read the entry",
              type: 3,
              choices: [
                %{name: "Private (character owner and DM)", value: "private"},
                %{name: "Public (campaign-readable)", value: "public"}
              ]
            }
          ]
        },
        %{
          name: "list",
          description: "List journal entries (character scope is DM-role-only)",
          type: 1,
          options: [
            %{
              name: "scope",
              description: "Which entries to list",
              type: 3,
              choices: [
                %{name: "Mine", value: "mine"},
                %{name: "Public", value: "public"},
                %{name: "Character (DM only)", value: "character"}
              ]
            },
            %{
              name: "character",
              description: "Campaign character ID (character scope only)",
              type: 3
            }
          ]
        },
        %{
          name: "open",
          description: "Read a journal entry privately",
          type: 1,
          options: [entry_option()]
        },
        %{
          name: "delete",
          description: "Confirm deletion of a journal entry",
          type: 1,
          options: [entry_option()]
        }
      ]
    }
  end

  defp entry_option,
    do: %{name: "entry", description: "Journal entry ID", type: 3, required: true}

  def route(%{options: [%{type: 1, name: name} = option]}) do
    with {:ok, options} <- options(Map.get(option, :options, [])) do
      case {name, options} do
        {"new", opts} when map_size(opts) == 0 ->
          {:ok, {:journal_new, "private"}, :player}

        {"new", %{"visibility" => v} = opts}
        when map_size(opts) == 1 and v in ["private", "public"] ->
          {:ok, {:journal_new, v}, :player}

        {"list", opts} ->
          list_route(opts)

        {"open", %{"entry" => id} = opts} when map_size(opts) == 1 ->
          {:ok, {:journal_open, id}, :player}

        {"delete", %{"entry" => id} = opts} when map_size(opts) == 1 ->
          {:ok, {:journal_delete, id}, :player}

        _ ->
          {:error, :unknown_command}
      end
    end
  end

  def route(_), do: {:error, :unknown_command}

  defp options(options) when is_list(options) and length(options) <= 2 do
    Enum.reduce_while(options, {:ok, %{}}, fn
      %{type: 3, name: name, value: value}, {:ok, acc}
      when is_binary(value) and byte_size(value) <= 100 ->
        if Map.has_key?(acc, name),
          do: {:halt, {:error, :unknown_command}},
          else: {:cont, {:ok, Map.put(acc, name, value)}}

      _, _ ->
        {:halt, {:error, :unknown_command}}
    end)
  end

  defp options(_), do: {:error, :unknown_command}

  defp list_route(opts) do
    case {Map.get(opts, "scope", "mine"), Map.get(opts, "character"),
          Map.keys(opts) -- ["scope", "character"]} do
      {"mine", nil, []} -> {:ok, {:journal_list, :mine, nil, nil}, :player}
      {"public", nil, []} -> {:ok, {:journal_list, :public, nil, nil}, :player}
      {"character", id, []} when is_binary(id) -> {:ok, {:journal_list, :character, id, nil}, :dm}
      _ -> {:error, :unknown_command}
    end
  end

  def modal_open?(%{type: 3, data: %{component_type: 2, custom_id: @prefix <> "write:" <> _}}),
    do: true

  def modal_open?(_), do: false
  def modal_submit?(%{type: 5, data: %{custom_id: @prefix <> "submit:" <> _}}), do: true
  def modal_submit?(_), do: false
  def journal_control?(%{data: %{custom_id: @prefix <> _}}), do: true
  def journal_control?(_), do: false

  def component_route(%{component_type: 2, custom_id: @prefix <> _ = id}),
    do: {:ok, {:journal_control, id}, :player}

  def component_route(_), do: {:error, :unknown_command}

  def open(id, context) do
    with {:ok, uuid} <- parse_creation(id, "write"),
         {:ok, _} <- JournalCreation.open_creation(context, uuid) do
      {:ok, modal(creation_id("submit", uuid))}
    end
  end

  def execute({:journal_new, visibility}, context) do
    with {:ok, receipt} <-
           JournalCreation.begin_creation(context, context.interaction_id, visibility) do
      if receipt.state == :pending do
        {:ok,
         %{
           content:
             "Visibility: #{visibility_label(receipt.visibility)}. All replies stay private.\nClick Write entry within 15 minutes.",
           components: rows([button("Write entry", creation_id("write", receipt.id), 1)])
         }}
      else
        {:ok, creation_result(receipt)}
      end
    end
  end

  def execute({:journal_submit, id, components}, context) do
    with {:ok, uuid} <- parse_creation(id, "submit"),
         {:ok, attrs} <- inputs(components),
         {:ok, receipt} <- JournalCreation.submit(context, uuid, attrs) do
      {:ok, creation_result(receipt)}
    end
  end

  def execute({:journal_list, scope, character, cursor}, context) do
    dm? = scope == :character or (scope == :public and context.role == :dm)

    with {:ok, page} <- Journals.list_entries(context, scope, character, cursor) do
      binding = page.binding
      mode = if dm?, do: "d", else: "p"

      lines =
        Enum.map(page.entries, fn e ->
          "##{e.id} · #{e.title}\n#{e.character} · #{e.visibility} · #{date(e.inserted_at)}"
        end)

      opens =
        Enum.map(page.entries, fn e ->
          button("Open ##{e.id}", control("open", mode, Integer.to_string(e.id, 36), binding))
        end)

      navigation =
        for {label, cursor} <- [{"Previous", page.previous}, {"Next", page.next}], cursor do
          subject =
            if character,
              do: Integer.to_string(String.to_integer(to_string(character)), 36),
              else: "-"

          data =
            Enum.join(
              [
                scope_code(scope),
                subject,
                direction_code(cursor.direction),
                Integer.to_string(cursor.anchor, 36),
                Integer.to_string(cursor.ceiling, 36)
              ],
              "/"
            )

          button(label, control("page", mode, data, binding))
        end

      content =
        if lines == [], do: "No journal entries on this page.", else: Enum.join(lines, "\n\n")

      {:ok, %{content: content, components: rows(opens ++ navigation)}}
    end
  end

  def execute({:journal_open, id}, context) do
    with {:ok, entry} <- Journals.get_entry(context, id) do
      binding = entry.binding
      mode = if context.role == :dm, do: "d", else: "p"

      buttons =
        if entry.can_delete?,
          do: [
            button(
              "Delete ##{entry.id}",
              control("delete", mode, Integer.to_string(entry.id, 36), binding),
              4
            )
          ],
          else: []

      {:ok,
       %{
         content:
           "#{entry.title}\nEntry ##{entry.id} · #{entry.character} · #{date(entry.inserted_at)}\n#{visibility_label(entry.visibility)} · Author: #{entry.author_discord_user_id} · #{entry.origin}\n\n#{entry.body}",
         components: rows(buttons)
       }}
    end
  end

  def execute({:journal_delete, id}, context) do
    with {:ok, target} <- Journals.prepare_delete(context, id) do
      mode = if context.role == :dm, do: "d", else: "p"
      data = Integer.to_string(target.id, 36)

      {:ok,
       %{
         content:
           "Delete entry ##{target.id}: #{target.title}?\nThis removes its content from the application. Existing backups follow separate retention.",
         components:
           rows([
             button("Confirm deletion", control("confirm", mode, data, target.binding), 4),
             button("Cancel", control("cancel", mode, data, target.binding))
           ])
       }}
    end
  end

  def execute({:journal_control, id}, context) do
    with {:ok, action, mode, data, issued, signature} <- parse_control(id),
         {:ok, base_binding} <- Journals.control_binding(context, mode == "d"),
         {:ok, binding} <- confirmation_binding(action, data, base_binding),
         true <-
           Plug.Crypto.secure_compare(signature, sign([action, mode, data, issued], binding)) do
      case action do
        "page" ->
          with {:ok, scope, character, cursor} <- parse_page(data) do
            execute({:journal_list, scope, character, cursor}, context)
          end

        action when action in ["open", "delete", "confirm", "cancel"] ->
          with {entry_id, ""} <- Integer.parse(data, 36), true <- entry_id > 0 do
            case action do
              "open" ->
                execute({:journal_open, entry_id}, context)

              "delete" ->
                execute({:journal_delete, entry_id}, context)

              "cancel" ->
                {:ok, %{content: "Deletion canceled. No entry was changed.", components: []}}

              "confirm" ->
                with {:ok, _} <- Journals.delete_entry(context, entry_id, binding),
                     do: {:ok, %{content: "Entry ##{entry_id} deleted.", components: []}}
            end
          else
            _ -> {:error, :stale_component}
          end

        _ ->
          {:error, :stale_component}
      end
    else
      _ -> {:error, :stale_component}
    end
  end

  defp confirmation_binding(action, data, binding) when action in ["confirm", "cancel"] do
    case Integer.parse(data, 36) do
      {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 ->
        {:ok, Map.put(binding, "target", id)}

      _ ->
        {:error, :stale_component}
    end
  end

  defp confirmation_binding(_, _, binding), do: {:ok, binding}

  defp parse_page(data) do
    with [scope, character, direction, anchor, ceiling] <- String.split(data, "/"),
         {:ok, scope} <- scope(scope),
         {:ok, direction} <- direction(direction),
         {anchor, ""} <- Integer.parse(anchor, 36),
         {ceiling, ""} <- Integer.parse(ceiling, 36) do
      {:ok, scope, if(character == "-", do: nil, else: String.to_integer(character, 36)),
       %{direction: direction, anchor: anchor, ceiling: ceiling}}
    else
      _ -> {:error, :stale_component}
    end
  end

  defp scope_code(:mine), do: "m"
  defp scope_code(:public), do: "p"
  defp scope_code(:character), do: "c"
  defp direction_code(:next), do: "n"
  defp direction_code(:previous), do: "p"
  defp scope("m"), do: {:ok, :mine}
  defp scope("p"), do: {:ok, :public}
  defp scope("c"), do: {:ok, :character}
  defp scope(_), do: :error
  defp direction("n"), do: {:ok, :next}
  defp direction("p"), do: {:ok, :previous}
  defp direction(_), do: :error

  defp creation_result(%{state: :deleted, entry_id: id}),
    do: "Entry ##{id} was already created and deleted. This flow cannot recreate it."

  defp creation_result(%{state: :completed, entry_id: id}),
    do: "Saved entry ##{id}. Use /journal open entry:#{id} or /journal list to read it."

  defp creation_result(_),
    do: "This creation flow is unavailable. Run /journal new to start again."

  defp visibility_label(:private),
    do: "Private · visible to the current character owner and campaign DM"

  defp visibility_label(:public),
    do: "Public · readable by campaign players and DM (not posted automatically)"

  defp date(date), do: Calendar.strftime(date, "%Y-%m-%d %H:%M UTC")
  defp button(label, id, style \\ 2), do: %{type: 2, label: label, custom_id: id, style: style}
  defp rows(buttons), do: Enum.map(Enum.chunk_every(buttons, 5), &%{type: 1, components: &1})

  defp creation_id(action, uuid) do
    {:ok, bytes} = Ecto.UUID.dump(uuid)
    @prefix <> action <> ":" <> Base.url_encode64(bytes, padding: false)
  end

  defp parse_creation(id, action) when is_binary(id) and byte_size(id) <= 100 do
    with ["j1", ^action, encoded] <- String.split(id, ":"),
         {:ok, bytes} <- Base.url_decode64(encoded, padding: false),
         {:ok, uuid} <- Ecto.UUID.load(bytes) do
      {:ok, uuid}
    else
      _ -> {:error, :stale_component}
    end
  end

  defp parse_creation(_, _), do: {:error, :stale_component}

  defp control(action, mode, data, binding) do
    issued = Integer.to_string(System.system_time(:second), 36)
    fields = [action, mode, data, issued]
    Enum.join(["j1" | fields] ++ [sign(fields, binding)], ":")
  end

  defp parse_control(id) when is_binary(id) and byte_size(id) <= 100 do
    with ["j1", action, mode, data, issued, signature] <- String.split(id, ":"),
         true <- mode in ["p", "d"] and byte_size(signature) == 22,
         {time, ""} <- Integer.parse(issued, 36),
         age = System.system_time(:second) - time,
         true <- age >= 0 and age <= 900 do
      {:ok, action, mode, data, issued, signature}
    else
      _ -> {:error, :stale_component}
    end
  end

  defp parse_control(_), do: {:error, :stale_component}

  defp sign(fields, binding) do
    :crypto.mac(
      :hmac,
      :sha256,
      AsyncWorldsWeb.Endpoint.config(:secret_key_base),
      :erlang.term_to_binary({fields, binding})
    )
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end

  @doc "Legacy format isolated for eventual migration from deprecated Action Row inputs."
  def modal(custom_id) do
    %{
      custom_id: custom_id,
      title: "Write journal entry",
      components: [input("title", "Title", 1, 100), input("body", "Entry", 2, 4000)]
    }
  end

  defp input(id, label, style, max) do
    %{
      type: 1,
      components: [
        %{
          type: 4,
          custom_id: id,
          label: label,
          style: style,
          required: true,
          min_length: 1,
          max_length: max
        }
      ]
    }
  end

  def inputs(components) when is_list(components) and length(components) == 2 do
    values =
      Enum.map(components, fn
        %{type: 1, components: [%{type: 4, custom_id: id, value: value}]}
        when id in ["title", "body"] and is_binary(value) ->
          {id, value}

        _ ->
          :invalid
      end)

    case Enum.sort(values) do
      [{"body", body}, {"title", title}] ->
        if Entry.valid_text?(title, 100) and Entry.valid_text?(body, 4000),
          do: {:ok, %{title: title, body: body}},
          else: {:error, :invalid_journal_input}

      _ ->
        {:error, :invalid_journal_input}
    end
  end

  def inputs(_), do: {:error, :invalid_journal_input}
end
