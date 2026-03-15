defmodule AeroVisionWeb.CoreComponents do
  @moduledoc """
  Provides core UI components for AeroVision.
  """
  use Phoenix.Component

  @doc """
  Renders a hero icon by name.

  ## Examples

      <.icon name="hero-x-mark" class="w-5 h-5" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end
end
