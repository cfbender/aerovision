defmodule AeroVision.HardwareSupervisor do
  @moduledoc """
  Supervisor for the hardware display and GPIO subsystem.

  Manages the display driver, renderer, and GPIO button under a `rest_for_one`
  strategy. Because the Renderer and GPIO.Button both depend on Display.Driver
  being alive (they communicate over its port), a Driver crash will also restart
  everything that started after it — ensuring a consistent hardware state on
  recovery.

  This subtree is intentionally isolated from the flight data and web subtrees,
  so repeated Display.Driver crashes (e.g. the Go binary exiting) cannot
  escalate to the top-level supervisor and take down the Phoenix endpoint.

  On the `:host` target, `AeroVision.Display.PreviewServer` is inserted between
  the Driver and the Renderer so the browser preview also restarts cleanly
  alongside the driver it depends on.
  """
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    target = Application.get_env(:aerovision, :target, :host)

    children =
      [AeroVision.Display.Driver] ++
        if(target == :host, do: [AeroVision.Display.PreviewServer], else: []) ++
        [
          AeroVision.Display.Renderer,
          AeroVision.GPIO.Button
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
