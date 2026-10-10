defmodule AsyncWorldsWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AsyncWorldsWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-[#090b12] text-slate-100 selection:bg-amber-300 selection:text-slate-950">
      <div class="pointer-events-none fixed inset-0 overflow-hidden" aria-hidden="true">
        <div class="absolute -left-40 -top-48 size-[34rem] rounded-full bg-indigo-600/15 blur-3xl">
        </div>
        <div class="absolute -right-52 top-1/3 size-[38rem] rounded-full bg-amber-400/10 blur-3xl">
        </div>
      </div>
      <header class="relative border-b border-white/10">
        <div class="mx-auto flex max-w-7xl items-center justify-between px-5 py-5 sm:px-8">
          <a
            href={if @current_scope, do: ~p"/dashboard", else: ~p"/login"}
            class="group flex items-center gap-3"
          >
            <span class="grid size-10 place-items-center rounded-xl border border-amber-300/30 bg-amber-300/10 text-amber-300 transition group-hover:rotate-3 group-hover:bg-amber-300/15">
              <.icon name="hero-sparkles" class="size-5" />
            </span>
            <span>
              <span class="block text-sm font-semibold tracking-wide text-white">World Games</span>
              <span class="block text-[10px] uppercase tracking-[0.2em] text-slate-500">DM console</span>
            </span>
          </a>
          <%= if @current_scope do %>
            <.link
              id="logout-link"
              href={~p"/auth/logout"}
              method="delete"
              class="rounded-full border border-white/10 px-4 py-2 text-xs font-semibold text-slate-300 transition hover:border-rose-300/40 hover:bg-rose-300/10 hover:text-white focus:outline-none focus:ring-2 focus:ring-rose-300"
            >
              Sign out
            </.link>
          <% end %>
        </div>
      </header>
      <main class="relative mx-auto max-w-7xl px-5 py-12 sm:px-8 sm:py-20">
        {render_slot(@inner_block)}
      </main>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
