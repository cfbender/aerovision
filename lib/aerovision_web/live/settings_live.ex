defmodule AeroVisionWeb.SettingsLive do
  use AeroVisionWeb, :live_view

  alias AeroVision.Config.Store

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Store.subscribe()
      Phoenix.PubSub.subscribe(AeroVision.PubSub, "network")
      Phoenix.PubSub.subscribe(AeroVision.PubSub, "config")
      # Disarm the network watchdog — a client has successfully reached the UI
      AeroVision.Network.Watchdog.ping()
    end

    config = Store.all()

    network_mode = AeroVision.Network.Manager.current_mode()
    ip = AeroVision.Network.Manager.current_ip()

    uptime = format_uptime()

    {:ok,
     assign(socket,
       page_title: "Settings",
       # Location (radius stored as km internally, displayed as miles)
       location_lat: to_string(config.location_lat),
       location_lon: to_string(config.location_lon),
       radius_mi: to_string(km_to_mi(config.radius_km)),
       # Display
       display_mode: config.display_mode,
       display_brightness: config.display_brightness,
       display_cycle_seconds: config.display_cycle_seconds,
       timezone: config.timezone,
       # Flights
       tracked_flights: config.tracked_flights,
       airline_filters: config.airline_filters,
       airport_filters: config.airport_filters,
       # API Keys
       skylink_api_key: config.skylink_api_key || "",
       opensky_client_id: config.opensky_client_id || "",
       opensky_client_secret: config.opensky_client_secret || "",
       # WiFi
       wifi_ssid: config.wifi_ssid || "",
       wifi_editing: config.wifi_ssid == nil,
       wifi_scan_results: [],
       wifi_scanning: false,
       # System
       network_mode: network_mode,
       ip: ip,
       uptime: uptime,
       firmware_version: firmware_version(),
       # UI state
       saved_flash: nil
     )}
  end

  @impl true
  def handle_info({:config_changed, :timezone, value}, socket) do
    {:noreply, assign(socket, timezone: value)}
  end

  def handle_info({:config_changed, _key, _value}, socket) do
    {:noreply, socket}
  end

  def handle_info({:network, :connected, ip}, socket) do
    {:noreply, assign(socket, network_mode: :infrastructure, ip: ip, wifi_editing: false)}
  end

  def handle_info({:network, :ap_mode}, socket) do
    {:noreply, assign(socket, network_mode: :ap, ip: "192.168.24.1")}
  end

  def handle_info(:wifi_scan_complete, socket) do
    networks = AeroVision.Network.Manager.scan_networks()
    {:noreply, assign(socket, wifi_scanning: false, wifi_scan_results: networks)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # ---- Location ---------------------------------------------------------------

  @impl true
  def handle_event("save_location", %{"location" => params}, socket) do
    lat = parse_float(params["location_lat"])
    lon = parse_float(params["location_lon"])
    radius_mi = parse_float(params["radius_mi"])

    if lat && lon && radius_mi do
      Store.put(:location_lat, lat)
      Store.put(:location_lon, lon)
      Store.put(:radius_km, mi_to_km(radius_mi))

      {:noreply,
       assign(socket,
         location_lat: to_string(lat),
         location_lon: to_string(lon),
         radius_mi: to_string(radius_mi),
         saved_flash: "location"
       )}
    else
      {:noreply, socket}
    end
  end

  # ---- Display Mode -----------------------------------------------------------

  def handle_event("set_display_mode", %{"mode" => mode}, socket) do
    mode_atom = String.to_existing_atom(mode)
    Store.put(:display_mode, mode_atom)
    {:noreply, assign(socket, display_mode: mode_atom, saved_flash: "display_mode")}
  end

  # ---- Display Settings -------------------------------------------------------

  def handle_event("update_display_preview", %{"display_settings" => params}, socket) do
    brightness = parse_int(params["display_brightness"]) || socket.assigns.display_brightness
    cycle = parse_int(params["display_cycle_seconds"]) || socket.assigns.display_cycle_seconds
    {:noreply, assign(socket, display_brightness: brightness, display_cycle_seconds: cycle)}
  end

  def handle_event("save_display_settings", %{"display_settings" => params}, socket) do
    brightness = params["display_brightness"] |> parse_int() |> clamp(20, 100)
    cycle = parse_int(params["display_cycle_seconds"])
    timezone = Map.get(params, "timezone", socket.assigns.timezone)

    if brightness && cycle do
      Store.put(:display_brightness, brightness)
      Store.put(:display_cycle_seconds, cycle)
      Store.put(:timezone, timezone)

      {:noreply,
       assign(socket,
         display_brightness: brightness,
         display_cycle_seconds: cycle,
         timezone: timezone,
         saved_flash: "display_settings"
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_timezone", %{"tz" => tz}, socket) do
    Store.put(:timezone, tz)
    {:noreply, assign(socket, timezone: tz, saved_flash: true)}
  end

  # ---- Tracked Flights --------------------------------------------------------

  def handle_event("add_tracked_flight", %{"callsign" => callsign}, socket) do
    callsign = String.upcase(String.trim(callsign))

    if callsign != "" and callsign not in socket.assigns.tracked_flights do
      updated = socket.assigns.tracked_flights ++ [callsign]
      Store.put(:tracked_flights, updated)
      {:noreply, assign(socket, tracked_flights: updated)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_tracked_flight", %{"callsign" => callsign}, socket) do
    updated = Enum.reject(socket.assigns.tracked_flights, &(&1 == callsign))
    Store.put(:tracked_flights, updated)
    {:noreply, assign(socket, tracked_flights: updated)}
  end

  # ---- Airline Filters --------------------------------------------------------

  def handle_event("add_airline_filter", %{"prefix" => prefix}, socket) do
    prefix = String.upcase(String.trim(prefix))

    if prefix != "" and prefix not in socket.assigns.airline_filters do
      updated = socket.assigns.airline_filters ++ [prefix]
      Store.put(:airline_filters, updated)
      {:noreply, assign(socket, airline_filters: updated)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_airline_filter", %{"prefix" => prefix}, socket) do
    updated = Enum.reject(socket.assigns.airline_filters, &(&1 == prefix))
    Store.put(:airline_filters, updated)
    {:noreply, assign(socket, airline_filters: updated)}
  end

  # ---- Airport Filters --------------------------------------------------------

  def handle_event("add_airport_filter", %{"code" => code}, socket) do
    code = code |> String.upcase() |> String.trim()

    if code != "" and code not in socket.assigns.airport_filters do
      updated = socket.assigns.airport_filters ++ [code]
      Store.put(:airport_filters, updated)
      {:noreply, assign(socket, airport_filters: updated)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("remove_airport_filter", %{"code" => code}, socket) do
    updated = Enum.reject(socket.assigns.airport_filters, &(&1 == code))
    Store.put(:airport_filters, updated)
    {:noreply, assign(socket, airport_filters: updated)}
  end

  # ---- API Keys ---------------------------------------------------------------

  def handle_event("save_api_keys", %{"api_keys" => params}, socket) do
    skylink_api_key = String.trim(params["skylink_api_key"] || "")
    opensky_id = String.trim(params["opensky_client_id"] || "")
    opensky_secret = String.trim(params["opensky_client_secret"] || "")

    Store.put(:skylink_api_key, skylink_api_key)
    Store.put(:opensky_client_id, if(opensky_id == "", do: nil, else: opensky_id))
    Store.put(:opensky_client_secret, if(opensky_secret == "", do: nil, else: opensky_secret))

    {:noreply,
     assign(socket,
       skylink_api_key: skylink_api_key,
       opensky_client_id: opensky_id,
       opensky_client_secret: opensky_secret,
       saved_flash: "api_keys"
     )}
  end

  # ---- WiFi -------------------------------------------------------------------

  def handle_event("toggle_wifi_edit", _params, socket) do
    {:noreply, assign(socket, wifi_editing: !socket.assigns.wifi_editing)}
  end

  def handle_event("scan_wifi", _params, socket) do
    if on_target?() do
      send(self(), :wifi_scan_complete)
      {:noreply, assign(socket, wifi_scanning: true, wifi_scan_results: [])}
    else
      {:noreply, assign(socket, wifi_scanning: false, wifi_scan_results: [])}
    end
  end

  def handle_event("select_wifi_network", %{"ssid" => ssid}, socket) do
    {:noreply, assign(socket, wifi_ssid: ssid)}
  end

  def handle_event("save_wifi", %{"wifi" => params}, socket) do
    ssid = String.trim(params["ssid"] || "")
    password = params["password"] || ""

    if ssid != "" do
      Store.put(:wifi_ssid, ssid)
      Store.put(:wifi_password, password)
      AeroVision.Network.Manager.connect_wifi(ssid, password)

      {:noreply,
       assign(socket,
         wifi_ssid: ssid,
         wifi_editing: false,
         saved_flash: "wifi"
       )}
    else
      {:noreply, socket}
    end
  end

  # ---- System -----------------------------------------------------------------

  def handle_event("reboot", _params, socket) do
    if on_target?() do
      spawn(fn ->
        Process.sleep(500)
        Nerves.Runtime.reboot()
      end)
    end

    {:noreply, socket}
  end

  def handle_event("shutdown", _params, socket) do
    if on_target?() do
      spawn(fn ->
        Process.sleep(500)
        Nerves.Runtime.poweroff()
      end)
    end

    {:noreply, socket}
  end

  def handle_event("purge_cache", _params, socket) do
    AeroVision.Flight.Skylink.FlightStatus.clear_cache()
    AeroVision.Flight.Tracker.clear_flights()
    {:noreply, assign(socket, saved_flash: "cache_purged")}
  end

  def handle_event("dismiss_flash", _params, socket) do
    {:noreply, assign(socket, saved_flash: nil)}
  end

  # ---- Render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6 max-w-2xl mx-auto pb-12">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold text-white">Settings</h1>
          <%= if @saved_flash do %>
            <div
              class={[
                "flex items-center gap-2 px-3 py-1.5 rounded-lg text-sm",
                @saved_flash == "cache_purged" &&
                  "bg-amber-900/60 border border-amber-700 text-amber-300",
                @saved_flash != "cache_purged" &&
                  "bg-emerald-900/60 border border-emerald-700 text-emerald-300"
              ]}
              phx-click="dismiss_flash"
            >
              <%= if @saved_flash == "cache_purged" do %>
                <span>✓ Cache purged</span>
              <% else %>
                <span>✓ Saved</span>
              <% end %>
            </div>
          <% end %>
        </div>

        <%!-- 1. Display Mode (always visible) --%>
        <.settings_card title="Display Mode" icon="🖥️">
          <div class="flex gap-4">
            <div
              phx-click="set_display_mode"
              phx-value-mode="nearby"
              class={[
                "flex-1 flex items-center justify-center gap-2 px-4 py-3 rounded-lg border cursor-pointer transition-colors",
                @display_mode == :nearby &&
                  "border-cyan-500 bg-cyan-950 text-cyan-300",
                @display_mode != :nearby &&
                  "border-gray-700 bg-gray-800 text-gray-400 hover:border-gray-600"
              ]}
            >
              <span class="text-lg">📡</span>
              <div>
                <div class="font-medium text-sm">Nearby</div>
                <div class="text-xs opacity-70">All flights in radius</div>
              </div>
            </div>
            <div
              phx-click="set_display_mode"
              phx-value-mode="tracked"
              class={[
                "flex-1 flex items-center justify-center gap-2 px-4 py-3 rounded-lg border cursor-pointer transition-colors",
                @display_mode == :tracked &&
                  "border-cyan-500 bg-cyan-950 text-cyan-300",
                @display_mode != :tracked &&
                  "border-gray-700 bg-gray-800 text-gray-400 hover:border-gray-600"
              ]}
            >
              <span class="text-lg">🎯</span>
              <div>
                <div class="font-medium text-sm">Tracked</div>
                <div class="text-xs opacity-70">Specific flights only</div>
              </div>
            </div>
          </div>
        </.settings_card>

        <%!-- 2. Location (nearby mode only) --%>
        <%= if @display_mode == :nearby do %>
          <.settings_card title="Location" icon="📍">
            <.form for={%{}} as={:location} phx-submit="save_location" class="space-y-4">
              <div class="grid grid-cols-2 gap-4">
                <div class="space-y-1">
                  <label class="block text-xs text-gray-400 uppercase tracking-wide">Latitude</label>
                  <input
                    type="number"
                    name="location[location_lat]"
                    value={@location_lat}
                    step="0.0001"
                    class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2 text-white text-sm font-mono focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                    placeholder="35.7721"
                  />
                </div>
                <div class="space-y-1">
                  <label class="block text-xs text-gray-400 uppercase tracking-wide">Longitude</label>
                  <input
                    type="number"
                    name="location[location_lon]"
                    value={@location_lon}
                    step="0.0001"
                    class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2 text-white text-sm font-mono focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
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
                  value={@radius_mi}
                  min="3"
                  max="300"
                  step="1"
                  class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2 text-white text-sm font-mono focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                  placeholder="25"
                />
              </div>
              <.save_button />
            </.form>
          </.settings_card>
        <% end %>

        <%!-- 3. Tracked Flights (tracked mode only) --%>
        <%= if @display_mode == :tracked do %>
          <.settings_card title="Tracked Flights" icon="🎯">
            <div class="space-y-3">
              <p class="text-xs text-gray-500">
                Add specific callsigns to track (e.g. DAL123, UAL456).
              </p>
              <form phx-submit="add_tracked_flight" class="flex gap-2">
                <input
                  type="text"
                  name="callsign"
                  value=""
                  class="flex-1 bg-gray-800 border border-gray-700 rounded-md px-3 py-2 text-white text-sm font-mono uppercase focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                  placeholder="DAL123"
                  autocomplete="off"
                  autocorrect="off"
                  autocapitalize="characters"
                  phx-debounce="200"
                />
                <button
                  type="submit"
                  class="px-4 py-2 bg-cyan-700 hover:bg-cyan-600 text-white text-sm font-medium rounded-md transition-colors"
                >
                  Add
                </button>
              </form>
              <%= if @tracked_flights == [] do %>
                <p class="text-sm text-gray-600 italic">No tracked flights. Add callsigns above.</p>
              <% else %>
                <div class="space-y-2">
                  <%= for callsign <- @tracked_flights do %>
                    <div class="flex items-center justify-between px-3 py-2 bg-gray-800 rounded-md">
                      <span class="font-mono text-sm text-white">{callsign}</span>
                      <button
                        phx-click="remove_tracked_flight"
                        phx-value-callsign={callsign}
                        class="text-gray-500 hover:text-red-400 transition-colors text-sm"
                      >
                        ✕
                      </button>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </.settings_card>
        <% end %>

        <%!-- 4. Airline Filters (nearby mode only) --%>
        <%= if @display_mode == :nearby do %>
          <.settings_card title="Airline Filters" icon="✈️">
            <div class="space-y-3">
              <p class="text-xs text-gray-500">
                Filter by ICAO airline prefix (e.g. AAL, UAL, DAL). Only these airlines will be shown.
              </p>
              <form phx-submit="add_airline_filter" class="flex gap-2">
                <input
                  type="text"
                  name="prefix"
                  value=""
                  class="flex-1 bg-gray-800 border border-gray-700 rounded-md px-3 py-2 text-white text-sm font-mono uppercase focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                  placeholder="AAL"
                  autocomplete="off"
                  autocorrect="off"
                  autocapitalize="characters"
                  phx-debounce="200"
                />
                <button
                  type="submit"
                  class="px-4 py-2 bg-cyan-700 hover:bg-cyan-600 text-white text-sm font-medium rounded-md transition-colors"
                >
                  Add
                </button>
              </form>
              <%= if @airline_filters == [] do %>
                <p class="text-sm text-gray-600 italic">No filters active — all airlines shown.</p>
              <% else %>
                <div class="flex flex-wrap gap-2">
                  <%= for prefix <- @airline_filters do %>
                    <div class="flex items-center gap-1.5 px-2.5 py-1 bg-gray-800 rounded-full border border-gray-700">
                      <span class="font-mono text-sm text-cyan-300">{prefix}</span>
                      <button
                        phx-click="remove_airline_filter"
                        phx-value-prefix={prefix}
                        class="text-gray-500 hover:text-red-400 transition-colors leading-none"
                      >
                        ✕
                      </button>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </.settings_card>
        <% end %>

        <%!-- 5. Airport Filters (nearby mode only) --%>
        <%= if @display_mode == :nearby do %>
          <.settings_card title="Airport Filters" icon="🛬">
            <div class="space-y-3">
              <p class="text-xs text-gray-500">
                Show only flights departing or arriving at these airports. Accepts IATA (e.g. <span class="font-mono text-gray-400">RDU</span>) or ICAO codes (e.g. <span class="font-mono text-gray-400">KRDU</span>). Requires AeroAPI enrichment.
              </p>
              <form phx-submit="add_airport_filter" class="flex gap-2">
                <input
                  type="text"
                  name="code"
                  value=""
                  class="flex-1 bg-gray-800 border border-gray-700 rounded-md px-3 py-2 text-white text-sm font-mono uppercase focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                  placeholder="RDU"
                  autocomplete="off"
                  autocorrect="off"
                  autocapitalize="characters"
                  phx-debounce="200"
                />
                <button
                  type="submit"
                  class="px-4 py-2 bg-cyan-700 hover:bg-cyan-600 text-white text-sm font-medium rounded-md transition-colors"
                >
                  Add
                </button>
              </form>
              <%= if @airport_filters == [] do %>
                <p class="text-sm text-gray-600 italic">No filters active — all airports shown.</p>
              <% else %>
                <div class="flex flex-wrap gap-2">
                  <%= for code <- @airport_filters do %>
                    <div class="flex items-center gap-1.5 px-2.5 py-1 bg-gray-800 rounded-full border border-gray-700">
                      <span class="font-mono text-sm text-cyan-300">{code}</span>
                      <button
                        phx-click="remove_airport_filter"
                        phx-value-code={code}
                        class="text-gray-500 hover:text-red-400 transition-colors leading-none"
                      >
                        ✕
                      </button>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </.settings_card>
        <% end %>
        
    <!-- 6. Display Settings -->
        <.settings_card title="Display Settings" icon="💡">
          <.form
            for={%{}}
            as={:display_settings}
            phx-submit="save_display_settings"
            phx-change="update_display_preview"
            class="space-y-4"
          >
            <div class="space-y-2">
              <div class="flex items-center justify-between">
                <label class="block text-xs text-gray-400 uppercase tracking-wide">Brightness</label>
                <span class="text-sm font-mono text-cyan-400">{@display_brightness}%</span>
              </div>
              <input
                type="range"
                name="display_settings[display_brightness]"
                value={@display_brightness}
                min="20"
                max="100"
                step="1"
                class="w-full accent-cyan-500"
              />
              <div class="flex justify-between text-xs text-gray-600">
                <span>20%</span>
                <span>100%</span>
              </div>
            </div>
            <div class="space-y-1">
              <label class="block text-xs text-gray-400 uppercase tracking-wide">
                Cycle Interval (seconds)
              </label>
              <input
                type="number"
                name="display_settings[display_cycle_seconds]"
                value={@display_cycle_seconds}
                min="1"
                max="60"
                step="1"
                class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2 text-white text-sm font-mono focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
              />
              <p class="text-xs text-gray-600">How long each flight is displayed on the LED panel.</p>
            </div>
            <div class="space-y-2">
              <label class="block text-xs text-gray-400 uppercase tracking-wide">
                Timezone
              </label>
              <input
                type="text"
                name="display_settings[timezone]"
                value={@timezone}
                class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2 text-white text-sm font-mono focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                placeholder="America/New_York"
                autocomplete="off"
              />
              <div class="flex flex-wrap gap-1.5 mt-2">
                <button
                  type="button"
                  phx-click="set_timezone"
                  phx-value-tz="America/New_York"
                  class={[
                    "px-2 py-1 text-xs rounded-md border transition-colors",
                    @timezone == "America/New_York" && "border-cyan-500 bg-cyan-950 text-cyan-300",
                    @timezone != "America/New_York" &&
                      "border-gray-700 bg-gray-800 text-gray-400 hover:border-gray-600"
                  ]}
                >
                  ET
                </button>
                <button
                  type="button"
                  phx-click="set_timezone"
                  phx-value-tz="America/Chicago"
                  class={[
                    "px-2 py-1 text-xs rounded-md border transition-colors",
                    @timezone == "America/Chicago" && "border-cyan-500 bg-cyan-950 text-cyan-300",
                    @timezone != "America/Chicago" &&
                      "border-gray-700 bg-gray-800 text-gray-400 hover:border-gray-600"
                  ]}
                >
                  CT
                </button>
                <button
                  type="button"
                  phx-click="set_timezone"
                  phx-value-tz="America/Denver"
                  class={[
                    "px-2 py-1 text-xs rounded-md border transition-colors",
                    @timezone == "America/Denver" && "border-cyan-500 bg-cyan-950 text-cyan-300",
                    @timezone != "America/Denver" &&
                      "border-gray-700 bg-gray-800 text-gray-400 hover:border-gray-600"
                  ]}
                >
                  MT
                </button>
                <button
                  type="button"
                  phx-click="set_timezone"
                  phx-value-tz="America/Los_Angeles"
                  class={[
                    "px-2 py-1 text-xs rounded-md border transition-colors",
                    @timezone == "America/Los_Angeles" &&
                      "border-cyan-500 bg-cyan-950 text-cyan-300",
                    @timezone != "America/Los_Angeles" &&
                      "border-gray-700 bg-gray-800 text-gray-400 hover:border-gray-600"
                  ]}
                >
                  PT
                </button>
                <button
                  type="button"
                  phx-click="set_timezone"
                  phx-value-tz="Etc/UTC"
                  class={[
                    "px-2 py-1 text-xs rounded-md border transition-colors",
                    @timezone == "Etc/UTC" && "border-cyan-500 bg-cyan-950 text-cyan-300",
                    @timezone != "Etc/UTC" &&
                      "border-gray-700 bg-gray-800 text-gray-400 hover:border-gray-600"
                  ]}
                >
                  UTC
                </button>
              </div>
              <p class="text-xs text-gray-600">
                IANA timezone (e.g. America/New_York, Europe/London)
              </p>
            </div>
            <.save_button />
          </.form>
        </.settings_card>

        <%!-- 6. API Keys --%>
        <.settings_card title="API Keys" icon="🔑">
          <.form for={%{}} as={:api_keys} phx-submit="save_api_keys" class="space-y-6">
            <%!-- OpenSky section (primary ADS-B source) --%>
            <div class="space-y-3">
              <div class="space-y-1">
                <div class="flex items-center gap-2">
                  <label class="block text-xs text-gray-400 uppercase tracking-wide">
                    OpenSky Client ID
                  </label>
                  <span class="text-[10px] text-gray-600 border border-gray-700 rounded px-1.5 py-0.5 uppercase tracking-wider">
                    Optional
                  </span>
                </div>
                <input
                  type="text"
                  name="api_keys[opensky_client_id]"
                  value={@opensky_client_id}
                  class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2 text-white text-sm font-mono focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                  placeholder="username"
                  autocomplete="off"
                />
              </div>
              <div class="space-y-1">
                <div class="flex items-center gap-2">
                  <label class="block text-xs text-gray-400 uppercase tracking-wide">
                    OpenSky Client Secret
                  </label>
                  <span class="text-[10px] text-gray-600 border border-gray-700 rounded px-1.5 py-0.5 uppercase tracking-wider">
                    Optional
                  </span>
                </div>
                <input
                  type="password"
                  name="api_keys[opensky_client_secret]"
                  value={@opensky_client_secret}
                  class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2 text-white text-sm font-mono focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                  placeholder="••••••••"
                  autocomplete="off"
                />
              </div>
              <p class="text-xs text-gray-600">
                Primary ADS-B source for nearby mode. Free at
                <a
                  href="https://opensky-network.org"
                  target="_blank"
                  class="text-cyan-500 hover:underline"
                >
                  opensky-network.org
                </a>
              </p>
            </div>

            <%!-- Divider --%>
            <div class="border-t border-gray-800" />

            <%!-- Skylink section (fallback) --%>
            <div class="space-y-1">
              <div class="flex items-center gap-2">
                <label class="block text-xs text-gray-400 uppercase tracking-wide">
                  Skylink API Key
                </label>
                <span class="text-[10px] text-gray-600 border border-gray-700 rounded px-1.5 py-0.5 uppercase tracking-wider">
                  Optional
                </span>
              </div>
              <input
                type="password"
                name="api_keys[skylink_api_key]"
                value={@skylink_api_key}
                class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2 text-white text-sm font-mono focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                placeholder="Your RapidAPI key"
                autocomplete="off"
              />
              <p class="text-xs text-gray-600">
                Fallback ADS-B + enrichment source. Flight data is provided by FlightStats by default.
                <a
                  href="https://rapidapi.com/skylink-api-skylink-api-default/api/skylink-api"
                  target="_blank"
                  class="text-cyan-500 hover:underline"
                >
                  Get key at RapidAPI
                </a>
              </p>
            </div>

            <button
              type="submit"
              id="save-api-keys"
              class="w-full px-4 py-2 bg-cyan-700 hover:bg-cyan-600 text-white text-sm font-semibold rounded-md transition-colors"
            >
              Save Changes
            </button>
          </.form>
        </.settings_card>

        <%!-- 7. WiFi --%>
        <.settings_card title="WiFi" icon="📶">
          <div class="space-y-4">
            <%!-- Current connection status --%>
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-3">
                <span class={[
                  "w-2 h-2 rounded-full shrink-0",
                  @network_mode == :infrastructure && "bg-emerald-400",
                  @network_mode == :ap && "bg-amber-400",
                  @network_mode not in [:infrastructure, :ap] && "bg-gray-500"
                ]} />
                <div>
                  <%= if @wifi_ssid != "" do %>
                    <div class="text-sm text-white font-medium">{@wifi_ssid}</div>
                    <div class="text-xs text-gray-500">
                      {network_mode_label(@network_mode)} · {@ip}
                    </div>
                  <% else %>
                    <div class="text-sm text-gray-400">No WiFi configured</div>
                    <div class="text-xs text-gray-600">
                      Connect to a network to enable flight tracking.
                    </div>
                  <% end %>
                </div>
              </div>
              <%= if @wifi_ssid != "" and not @wifi_editing do %>
                <button
                  phx-click="toggle_wifi_edit"
                  class="px-3 py-1.5 text-xs font-medium text-gray-300 bg-gray-800 hover:bg-gray-700 border border-gray-700 rounded-md transition-colors"
                >
                  Change
                </button>
              <% end %>
            </div>

            <%!-- WiFi form (shown when editing or no SSID configured) --%>
            <%= if @wifi_editing do %>
              <div class="pt-3 border-t border-gray-800 space-y-3">
                <%!-- Scan button + results --%>
                <div class="flex items-center justify-between">
                  <span class="text-xs text-gray-400 uppercase tracking-wide">
                    Available Networks
                  </span>
                  <button
                    phx-click="scan_wifi"
                    disabled={@wifi_scanning}
                    class="flex items-center gap-1.5 px-2.5 py-1 text-xs font-medium text-gray-300 bg-gray-800 hover:bg-gray-700 disabled:opacity-50 border border-gray-700 rounded-md transition-colors"
                  >
                    <%= if @wifi_scanning do %>
                      <span class="animate-spin inline-block">⟳</span> Scanning…
                    <% else %>
                      <span>⟳</span> Scan
                    <% end %>
                  </button>
                </div>

                <%!-- Network list --%>
                <%= if @wifi_scan_results != [] do %>
                  <div class="rounded-md border border-gray-700 overflow-hidden divide-y divide-gray-700/50">
                    <%= for network <- @wifi_scan_results do %>
                      <button
                        type="button"
                        phx-click="select_wifi_network"
                        phx-value-ssid={network.ssid}
                        class={[
                          "w-full flex items-center justify-between px-3 py-2 text-left text-sm transition-colors",
                          @wifi_ssid == network.ssid &&
                            "bg-cyan-950 text-cyan-300",
                          @wifi_ssid != network.ssid &&
                            "bg-gray-800 hover:bg-gray-750 text-white"
                        ]}
                      >
                        <div class="flex items-center gap-2 min-w-0">
                          <span class="text-xs">
                            {wifi_signal_icon(network.signal)}
                          </span>
                          <span class="truncate font-medium">{network.ssid}</span>
                          <span class="text-xs text-gray-500 shrink-0">{network.security}</span>
                        </div>
                        <%= if @wifi_ssid == network.ssid do %>
                          <span class="text-xs font-medium shrink-0 ml-2">✓</span>
                        <% end %>
                      </button>
                    <% end %>
                  </div>
                <% else %>
                  <%= if not @wifi_scanning do %>
                    <p class="text-xs text-gray-600 text-center py-2">
                      {if on_target?(),
                        do: "Press Scan to find nearby networks.",
                        else: "WiFi scanning is not available in development mode."}
                    </p>
                  <% end %>
                <% end %>

                <%!-- Manual SSID entry + password form --%>
                <.form for={%{}} as={:wifi} phx-submit="save_wifi" class="space-y-3">
                  <div class="space-y-1">
                    <label class="block text-xs text-gray-400 uppercase tracking-wide">
                      Network Name (SSID)
                    </label>
                    <input
                      type="text"
                      name="wifi[ssid]"
                      value={@wifi_ssid}
                      class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2 text-white text-sm focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                      placeholder="MyHomeNetwork"
                      autocomplete="off"
                      autocorrect="off"
                      autocapitalize="none"
                    />
                  </div>
                  <div class="space-y-1">
                    <label class="block text-xs text-gray-400 uppercase tracking-wide">
                      Password
                    </label>
                    <input
                      type="password"
                      name="wifi[password]"
                      value=""
                      class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2 text-white text-sm focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                      placeholder="••••••••"
                      autocomplete="new-password"
                    />
                  </div>
                  <p class="text-xs text-amber-400/70">
                    ⚠ Changing WiFi will disconnect the device. You may need to reconnect to the new network.
                  </p>
                  <div class="flex gap-3">
                    <button
                      type="submit"
                      class="flex-1 px-4 py-2 bg-cyan-700 hover:bg-cyan-600 text-white text-sm font-medium rounded-md transition-colors"
                    >
                      Connect
                    </button>
                    <%= if @wifi_ssid != "" do %>
                      <button
                        type="button"
                        phx-click="toggle_wifi_edit"
                        class="px-4 py-2 bg-gray-800 hover:bg-gray-700 text-gray-300 text-sm font-medium rounded-md border border-gray-700 transition-colors"
                      >
                        Cancel
                      </button>
                    <% end %>
                  </div>
                </.form>
              </div>
            <% end %>
          </div>
        </.settings_card>
        
    <!-- 8. System -->
        <.settings_card title="System" icon="⚙️">
          <div class="space-y-4">
            <div class="grid grid-cols-2 gap-3 text-sm">
              <.info_row label="Firmware" value={@firmware_version} />
              <.info_row label="IP Address" value={@ip} mono />
              <.info_row label="Network" value={network_mode_label(@network_mode)} />
              <.info_row label="Uptime" value={@uptime} />
            </div>

            <div class="pt-2 border-t border-gray-800 space-y-4">
              <div class="space-y-1">
                <label class="block text-xs text-gray-400 uppercase tracking-wide">
                  Flight Cache
                </label>
                <button
                  phx-click="purge_cache"
                  class="w-full px-3 py-2 bg-amber-900/50 border border-amber-700/50 rounded-md text-amber-300 text-sm hover:bg-amber-900/70 hover:border-amber-600/50 transition-colors"
                >
                  🗑️ Purge Flight Cache
                </button>
                <p class="text-xs text-gray-600">
                  Clear all cached enrichment data and tracked flights. Data will repopulate on the next poll cycle.
                </p>
              </div>

              <div class="flex items-center gap-3 flex-wrap">
                <button
                  phx-click="reboot"
                  data-confirm="Reboot the device?"
                  class="px-4 py-2 bg-red-900 hover:bg-red-800 text-red-200 text-sm font-medium rounded-md border border-red-700 transition-colors"
                >
                  Reboot
                </button>
                <button
                  phx-click="shutdown"
                  data-confirm="Shut down the device? You will need to physically power cycle it to turn it back on."
                  class="px-4 py-2 bg-gray-800 hover:bg-gray-700 text-gray-300 text-sm font-medium rounded-md border border-gray-700 transition-colors"
                >
                  Shut Down
                </button>
                <p class="text-xs text-gray-600 w-full mt-1">
                  {if on_target?(),
                    do: "Reboot restarts the Pi. Shut Down powers it off safely.",
                    else: "System controls disabled in development mode."}
                </p>
              </div>
            </div>
          </div>
        </.settings_card>
      </div>
    </Layouts.app>
    """
  end

  # ---- Private Components -----------------------------------------------------

  attr :title, :string, required: true
  attr :icon, :string, required: true
  slot :inner_block, required: true

  defp settings_card(assigns) do
    ~H"""
    <div class="bg-gray-900 rounded-lg border border-gray-800 overflow-hidden">
      <div class="flex items-center gap-2 px-4 py-3 border-b border-gray-800 bg-gray-900/50">
        <span class="text-base">{@icon}</span>
        <h2 class="text-sm font-semibold text-gray-300 uppercase tracking-wide">{@title}</h2>
      </div>
      <div class="p-4">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  defp save_button(assigns) do
    ~H"""
    <button
      type="submit"
      class="w-full px-4 py-2 bg-cyan-700 hover:bg-cyan-600 text-white text-sm font-medium rounded-md transition-colors"
    >
      Save Changes
    </button>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :mono, :boolean, default: false

  defp info_row(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <span class="text-xs text-gray-500 uppercase tracking-wide">{@label}</span>
      <span class={["text-sm text-white", @mono && "font-mono"]}>{@value || "—"}</span>
    </div>
    """
  end

  # ---- Helpers ----------------------------------------------------------------

  defp parse_float(s) when is_binary(s) do
    case Float.parse(s) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp parse_float(_), do: nil

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp clamp(nil, _min, _max), do: nil
  defp clamp(n, min_val, max_val), do: n |> max(min_val) |> min(max_val)

  defp on_target? do
    Application.get_env(:aerovision, :target, :host) != :host
  end

  defp firmware_version do
    if on_target?() do
      try do
        Nerves.Runtime.KV.get_active("nerves_fw_version") || "unknown"
      rescue
        _ -> "unknown"
      end
    else
      "dev (host)"
    end
  end

  defp format_uptime do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    seconds = div(uptime_ms, 1000)
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    secs = rem(seconds, 60)
    :io_lib.format("~2..0Bh ~2..0Bm ~2..0Bs", [hours, minutes, secs]) |> IO.iodata_to_binary()
  end

  defp network_mode_label(:infrastructure), do: "WiFi (connected)"
  defp network_mode_label(:ap), do: "AP Mode (setup)"
  defp network_mode_label(:disconnected), do: "Disconnected"
  defp network_mode_label(_), do: "Unknown"

  defp wifi_signal_icon(rssi) when rssi >= -50, do: "▂▄▆█"
  defp wifi_signal_icon(rssi) when rssi >= -65, do: "▂▄▆░"
  defp wifi_signal_icon(rssi) when rssi >= -80, do: "▂▄░░"
  defp wifi_signal_icon(_), do: "▂░░░"

  defp km_to_mi(km), do: Float.round(km * 0.621371, 1)
  defp mi_to_km(mi), do: Float.round(mi * 1.60934, 2)
end
