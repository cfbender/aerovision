defmodule AeroVision.Flight.Progress do
  @moduledoc """
  Time-based flight progress calculation.

  Computes progress as a float from 0.0 to 1.0 based on scheduled/actual
  departure and arrival times. Pure functions with no side effects.
  """

  alias AeroVision.Flight.FlightInfo

  # Must match the same constant in Renderer — no flight shorter than this is valid
  @min_flight_duration_sec 15 * 60

  @doc """
  Calculate flight progress (0.0–1.0) from departure and arrival times.

  Prefers actual_departure_time over scheduled for accuracy when the flight
  departed late. Applies a 15-minute sanity check so bad estimated_arrival_time
  values from the API don't collapse progress to 0.

  Returns nil if any required time is unavailable or the data looks invalid.
  """
  @spec calculate(term(), FlightInfo.t()) :: float() | nil
  def calculate(_sv, info) do
    now = DateTime.utc_now()

    # Prefer most accurate departure time: actual > estimated > scheduled
    depart = info.actual_departure_time || info.estimated_departure_time || info.departure_time
    # Use validated arrival — rejects estimated values within 15 min of departure
    arrive = validated_arrival_time(info, depart)

    if is_nil(depart) or is_nil(arrive) do
      nil
    else
      dep_unix = DateTime.to_unix(depart)
      arr_unix = DateTime.to_unix(arrive)
      now_unix = DateTime.to_unix(now)
      total = arr_unix - dep_unix

      cond do
        # Arrival not meaningfully after departure — data is unusable
        total <= 0 -> nil
        # Flight hasn't departed yet
        now_unix < dep_unix -> nil
        true -> min((now_unix - dep_unix) / total, 1.0)
      end
    end
  end

  @doc """
  Recompute progress_pct on a FlightInfo struct. Returns nil for nil input.
  """
  @spec refresh(FlightInfo.t() | nil, term()) :: FlightInfo.t() | nil
  def refresh(nil, _sv), do: nil
  def refresh(fi, sv), do: %{fi | progress_pct: calculate(sv, fi)}

  # ──────────────────────────────────────────────── private helpers ──

  # Mirror of Renderer.best_arrival_time/1 — rejects estimated arrival times
  # that are within @min_flight_duration_sec of departure (bad API data).
  defp validated_arrival_time(info, departure) do
    estimated = info.estimated_arrival_time

    estimated_valid? =
      not is_nil(estimated) and
        (is_nil(departure) or DateTime.diff(estimated, departure) > @min_flight_duration_sec)

    if estimated_valid?, do: estimated, else: info.arrival_time
  end
end
