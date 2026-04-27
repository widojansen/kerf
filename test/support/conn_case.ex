defmodule Kerf.ConnCase do
  @moduledoc """
  Test case template for Phoenix controller and LiveView tests.
  The Dashboard Endpoint is started once in test_helper.exs.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      @endpoint Kerf.Dashboard.Endpoint
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
