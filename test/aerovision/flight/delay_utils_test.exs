defmodule AeroVision.Flight.Utils.DelayTest do
  use ExUnit.Case, async: true

  alias AeroVision.Flight.Utils.Delay

  # ──────────────────────────────────────────────── compute_delay/2 ──

  describe "compute_delay/2" do
    test "nil actual returns nil" do
      assert Delay.compute_delay(nil, ~U[2026-03-17 12:00:00Z]) == nil
    end

    test "nil scheduled returns nil" do
      assert Delay.compute_delay(~U[2026-03-17 12:30:00Z], nil) == nil
    end

    test "both nil returns nil" do
      assert Delay.compute_delay(nil, nil) == nil
    end

    test "early flight (actual before scheduled) returns nil" do
      actual = ~U[2026-03-17 11:50:00Z]
      scheduled = ~U[2026-03-17 12:00:00Z]
      assert Delay.compute_delay(actual, scheduled) == nil
    end

    test "on-time (exact same time) returns nil" do
      time = ~U[2026-03-17 12:00:00Z]
      assert Delay.compute_delay(time, time) == nil
    end

    test "1 second late returns 0 minutes" do
      scheduled = ~U[2026-03-17 12:00:00Z]
      actual = ~U[2026-03-17 12:00:01Z]
      assert Delay.compute_delay(actual, scheduled) == 0
    end

    test "19 minutes late returns 19" do
      scheduled = ~U[2026-03-17 12:00:00Z]
      actual = ~U[2026-03-17 12:19:00Z]
      assert Delay.compute_delay(actual, scheduled) == 19
    end

    test "30 minutes late returns 30" do
      scheduled = ~U[2026-03-17 12:00:00Z]
      actual = ~U[2026-03-17 12:30:00Z]
      assert Delay.compute_delay(actual, scheduled) == 30
    end

    test "90 minutes late returns 90" do
      scheduled = ~U[2026-03-17 12:00:00Z]
      actual = ~U[2026-03-17 13:30:00Z]
      assert Delay.compute_delay(actual, scheduled) == 90
    end

    test "partial minute is truncated (not rounded)" do
      scheduled = ~U[2026-03-17 12:00:00Z]
      actual = ~U[2026-03-17 12:19:59Z]
      assert Delay.compute_delay(actual, scheduled) == 19
    end
  end

  # ──────────────────────────────────────────────── delay_rgb/1 ──

  describe "delay_rgb/1" do
    test "nil returns gray" do
      assert Delay.delay_rgb(nil) == [120, 120, 120]
    end

    test "0 minutes returns gray" do
      assert Delay.delay_rgb(0) == [120, 120, 120]
    end

    test "19 minutes returns gray" do
      assert Delay.delay_rgb(19) == [120, 120, 120]
    end

    test "20 minutes returns orange" do
      assert Delay.delay_rgb(20) == [251, 146, 60]
    end

    test "45 minutes returns orange" do
      assert Delay.delay_rgb(45) == [251, 146, 60]
    end

    test "60 minutes returns orange" do
      assert Delay.delay_rgb(60) == [251, 146, 60]
    end

    test "61 minutes returns red" do
      assert Delay.delay_rgb(61) == [248, 113, 113]
    end

    test "120 minutes returns red" do
      assert Delay.delay_rgb(120) == [248, 113, 113]
    end
  end

  # ──────────────────────────────────────────────── delay_color/1 ──

  describe "delay_color/1" do
    test "nil returns gray class" do
      assert Delay.delay_color(nil) == "text-gray-500"
    end

    test "0 minutes returns gray class" do
      assert Delay.delay_color(0) == "text-gray-500"
    end

    test "19 minutes returns gray class" do
      assert Delay.delay_color(19) == "text-gray-500"
    end

    test "20 minutes returns orange class" do
      assert Delay.delay_color(20) == "text-orange-400"
    end

    test "60 minutes returns orange class" do
      assert Delay.delay_color(60) == "text-orange-400"
    end

    test "61 minutes returns red class" do
      assert Delay.delay_color(61) == "text-red-400"
    end

    test "120 minutes returns red class" do
      assert Delay.delay_color(120) == "text-red-400"
    end
  end
end
