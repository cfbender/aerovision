# Register modules that may be mocked in tests.
# Must be called before ExUnit.start().
Mimic.copy(CubDB)
Mimic.copy(AeroVision.Flight.FlightStats)
Mimic.copy(AeroVision.Flight.FlightAware)
Mimic.copy(AeroVision.Flight.Skylink.FlightStatus)
Mimic.copy(AeroVision.Network.Manager)
Mimic.copy(AeroVision.Display.Driver)
Mimic.copy(AeroVision.Network.Watchdog)
Mimic.copy(AeroVision.Flight.Tracker)

ExUnit.start()

# Start the Phoenix endpoint for LiveView/controller tests.
{:ok, _} = AeroVisionWeb.Endpoint.start_link()
