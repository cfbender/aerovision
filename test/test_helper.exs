# Register modules that may be mocked in tests.
# Must be called before ExUnit.start().
Mimic.copy(CubDB)
Mimic.copy(AeroVision.Flight.Providers.FlightStats)
Mimic.copy(AeroVision.Flight.Providers.FlightAware)
Mimic.copy(AeroVision.Flight.FlightStatus)
Mimic.copy(AeroVision.Flight.Providers.Skylink.Api)
Mimic.copy(AeroVision.Network.Manager)
Mimic.copy(AeroVision.Display.Driver)
Mimic.copy(AeroVision.Network.Watchdog)
Mimic.copy(AeroVision.Flight.Tracker)
Mimic.copy(AeroVision.Cache)

ExUnit.start()

# Start the Phoenix endpoint for LiveView/controller tests.
{:ok, _} = AeroVisionWeb.Endpoint.start_link()
