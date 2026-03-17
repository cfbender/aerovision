defmodule AeroVision.Flight.OpenSkyTest do
  use ExUnit.Case, async: false
  alias AeroVision.Flight.OpenSky
  alias AeroVision.Config.Store

  setup do
    Store.reset()
    :ok
  end

  test "module exists and compiles" do
    assert Code.ensure_loaded?(AeroVision.Flight.OpenSky)
  end

  test "does not poll when no credentials configured" do
    # Store.reset() leaves opensky_client_id and opensky_client_secret as nil
    # Starting the GenServer should not crash and should not attempt to fetch
    tmp = Path.join(System.tmp_dir!(), "opensky_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    # Should start without crashing
    pid = start_supervised!({OpenSky, []})
    assert Process.alive?(pid)

    # No flights_raw message should arrive (no credentials = no fetch)
    Phoenix.PubSub.subscribe(AeroVision.PubSub, "flights")
    refute_receive {:flights_raw, _}, 500
  end
end
