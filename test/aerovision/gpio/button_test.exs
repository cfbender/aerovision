defmodule AeroVision.GPIO.ButtonTest do
  use ExUnit.Case, async: true
  use Mimic

  alias AeroVision.GPIO.Button

  # ── helpers ────────────────────────────────────────────────────────────────

  # Send a GPIO interrupt with an explicit timestamp in nanoseconds,
  # matching what Circuits.GPIO v2 sends on real hardware.
  defp gpio_event(pid, value, ts_ns) do
    send(pid, {:circuits_gpio, 26, ts_ns, value})
    # Sync: wait for GenServer to process the message
    :sys.get_state(pid)
  end

  # Convert a millisecond offset to nanoseconds for use in gpio_event.
  defp ms_to_ns(ms), do: ms * 1_000_000

  defp press_and_release(pid, held_ms) do
    now = System.monotonic_time(:nanosecond)
    gpio_event(pid, 0, now)
    gpio_event(pid, 1, now + ms_to_ns(held_ms))
  end

  # ── setup ──────────────────────────────────────────────────────────────────

  setup do
    AeroVision.Config.Store.reset()

    # Stub Network.Manager.force_ap_mode so long-press tests don't need
    # the real Network.Manager process.
    stub(AeroVision.Network.Manager, :force_ap_mode, fn -> :ok end)

    start_supervised!(Button)

    # Extend the Network.Manager stub to the Button GenServer process
    # so calls from within handle_gpio_value reach the stub.
    button_pid = GenServer.whereis(Button)
    allow(AeroVision.Network.Manager, self(), button_pid)

    Phoenix.PubSub.subscribe(AeroVision.PubSub, "gpio")
    :ok
  end

  # ── init on host ────────────────────────────────────────────────────────────

  test "starts successfully on host with gpio: nil in state" do
    pid = GenServer.whereis(Button)
    assert is_pid(pid)
    state = :sys.get_state(pid)
    assert state.gpio == nil
  end

  # ── short press ─────────────────────────────────────────────────────────────

  test "60ms hold is a short press" do
    pid = GenServer.whereis(Button)
    press_and_release(pid, 60)
    assert_receive {:button, :short_press}
  end

  test "200ms hold is a short press" do
    pid = GenServer.whereis(Button)
    press_and_release(pid, 200)
    assert_receive {:button, :short_press}
  end

  test "999ms hold is a short press (just under 1000ms threshold)" do
    pid = GenServer.whereis(Button)
    press_and_release(pid, 999)
    assert_receive {:button, :short_press}
  end

  # ── long press ──────────────────────────────────────────────────────────────

  test "3000ms hold is a long press" do
    pid = GenServer.whereis(Button)
    press_and_release(pid, 3000)
    assert_receive {:button, :long_press}
  end

  test "5000ms hold is a long press" do
    pid = GenServer.whereis(Button)
    press_and_release(pid, 5000)
    assert_receive {:button, :long_press}
  end

  test "long press calls Network.Manager.force_ap_mode/0" do
    pid = GenServer.whereis(Button)

    # Expect exactly one call to force_ap_mode
    expect(AeroVision.Network.Manager, :force_ap_mode, fn -> :ok end)

    press_and_release(pid, 3000)
    assert_receive {:button, :long_press}
  end

  # ── medium press (no broadcast) ─────────────────────────────────────────────

  test "1000ms hold is a medium press — no broadcast" do
    pid = GenServer.whereis(Button)
    press_and_release(pid, 1000)
    refute_receive {:button, _}, 50
  end

  test "2000ms hold is a medium press — no broadcast" do
    pid = GenServer.whereis(Button)
    press_and_release(pid, 2000)
    refute_receive {:button, _}, 50
  end

  test "2999ms hold is a medium press (just under long threshold) — no broadcast" do
    pid = GenServer.whereis(Button)
    press_and_release(pid, 2999)
    refute_receive {:button, _}, 50
  end

  # ── release without press ───────────────────────────────────────────────────

  test "release event with no prior press produces no broadcast and no crash" do
    pid = GenServer.whereis(Button)
    now = System.monotonic_time(:nanosecond)
    gpio_event(pid, 1, now)
    refute_receive {:button, _}, 50
    assert Process.alive?(pid)
  end

  # ── debounce ────────────────────────────────────────────────────────────────

  test "second event within 50ms debounce window is ignored" do
    pid = GenServer.whereis(Button)
    now = System.monotonic_time(:nanosecond)

    # First press at t=now — sets last_event
    gpio_event(pid, 0, now)

    # Second press 10ms later — within the 50ms debounce window, should be ignored
    gpio_event(pid, 0, now + ms_to_ns(10))

    # Release 100ms after first press — clears debounce, produces one short press
    gpio_event(pid, 1, now + ms_to_ns(100))

    assert_receive {:button, :short_press}
    refute_receive {:button, _}, 50
  end

  test "events more than 50ms apart are each processed" do
    pid = GenServer.whereis(Button)
    now = System.monotonic_time(:nanosecond)

    # First press-release cycle
    gpio_event(pid, 0, now)
    gpio_event(pid, 1, now + ms_to_ns(100))
    assert_receive {:button, :short_press}

    # Second press-release cycle starting 200ms after the first press
    gpio_event(pid, 0, now + ms_to_ns(200))
    gpio_event(pid, 1, now + ms_to_ns(300))
    assert_receive {:button, :short_press}
  end

  # ── state after press ────────────────────────────────────────────────────────

  test "press_start is cleared after release" do
    pid = GenServer.whereis(Button)
    press_and_release(pid, 100)
    assert_receive {:button, :short_press}

    state = :sys.get_state(pid)
    assert state.press_start == nil
  end

  test "three sequential short presses each produce a broadcast" do
    pid = GenServer.whereis(Button)
    now = System.monotonic_time(:nanosecond)

    gpio_event(pid, 0, now)
    gpio_event(pid, 1, now + ms_to_ns(100))
    assert_receive {:button, :short_press}

    gpio_event(pid, 0, now + ms_to_ns(200))
    gpio_event(pid, 1, now + ms_to_ns(300))
    assert_receive {:button, :short_press}

    gpio_event(pid, 0, now + ms_to_ns(400))
    gpio_event(pid, 1, now + ms_to_ns(500))
    assert_receive {:button, :short_press}
  end
end
