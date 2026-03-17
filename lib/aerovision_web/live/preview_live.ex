defmodule AeroVisionWeb.PreviewLive do
  use AeroVisionWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    # Load last pixel data immediately so the grid isn't blank on load
    last_pixels =
      try do
        AeroVision.Display.PreviewServer.get_last_pixels()
      catch
        :exit, _ -> nil
      end

    if connected?(socket) do
      Phoenix.PubSub.subscribe(AeroVision.PubSub, "preview")
      Phoenix.PubSub.subscribe(AeroVision.PubSub, "config")

      # Push cached pixels immediately if available
      if last_pixels do
        send(self(), {:preview_pixels, last_pixels})
      end
    end

    {:ok,
     assign(socket,
       page_title: "Display Preview",
       last_updated: if(last_pixels, do: DateTime.utc_now(), else: nil),
       pixel_count: if(last_pixels, do: length(last_pixels), else: 0),
       timezone: AeroVision.Config.Store.get(:timezone)
     )}
  end

  @impl true
  def handle_info({:preview_pixels, pixels}, socket) do
    socket =
      socket
      |> assign(last_updated: DateTime.utc_now(), pixel_count: length(pixels))
      |> push_event("pixels", %{data: pixels})

    {:noreply, socket}
  end

  def handle_info({:config_changed, :timezone, value}, socket) do
    {:noreply, assign(socket, timezone: value)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-4">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-bold text-white">Display Preview</h1>
          <div class="text-sm text-gray-500">
            <%= if @last_updated do %>
              Updated:
              <span class="text-gray-400 font-mono">
                {format_local_time(@last_updated, @timezone)}
              </span>
            <% else %>
              <span class="text-gray-600">Waiting for first frame...</span>
            <% end %>
          </div>
        </div>

        <p class="text-sm text-gray-500">
          Live pixel render of the 64×64 LED panel. Updates whenever the display changes.
        </p>

        <%!-- Pixel grid container — populated and updated by the PixelGrid JS hook --%>
        <div class="bg-black rounded-lg border border-gray-800 p-6 flex justify-center">
          <div
            id="pixel-grid"
            phx-hook="PixelGrid"
            phx-update="ignore"
            style="display:grid;grid-template-columns:repeat(64,6px);width:384px;height:384px;gap:0;image-rendering:pixelated"
          >
            <%!-- JS hook creates 4096 divs on mount --%>
          </div>
        </div>

        <div class="text-xs text-gray-700">
          <p>
            Each cell is 6×6px — 64×64 = 4,096 pixels total. The physical panel uses RGB LEDs at full resolution.
          </p>
        </div>

        <%= unless File.exists?(Application.app_dir(:aerovision, "priv/led_driver")) do %>
          <div class="text-sm text-amber-600 bg-amber-950/50 border border-amber-800 rounded-lg px-4 py-3">
            <code>priv/led_driver</code>
            not found — run <code class="text-cyan-400">cd go_src && make build-host</code>
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp format_local_time(nil, _), do: "--:--:--"

  defp format_local_time(%DateTime{} = dt, timezone) do
    case DateTime.shift_zone(dt, timezone) do
      {:ok, shifted} -> Calendar.strftime(shifted, "%H:%M:%S")
      {:error, _} -> Calendar.strftime(dt, "%H:%M:%S")
    end
  end
end
