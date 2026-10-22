defmodule Kerf.Dashboard.Live.Eval.LabelPage do
  @moduledoc """
  SPEC_H F08.1–F08.4 — the owner's labelling page. Mounted only where
  `config :kerf, :eval_ui` is set (plan §2.8). RED skeleton.
  """
  use Phoenix.LiveDashboard.PageBuilder

  @impl true
  def menu_link(_, _), do: {:ok, "Eval Labels"}

  @impl true
  def mount(_params, _session, _socket), do: not_implemented("F08.2 mount/3")

  @impl true
  def render(_assigns), do: not_implemented("F08.2 render/1")

  # RED skeleton: apply/3 keeps Elixir 1.20's type inference from typing the
  # body as none(), which would turn every test call site into a type warning.
  defp not_implemented(check),
    do: apply(:erlang, :error, [RuntimeError.exception("not implemented (SPEC_H #{check})")])
end
