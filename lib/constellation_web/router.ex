defmodule ConstellationWeb.Router do
  use ConstellationWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ConstellationWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ConstellationWeb do
    pipe_through :browser

    get "/", PageController, :home
    
    # Game routes
    post "/games", GameController, :create
    live "/games/:id", GameLobbyLive
    post "/games/join", GameController, :join
    post "/games/:id/start", GameController, :start
    live "/games/:id/play", GameLive
    
    # Rules and leaderboard routes
    get "/rules", RulesController, :index
    get "/leaderboard", LeaderboardController, :index
    get "/leaderboard/:game_id", LeaderboardController, :show
  end

  # Other scopes may use custom stacks.
  scope "/api", ConstellationWeb.API do
    pipe_through :api
    
    get "/games/:id/players", GameController, :players
    get "/games/:id/status", GameController, :status
    post "/games/:id/rounds", RoundController, :create
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:constellation, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ConstellationWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
