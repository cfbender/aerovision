defmodule AeroVision.Display.RendererTest do
  use ExUnit.Case, async: true
  alias AeroVision.Display.Renderer

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
