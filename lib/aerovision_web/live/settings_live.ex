defmodule AeroVisionWeb.SettingsLive do
  use AeroVisionWeb, :live_view

  alias AeroVision.Config.Store

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Store.subscribe()
    end

    config = Store.all()

    network_mode = AeroVision.Network.Manager.current_mode()
    ip = AeroVision.Network.Manager.current_ip()

    uptime = format_uptime()

    {:ok,
     assign(socket,
       page_title: "Settings",
       # Location
       location_lat: to_string(config.location_lat),
       location_lon: to_string(config.location_lon),
       radius_km: to_string(config.radius_km),
       # Display
       display_mode: config.display_mode,
       display_brightness: config.display_brightness,
       display_cycle_seconds: config.display_cycle_seconds,
       # Flights
       tracked_flights: config.tracked_flights,
       airline_filters: config.airline_filters,
       # API Keys
       opensky_client_id: config.opensky_client_id || "",
       opensky_client_secret: config.opensky_client_secret || "",
       aeroapi_key: config.aeroapi_key || "",
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
  def handle_info({:config_changed, _key, _value}, socket) do
    {:noreply, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # ---- Location ---------------------------------------------------------------

  @impl true
  def handle_event("save_location", %{"location" => params}, socket) do
    lat = parse_float(params["location_lat"])
    lon = parse_float(params["location_lon"])
    radius = parse_float(params["radius_km"])

    dbg(radius)

    if lat && lon && radius do
      Store.put(:location_lat, lat)
      Store.put(:location_lon, lon)
      Store.put(:radius_km, radius)

      {:noreply,
       assign(socket,
         location_lat: to_string(lat),
         location_lon: to_string(lon),
         radius_km: to_string(radius),
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
    brightness = parse_int(params["display_brightness"])
    cycle = parse_int(params["display_cycle_seconds"])

    if brightness && cycle do
      Store.put(:display_brightness, brightness)
      Store.put(:display_cycle_seconds, cycle)

      {:noreply,
       assign(socket,
         display_brightness: brightness,
         display_cycle_seconds: cycle,
         saved_flash: "display_settings"
       )}
    else
      {:noreply, socket}
    end
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

  # ---- API Keys ---------------------------------------------------------------

  def handle_event("save_api_keys", %{"api_keys" => params}, socket) do
    Store.put(:opensky_client_id, params["opensky_client_id"])
    Store.put(:opensky_client_secret, params["opensky_client_secret"])
    Store.put(:aeroapi_key, params["aeroapi_key"])

    {:noreply,
     assign(socket,
       opensky_client_id: params["opensky_client_id"],
       opensky_client_secret: params["opensky_client_secret"],
       aeroapi_key: params["aeroapi_key"],
       saved_flash: "api_keys"
     )}
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
              class="flex items-center gap-2 px-3 py-1.5 bg-emerald-900/60 border border-emerald-700 rounded-lg text-emerald-300 text-sm"
              phx-click="dismiss_flash"
            >
              <span>✓ Saved</span>
            </div>
          <% end %>
        </div>
        
    <!-- 1. Location -->
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
                  placeholder="35.7796"
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
                  placeholder="-78.6382"
                />
              </div>
            </div>
            <div class="space-y-1">
              <label class="block text-xs text-gray-400 uppercase tracking-wide">Radius (km)</label>
              <input
                type="number"
                name="location[radius_km]"
                value={@radius_km}
                min="5"
                max="500"
                step="5"
                class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2 text-white text-sm font-mono focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                placeholder="50"
              />
            </div>
            <.save_button />
          </.form>
        </.settings_card>
        
    <!-- 2. Display Mode -->
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
        
    <!-- 3. Tracked Flights -->
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
        
    <!-- 4. Airline Filters -->
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
        
    <!-- 5. Display Settings -->
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
                min="1"
                max="100"
                step="1"
                class="w-full accent-cyan-500"
              />
              <div class="flex justify-between text-xs text-gray-600">
                <span>1%</span>
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
            <.save_button />
          </.form>
        </.settings_card>
        
    <!-- 6. API Keys -->
        <.settings_card title="API Keys" icon="🔑">
          <.form for={%{}} as={:api_keys} phx-submit="save_api_keys" class="space-y-4">
            <div class="space-y-1">
              <label class="block text-xs text-gray-400 uppercase tracking-wide">
                OpenSky Client ID
              </label>
              <input
                type="text"
                name="api_keys[opensky_client_id]"
                value={@opensky_client_id}
                class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2 text-white text-sm font-mono focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                placeholder="your-client-id"
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
                value={@opensky_client_secret}
                class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2 text-white text-sm font-mono focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                placeholder="••••••••"
                autocomplete="new-password"
              />
            </div>
            <div class="space-y-1">
              <label class="block text-xs text-gray-400 uppercase tracking-wide">
                FlightAware AeroAPI Key
              </label>
              <input
                type="password"
                name="api_keys[aeroapi_key]"
                value={@aeroapi_key}
                class="w-full bg-gray-800 border border-gray-700 rounded-md px-3 py-2 text-white text-sm font-mono focus:outline-none focus:border-cyan-500 focus:ring-1 focus:ring-cyan-500"
                placeholder="••••••••"
                autocomplete="new-password"
              />
              <p class="text-xs text-gray-600">
                Optional — enables route and airline info enrichment.
              </p>
            </div>
            <.save_button />
          </.form>
        </.settings_card>
        
    <!-- 7. System -->
        <.settings_card title="System" icon="⚙️">
          <div class="space-y-4">
            <div class="grid grid-cols-2 gap-3 text-sm">
              <.info_row label="Firmware" value={@firmware_version} />
              <.info_row label="IP Address" value={@ip} mono />
              <.info_row label="Network" value={network_mode_label(@network_mode)} />
              <.info_row label="Uptime" value={@uptime} />
            </div>

            <div class="pt-2 border-t border-gray-800">
              <button
                phx-click="reboot"
                data-confirm="Reboot the device?"
                class="px-4 py-2 bg-red-900 hover:bg-red-800 text-red-200 text-sm font-medium rounded-md border border-red-700 transition-colors"
              >
                Reboot Device
              </button>
              <p class="text-xs text-gray-600 mt-2">
                {if on_target?(),
                  do: "Reboots the Raspberry Pi.",
                  else: "Reboot disabled in development mode."}
              </p>
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
end
