defmodule AeroVisionWeb.DashboardLive do
  use AeroVisionWeb, :live_view

  alias AeroVision.Flight.Tracker
  alias AeroVision.Flight.GeoUtils

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(AeroVision.PubSub, "display")
      Phoenix.PubSub.subscribe(AeroVision.PubSub, "network")
    end

    flights = Tracker.get_flights()
    mode = AeroVision.Config.Store.get(:display_mode)
    network_mode = AeroVision.Network.Manager.current_mode()
    ip = AeroVision.Network.Manager.current_ip()

    {:ok,
     assign(socket,
       page_title: "Dashboard",
       flights: flights,
       mode: mode,
       network_mode: network_mode,
       ip: ip
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

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <!-- Status Bar -->
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
    </Layouts.app>
    """
  end

  attr :flight, :map, required: true

  defp flight_card(assigns) do
    sv = assigns.flight.state_vector
    fi = assigns.flight.flight_info

    assigns =
      assign(assigns,
        callsign: sv.callsign || "---",
        airline: (fi && fi.airline_name) || "Unknown",
        aircraft: (fi && fi.aircraft_type) || "---",
        altitude: format_altitude(sv.baro_altitude),
        speed: format_speed(sv.velocity),
        bearing: format_bearing(sv.true_track),
        origin: format_airport(fi && fi.origin),
        destination: format_airport(fi && fi.destination),
        progress: (fi && fi.progress_pct) || 0.0,
        on_ground: sv.on_ground || false
      )

    ~H"""
    <div class="bg-gray-900 rounded-lg border border-gray-800 p-4 space-y-3 hover:border-gray-700 transition-colors">
      <!-- Header: callsign + airline + aircraft type -->
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
      
    <!-- Route -->
      <div class="flex items-center gap-2 text-sm">
        <span class="font-mono text-white font-medium">{@origin}</span>
        <span class="text-gray-600 text-xs">──────▶</span>
        <span class="font-mono text-white font-medium">{@destination}</span>
      </div>
      
    <!-- Telemetry grid -->
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
      
    <!-- Progress bar -->
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

  defp format_altitude(nil), do: "---"

  defp format_altitude(meters) do
    ft = round(GeoUtils.meters_to_feet(meters))

    if ft >= 18_000 do
      "FL#{div(ft, 100)}"
    else
      "#{format_number(ft)}ft"
    end
  end

  defp format_speed(nil), do: "---"
  defp format_speed(ms), do: "#{round(GeoUtils.ms_to_knots(ms))}kt"

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
