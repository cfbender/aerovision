defmodule AeroVision.Flight.Skylink.FlightStatusTest do
  use ExUnit.Case, async: false
  alias AeroVision.Flight.Skylink.FlightStatus
  alias AeroVision.Flight.{FlightInfo, Airport}
  alias AeroVision.Config.Store

  @cache_table :aerovision_skylink_cache

  setup do
    Store.reset()
    Phoenix.PubSub.subscribe(AeroVision.PubSub, "flights")
    tmp = Path.join(System.tmp_dir!(), "skylink_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    start_supervised!({FlightStatus, data_dir: tmp})
    :ok
  end

  test "monthly_usage/0 returns 0 on fresh start" do
    assert FlightStatus.monthly_usage() == 0
  end

  test "get_cached/1 returns nil when callsign is not in cache" do
    assert FlightStatus.get_cached("ZZZ999") == nil
  end

  test "get_cached/1 returns cached FlightInfo within TTL" do
    info = %FlightInfo{
      ident: "DAL1192",
      operator: nil,
      airline_name: "Delta Air Lines",
      aircraft_type: nil,
      aircraft_name: nil,
      origin: %Airport{icao: "KATL", iata: nil, name: "Atlanta", city: nil},
      destination: %Airport{icao: "KRDU", iata: nil, name: "Raleigh", city: nil},
      departure_time: nil,
      actual_departure_time: nil,
      arrival_time: nil,
      status: "En Route",
      progress_pct: nil,
      cached_at: DateTime.utc_now()
    }

    now = System.system_time(:second)
    :ets.insert(@cache_table, {"DAL1192", info, now})

    result = FlightStatus.get_cached("DAL1192")
    assert result.ident == "DAL1192"
    assert result.status == "En Route"
  end

  test "enrich/1 returns :ok immediately" do
    assert FlightStatus.enrich("DAL1192") == :ok
  end

  @tag :capture_log
  test "enrich/1 with no API key configured — no broadcast within 1500ms" do
    FlightStatus.enrich("DAL1192")
    refute_receive {:flight_enriched, "DAL1192", _}, 1500
  end

  test "unknown messages are ignored without crash" do
    pid = GenServer.whereis(FlightStatus)
    send(pid, {:unknown_message, :whatever})
    :sys.get_state(pid)
    assert Process.alive?(pid)
  end
end
