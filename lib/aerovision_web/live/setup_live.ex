defmodule AeroVisionWeb.SetupLive do
  @moduledoc false
  use AeroVisionWeb, :live_view

  alias AeroVision.Network.Manager

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AeroVision.PubSub, "network")
      # Disarm the network watchdog — a client has successfully reached the UI
      AeroVision.Network.Watchdog.ping()
    end

    network_mode = Manager.current_mode()
    ip = Manager.current_ip()

    {:ok,
     assign(socket,
       page_title: "WiFi Setup",
       network_mode: network_mode,
       ip: ip,
       ssid: "",
       password: "",
       scan_results: [],
       scanning: false,
       connecting: false,
       connect_status: nil
     )}
  end

  # ---- PubSub -----------------------------------------------------------------

  @impl true
  def handle_info({:network, :connected, ip}, socket) do
    # NOTE: if we were connecting via AP, the WebSocket likely dropped the moment
    # the AP shut down and this message will never arrive at the browser. The
    # "reconnect" banner below handles that case. If it *does* arrive (e.g. already
    # on infra mode and credentials changed), just update the status.
    {:noreply,
     assign(socket,
       network_mode: :infrastructure,
       ip: ip,
       connecting: false,
       connect_status: {:ok, "Connected! Visit http://aerovision.local to continue."}
     )}
  end

  def handle_info({:network, :ap_mode}, socket) do
    {:noreply,
     assign(socket,
       network_mode: :ap,
       ip: "192.168.24.1",
       connecting: false,
       connect_status: {:error, "Failed to connect — returned to setup mode."}
     )}
  end

  @impl true
  def handle_info({:scan_complete, networks}, socket) do
    status =
      if networks == [] do
        {:info, "No networks found. Make sure you're within range and try again."}
      end

    {:noreply, assign(socket, scanning: false, scan_results: networks, connect_status: status)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # ---- Events -----------------------------------------------------------------

  @impl true
  def handle_event("scan_networks", _params, socket) do
    if on_target?() do
      lv = self()

      Task.start(fn ->
        networks = Manager.scan_networks()
        send(lv, {:scan_complete, networks})
      end)

      {:noreply, assign(socket, scanning: true, scan_results: [])}
    else
      {:noreply,
       assign(socket,
         scanning: false,
         scan_results: [],
         connect_status: {:info, "WiFi scanning is not available in development mode."}
       )}
    end
  end

  def handle_event("select_network", %{"ssid" => ssid}, socket) do
    {:noreply, assign(socket, ssid: ssid)}
  end

  def handle_event("update_ssid", %{"value" => value}, socket) do
    {:noreply, assign(socket, ssid: value)}
  end

  def handle_event("update_password", %{"value" => value}, socket) do
    {:noreply, assign(socket, password: value)}
  end

  def handle_event("connect", %{"wifi" => params}, socket) do
    ssid = String.trim(params["ssid"] || "")
    password = params["password"] || ""

    if ssid == "" do
      {:noreply, assign(socket, connect_status: {:error, "Please enter a network name."})}
    else
      Manager.connect_wifi(ssid, password)

      # The AP will shut down as soon as VintageNet switches to infrastructure mode,
      # which drops this WebSocket connection. Tell the user to reconnect.
      {:noreply,
       assign(socket,
         ssid: ssid,
         connecting: true,
         connect_status:
           {:info,
            "Rebooting to connect to #{ssid}… " <>
              "Reconnect your device to #{ssid} and visit http://aerovision.local"}
       )}
    end
  end

  def handle_event("dismiss_status", _params, socket) do
    {:noreply, assign(socket, connect_status: nil)}
  end

  # ---- Render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="max-w-lg mx-auto space-y-6 pb-12">
        <div class="text-center space-y-2">
          <div class="text-5xl">📡</div>
          <h1 class="text-2xl font-bold text-white">WiFi Setup</h1>
          <p class="text-sm text-gray-400">Connect AeroVision to your home network.</p>
        </div>
        
    <!-- Network Status -->
        <div class={[
          "flex items-center gap-3 px-4 py-3 rounded-lg border",
          @network_mode == :infrastructure &&
            "bg-emerald-950 border-emerald-700 text-emerald-300",
          @network_mode == :ap &&
            "bg-amber-950 border-amber-700 text-amber-300",
          @network_mode not in [:infrastructure, :ap] &&
            "bg-gray-800 border-gray-700 text-gray-300"
        ]}>
          <span class="text-xl shrink-0">
            <%= case @network_mode do %>
              <% :infrastructure -> %>
                ✅
              <% :ap -> %>
                🔶
              <% _ -> %>
                ⏳
            <% end %>
          </span>
          <div class="min-w-0">
            <div class="font-medium text-sm">
              <%= case @network_mode do %>
                <% :infrastructure -> %>
                  Connected to WiFi
                <% :ap -> %>
                  Access Point Mode — connect to "AeroVision-Setup"
                <% _ -> %>
                  Checking network status…
              <% end %>
            </div>
            <div class="font-mono text-xs opacity-70 truncate">
              IP: {@ip}
            </div>
          </div>
        </div>
        
    <!-- Status / Feedback Banner -->
        <%= if @connect_status do %>
          <div class={[
            "flex items-start justify-between gap-3 px-4 py-3 rounded-lg border text-sm",
            elem(@connect_status, 0) == :ok &&
              "bg-emerald-950 border-emerald-700 text-emerald-300",
            elem(@connect_status, 0) == :error &&
              "bg-red-950 border-red-700 text-red-300",
            elem(@connect_status, 0) == :info &&
              "bg-blue-950 border-blue-700 text-blue-300"
          ]}>
            <span>{elem(@connect_status, 1)}</span>
            <button
              phx-click="dismiss_status"
              class="shrink-0 opacity-60 hover:opacity-100 leading-none"
            >
              ✕
            </button>
          </div>
        <% end %>
        
    <!-- Network Scanner -->
        <div class="bg-gray-900 rounded-lg border border-gray-800 overflow-hidden">
          <div class="flex items-center justify-between px-4 py-3 border-b border-gray-800">
            <h2 class="text-sm font-semibold text-gray-300 uppercase tracking-wide">
              Available Networks
            </h2>
            <button
              phx-click="scan_networks"
              disabled={@scanning}
              class="flex items-center gap-1.5 px-3 py-1.5 bg-gray-700 hover:bg-gray-600 disabled:opacity-50 disabled:cursor-not-allowed text-white text-xs font-medium rounded-md transition-colors"
            >
              <%= if @scanning do %>
                <span class="animate-spin">⟳</span> Scanning…
              <% else %>
                <span>⟳</span> Scan
              <% end %>
            </button>
          </div>

          <div class="divide-y divide-gray-800">
            <%= if @scanning do %>
              <div class="px-4 py-6 text-center text-gray-500 text-sm">
                Scanning for networks…
              </div>
            <% else %>
              <%= if @scan_results == [] do %>
                <div class="px-4 py-6 text-center text-gray-500 text-sm">
                  <%= if on_target?() do %>
                    Press "Scan" to find nearby networks.
                  <% else %>
                    WiFi scanning is not available in development mode.
                  <% end %>
                </div>
              <% else %>
                <%= for network <- @scan_results do %>
                  <button
                    phx-click="select_network"
                    phx-value-ssid={network.ssid}
                    class={[
                      "w-full flex items-center justify-between px-4 py-3 text-left hover:bg-gray-800 transition-colors",
                      @ssid == network.ssid && "bg-gray-800"
                    ]}
                  >
                    <div class="flex items-center gap-3">
                      <span class="text-lg"><.signal_icon rssi={network.signal} /></span>
                      <div>
                        <div class="text-sm font-medium text-white">{network.ssid}</div>
                        <div class="text-xs text-gray-500">
                          {signal_label(network.signal)} · {network.security}
                        </div>
                      </div>
                    </div>
                    <%= if @ssid == network.ssid do %>
                      <span class="text-cyan-400 text-xs font-medium">Selected</span>
                    <% end %>
                  </button>
                <% end %>
              <% end %>
            <% end %>
          </div>
        </div>
        
    <!-- Connection Form -->
        <div class="bg-gray-900 rounded-lg border border-gray-800 overflow-hidden">
          <div class="px-4 py-3 border-b border-gray-800">
            <h2 class="text-sm font-semibold text-gray-300 uppercase tracking-wide">
              Connect to Network
            </h2>
          </div>
          <div class="p-4">
            <.form for={%{}} as={:wifi} phx-submit="connect" class="space-y-4">
              <div class="space-y-1">
                <label class="block text-xs text-gray-400 uppercase tracking-wide">
                  Network Name (SSID)
                </label>
                <input
                  type="text"
                  name="wifi[ssid]"
                  value={@ssid}
                  phx-keyup="update_ssid"
                  phx-value-value={@ssid}
                  class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2.5 text-white text-sm focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                  placeholder="MyHomeNetwork"
                  autocomplete="off"
                  autocorrect="off"
                  autocapitalize="none"
                />
              </div>
              <div class="space-y-1">
                <label class="block text-xs text-gray-400 uppercase tracking-wide">Password</label>
                <input
                  type="password"
                  name="wifi[password]"
                  value={@password}
                  phx-keyup="update_password"
                  phx-value-value={@password}
                  class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2.5 text-white text-sm focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                  placeholder="••••••••"
                  autocomplete="new-password"
                />
              </div>
              <button
                type="submit"
                disabled={@connecting}
                class="w-full flex items-center justify-center gap-2 px-4 py-2.5 bg-cyan-700 hover:bg-cyan-600 disabled:opacity-60 disabled:cursor-not-allowed text-white text-sm font-semibold rounded-md transition-colors"
              >
                <%= if @connecting do %>
                  <span class="animate-spin">⟳</span> Connecting…
                <% else %>
                  Connect
                <% end %>
              </button>
            </.form>
          </div>
        </div>

        <p class="text-center text-xs text-gray-600">
          After connecting, the device IP will change. You may need to refresh or navigate to the new address.
        </p>
      </div>
    </Layouts.app>
    """
  end

  # ---- Private Components -----------------------------------------------------

  attr :rssi, :integer, required: true

  defp signal_icon(%{rssi: rssi} = assigns) do
    assigns =
      assign(
        assigns,
        :icon,
        cond do
          rssi >= -50 -> "▂▄▆█"
          rssi >= -65 -> "▂▄▆░"
          rssi >= -80 -> "▂▄░░"
          true -> "▂░░░"
        end
      )

    ~H"""
    <span class="font-mono text-xs text-green-400">{@icon}</span>
    """
  end

  # ---- Helpers ----------------------------------------------------------------

  defp signal_label(rssi) when rssi >= -50, do: "Excellent"
  defp signal_label(rssi) when rssi >= -65, do: "Good"
  defp signal_label(rssi) when rssi >= -80, do: "Fair"
  defp signal_label(_), do: "Weak"

  defp on_target? do
    Application.get_env(:aerovision, :target, :host) != :host
  end
end
