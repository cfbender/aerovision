defmodule AeroVision.TimeSync do
  @moduledoc """
  Thin wrapper around NervesTime clock-sync detection.

  On the device, delegates to `NervesTime.synchronized?/0` (via `apply/3`
  since nerves_time is a target-only dependency). On host, always returns true.
  """

  @doc "Returns true when the system clock has been set via NTP (always true on host)."
  def synchronized? do
    if on_target?() do
      apply(NervesTime, :synchronized?, [])
    else
      true
    end
  end

  defp on_target? do
    Application.get_env(:aerovision, :target, :host) not in [:host, :test]
  end
end
