defmodule AeroVisionWeb.Router do
  use AeroVisionWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {AeroVisionWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", AeroVisionWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    live("/settings", SettingsLive, :index)
    live("/setup", SetupLive, :index)
  end
end
