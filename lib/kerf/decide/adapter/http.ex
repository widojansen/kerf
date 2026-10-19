defmodule Kerf.Decide.Adapter.HTTP do
  @moduledoc """
  SPEC_H F03 — RED skeleton. POST /v1/systemone (kev, Strands Decider server,
  laya-serve). Options: `base_url:` (loopback or tailnet 100.64.0.0/10 unless
  `allow_remote: true`), `req_options:` (merged into Req.new/1).
  """

  @behaviour Kerf.Decide.Adapter

  @impl true
  def ask(_state, _questions, _opts),
    do: raise(Kerf.Decide.NotImplemented, function: "Kerf.Decide.Adapter.HTTP.ask/3")

  @impl true
  def info, do: raise(Kerf.Decide.NotImplemented, function: "Kerf.Decide.Adapter.HTTP.info/0")
end
