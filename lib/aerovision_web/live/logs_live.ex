defmodule AeroVisionWeb.LogsLive do
  @moduledoc false
  use AeroVisionWeb, :live_view

  @levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]

  @impl true
  def mount(_params, _session, socket) do
    on_device? = on_target?()

    if on_device? and connected?(socket) do
      apply(RingLogger.Server, :attach_client, [self()])
      AeroVision.Network.Watchdog.ping()
    end

    min_level = :info

    logs =
      if on_device? do
        fetch_logs(min_level)
      else
        []
      end

    socket =
      socket
      |> assign(page_title: "Logs", on_device?: on_device?, min_level: min_level)
      |> stream(:logs, logs)

    {:ok, socket}
  end

  @impl true
  def handle_info({:log, entry}, socket) do
    if level_at_or_above?(entry.level, socket.assigns.min_level) do
      normalized = normalize_entry(entry)
      {:noreply, stream_insert(socket, :logs, normalized)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("set_level", %{"level" => level_str}, socket) do
    min_level = String.to_existing_atom(level_str)
    logs = fetch_logs(min_level)

    socket =
      socket
      |> assign(min_level: min_level)
      |> stream(:logs, logs, reset: true)

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} fullscreen={@on_device?}>
      <%= if @on_device? do %>
        <div class="h-full flex flex-col">
          <%!-- Filter bar --%>
          <div class="flex items-center justify-between pb-3 shrink-0">
            <div class="flex items-center gap-2">
              <span class="text-sm text-gray-400">Filter:</span>
              <.level_button level={:debug} current={@min_level} />
              <.level_button level={:info} current={@min_level} />
              <.level_button level={:warning} current={@min_level} />
              <.level_button level={:error} current={@min_level} />
            </div>
            <div class="flex items-center gap-1.5 text-xs text-gray-500">
              <span class="relative flex h-2 w-2">
                <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-green-400 opacity-75">
                </span>
                <span class="relative inline-flex rounded-full h-2 w-2 bg-green-500"></span>
              </span>
              Live
            </div>
          </div>

          <%!-- Log container — fills remaining viewport, scrollable --%>
          <div
            id="log-container"
            class="flex-1 min-h-0 max-h-[75vh] bg-gray-950 border border-gray-800 rounded-lg font-mono text-xs overflow-y-scroll"
            phx-hook=".AutoScroll"
            phx-update="stream"
          >
            <div class="hidden only:flex items-center justify-center py-12 text-gray-500">
              No log entries at this level
            </div>
            <div
              :for={{id, log} <- @streams.logs}
              id={id}
              class={[
                "px-3 py-0.5 border-b border-gray-900 whitespace-pre-wrap break-all",
                level_row_class(log.level)
              ]}
            >
              <span class="text-gray-500 select-none">{log.timestamp}</span>
              <span class={["font-semibold uppercase", level_text_class(log.level)]}>
                [{log.level}]
              </span>
              <span class="text-gray-300">{log.message}</span>
            </div>
          </div>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".AutoScroll">
          export default {
            mounted() {
              this.atBottom = true
              this.el.addEventListener("scroll", () => {
                const threshold = 50
                this.atBottom =
                  this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < threshold
              })
              // Scroll to bottom on initial load
              this.el.scrollTop = this.el.scrollHeight
            },
            updated() {
              if (this.atBottom) {
                requestAnimationFrame(() => {
                  this.el.scrollTop = this.el.scrollHeight
                })
              }
            }
          }
        </script>
      <% else %>
        <div class="flex flex-col items-center justify-center min-h-[400px] text-center px-8">
          <div class="text-6xl mb-4">📋</div>
          <h2 class="text-xl font-semibold text-white mb-2">Logs unavailable</h2>
          <p class="text-gray-400 max-w-md">
            Device logs are only available when running on the physical device.
            In development, logs are printed to the terminal.
          </p>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  attr :level, :atom, required: true
  attr :current, :atom, required: true

  defp level_button(assigns) do
    ~H"""
    <button
      phx-click="set_level"
      phx-value-level={@level}
      class={[
        "px-3 py-1 rounded-full text-xs font-medium transition-colors cursor-pointer",
        if(@level == @current,
          do: "bg-gray-700 text-white",
          else: "bg-gray-900 text-gray-400 hover:bg-gray-800 hover:text-gray-300"
        )
      ]}
    >
      {@level}
    </button>
    """
  end

  # ---- Private Helpers --------------------------------------------------------

  defp fetch_logs(min_level) do
    all_entries = apply(RingLogger, :get, [])

    all_entries
    |> Enum.filter(fn entry -> level_at_or_above?(entry.level, min_level) end)
    |> Enum.take(-200)
    |> Enum.map(&normalize_entry/1)
  end

  defp normalize_entry(entry) do
    index = Keyword.get(entry.metadata, :index, System.unique_integer([:positive]))

    %{
      id: "log-#{index}",
      level: entry.level,
      message: to_string(entry.message),
      timestamp: format_timestamp(entry.timestamp)
    }
  end

  defp format_timestamp({{_y, _mo, _d}, {h, m, s, ms}}) do
    "~2..0B:~2..0B:~2..0B.~3..0B"
    |> :io_lib.format([h, m, s, ms])
    |> to_string()
  end

  defp level_at_or_above?(entry_level, min_level) do
    level_value(entry_level) >= level_value(min_level)
  end

  defp level_value(level) do
    Enum.find_index(@levels, &(&1 == level)) || 0
  end

  defp level_row_class(:error), do: "bg-red-950/30"
  defp level_row_class(:critical), do: "bg-red-950/30"
  defp level_row_class(:alert), do: "bg-red-950/30"
  defp level_row_class(:emergency), do: "bg-red-950/30"
  defp level_row_class(:warning), do: "bg-amber-950/20"
  defp level_row_class(_), do: ""

  defp level_text_class(:error), do: "text-red-400"
  defp level_text_class(:critical), do: "text-red-400"
  defp level_text_class(:alert), do: "text-red-400"
  defp level_text_class(:emergency), do: "text-red-400"
  defp level_text_class(:warning), do: "text-amber-400"
  defp level_text_class(:info), do: "text-cyan-400"
  defp level_text_class(:notice), do: "text-cyan-400"
  defp level_text_class(:debug), do: "text-gray-500"
  defp level_text_class(_), do: "text-gray-400"

  defp on_target? do
    Application.get_env(:aerovision, :target, :host) != :host
  end
end
