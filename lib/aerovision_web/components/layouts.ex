defmodule AeroVisionWeb.Layouts do
  @moduledoc """
  Layout components for AeroVision web interface.
  """
  use AeroVisionWeb, :html

  embed_templates "layouts/*"

  @doc """
  Renders the app layout wrapping all page content.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>
  """
  attr :flash, :map, required: true
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <header class="bg-gray-900 border-b border-gray-800">
      <nav class="mx-auto flex max-w-7xl items-center justify-between p-4">
        <div class="flex items-center gap-4">
          <.link
            navigate={~p"/"}
            class="text-xl font-bold text-cyan-400 hover:text-cyan-300 transition-colors"
          >
            ✈ AeroVision
          </.link>
        </div>
        <div class="flex items-center gap-6 text-sm">
          <.link navigate={~p"/"} class="text-gray-300 hover:text-white transition-colors">
            Dashboard
          </.link>
          <.link navigate={~p"/preview"} class="text-gray-300 hover:text-white transition-colors">
            Preview
          </.link>
          <.link navigate={~p"/settings"} class="text-gray-300 hover:text-white transition-colors">
            Settings
          </.link>
        </div>
      </nav>
    </header>
    <main class="mx-auto max-w-7xl px-4 py-8">
      {render_slot(@inner_block)}
    </main>
    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Renders flash notices.
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={Phoenix.LiveView.JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class={[
        "fixed top-4 right-4 z-50 w-80 rounded-lg px-4 py-3 text-sm shadow-lg",
        @kind == :info && "bg-emerald-900 text-emerald-200 border border-emerald-700",
        @kind == :error && "bg-red-900 text-red-200 border border-red-700"
      ]}
      {@rest}
    >
      <div class="flex items-start gap-2">
        <div class="flex-1">
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <button type="button" class="cursor-pointer opacity-40 hover:opacity-70" aria-label="close">
          ✕
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error")}
        phx-connected={hide("#client-error")}
        hidden
      >
        Attempting to reconnect...
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error")}
        phx-connected={hide("#server-error")}
        hidden
      >
        Attempting to reconnect...
      </.flash>
    </div>
    """
  end

  ## JS Commands

  def show(js \\ %Phoenix.LiveView.JS{}, selector) do
    JS.show(js, to: selector)
  end

  def hide(js \\ %Phoenix.LiveView.JS{}, selector) do
    JS.hide(js, to: selector)
  end
end
