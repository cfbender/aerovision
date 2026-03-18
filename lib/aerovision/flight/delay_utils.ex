defmodule AeroVision.Flight.DelayUtils do
  @moduledoc """
  Delay computation and color mapping utilities for flight times.

  Used by both the LED display Renderer (RGB colors) and the web dashboard
  (Tailwind CSS classes) to indicate departure/arrival delays.
  """

  @doc """
  Compute the delay in minutes between an actual/estimated time and the
  scheduled time. Returns nil if either time is missing or the flight is early/on-time.
  """
  def compute_delay(nil, _scheduled), do: nil
  def compute_delay(_actual, nil), do: nil

  def compute_delay(actual, scheduled) do
    diff = DateTime.diff(actual, scheduled, :second)
    if diff > 0, do: div(diff, 60)
  end

  @doc """
  Map delay minutes to an RGB color triple for the LED display.

  Returns gray for on-time/unknown, orange for 20–60 min delays, red for >60 min.
  """
  def delay_rgb(nil), do: [120, 120, 120]
  def delay_rgb(min) when min < 20, do: [120, 120, 120]
  def delay_rgb(min) when min <= 60, do: [251, 146, 60]
  def delay_rgb(_min), do: [248, 113, 113]

  @doc """
  Map delay minutes to a Tailwind CSS color class for the web UI.

  Returns gray for on-time/unknown, orange for 20–60 min delays, red for >60 min.
  """
  def delay_color(nil), do: "text-gray-500"
  def delay_color(min) when min < 20, do: "text-gray-500"
  def delay_color(min) when min <= 60, do: "text-orange-400"
  def delay_color(_min), do: "text-red-400"
end
