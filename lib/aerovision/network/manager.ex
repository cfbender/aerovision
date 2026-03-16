defmodule AeroVision.Network.Manager do
  @moduledoc """
  WiFi and AP mode network management for AeroVision.

  Manages WiFi connectivity with an AP mode fallback for initial setup:

  - On boot, reads WiFi credentials from `AeroVision.Config.Store`.
  - If credentials exist, configures VintageNet for infrastructure (client) mode.
  - If no credentials exist, immediately enters AP mode (`"AeroVision-Setup"`).
  - Monitors connection state and falls back to AP mode after 30 s of disconnection.
  - Responds to external triggers: `force_ap_mode/0`, `connect_wifi/2`.
  - Safe to run on host (development) — VintageNet calls are no-ops when not on target.
  - Publishes `{:network, :ap_mode}` and `{:network, :connected, ip}` via PubSub.
  """

  use GenServer

  require Logger

  @pubsub AeroVision.PubSub
  @topic "network"

  @interface "wlan0"
  @ap_ssid "AeroVision-Setup"
  @ap_ip "192.168.24.1"
  @reconnect_timeout_ms 30_000

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

  @doc """
  Scan for available WiFi networks. Returns a list of maps with `:ssid`, `:signal`, and `:security`.
  Only works on target; returns `[]` on host.
  """
  def scan_networks do
    if Application.get_env(:aerovision, :target, :host) != :host do
      try do
        case VintageNet.get(["interface", "wlan0", "wifi", "access_points"]) do
          aps when is_map(aps) ->
            aps
            |> Enum.map(fn {ssid, info} ->
              %{
                ssid: ssid,
                signal: Map.get(info, :signal_dbm, -80),
                security:
                  if(Map.get(info, :flags, []) |> Enum.any?(&(&1 == :wpa2_psk)),
                    do: "WPA2",
                    else: "Open"
                  )
              }
            end)
            |> Enum.sort_by(& &1.signal, :desc)

          _ ->
            []
        end
      rescue
        _ -> []
      end
    else
      []
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # Subscribe to VintageNet connection-state changes
    vintage_net_subscribe(["interface", @interface, "connection"])

    # Subscribe to config store changes (WiFi credential updates)
    AeroVision.Config.Store.subscribe()

    ssid = AeroVision.Config.Store.get(:wifi_ssid)
    password = AeroVision.Config.Store.get(:wifi_password)

    state =
      if credentials_present?(ssid, password) do
        Logger.info("[Network.Manager] Credentials found — starting in infrastructure mode")
        configure_infrastructure(ssid, password)
        %{mode: :infrastructure, reconnect_timer: nil, ssid: ssid}
      else
        Logger.info("[Network.Manager] No credentials — starting in AP mode")
        configure_ap()
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

    AeroVision.Config.Store.put(:wifi_ssid, ssid)
    AeroVision.Config.Store.put(:wifi_password, password)

    state = cancel_reconnect_timer(state)
    configure_infrastructure(ssid, password)

    {:reply, :ok, %{state | mode: :infrastructure, ssid: ssid}}
  end

  # --- Asynchronous casts ------------------------------------------------------

  @impl true
  def handle_cast(:force_ap_mode, state) do
    Logger.info("[Network.Manager] force_ap_mode triggered")
    state = cancel_reconnect_timer(state)
    configure_ap()
    broadcast_ap_mode()
    {:noreply, %{state | mode: :ap}}
  end

  # --- Info messages -----------------------------------------------------------

  # VintageNet property-change messages arrive as:
  # {VintageNet, ["interface", iface, "connection"], old_value, new_value, metadata}
  @impl true
  def handle_info(
        {VintageNet, ["interface", @interface, "connection"], _old, new_value, _meta},
        state
      ) do
    Logger.info("[Network.Manager] Connection event on #{@interface}: #{inspect(new_value)}")
    state = handle_connection_change(new_value, state)
    {:noreply, state}
  end

  # Config-store change: WiFi SSID or password updated externally
  @impl true
  def handle_info({:config_changed, key, _value}, state)
      when key in [:wifi_ssid, :wifi_password] do
    Logger.info("[Network.Manager] WiFi credentials changed (#{key}) — reconnecting")

    ssid = AeroVision.Config.Store.get(:wifi_ssid)
    password = AeroVision.Config.Store.get(:wifi_password)

    if credentials_present?(ssid, password) do
      state = cancel_reconnect_timer(state)
      configure_infrastructure(ssid, password)
      {:noreply, %{state | mode: :infrastructure, ssid: ssid}}
    else
      {:noreply, state}
    end
  end

  # Ignore other config changes
  @impl true
  def handle_info({:config_changed, _key, _value}, state) do
    {:noreply, state}
  end

  # Reconnect timer fired — still disconnected; fall back to AP mode
  @impl true
  def handle_info(:reconnect_timeout, state) do
    Logger.warning(
      "[Network.Manager] Reconnect timeout — still disconnected, switching to AP mode"
    )

    configure_ap()
    broadcast_ap_mode()
    {:noreply, %{state | mode: :ap, reconnect_timer: nil}}
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

  defp configure_ap do
    Logger.info("[Network.Manager] Configuring AP mode (SSID: #{@ap_ssid})")

    vintage_net_configure(@interface, %{
      type: VintageNetWiFi,
      vintage_net_wifi: %{
        networks: [%{mode: :ap, ssid: @ap_ssid, key_mgmt: :none}]
      },
      ipv4: %{
        method: :static,
        address: @ap_ip,
        netmask: "255.255.255.0"
      },
      dhcpd: %{
        start: "192.168.24.2",
        end: "192.168.24.10",
        options: %{
          dns: [@ap_ip],
          subnet: "255.255.255.0",
          router: [@ap_ip]
        }
      }
    })
  end

  # --- Connection change handling ---------------------------------------------

  defp handle_connection_change(:internet, state) do
    Logger.info("[Network.Manager] Connected to internet")
    state = cancel_reconnect_timer(state)
    ip = fetch_ip()
    broadcast_connected(ip)
    %{state | mode: :infrastructure}
  end

  defp handle_connection_change(:lan, state) do
    Logger.info("[Network.Manager] Connected to LAN (no internet)")
    state = cancel_reconnect_timer(state)
    ip = fetch_ip()
    broadcast_connected(ip)
    %{state | mode: :infrastructure}
  end

  defp handle_connection_change(:disconnected, %{mode: :infrastructure} = state) do
    Logger.warning(
      "[Network.Manager] Disconnected — starting #{@reconnect_timeout_ms}ms fallback timer"
    )

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
      VintageNet.get(property)
    else
      nil
    end
  end
end
