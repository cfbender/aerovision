defmodule AeroVisionWeb.DashboardLive do
  use AeroVisionWeb, :live_view

  alias AeroVision.Flight.Tracker
  alias AeroVision.Flight.AircraftCodes
  alias AeroVision.Display.Renderer

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AeroVision.PubSub, "display")
      Phoenix.PubSub.subscribe(AeroVision.PubSub, "network")
      Phoenix.PubSub.subscribe(AeroVision.PubSub, "config")
      # Ask Tracker to re-broadcast current state so we don't wait for the next poll
      AeroVision.Flight.Tracker.broadcast_now()
      # Disarm the network watchdog — a client has successfully reached the UI
      AeroVision.Network.Watchdog.ping()
    end

    config = AeroVision.Config.Store.all()
    flights = Tracker.get_flights()
    network_mode = AeroVision.Network.Manager.current_mode()
    ip = AeroVision.Network.Manager.current_ip()

    setup_step = compute_setup_step(config)

    {:ok,
     assign(socket,
       page_title: if(setup_step != :done, do: "Setup", else: "Dashboard"),
       flights: flights,
       mode: config.display_mode,
       network_mode: network_mode,
       ip: ip,
       # Setup wizard
       setup_step: setup_step,
       setup_complete: setup_step == :done,
       wizard_ssid: "",
       wizard_password: "",
       wizard_wifi_saved: false,
       wizard_connecting: false,
       wizard_scan_results: [],
       wizard_scanning: false
     )}
  end

  @impl true
  def handle_info({:display_flights, flights}, socket) do
    {:noreply, assign(socket, flights: flights)}
  end

  def handle_info({:network, :connected, ip}, socket) do
    {:noreply, assign(socket, network_mode: :infrastructure, ip: ip)}
  end

  def handle_info({:network, :ap_mode}, socket) do
    {:noreply, assign(socket, network_mode: :ap, ip: "192.168.24.1")}
  end

  def handle_info({:config_changed, _key, _value}, socket) do
    config = AeroVision.Config.Store.all()
    setup_step = compute_setup_step(config)
    {:noreply, assign(socket, setup_step: setup_step, setup_complete: setup_step == :done)}
  end

  def handle_info({:wizard_scan_complete, networks}, socket) do
    {:noreply, assign(socket, wizard_scanning: false, wizard_scan_results: networks)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # ---- Setup Wizard -----------------------------------------------------------

  @impl true
  def handle_event("setup_wifi", %{"wifi" => params}, socket) do
    ssid = String.trim(params["ssid"] || "")
    password = params["password"] || ""

    if ssid != "" do
      # Save credentials now so later steps can read them, but defer the
      # actual WiFi connection until setup is complete — connecting immediately
      # would drop the AP and disconnect the browser before setup is done.
      AeroVision.Config.Store.put(:wifi_ssid, ssid)
      AeroVision.Config.Store.put(:wifi_password, password)

      config = AeroVision.Config.Store.all()

      {:noreply,
       assign(socket,
         wizard_ssid: ssid,
         wizard_password: password,
         wizard_wifi_saved: true,
         setup_step: compute_setup_step(config)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("setup_api_keys", %{"api_keys" => params}, socket) do
    skylink_api_key = String.trim(params["skylink_api_key"] || "")
    opensky_id = String.trim(params["opensky_client_id"] || "")
    opensky_secret = String.trim(params["opensky_client_secret"] || "")

    if skylink_api_key != "" do
      AeroVision.Config.Store.put(:skylink_api_key, skylink_api_key)
    end

    AeroVision.Config.Store.put(
      :opensky_client_id,
      if(opensky_id == "", do: nil, else: opensky_id)
    )

    AeroVision.Config.Store.put(
      :opensky_client_secret,
      if(opensky_secret == "", do: nil, else: opensky_secret)
    )

    config = AeroVision.Config.Store.all()
    {:noreply, assign(socket, setup_step: compute_setup_step(config))}
  end

  def handle_event("setup_location", %{"location" => params}, socket) do
    lat = parse_float(params["lat"])
    lon = parse_float(params["lon"])
    radius_mi = parse_float(params["radius_mi"])

    if lat && lon && radius_mi do
      AeroVision.Config.Store.put(:location_lat, lat)
      AeroVision.Config.Store.put(:location_lon, lon)
      AeroVision.Config.Store.put(:radius_km, Float.round(radius_mi * 1.60934, 2))
    end

    config = AeroVision.Config.Store.all()
    next_step = compute_setup_step(config)

    # Setup complete — now trigger WiFi connection if credentials were entered.
    # This is deferred to here so the browser stays connected to the AP long
    # enough for the user to finish all steps.
    connecting =
      if next_step == :done and socket.assigns.wizard_wifi_saved do
        AeroVision.Network.Manager.connect_wifi(
          socket.assigns.wizard_ssid,
          socket.assigns.wizard_password
        )

        true
      else
        false
      end

    {:noreply,
     assign(socket,
       setup_step: next_step,
       setup_complete: next_step == :done,
       wizard_connecting: connecting
     )}
  end

  def handle_event("wizard_scan_wifi", _params, socket) do
    if Application.get_env(:aerovision, :target, :host) != :host do
      lv = self()

      Task.start(fn ->
        networks = AeroVision.Network.Manager.scan_networks()
        send(lv, {:wizard_scan_complete, networks})
      end)

      {:noreply, assign(socket, wizard_scanning: true, wizard_scan_results: [])}
    else
      {:noreply, assign(socket, wizard_scanning: false, wizard_scan_results: [])}
    end
  end

  def handle_event("wizard_select_network", %{"ssid" => ssid}, socket) do
    {:noreply, assign(socket, wizard_ssid: ssid)}
  end

  def handle_event("setup_wifi_redo", _params, socket) do
    {:noreply, assign(socket, wizard_wifi_saved: false, wizard_ssid: "", wizard_password: "")}
  end

  def handle_event("skip_setup", _params, socket) do
    connecting =
      if socket.assigns.wizard_wifi_saved do
        AeroVision.Network.Manager.connect_wifi(
          socket.assigns.wizard_ssid,
          socket.assigns.wizard_password
        )

        true
      else
        false
      end

    {:noreply,
     assign(socket, setup_step: :done, setup_complete: true, wizard_connecting: connecting)}
  end

  def handle_event("skip_step", _params, socket) do
    next_step =
      case socket.assigns.setup_step do
        :wifi -> :api_keys
        :api_keys -> :location
        :location -> :done
        _ -> :done
      end

    connecting =
      if next_step == :done and socket.assigns.wizard_wifi_saved do
        AeroVision.Network.Manager.connect_wifi(
          socket.assigns.wizard_ssid,
          socket.assigns.wizard_password
        )

        true
      else
        false
      end

    {:noreply,
     assign(socket,
       setup_step: next_step,
       setup_complete: next_step == :done,
       wizard_connecting: connecting
     )}
  end

  # ---- Render Functions -------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <%= if @setup_complete do %>
        <.flight_dashboard {assigns} />
      <% else %>
        <.setup_wizard {assigns} />
      <% end %>
    </Layouts.app>
    """
  end

  defp flight_dashboard(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- WiFi connecting banner --%>
      <%= if @wizard_connecting do %>
        <div class="flex items-start gap-3 px-4 py-3 rounded-lg bg-amber-950 border border-amber-700 text-amber-300 text-sm">
          <span class="text-lg shrink-0 animate-spin">⟳</span>
          <div>
            <div class="font-medium">
              Rebooting to connect to <span class="font-mono">{@wizard_ssid}</span>…
            </div>
            <div class="text-xs opacity-80 mt-0.5">
              The device will reboot in a few seconds. Reconnect your device to
              <span class="font-mono font-medium">{@wizard_ssid}</span>
              and visit <span class="font-mono font-medium">http://aerovision.local</span>
            </div>
          </div>
        </div>
      <% end %>

      <%!-- Status Bar --%>
      <div class="flex items-center justify-between flex-wrap gap-3">
        <div class="flex items-center gap-3">
          <h1 class="text-2xl font-bold text-white">Flight Dashboard</h1>
          <span class={[
            "px-2 py-1 text-xs font-medium rounded-full",
            @network_mode == :infrastructure && "bg-emerald-900 text-emerald-300",
            @network_mode == :ap && "bg-amber-900 text-amber-300",
            @network_mode not in [:infrastructure, :ap] && "bg-gray-700 text-gray-300"
          ]}>
            <%= case @network_mode do %>
              <% :infrastructure -> %>
                Online
              <% :ap -> %>
                Setup Mode
              <% _ -> %>
                Connecting...
            <% end %>
          </span>
        </div>
        <div class="text-sm text-gray-500 flex items-center gap-2">
          <span class="font-mono">{@ip}</span>
          <span>·</span>
          <span>Mode: <span class="text-cyan-400 font-medium">{@mode}</span></span>
          <span>·</span>
          <span class="text-gray-400">{length(@flights)} flights</span>
        </div>
      </div>

      <%!-- Flight Cards --%>
      <%= if @flights == [] do %>
        <div class="text-center py-20">
          <div class="text-6xl mb-4">✈️</div>
          <p class="text-xl text-gray-400">Scanning for flights...</p>
          <p class="text-sm text-gray-600 mt-2">
            Configure your location in
            <.link navigate={~p"/settings"} class="text-cyan-400 hover:underline">Settings</.link>
          </p>
        </div>
      <% else %>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <%= for flight <- @flights do %>
            <.flight_card flight={flight} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp setup_wizard(assigns) do
    ~H"""
    <div class="max-w-lg mx-auto space-y-8 pb-12">
      <%!-- Header --%>
      <div class="text-center space-y-2 pt-4">
        <div class="text-5xl">✈️</div>
        <h1 class="text-2xl font-bold text-white">Welcome to AeroVision</h1>
        <p class="text-sm text-gray-400">Let's get your flight tracker set up.</p>
      </div>

      <%!-- Step indicator --%>
      <div class="flex items-center justify-center gap-2">
        <.step_dot step={:wifi} current={@setup_step} label="WiFi" />
        <div class="w-8 h-px bg-gray-700" />
        <.step_dot step={:api_keys} current={@setup_step} label="API Keys" />
        <div class="w-8 h-px bg-gray-700" />
        <.step_dot step={:location} current={@setup_step} label="Location" />
      </div>

      <%!-- Step content --%>
      <%= case @setup_step do %>
        <% :wifi -> %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 space-y-4">
            <div class="flex items-center gap-3 mb-2">
              <span class="text-2xl">📶</span>
              <div>
                <h2 class="text-lg font-semibold text-white">Connect to WiFi</h2>
                <p class="text-xs text-gray-500">Required for fetching flight data.</p>
              </div>
            </div>

            <%!-- Scan button + results --%>
            <div class="space-y-2">
              <div class="flex items-center justify-between">
                <span class="text-xs text-gray-400 uppercase tracking-wide">Available Networks</span>
                <button
                  phx-click="wizard_scan_wifi"
                  disabled={@wizard_scanning}
                  class="flex items-center gap-1.5 px-2.5 py-1 text-xs font-medium text-gray-300 bg-gray-800 hover:bg-gray-700 disabled:opacity-50 border border-gray-700 rounded-md transition-colors"
                >
                  <%= if @wizard_scanning do %>
                    <span class="animate-spin inline-block">⟳</span> Scanning…
                  <% else %>
                    <span>⟳</span> Scan
                  <% end %>
                </button>
              </div>

              <%= if @wizard_scan_results != [] do %>
                <div class="rounded-md border border-gray-700 overflow-hidden divide-y divide-gray-700/50">
                  <%= for network <- @wizard_scan_results do %>
                    <button
                      type="button"
                      phx-click="wizard_select_network"
                      phx-value-ssid={network.ssid}
                      class={[
                        "w-full flex items-center justify-between px-3 py-2.5 text-left text-sm transition-colors",
                        @wizard_ssid == network.ssid &&
                          "bg-cyan-950 text-cyan-300",
                        @wizard_ssid != network.ssid &&
                          "bg-gray-800/50 hover:bg-gray-800 text-white"
                      ]}
                    >
                      <div class="flex items-center gap-2 min-w-0">
                        <span class="font-mono text-xs text-green-400">
                          {cond do
                            network.signal >= -50 -> "▂▄▆█"
                            network.signal >= -65 -> "▂▄▆░"
                            network.signal >= -80 -> "▂▄░░"
                            true -> "▂░░░"
                          end}
                        </span>
                        <span class="truncate font-medium">{network.ssid}</span>
                        <span class="text-xs text-gray-500 shrink-0">{network.security}</span>
                      </div>
                      <%= if @wizard_ssid == network.ssid do %>
                        <span class="text-xs font-medium shrink-0 ml-2">✓</span>
                      <% end %>
                    </button>
                  <% end %>
                </div>
              <% else %>
                <%= if not @wizard_scanning do %>
                  <p class="text-xs text-gray-600 text-center py-1">
                    {if Application.get_env(:aerovision, :target, :host) != :host,
                      do: "Press Scan to find nearby networks.",
                      else: "WiFi scanning not available in development mode."}
                  </p>
                <% end %>
              <% end %>
            </div>

            <%!-- Connection form or saved confirmation --%>
            <%= if @wizard_wifi_saved do %>
              <div class="flex items-center gap-3 px-4 py-3 rounded-lg bg-emerald-950 border border-emerald-700 text-emerald-300 text-sm">
                <span class="text-lg">✅</span>
                <div class="min-w-0">
                  <div class="font-medium">Network saved</div>
                  <div class="text-xs opacity-70 truncate font-mono">{@wizard_ssid}</div>
                </div>
              </div>
              <p class="text-xs text-gray-500 text-center">
                AeroVision will connect to <span class="text-white font-medium">{@wizard_ssid}</span>
                when setup is complete.
              </p>
              <button
                phx-click="skip_step"
                class="w-full px-4 py-2.5 bg-cyan-700 hover:bg-cyan-600 text-white text-sm font-semibold rounded-md transition-colors"
              >
                Continue →
              </button>
              <button
                phx-click="setup_wifi_redo"
                class="w-full text-center text-xs text-gray-600 hover:text-gray-400 transition-colors py-1"
              >
                Change network
              </button>
            <% else %>
              <.form for={%{}} as={:wifi} phx-submit="setup_wifi" class="space-y-3">
                <div class="space-y-1">
                  <label class="block text-xs text-gray-400 uppercase tracking-wide">
                    Network Name (SSID)
                  </label>
                  <input
                    type="text"
                    name="wifi[ssid]"
                    value={@wizard_ssid}
                    class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2.5 text-white text-sm focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                    placeholder="MyHomeNetwork"
                    autocomplete="off"
                  />
                </div>
                <div class="space-y-1">
                  <label class="block text-xs text-gray-400 uppercase tracking-wide">
                    Password
                  </label>
                  <input
                    type="password"
                    name="wifi[password]"
                    class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2.5 text-white text-sm focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                    placeholder="••••••••"
                    autocomplete="new-password"
                  />
                </div>
                <button
                  type="submit"
                  class="w-full px-4 py-2.5 bg-cyan-700 hover:bg-cyan-600 text-white text-sm font-semibold rounded-md transition-colors"
                >
                  Save & Continue →
                </button>
              </.form>
              <button
                phx-click="skip_step"
                class="w-full text-center text-xs text-gray-600 hover:text-gray-400 transition-colors py-1"
              >
                Skip for now →
              </button>
            <% end %>
          </div>
        <% :api_keys -> %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 space-y-4">
            <div class="flex items-center gap-3 mb-2">
              <span class="text-2xl">🔑</span>
              <div>
                <h2 class="text-lg font-semibold text-white">API Keys</h2>
                <p class="text-xs text-gray-500">Configure at least one ADS-B source.</p>
              </div>
            </div>
            <.form for={%{}} as={:api_keys} phx-submit="setup_api_keys" class="space-y-4">
              <%!-- Skylink section --%>
              <div class="space-y-1">
                <label class="block text-xs text-gray-400 uppercase tracking-wide">
                  Skylink API Key
                </label>
                <input
                  type="password"
                  name="api_keys[skylink_api_key]"
                  value=""
                  class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2.5 text-white text-sm font-mono focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                  placeholder="••••••••"
                  autocomplete="new-password"
                />
                <p class="text-xs text-gray-600">
                  Tracked mode ADS-B + flight status enrichment.
                </p>
              </div>

              <%!-- Divider --%>
              <div class="border-t border-gray-800" />

              <%!-- OpenSky section --%>
              <div class="space-y-3">
                <div class="space-y-1">
                  <label class="block text-xs text-gray-400 uppercase tracking-wide">
                    OpenSky Client ID
                  </label>
                  <input
                    type="text"
                    name="api_keys[opensky_client_id]"
                    value=""
                    class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2.5 text-white text-sm font-mono focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                    placeholder="username"
                    autocomplete="off"
                  />
                </div>
                <div class="space-y-1">
                  <label class="block text-xs text-gray-400 uppercase tracking-wide">
                    OpenSky Client Secret
                  </label>
                  <input
                    type="password"
                    name="api_keys[opensky_client_secret]"
                    value=""
                    class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2.5 text-white text-sm font-mono focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                    placeholder="••••••••"
                    autocomplete="new-password"
                  />
                </div>
                <p class="text-xs text-gray-600">
                  Nearby mode ADS-B (30s updates). Free at
                  <a
                    href="https://opensky-network.org"
                    target="_blank"
                    class="text-cyan-500 hover:underline"
                  >
                    opensky-network.org
                  </a>
                </p>
              </div>

              <button
                type="submit"
                class="w-full px-4 py-2.5 bg-cyan-700 hover:bg-cyan-600 text-white text-sm font-semibold rounded-md transition-colors"
              >
                Save & Continue
              </button>
            </.form>
            <button
              phx-click="skip_step"
              class="w-full text-center text-xs text-gray-600 hover:text-gray-400 transition-colors py-1"
            >
              Skip for now →
            </button>
          </div>
        <% :location -> %>
          <div class="bg-gray-900 rounded-lg border border-gray-800 p-6 space-y-4">
            <div class="flex items-center gap-3 mb-2">
              <span class="text-2xl">📍</span>
              <div>
                <h2 class="text-lg font-semibold text-white">Set Your Location</h2>
                <p class="text-xs text-gray-500">Where should we look for flights?</p>
              </div>
            </div>
            <.form for={%{}} as={:location} phx-submit="setup_location" class="space-y-3">
              <div class="grid grid-cols-2 gap-3">
                <div class="space-y-1">
                  <label class="block text-xs text-gray-400 uppercase tracking-wide">Latitude</label>
                  <input
                    type="number"
                    name="location[lat]"
                    value=""
                    step="0.0001"
                    class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2.5 text-white text-sm font-mono focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                    placeholder="35.7721"
                  />
                </div>
                <div class="space-y-1">
                  <label class="block text-xs text-gray-400 uppercase tracking-wide">Longitude</label>
                  <input
                    type="number"
                    name="location[lon]"
                    value=""
                    step="0.0001"
                    class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2.5 text-white text-sm font-mono focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                    placeholder="-78.63861"
                  />
                </div>
              </div>
              <div class="space-y-1">
                <label class="block text-xs text-gray-400 uppercase tracking-wide">
                  Radius (miles)
                </label>
                <input
                  type="number"
                  name="location[radius_mi]"
                  value=""
                  min="3"
                  max="300"
                  step="1"
                  class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2.5 text-white text-sm font-mono focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                  placeholder="25"
                />
              </div>
              <button
                type="submit"
                class="w-full px-4 py-2.5 bg-emerald-700 hover:bg-emerald-600 text-white text-sm font-semibold rounded-md transition-colors"
              >
                🚀 Save & Start Tracking!
              </button>
            </.form>
          </div>
        <% _ -> %>
          <%!-- Should not reach here, but just in case --%>
      <% end %>

      <%!-- Skip setup entirely --%>
      <div class="text-center">
        <button
          phx-click="skip_setup"
          class="text-xs text-gray-600 hover:text-gray-400 transition-colors"
        >
          Skip setup and go to dashboard →
        </button>
      </div>
    </div>
    """
  end

  attr :step, :atom, required: true
  attr :current, :atom, required: true
  attr :label, :string, required: true

  defp step_dot(assigns) do
    step_order = %{wifi: 0, api_keys: 1, location: 2, done: 3}
    current_idx = Map.get(step_order, assigns.current, 0)
    step_idx = Map.get(step_order, assigns.step, 0)

    assigns =
      assign(assigns,
        completed: step_idx < current_idx,
        active: assigns.step == assigns.current
      )

    ~H"""
    <div class="flex flex-col items-center gap-1">
      <div class={[
        "w-3 h-3 rounded-full border-2 transition-colors",
        @completed && "bg-cyan-500 border-cyan-500",
        @active && "bg-cyan-500 border-cyan-500 ring-2 ring-cyan-500/30",
        (not @completed and not @active) && "bg-transparent border-gray-600"
      ]} />
      <span class={[
        "text-xs",
        if(@active or @completed, do: "text-cyan-400", else: "text-gray-600")
      ]}>
        {@label}
      </span>
    </div>
    """
  end

  attr :flight, :map, required: true

  defp flight_card(assigns) do
    sv = assigns.flight.state_vector
    fi = assigns.flight.flight_info
    timezone = AeroVision.Config.Store.get(:timezone)

    assigns =
      assign(assigns,
        callsign: sv.callsign || "---",
        airline: (fi && fi.airline_name) || "Unknown",
        aircraft:
          (fi && fi.aircraft_type) || AircraftCodes.abbreviate(sv && sv.aircraft_type_name) ||
            "---",
        altitude: format_altitude(sv.baro_altitude),
        speed: format_speed(sv.velocity),
        bearing: format_bearing(sv.true_track),
        origin: format_airport(fi && fi.origin),
        destination: format_airport(fi && fi.destination),
        dep_time: Renderer.format_time(Renderer.best_departure_time(fi), timezone),
        arr_time: Renderer.format_time(Renderer.best_arrival_time(fi), timezone),
        progress: (fi && fi.progress_pct) || 0.0,
        on_ground: sv.on_ground || false
      )

    ~H"""
    <div class="bg-gray-900 rounded-lg border border-gray-800 p-4 space-y-3 hover:border-gray-700 transition-colors">
      <%!-- Header: callsign + airline + aircraft type --%>
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-2">
          <span class="text-lg font-bold text-white font-mono">{@callsign}</span>
          <span class="text-sm text-gray-500">{@airline}</span>
        </div>
        <div class="flex items-center gap-2">
          <%= if @on_ground do %>
            <span class="px-1.5 py-0.5 text-xs rounded bg-gray-700 text-gray-400">Ground</span>
          <% end %>
          <span class="text-sm font-mono text-gray-400">{@aircraft}</span>
        </div>
      </div>

      <%!-- Route with times --%>
      <div class="flex items-center gap-2 text-sm">
        <div>
          <div class="font-mono text-white font-medium">{@origin}</div>
          <div class="font-mono text-xs text-gray-500">{@dep_time}</div>
        </div>
        <span class="text-gray-600 text-xs flex-1 text-center">──────▶</span>
        <div class="text-right">
          <div class="font-mono text-white font-medium">{@destination}</div>
          <div class="font-mono text-xs text-gray-500">{@arr_time}</div>
        </div>
      </div>

      <%!-- Telemetry grid --%>
      <div class="grid grid-cols-3 gap-3 text-xs">
        <div class="flex flex-col gap-0.5">
          <span class="text-gray-500 uppercase tracking-wide">Alt</span>
          <span class="text-green-400 font-mono font-medium">{@altitude}</span>
        </div>
        <div class="flex flex-col gap-0.5">
          <span class="text-gray-500 uppercase tracking-wide">Spd</span>
          <span class="text-green-400 font-mono font-medium">{@speed}</span>
        </div>
        <div class="flex flex-col gap-0.5">
          <span class="text-gray-500 uppercase tracking-wide">Hdg</span>
          <span class="text-green-400 font-mono font-medium">{@bearing}</span>
        </div>
      </div>

      <%!-- Progress bar --%>
      <div>
        <div class="flex justify-between text-xs text-gray-600 mb-1">
          <span>Progress</span>
          <span>{round(@progress * 100)}%</span>
        </div>
        <div class="h-1.5 bg-gray-800 rounded-full overflow-hidden">
          <div
            class="h-full bg-cyan-500 rounded-full transition-all duration-500"
            style={"width: #{round(@progress * 100)}%"}
          >
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---- Private Helper Functions -----------------------------------------------

  @on_target Application.compile_env(:aerovision, :target, :host) != :host

  defp compute_setup_step(config) do
    if @on_target do
      cond do
        is_nil(config.wifi_ssid) or config.wifi_ssid == "" -> :wifi
        not has_adsb_source?(config) -> :api_keys
        config.location_lat == 35.7721 and config.location_lon == -78.63861 -> :location
        true -> :done
      end
    else
      :done
    end
  end

  defp has_adsb_source?(config) do
    skylink_ok = is_binary(config.skylink_api_key) and config.skylink_api_key != ""

    opensky_ok =
      is_binary(config.opensky_client_id) and config.opensky_client_id != "" and
        is_binary(config.opensky_client_secret) and config.opensky_client_secret != ""

    skylink_ok or opensky_ok
  end

  defp parse_float(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_float(_), do: nil

  defp format_altitude(nil), do: "---"

  defp format_altitude(feet) do
    ft = round(feet)

    if ft >= 18_000 do
      "FL#{div(ft, 100)}"
    else
      "#{format_number(ft)}ft"
    end
  end

  defp format_speed(nil), do: "---"
  defp format_speed(knots), do: "#{round(knots)}kt"

  defp format_bearing(nil), do: "---"

  defp format_bearing(deg) do
    deg
    |> round()
    |> Integer.to_string()
    |> String.pad_leading(3, "0")
    |> Kernel.<>("°")
  end

  defp format_airport(nil), do: "---"
  defp format_airport(%{iata: iata}) when is_binary(iata) and iata != "", do: iata
  defp format_airport(%{icao: icao}) when is_binary(icao), do: icao
  defp format_airport(_), do: "---"

  # Format a number with comma thousands separators (avoids Number.Delimited dep)
  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
