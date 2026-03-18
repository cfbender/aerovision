defmodule AeroVisionWeb.SettingsLiveTest do
  use AeroVisionWeb.ConnCase, async: false
  use Mimic

  alias AeroVision.Config.Store
  alias AeroVision.Network.Manager, as: NetManager

  setup do
    Store.reset()

    stub(NetManager, :current_mode, fn -> :infrastructure end)
    stub(NetManager, :current_ip, fn -> "192.168.1.42" end)

    :ok
  end

  describe "display settings brightness" do
    test "saves brightness value from form submission", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> form("form[phx-submit='save_display_settings']", %{
        display_settings: %{
          display_brightness: "75",
          display_cycle_seconds: "8",
          timezone: "America/New_York"
        }
      })
      |> render_submit()

      assert Store.get(:display_brightness) == 75
    end

    test "clamps brightness to minimum of 20", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> form("form[phx-submit='save_display_settings']", %{
        display_settings: %{
          display_brightness: "5",
          display_cycle_seconds: "8",
          timezone: "America/New_York"
        }
      })
      |> render_submit()

      assert Store.get(:display_brightness) == 20
    end

    test "clamps brightness to maximum of 100", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings")

      view
      |> form("form[phx-submit='save_display_settings']", %{
        display_settings: %{
          display_brightness: "150",
          display_cycle_seconds: "8",
          timezone: "America/New_York"
        }
      })
      |> render_submit()

      assert Store.get(:display_brightness) == 100
    end
  end
end
