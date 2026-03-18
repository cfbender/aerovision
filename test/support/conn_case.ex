defmodule AeroVisionWeb.ConnCase do
  @moduledoc """
  Test case template for tests that require an HTTP connection.
  Adapated from the Phoenix-generated ConnCase.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use AeroVisionWeb, :verified_routes

      import AeroVisionWeb.ConnCase
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Plug.Conn

      @endpoint AeroVisionWeb.Endpoint
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
