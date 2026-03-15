# IEx configuration for Nerves target
NervesPack.setup()

if RingLogger in Application.get_env(:logger, :backends, []) do
  IO.puts("""

  RingLogger is collecting log messages from prior boot.
  To see the messages, run:

    RingLogger.next()

  """)
end
