defmodule AsyncWorldsWeb.ErrorJSON do
  @moduledoc "Safe JSON exception envelopes, consistent with API controller responses."
  alias AsyncWorldsWeb.ApiResponse

  def render("400.json", %{reason: %Plug.Parsers.ParseError{}}),
    do: ApiResponse.error_payload(:invalid_json)

  def render(template, _assigns) do
    reason =
      case template do
        "400.json" -> :bad_request
        "401.json" -> :unauthenticated
        "403.json" -> :forbidden
        "404.json" -> :not_found
        "405.json" -> :method_not_allowed
        "409.json" -> :invalid_transition
        "413.json" -> :payload_too_large
        "415.json" -> :unsupported_media_type
        "422.json" -> :invalid_parameters
        "428.json" -> :precondition_required
        _ -> :internal_error
      end

    ApiResponse.error_payload(reason)
  end
end
