defmodule AsyncWorldsWeb.Router do
  use AsyncWorldsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AsyncWorldsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug AsyncWorldsWeb.Auth, :fetch_current_scope
  end

  pipeline :require_authenticated_dm do
    plug AsyncWorldsWeb.Auth, :require_authenticated_dm
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AsyncWorldsWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/login", PageController, :home
    get "/auth/discord", AuthController, :new
    get "/auth/discord/callback", AuthController, :callback
  end

  scope "/", AsyncWorldsWeb do
    pipe_through [:browser, :require_authenticated_dm]

    delete "/auth/logout", AuthController, :delete

    live_session :authenticated_dm,
      on_mount: [{AsyncWorldsWeb.LiveAuth, :ensure_dm}] do
      live "/dashboard", DashboardLive, :index
      live "/clocks", ClockLive, :index
      live "/characters", CharacterLive, :index
      live "/factions", FactionLive, :index
      live "/locations", LocationLive, :index
      live "/quests", QuestLive, :index
      live "/quests/library", QuestLibraryLive, :index
      live "/ticks/history", TickHistoryLive, :index
      live "/ticks/:id/history", TickHistoryLive, :show
      live "/ticks/:id/review", TickReviewLive, :show
    end
  end

  scope "/api", AsyncWorldsWeb do
    pipe_through :api

    post "/campaigns/:guild_id/quests/import", QuestImportController, :create

    get "/campaigns/:guild_id/quests/management", QuestInterventionController, :management
    get "/campaigns/:guild_id/characters/:id/quests", QuestInterventionController, :management

    get "/campaigns/:guild_id/characters/:id/quests/unlocked",
        QuestInterventionController,
        :unlocked

    get "/campaigns/:guild_id/characters/:id/quests/interventions",
        QuestInterventionController,
        :interventions

    post "/campaigns/:guild_id/characters/:id/quests/assign",
         QuestInterventionController,
         :assign_quest

    post "/campaigns/:guild_id/characters/:id/quests/replace",
         QuestInterventionController,
         :replace

    post "/campaigns/:guild_id/characters/:id/quests/move", QuestInterventionController, :move
    post "/campaigns/:guild_id/characters/:id/quests/end", QuestInterventionController, :end_quest

    get "/campaigns/:guild_id/quests", QuestAuthoringController, :index
    get "/campaigns/:guild_id/quests/revisions", QuestAuthoringController, :revisions
    get "/campaigns/:guild_id/quests/revisions/:id", QuestAuthoringController, :revision
    get "/campaigns/:guild_id/quests/working-copies", QuestAuthoringController, :working_copies
    post "/campaigns/:guild_id/quests/working-copies", QuestAuthoringController, :create
    get "/campaigns/:guild_id/quests/working-copies/:id", QuestAuthoringController, :show
    put "/campaigns/:guild_id/quests/working-copies/:id", QuestAuthoringController, :save

    post "/campaigns/:guild_id/quests/working-copies/:id/recover",
         QuestAuthoringController,
         :recover

    post "/campaigns/:guild_id/quests/working-copies/:id/release",
         QuestAuthoringController,
         :release

    get "/campaigns/:guild_id/characters/:id/journals", JournalController, :index
    post "/campaigns/:guild_id/characters/:id/journals", JournalController, :create
    get "/campaigns/:guild_id/journals/:id", JournalController, :show
    delete "/campaigns/:guild_id/journals/:id", JournalController, :delete

    get "/campaigns/:guild_id/deliveries", DeliveryController, :index
    get "/campaigns/:guild_id/deliveries/:id", DeliveryController, :show
    post "/campaigns/:guild_id/deliveries/:id/retry", DeliveryController, :retry

    get "/campaigns/:guild_id/ticks/history", HistoryController, :index
    get "/campaigns/:guild_id/ticks/:id/history", HistoryController, :show
    get "/campaigns/:guild_id/characters/:id/history/result", HistoryController, :result
    get "/campaigns/:guild_id/characters/:id/history/submission", HistoryController, :submission

    get "/campaigns/:guild_id/ticks/:id/review", TickReviewController, :show
    get "/campaigns/:guild_id/ticks/:id/review/audits", TickReviewController, :audits
    get "/campaigns/:guild_id/ticks/:id/review/preview", TickReviewController, :preview
    post "/campaigns/:guild_id/ticks/:id/review/edits", TickReviewController, :edit
    post "/campaigns/:guild_id/ticks/:id/publish", TickReviewController, :publish

    get "/campaigns/:guild_id/ticks/status", TickController, :status
    post "/campaigns/:guild_id/ticks/open", TickController, :open
    post "/campaigns/:guild_id/ticks/remind", TickController, :remind
    post "/campaigns/:guild_id/ticks/:id/close", TickController, :close
    get "/campaigns/:guild_id/ticks/:id/readiness", TickController, :readiness
    get "/campaigns/:guild_id/ticks/:id/readiness/roster", TickController, :roster

    get "/campaigns/:guild_id/clocks", ClockController, :index
    get "/campaigns/:guild_id/clocks/:id", ClockController, :show
    post "/campaigns/:guild_id/clocks", ClockController, :create
    patch "/campaigns/:guild_id/clocks/:id", ClockController, :update
    post "/campaigns/:guild_id/clocks/:id/adjust", ClockController, :adjust
    post "/campaigns/:guild_id/clocks/:id/pause", ClockController, :pause
    post "/campaigns/:guild_id/clocks/:id/resume", ClockController, :resume
    post "/campaigns/:guild_id/clocks/:id/reset", ClockController, :reset
    post "/campaigns/:guild_id/clocks/:id/pair", ClockController, :pair
    post "/campaigns/:guild_id/clocks/:id/unpair", ClockController, :unpair

    get "/campaigns/:guild_id/factions/:id/memberships", MembershipController, :faction_members

    get "/campaigns/:guild_id/characters/:id/memberships",
        MembershipController,
        :character_affiliations

    post "/campaigns/:guild_id/memberships", MembershipController, :create
    patch "/campaigns/:guild_id/memberships/:id", MembershipController, :update
    delete "/campaigns/:guild_id/memberships/:id", MembershipController, :delete

    get "/campaigns/:guild_id/locations/roots", LocationController, :roots
    get "/campaigns/:guild_id/locations/:id/children", LocationController, :children
    get "/campaigns/:guild_id/locations/:id/breadcrumbs", LocationController, :breadcrumbs
    patch "/campaigns/:guild_id/locations/:id/parent", LocationController, :parent
    get "/campaigns/:guild_id/locations", LocationController, :index
    get "/campaigns/:guild_id/locations/:id", LocationController, :show
    post "/campaigns/:guild_id/locations", LocationController, :create
    patch "/campaigns/:guild_id/locations/:id", LocationController, :update
    delete "/campaigns/:guild_id/locations/:id", LocationController, :delete

    get "/campaigns/:guild_id/factions", FactionController, :index
    get "/campaigns/:guild_id/factions/:id", FactionController, :show
    post "/campaigns/:guild_id/factions", FactionController, :create
    patch "/campaigns/:guild_id/factions/:id", FactionController, :update
    delete "/campaigns/:guild_id/factions/:id", FactionController, :delete

    get "/campaigns/:guild_id/characters", CharacterController, :index
    get "/campaigns/:guild_id/characters/:id", CharacterController, :show
    post "/campaigns/:guild_id/characters", CharacterController, :create
    patch "/campaigns/:guild_id/characters/:id", CharacterController, :update
    put "/campaigns/:guild_id/characters/:id/flags/:key", CharacterController, :set_flag
    delete "/campaigns/:guild_id/characters/:id/flags/:key", CharacterController, :clear_flag
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:async_worlds, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AsyncWorldsWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
