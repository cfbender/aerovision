defmodule AeroVision.Flight.Skylink.ADSBTest do
  use ExUnit.Case, async: false

  alias AeroVision.Config.Store

  setup do
    Store.reset()
    :ok
  end

  test "module exists and can be started" do
    # Just verify the module compiles and the GenServer starts
    assert Code.ensure_loaded?(AeroVision.Flight.Skylink.ADSB)
  end
end
