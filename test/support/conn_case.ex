defmodule AeroVisionWeb.ConnCase do
  @moduledoc """
  Test case template for tests that require an HTTP connection.
  Adapated from the Phoenix-generated ConnCase.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint AeroVisionWeb.Endpoint

      use AeroVisionWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import AeroVisionWeb.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
