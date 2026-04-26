defmodule Kerf.Dashboard.DashboardLiveTest do
  use Kerf.ConnCase, async: false
  @moduletag :integration

  describe "root redirect" do
    test "GET / redirects to /dashboard", %{conn: conn} do
      conn = get(conn, "/")
      assert redirected_to(conn, 302) == "/dashboard"
    end
  end

  describe "live dashboard" do
    test "GET /dashboard redirects to /dashboard/home", %{conn: conn} do
      conn = get(conn, "/dashboard")
      assert redirected_to(conn, 302) =~ "/dashboard/home"
    end
  end
end
