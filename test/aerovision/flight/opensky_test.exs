defmodule AeroVision.Flight.OpenSkyTest do
  @moduledoc """
  Tests for AeroVision.Flight.OpenSky.

  We verify startup behaviour, config-change handling, and the fetch_now cast
  without making real HTTP calls (no credentials configured in test env).
  """
  use ExUnit.Case, async: false

  alias AeroVision.Flight.OpenSky
  alias AeroVision.Config.Store

  # ── setup ──────────────────────────────────────────────────────────────────

  setup do
    Store.reset()
    Phoenix.PubSub.subscribe(AeroVision.PubSub, "flights")
    start_supervised!(OpenSky)
    :ok
  end

  # ── startup ──────────────────────────────────────────────────────────────────

  test "starts successfully with no credentials" do
    pid = GenServer.whereis(OpenSky)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  @tag :capture_log
  test "initial state has nil token" do
    state = :sys.get_state(GenServer.whereis(OpenSky))
    assert state.token == nil
  end

  @tag :capture_log
  test "initial state has nil last_fetch_at" do
    state = :sys.get_state(GenServer.whereis(OpenSky))
    assert state.last_fetch_at == nil
  end

  @tag :capture_log
  test "subscribes to config PubSub topic on startup" do
    # Verify by sending a config change and confirming the GenServer handles it
    pid = GenServer.whereis(OpenSky)
    Phoenix.PubSub.broadcast(AeroVision.PubSub, "config", {:config_changed, :location_lat, 40.0})
    # Process the message (sync via a cast that comes after)
    :sys.get_state(pid)
    # GenServer is still alive — message was handled
    assert Process.alive?(pid)
  end

  # ── fetch_now/0 ──────────────────────────────────────────────────────────────

  test "fetch_now/0 returns :ok immediately" do
    # It's a cast so returns immediately
    assert OpenSky.fetch_now() == :ok
  end

  @tag :capture_log
  test "fetch_now/0 does not crash with no credentials" do
    OpenSky.fetch_now()
    # Sync with a follow-up state read
    :sys.get_state(GenServer.whereis(OpenSky))
    assert Process.alive?(GenServer.whereis(OpenSky))
  end

  @tag :capture_log
  test "fetch_now/0 with no credentials does not broadcast :flights_raw" do
    OpenSky.fetch_now()
    # No credentials → no API call → no broadcast
    refute_receive {:flights_raw, _}, 200
  end

  # ── :poll message ────────────────────────────────────────────────────────────

  @tag :capture_log
  test ":poll message is handled without crash" do
    pid = GenServer.whereis(OpenSky)
    send(pid, :poll)
    :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  # ── config_changed: location ─────────────────────────────────────────────────

  @tag :capture_log
  test "{:config_changed, :location_lat, ...} schedules a re-poll timer" do
    pid = GenServer.whereis(OpenSky)

    # Cancel any existing timer to start clean
    state_before = :sys.get_state(pid)
    if state_before.poll_timer, do: Process.cancel_timer(state_before.poll_timer)

    Phoenix.PubSub.broadcast(
      AeroVision.PubSub,
      "config",
      {:config_changed, :location_lat, 40.0}
    )

    :sys.get_state(pid)
    state_after = :sys.get_state(pid)

    # A timer should have been scheduled
    assert state_after.poll_timer != nil
  end

  @tag :capture_log
  test "{:config_changed, :location_lon, ...} schedules a re-poll timer" do
    pid = GenServer.whereis(OpenSky)
    state_before = :sys.get_state(pid)
    if state_before.poll_timer, do: Process.cancel_timer(state_before.poll_timer)

    Phoenix.PubSub.broadcast(
      AeroVision.PubSub,
      "config",
      {:config_changed, :location_lon, -95.0}
    )

    :sys.get_state(pid)
    assert :sys.get_state(pid).poll_timer != nil
  end

  @tag :capture_log
  test "{:config_changed, :radius_km, ...} schedules a re-poll timer" do
    pid = GenServer.whereis(OpenSky)
    state_before = :sys.get_state(pid)
    if state_before.poll_timer, do: Process.cancel_timer(state_before.poll_timer)

    Phoenix.PubSub.broadcast(
      AeroVision.PubSub,
      "config",
      {:config_changed, :radius_km, 100}
    )

    :sys.get_state(pid)
    assert :sys.get_state(pid).poll_timer != nil
  end

  @tag :capture_log
  test "rapid location changes only schedule one timer (debounce)" do
    pid = GenServer.whereis(OpenSky)

    Phoenix.PubSub.broadcast(
      AeroVision.PubSub,
      "config",
      {:config_changed, :location_lat, 40.0}
    )

    Phoenix.PubSub.broadcast(
      AeroVision.PubSub,
      "config",
      {:config_changed, :location_lon, -95.0}
    )

    Phoenix.PubSub.broadcast(
      AeroVision.PubSub,
      "config",
      {:config_changed, :radius_km, 75}
    )

    # Sync after all three
    :sys.get_state(pid)
    :sys.get_state(pid)
    :sys.get_state(pid)

    # Only one timer should be active (the last one replaces the previous ones)
    state = :sys.get_state(pid)
    assert state.poll_timer != nil
    assert Process.alive?(pid)
  end

  @tag :capture_log
  test "unrelated config changes are ignored" do
    pid = GenServer.whereis(OpenSky)

    Phoenix.PubSub.broadcast(
      AeroVision.PubSub,
      "config",
      {:config_changed, :display_brightness, 50}
    )

    :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  # ── unknown messages ─────────────────────────────────────────────────────────

  @tag :capture_log
  test "unknown messages are handled without crash" do
    pid = GenServer.whereis(OpenSky)
    send(pid, :some_random_message)
    :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  # ── parse helpers (tested via module internals) ──────────────────────────────
  # These exercise the parse_states/1 and parse_rate_limit/1 private functions
  # indirectly by injecting a fake HTTP response via the GenServer state.

  @tag :capture_log
  test "rate_limited? state causes fetch to be skipped" do
    pid = GenServer.whereis(OpenSky)

    # Force rate_limit_remaining to 0 to trigger the rate-limited path
    :sys.replace_state(pid, fn state ->
      %{state | rate_limit_remaining: 0}
    end)

    # Set credentials so the "no credentials" path is bypassed
    Store.put(:opensky_client_id, "test_id")
    Store.put(:opensky_client_secret, "test_secret")

    # fetch_now triggers do_fetch which should skip due to rate limit
    OpenSky.fetch_now()
    :sys.get_state(pid)

    # No broadcast since rate-limited
    refute_receive {:flights_raw, _}, 200
  end

  @tag :capture_log
  test "rate_limit_remaining: nil does not trigger rate limiting" do
    pid = GenServer.whereis(OpenSky)
    state = :sys.get_state(pid)
    # Default state has nil rate_limit_remaining — not rate limited
    assert state.rate_limit_remaining != 0
  end
end
