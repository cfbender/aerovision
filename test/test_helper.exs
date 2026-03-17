# Register modules that may be mocked in tests.
# Must be called before ExUnit.start().
Mimic.copy(CubDB)
Mimic.copy(AeroVision.Flight.Skylink.FlightStatus)
Mimic.copy(AeroVision.Network.Manager)
Mimic.copy(AeroVision.Display.Driver)

ExUnit.start()
