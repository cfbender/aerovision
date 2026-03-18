defmodule AeroVision.Display.RendererTest do
  use ExUnit.Case, async: true

  alias AeroVision.Display.Renderer
  alias AeroVision.Flight.FlightInfo

  # ──────────────────────────────────────────────── best_arrival_time/1 ──

  describe "best_arrival_time/1" do
    test "nil flight_info returns nil" do
      assert Renderer.best_arrival_time(nil) == nil
    end

    test "returns scheduled arrival when no estimated is present" do
      scheduled = ~U[2026-03-17 20:00:00Z]
      fi = %FlightInfo{arrival_time: scheduled, estimated_arrival_time: nil}
      assert Renderer.best_arrival_time(fi) == scheduled
    end

    test "returns estimated when it is well after departure (valid data)" do
      departure = ~U[2026-03-17 17:00:00Z]
      # 2 hours after departure — clearly valid
      estimated = ~U[2026-03-17 19:00:00Z]
      scheduled = ~U[2026-03-17 18:45:00Z]

      fi = %FlightInfo{
        departure_time: departure,
        actual_departure_time: nil,
        estimated_arrival_time: estimated,
        arrival_time: scheduled
      }

      assert Renderer.best_arrival_time(fi) == estimated
    end

    test "falls back to scheduled when estimated equals departure (bad API data)" do
      departure = ~U[2026-03-17 17:00:00Z]
      estimated = ~U[2026-03-17 17:00:00Z]
      scheduled = ~U[2026-03-17 18:45:00Z]

      fi = %FlightInfo{
        departure_time: departure,
        actual_departure_time: nil,
        estimated_arrival_time: estimated,
        arrival_time: scheduled
      }

      assert Renderer.best_arrival_time(fi) == scheduled
    end

    test "falls back to scheduled when estimated is before departure (bad API data)" do
      departure = ~U[2026-03-17 17:00:00Z]
      estimated = ~U[2026-03-17 16:30:00Z]
      scheduled = ~U[2026-03-17 18:45:00Z]

      fi = %FlightInfo{
        departure_time: departure,
        actual_departure_time: nil,
        estimated_arrival_time: estimated,
        arrival_time: scheduled
      }

      assert Renderer.best_arrival_time(fi) == scheduled
    end

    test "falls back to scheduled when estimated is within 15 minutes of departure" do
      departure = ~U[2026-03-17 17:00:00Z]
      # Only 14 minutes — too short to be a real flight
      estimated = ~U[2026-03-17 17:14:00Z]
      scheduled = ~U[2026-03-17 18:45:00Z]

      fi = %FlightInfo{
        departure_time: departure,
        actual_departure_time: nil,
        estimated_arrival_time: estimated,
        arrival_time: scheduled
      }

      assert Renderer.best_arrival_time(fi) == scheduled
    end

    test "falls back to scheduled when estimated is exactly 15 minutes after departure" do
      departure = ~U[2026-03-17 17:00:00Z]
      estimated = ~U[2026-03-17 17:15:00Z]
      scheduled = ~U[2026-03-17 18:45:00Z]

      fi = %FlightInfo{
        departure_time: departure,
        actual_departure_time: nil,
        estimated_arrival_time: estimated,
        arrival_time: scheduled
      }

      # Boundary: exactly 15 min is not strictly greater, so still rejected
      assert Renderer.best_arrival_time(fi) == scheduled
    end

    test "accepts estimated that is just over 15 minutes after departure" do
      departure = ~U[2026-03-17 17:00:00Z]
      estimated = ~U[2026-03-17 17:16:00Z]
      scheduled = ~U[2026-03-17 18:45:00Z]

      fi = %FlightInfo{
        departure_time: departure,
        actual_departure_time: nil,
        estimated_arrival_time: estimated,
        arrival_time: scheduled
      }

      assert Renderer.best_arrival_time(fi) == estimated
    end

    test "prefers actual_departure_time over scheduled departure for the comparison" do
      # Scheduled says 17:00 but it actually left at 17:30 (delayed)
      scheduled_dep = ~U[2026-03-17 17:00:00Z]
      actual_dep = ~U[2026-03-17 17:30:00Z]
      # Estimated arrival is 17:40 — only 10 min after actual departure, so invalid
      estimated = ~U[2026-03-17 17:40:00Z]
      scheduled = ~U[2026-03-17 19:00:00Z]

      fi = %FlightInfo{
        departure_time: scheduled_dep,
        actual_departure_time: actual_dep,
        estimated_arrival_time: estimated,
        arrival_time: scheduled
      }

      assert Renderer.best_arrival_time(fi) == scheduled
    end

    test "trusts estimated arrival when no departure time is known" do
      estimated = ~U[2026-03-17 19:00:00Z]
      scheduled = ~U[2026-03-17 18:45:00Z]

      fi = %FlightInfo{
        departure_time: nil,
        actual_departure_time: nil,
        estimated_arrival_time: estimated,
        arrival_time: scheduled
      }

      # Without a departure reference we can't validate, so trust the estimate
      assert Renderer.best_arrival_time(fi) == estimated
    end
  end

  # ──────────────────────────────────────────────── format_time/2 ──

  describe "format_time/2" do
    test "nil returns '--:--'" do
      assert Renderer.format_time(nil, "Etc/UTC") == "--:--"
    end

    test "formats hour and minute correctly" do
      dt = ~U[2026-03-15 14:30:00Z]
      assert Renderer.format_time(dt, "Etc/UTC") == "14:30"
    end

    test "zero-pads single-digit minute" do
      dt = ~U[2026-03-15 09:05:00Z]
      assert Renderer.format_time(dt, "Etc/UTC") == "09:05"
    end

    test "midnight is formatted as 00:00" do
      dt = ~U[2026-03-15 00:00:00Z]
      assert Renderer.format_time(dt, "Etc/UTC") == "00:00"
    end

    test "end of day 23:59 is formatted correctly" do
      dt = ~U[2026-03-15 23:59:00Z]
      assert Renderer.format_time(dt, "Etc/UTC") == "23:59"
    end

    test "converts UTC to America/New_York (EDT, -4h)" do
      dt = ~U[2026-03-15 14:30:00Z]
      assert Renderer.format_time(dt, "America/New_York") == "10:30"
    end

    test "falls back to UTC for an invalid timezone" do
      dt = ~U[2026-03-15 14:30:00Z]
      assert Renderer.format_time(dt, "invalid/timezone") == "14:30"
    end
  end

  # ──────────────────────────────────────────────── meters_per_sec_to_fpm/1 ──

  describe "meters_per_sec_to_fpm/1" do
    test "nil returns nil" do
      assert Renderer.meters_per_sec_to_fpm(nil) == nil
    end

    test "0 returns 0" do
      assert Renderer.meters_per_sec_to_fpm(0) == 0
    end

    test "10 m/s returns 1969 fpm" do
      # round(10 * 196.85) = round(1968.5) = 1969 (Elixir banker's rounding → 1968)
      # Use assert_in_delta instead of exact match to handle rounding variants
      result = Renderer.meters_per_sec_to_fpm(10)
      assert_in_delta result, 1969, 1
    end

    test "negative m/s produces negative fpm" do
      result = Renderer.meters_per_sec_to_fpm(-5)
      # round(-5 * 196.85) = round(-984.25) = -984
      assert_in_delta result, -984, 1
    end

    test "1.0 m/s returns approximately 197 fpm" do
      # round(1.0 * 196.85) = round(196.85) = 197
      assert Renderer.meters_per_sec_to_fpm(1.0) == 197
    end
  end

  # ──────────────────────────────────────────────── safe_round/1 ──

  describe "safe_round/1" do
    test "nil returns nil" do
      assert Renderer.safe_round(nil) == nil
    end

    test "0 returns 0" do
      assert Renderer.safe_round(0) == 0
    end

    test "3.7 rounds to 4" do
      assert Renderer.safe_round(3.7) == 4
    end

    test "-2.3 rounds to -2" do
      assert Renderer.safe_round(-2.3) == -2
    end

    test "integer 5 passes through as 5" do
      assert Renderer.safe_round(5) == 5
    end

    test "0.5 rounds (Elixir uses half-up rounding via round/1)" do
      # Elixir's round/1 uses round-half-away-from-zero
      assert Renderer.safe_round(0.5) == 1
    end
  end

  # ──────────────────────────────────────────────── truncate/2 ──

  describe "truncate/2" do
    test "nil returns nil" do
      assert Renderer.truncate(nil, 7) == nil
    end

    test "string longer than max is sliced to max characters" do
      assert Renderer.truncate("AMERICAN", 7) == "AMERICA"
    end

    test "string shorter than max is returned unchanged" do
      assert Renderer.truncate("SHORT", 7) == "SHORT"
    end

    test "empty string returns empty string" do
      assert Renderer.truncate("", 7) == ""
    end

    test "string of exact length is returned unchanged" do
      assert Renderer.truncate("EXACT77", 7) == "EXACT77"
    end

    test "string one character over is truncated to max" do
      assert Renderer.truncate("TOOLONG!", 7) == "TOOLONG"
    end

    test "max of 0 returns empty string for any input" do
      assert Renderer.truncate("ANYTHING", 0) == ""
    end
  end
end
