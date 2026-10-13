defmodule AsyncWorlds.Discord.JournalModalSpike do
  @moduledoc "Opt-in ENG-44 legacy-modal round trip. Previews only; never persists journal content."

  alias AsyncWorlds.PlayerAccess

  @prefix "jm1:"
  @max_age 900

  def enabled?, do: Application.get_env(:async_worlds, :journal_modal_spike, false) == true

  def definition do
    %{
      name: "journal",
      description: "Test journal input (spike only; nothing is saved)",
      type: 1,
      permission: :player,
      options: [
        %{
          name: "new",
          description: "Preview a journal entry without saving it",
          type: 1,
          options: [
            %{
              name: "visibility",
              description: "Intended visibility (preview still stays private)",
              type: 3,
              choices: [
                %{name: "Private (you and the DM)", value: "private"},
                %{name: "Public (campaign-readable)", value: "public"}
              ]
            }
          ]
        }
      ]
    }
  end

  def route(%{options: [%{type: 1, name: "new"} = option]}) do
    case Map.get(option, :options) do
      options when options in [nil, []] ->
        {:ok, {:journal_spike_new, "private"}, :player}

      [%{type: 3, name: "visibility", value: value}] when value in ["private", "public"] ->
        {:ok, {:journal_spike_new, value}, :player}

      _ ->
        {:error, :unknown_command}
    end
  end

  def route(_), do: {:error, :unknown_command}

  def modal_open?(%{type: 3, data: %{component_type: 2, custom_id: @prefix <> "o:" <> _}}),
    do: enabled?()

  def modal_open?(_), do: false

  def modal_submit?(%{type: 5, data: %{custom_id: @prefix <> "s:" <> _}}), do: enabled?()
  def modal_submit?(_), do: false

  def execute({:journal_spike_new, visibility}, context) do
    PlayerAccess.run(context.campaign.discord_guild_id, context.access, fn campaign, character ->
      fields = [
        visibility,
        Integer.to_string(System.system_time(:second), 36),
        context.interaction_id
      ]

      id = control("o", fields, signature(fields, campaign, character, context))

      %{
        content:
          "Journal spike · nothing is saved.\nIntended visibility: #{visibility}. " <>
            "Private entries would be visible to you and the DM; public entries to campaign players.\n" <>
            "The preview is visible only to you. Click Write entry within 15 minutes.",
        components: [
          %{type: 1, components: [%{type: 2, style: 1, label: "Write entry", custom_id: id}]}
        ]
      }
    end)
  end

  def execute({:journal_spike_submit, id, components}, context) do
    with {:ok, fields} <- parse_control(id, "s"),
         {:ok, title, body} <- inputs(components) do
      PlayerAccess.run(context.campaign.discord_guild_id, context.access, fn campaign,
                                                                             character ->
        validate!(fields, campaign, character, context)
        [visibility, _, _, _] = fields

        "Journal spike preview · NOT SAVED\nCharacter: #{character.name}\n" <>
          "Intended visibility: #{visibility} · this response is private\n\n#{title}\n\n#{body}"
      end)
    end
  end

  def open(id, context) do
    with {:ok, fields} <- parse_control(id, "o") do
      PlayerAccess.run(context.campaign.discord_guild_id, context.access, fn campaign,
                                                                             character ->
        validate!(fields, campaign, character, context)
        [visibility, issued, request, signature] = fields
        modal(control("s", [visibility, issued, request], signature))
      end)
    end
  end

  @doc "Legacy payload supported by Nostrum 0.10.4: one Text Input per Action Row."
  def modal(custom_id) do
    %{
      custom_id: custom_id,
      title: "Journal preview — not saved",
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

  # Order is not an authorization boundary. Require exactly two unique known fields.
  defp inputs(components) when is_list(components) and length(components) == 2 do
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
        if valid_text?(title, 100) and valid_text?(body, 4000),
          do: {:ok, title, body},
          else: {:error, :invalid_journal_input}

      _ ->
        {:error, :invalid_journal_input}
    end
  end

  defp inputs(_), do: {:error, :invalid_journal_input}

  defp valid_text?(value, max),
    do:
      byte_size(value) <= max * 4 and String.valid?(value) and String.trim(value) != "" and
        length(String.codepoints(value)) <= max

  defp control(action, fields, signature),
    do: Enum.join(["jm1", action | fields] ++ [signature], ":")

  defp parse_control(id, action) when is_binary(id) and byte_size(id) <= 100 do
    case String.split(id, ":") do
      ["jm1", ^action, visibility, issued, request, signature]
      when visibility in ["private", "public"] and byte_size(signature) == 22 ->
        with {time, ""} <- Integer.parse(issued, 36),
             age = System.system_time(:second) - time,
             true <- age >= 0 and age <= @max_age,
             {:ok, _} <- AsyncWorlds.Discord.Snowflake.cast(request) do
          {:ok, [visibility, issued, request, signature]}
        else
          _ -> {:error, :stale_component}
        end

      _ ->
        {:error, :stale_component}
    end
  end

  defp parse_control(_, _), do: {:error, :stale_component}

  defp validate!([visibility, issued, request, expected], campaign, character, context) do
    actual = signature([visibility, issued, request], campaign, character, context)

    unless Plug.Crypto.secure_compare(actual, expected),
      do: AsyncWorlds.Repo.rollback(:stale_component)
  end

  # Bind to trusted actor + fresh subject/configuration, not player-provided IDs.
  # No draft text, webhook tokens or state survives in this control.
  defp signature(fields, campaign, character, context) do
    binding = {
      fields,
      campaign.id,
      campaign.discord_guild_id,
      campaign.dm_user_id,
      campaign.public_channel_id,
      context.user_id,
      context.access,
      character.id,
      character.discord_user_id,
      character.state_version
    }

    :crypto.mac(
      :hmac,
      :sha256,
      AsyncWorldsWeb.Endpoint.config(:secret_key_base),
      :erlang.term_to_binary(binding)
    )
    |> binary_part(0, 16)
    |> Base.url_encode64(padding: false)
  end
end
