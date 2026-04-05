defmodule ExClaw.Dashboard.RedirectController do
  use Phoenix.Controller, formats: [:html]

  def index(conn, _params) do
    redirect(conn, to: "/dashboard")
  end
end
