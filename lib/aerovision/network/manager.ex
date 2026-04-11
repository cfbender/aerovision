defmodule AeroVision.Network.Manager do
  @moduledoc """
  WiFi and AP mode network management for AeroVision.

  Manages WiFi connectivity with a reboot-retry strategy on disconnection:

  - On boot, reads WiFi credentials from `AeroVision.Config.Store`.
  - If credentials exist, configures VintageNet for infrastructure (client) mode.
  - If no credentials exist, immediately enters AP mode (`"AeroVision-Setup-XXXX"` per device).
  - Monitors connection state; reboots after 60 s of disconnection so VintageNet
    gets a clean driver state and retries the stored credentials on next boot.
  - AP mode is entered when no credentials exist, when `wifi_force_ap` is set,
    or via `force_ap_mode/0` (e.g. long-press of physical button).
  - Responds to external triggers: `force_ap_mode/0`, `connect_wifi/2`.
  - Safe to run on host (development) — VintageNet calls are no-ops when not on target.
  - Publishes `{:network, :ap_mode}` and `{:network, :connected, ip}` via PubSub.
  """

  use GenServer

  alias AeroVision.Config.Store

  require Logger

  @pubsub AeroVision.PubSub
  @topic "network"

  @interface "wlan0"
  @ap_ssid_base "AeroVision-Setup"
  @ap_ip "192.168.24.1"
  @ap_dhcp_start "192.168.24.2"
  @ap_dhcp_end "192.168.24.200"
  @ap_max_leases 128
  @reconnect_timeout_ms 60_000

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return the current network mode: `:infrastructure`, `:ap`, or `:disconnected`."
  def current_mode do
    GenServer.call(__MODULE__, :current_mode)
  end

  @doc "Return the current IPv4 address string, or `nil` if unavailable."
  def current_ip do
    GenServer.call(__MODULE__, :current_ip)
  end

  @doc """
  Save WiFi credentials and immediately attempt to connect in infrastructure mode.

  Called by `SetupLive` after the user submits the WiFi form.
  """
  def connect_wifi(ssid, password) do
    GenServer.call(__MODULE__, {:connect_wifi, ssid, password})
  end

  @doc "Force a switch to AP mode immediately (e.g. from GPIO long-press)."
  def force_ap_mode do
    GenServer.cast(__MODULE__, :force_ap_mode)
  end

  @doc "Return setup AP SSID from runtime config (fallback: wlan0 MAC suffix)."
  def setup_ap_ssid do
    configured_setup_ap_ssid() || derive_ap_ssid(wlan_mac_address())
  end

  @doc "Return setup AP IPv4 address."
  def setup_ap_ip, do: @ap_ip

  @doc """
  Trigger a WiFi scan and wait for results. Returns a list of maps with
  `:ssid`, `:signal`, and `:security`. Only works on target; returns `[]` on host.

  VintageNet stores results as a list of `%VintageNetWiFi.AccessPoint{}` structs
  at `["interface", "wlan0", "wifi", "access_points"]`.
  """
  def scan_networks do
    if on_target?() do
      try do
        # Subscribe to property changes so we know when scan results arrive.
        VintageNet.subscribe(["interface", @interface, "wifi", "access_points"])

        # Trigger the scan.
        VintageNet.scan(@interface)

        # Wait up to 10s for a property update — much more reliable than sleeping.
        results =
          receive do
            {VintageNet, ["interface", @interface, "wifi", "access_points"], _old, aps, _meta}
            when is_list(aps) ->
              parse_access_points(aps)
          after
            10_000 ->
              # Timeout — try reading whatever is there already
              case VintageNet.get(["interface", @interface, "wifi", "access_points"]) do
                aps when is_list(aps) -> parse_access_points(aps)
                _ -> []
              end
          end

        VintageNet.unsubscribe(["interface", @interface, "wifi", "access_points"])
        results
      rescue
        e ->
          Logger.warning("[Network.Manager] scan_networks failed: #{inspect(e)}")
          []
      end
    else
      []
    end
  end

  # Parse a list of %VintageNetWiFi.AccessPoint{} structs into plain maps.
  # Deduplicates by SSID, keeping the strongest signal per SSID.
  defp parse_access_points(aps) when is_list(aps) do
    aps
    |> Enum.filter(&(is_binary(&1.ssid) and &1.ssid != ""))
    |> Enum.group_by(& &1.ssid)
    |> Enum.map(fn {ssid, entries} ->
      best = Enum.max_by(entries, & &1.signal_dbm)
      flags = best.flags || []

      security =
        cond do
          Enum.any?(
            flags,
            &(&1 in [
                :wpa2,
                :rsn_ccmp,
                :wpa2_psk_ccmp,
                :wpa2_sae_ccmp,
                :wpa2_psk_ccmp_tkip,
                :wpa2_eap_ccmp
              ])
          ) ->
            "WPA2"

          Enum.any?(flags, &(&1 in [:wpa, :wpa_psk_ccmp, :wpa_psk_ccmp_tkip, :wpa_eap_ccmp])) ->
            "WPA"

          Enum.member?(flags, :wep) ->
            "WEP"

          true ->
            "Open"
        end

      %{ssid: ssid, signal: best.signal_dbm, security: security}
    end)
    |> Enum.sort_by(& &1.signal, :desc)
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # deconfigure usb0 to prevent it from interfering with our connection monitoring and fallback logic.
    if on_target?() do
      Logger.info("[Network.Manager] Deconfiguring usb0 to prevent interference with connection monitoring")
      :ok = VintageNet.deconfigure("usb0")
    end

    # Subscribe to VintageNet connection-state changes
    vintage_net_subscribe(["interface", @interface, "connection"])

    ssid = Store.get(:wifi_ssid)
    password = Store.get(:wifi_password)
    force_ap = Store.get(:wifi_force_ap) == true

    state =
      if credentials_present?(ssid, password) and not force_ap do
        Logger.info("[Network.Manager] Credentials found — starting in infrastructure mode")

        # Check if VintageNet already connected wlan0 from its boot config.
        # If so, skip reconfiguration — the brcmfmac driver on the Pi Zero 2 W
        # cannot reliably handle runtime wlan0 teardown/restart and may leave
        # the interface unable to pass traffic despite appearing associated.
        # On host/test, on_target?() is false so we always call configure_infrastructure.
        already_connected? =
          on_target?() and
            vintage_net_get(["interface", @interface, "connection"]) in [:internet, :lan] and
            not ap_mode_active?()

        if already_connected? do
          Logger.info("[Network.Manager] wlan0 already connected — skipping reconfiguration")
        else
          configure_infrastructure(ssid, password)
        end

        %{mode: :infrastructure, reconnect_timer: nil, ssid: ssid}
      else
        if force_ap do
          Logger.info("[Network.Manager] wifi_force_ap enabled — starting in AP mode")
        else
          Logger.info("[Network.Manager] No credentials — starting in AP mode")
        end

        ap_ssid = setup_ap_ssid()

        # If wlan0 already booted in AP mode from VintageNet's compile-time
        # config and SSID already matches expected per-device value, avoid
        # runtime reconfiguration churn and keep the AP stable.
        if ap_mode_active?(ap_ssid) do
          Logger.info(
            "[Network.Manager] AP already active from boot config with SSID #{ap_ssid} — skipping reconfiguration"
          )
        else
          configure_ap(ap_ssid)
        end

        broadcast_ap_mode()
        %{mode: :ap, reconnect_timer: nil, ssid: nil}
      end

    {:ok, state}
  end

  # --- Synchronous calls ------------------------------------------------------

  @impl true
  def handle_call(:current_mode, _from, state) do
    {:reply, state.mode, state}
  end

  @impl true
  def handle_call(:current_ip, _from, state) do
    {:reply, fetch_ip(), state}
  end

  @impl true
  def handle_call({:connect_wifi, ssid, password}, _from, state) do
    Logger.info("[Network.Manager] connect_wifi called for SSID: #{ssid}")

    Store.put(:wifi_ssid, ssid)
    Store.put(:wifi_password, password)
    Store.put(:wifi_force_ap, false)

    state = cancel_reconnect_timer(state)

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:network, :connecting, ssid})

    # The brcmfmac driver on the Pi Zero 2 W cannot reliably switch from AP
    # mode to station mode at runtime. VintageNet persists the config to disk,
    # so a reboot picks it up cleanly. Schedule a reboot after a short delay
    # to let the UI update and the response reach the browser.
    if on_target?() do
      Process.send_after(self(), :reboot_for_wifi, 3_000)
    else
      configure_infrastructure(ssid, password)
    end

    {:reply, :ok, %{state | mode: :connecting, ssid: ssid}}
  end

  # --- Asynchronous casts ------------------------------------------------------

  @impl true
  def handle_cast(:force_ap_mode, state) do
    Logger.info("[Network.Manager] force_ap_mode triggered")
    state = cancel_reconnect_timer(state)
    Store.put(:wifi_force_ap, true)

    if on_target?() do
      # On Pi Zero 2 W, STA/AP runtime switching can leave wlan0 in a bad state.
      # Persist AP intent and reboot so AP starts cleanly at boot.
      Logger.info("[Network.Manager] AP force flag saved — rebooting to apply AP mode cleanly")
      broadcast_ap_mode()
      Process.send_after(self(), :reboot_for_ap, 1_500)
      {:noreply, %{state | mode: :ap, ssid: nil}}
    else
      configure_ap(setup_ap_ssid())
      broadcast_ap_mode()
      {:noreply, %{state | mode: :ap, ssid: nil}}
    end
  end

  # --- Info messages -----------------------------------------------------------

  # VintageNet property-change messages arrive as:
  # {VintageNet, ["interface", iface, "connection"], old_value, new_value, metadata}
  @impl true
  def handle_info({VintageNet, ["interface", @interface, "connection"], _old, new_value, _meta}, state) do
    Logger.info("[Network.Manager] Connection event on #{@interface}: #{inspect(new_value)}")
    state = handle_connection_change(new_value, state)
    {:noreply, state}
  end

  # Ignore config store changes — WiFi connections are initiated explicitly via
  # connect_wifi/2, never automatically on credential saves. This prevents the
  # AP from being torn down when credentials are written during the setup wizard.
  @impl true
  def handle_info({:config_changed, _key, _value}, state) do
    {:noreply, state}
  end

  # Reboot to cleanly apply new WiFi credentials (brcmfmac AP→STA workaround)
  @impl true
  def handle_info(:reboot_for_wifi, state) do
    Logger.info("[Network.Manager] Rebooting to apply WiFi config for SSID: #{state.ssid}")
    Nerves.Runtime.reboot()
    {:noreply, state}
  end

  # Reboot to cleanly apply forced AP mode (brcmfmac STA→AP workaround)
  @impl true
  def handle_info(:reboot_for_ap, state) do
    Logger.info("[Network.Manager] Rebooting to apply forced AP mode")

    if on_target?() do
      Nerves.Runtime.reboot()
    end

    {:noreply, state}
  end

  # Reconnect timer fired — still disconnected; reboot to retry WiFi with a clean driver state
  @impl true
  def handle_info(:reconnect_timeout, state) do
    Logger.warning("[Network.Manager] Reconnect timeout — rebooting to retry WiFi")

    if on_target?() do
      Nerves.Runtime.reboot()
    else
      ssid = Store.get(:wifi_ssid)
      password = Store.get(:wifi_password)

      if credentials_present?(ssid, password) do
        configure_infrastructure(ssid, password)
      end
    end

    {:noreply, %{state | reconnect_timer: nil}}
  end

  # Ignore any other messages (e.g. PubSub broadcasts we subscribe to but don't handle)
  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp credentials_present?(ssid, password) do
    is_binary(ssid) and ssid != "" and is_binary(password) and password != ""
  end

  # Returns true if wlan0's current VintageNet config is AP mode.
  # Used to distinguish AP mode (which also reports :lan) from infrastructure
  # mode so we don't skip reconfiguration when AP mode was persisted on boot.
  # Must only be called on target (where vintage_net_get returns real data).
  defp ap_mode_active?(expected_ssid \\ nil) do
    if on_target?() do
      case vintage_net_get(["interface", @interface, "config"]) do
        %{vintage_net_wifi: %{networks: [%{mode: :ap} = network | _]}} ->
          ap_ssid_matches?(network, expected_ssid)

        _ ->
          false
      end
    else
      false
    end
  end

  # --- VintageNet configuration -----------------------------------------------

  defp configure_infrastructure(ssid, password) do
    Logger.info("[Network.Manager] Configuring infrastructure mode for SSID: #{ssid}")

    vintage_net_configure(@interface, %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        networks: [%{ssid: ssid, psk: password, key_mgmt: :wpa_psk}]
      },
      ipv4: %{method: :dhcp}
    })
  end

  defp configure_ap(ssid) do
    Logger.info("[Network.Manager] Configuring AP mode (SSID: #{ssid})")

    vintage_net_configure(@interface, %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        networks: [%{mode: :ap, ssid: ssid, key_mgmt: :none}]
      },
      ipv4: %{
        method: :static,
        address: setup_ap_ip(),
        netmask: "255.255.255.0"
      },
      dhcpd: %{
        start: @ap_dhcp_start,
        end: @ap_dhcp_end,
        max_leases: @ap_max_leases
      }
    })
  end

  # --- Connection change handling ---------------------------------------------

  defp handle_connection_change(:internet, state) do
    case state.mode do
      :ap ->
        # AP mode may report :internet/:lan for local interface activity.
        # Stay in AP mode and ignore these as infrastructure transitions.
        Logger.debug("[Network.Manager] :internet event while in AP mode — ignoring")
        state

      _ ->
        Logger.info("[Network.Manager] Connected to internet")
        state = cancel_reconnect_timer(state)
        ip = fetch_ip()
        broadcast_connected(ip)
        %{state | mode: :infrastructure}
    end
  end

  defp handle_connection_change(:lan, state) do
    case state.mode do
      :ap ->
        # AP mode's own LAN state is expected. Don't mutate mode.
        Logger.debug("[Network.Manager] :lan event while in AP mode — ignoring")
        state

      _ ->
        Logger.info("[Network.Manager] Connected to LAN (no internet)")
        state = cancel_reconnect_timer(state)
        ip = fetch_ip()
        broadcast_connected(ip)
        %{state | mode: :infrastructure}
    end
  end

  defp handle_connection_change(:disconnected, %{mode: :infrastructure} = state) do
    Logger.warning("[Network.Manager] Disconnected — starting #{@reconnect_timeout_ms}ms fallback timer")

    Phoenix.PubSub.broadcast(@pubsub, @topic, {:network, :disconnected})
    state = cancel_reconnect_timer(state)
    timer = Process.send_after(self(), :reconnect_timeout, @reconnect_timeout_ms)
    %{state | mode: :disconnected, reconnect_timer: timer}
  end

  defp handle_connection_change(:disconnected, state) do
    # Already in AP or disconnected mode — no timer needed
    Logger.debug("[Network.Manager] Disconnected event (mode: #{state.mode}) — no action")
    state
  end

  defp handle_connection_change(other, state) do
    Logger.debug("[Network.Manager] Unhandled connection value: #{inspect(other)}")
    state
  end

  defp cancel_reconnect_timer(%{reconnect_timer: nil} = state), do: state

  defp cancel_reconnect_timer(%{reconnect_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | reconnect_timer: nil}
  end

  defp configured_setup_ap_ssid do
    case Application.get_env(:aerovision, :setup_ap_ssid) do
      ssid when is_binary(ssid) and ssid != "" -> ssid
      _ -> nil
    end
  end

  defp derive_ap_ssid(nil), do: @ap_ssid_base

  defp derive_ap_ssid(mac_address) do
    case mac_suffix(mac_address) do
      nil -> @ap_ssid_base
      suffix -> "#{@ap_ssid_base}-#{suffix}"
    end
  end

  defp wlan_mac_address do
    path = Path.join(["/sys/class/net", @interface, "address"])

    case File.read(path) do
      {:ok, mac} ->
        String.trim(mac)

      {:error, _reason} ->
        case vintage_net_get(["interface", @interface, "mac_address"]) do
          mac when is_binary(mac) -> String.trim(mac)
          _ -> nil
        end
    end
  end

  defp mac_suffix(mac_address) when is_binary(mac_address) do
    cleaned =
      mac_address
      |> String.trim()
      |> String.replace(":", "")
      |> String.replace("-", "")
      |> String.upcase()

    if String.match?(cleaned, ~r/\A[0-9A-F]{12}\z/) do
      String.slice(cleaned, byte_size(cleaned) - 4, 4)
    end
  end

  defp mac_suffix(_), do: nil

  defp ap_ssid_matches?(_network, nil), do: true

  defp ap_ssid_matches?(network, expected_ssid) do
    Map.get(network, :ssid) == expected_ssid
  end

  # --- IP address helper -------------------------------------------------------

  defp fetch_ip do
    if on_target?() do
      case vintage_net_get(["interface", @interface, "addresses"]) do
        addresses when is_list(addresses) ->
          addresses
          |> Enum.find(&ipv4?/1)
          |> case do
            %{address: addr} -> to_string(:inet.ntoa(addr))
            nil -> nil
          end

        _ ->
          nil
      end
    else
      "127.0.0.1"
    end
  end

  defp ipv4?(%{family: :inet}), do: true
  defp ipv4?(_), do: false

  # --- PubSub broadcasts -------------------------------------------------------

  defp broadcast_ap_mode do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:network, :ap_mode})
  end

  defp broadcast_connected(ip) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:network, :connected, ip})
  end

  # --- VintageNet target safety wrappers ---------------------------------------

  defp on_target? do
    target = Application.get_env(:aerovision, :target, :host)
    target != :host and target != :test
  end

  defp vintage_net_configure(interface, config) do
    if on_target?() do
      VintageNet.configure(interface, config)
    else
      Logger.debug("[Network.Manager] (host) VintageNet.configure #{interface} — skipped")
    end
  end

  defp vintage_net_subscribe(property) do
    if on_target?() do
      VintageNet.subscribe(property)
    else
      Logger.debug("[Network.Manager] (host) VintageNet.subscribe #{inspect(property)} — skipped")
    end
  end

  defp vintage_net_get(property) do
    if on_target?() do
      apply(VintageNet, :get, [property])
    end
  end
end
