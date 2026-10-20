defmodule Kerf.Eval.Harness.Score do
  @moduledoc """
  SPEC_H F09.1–F09.7 (scoring side) and F07.3 (histogram shape) — turns a run
  (header + answer lines, plan §2.3) and the manifest items into the report
  map of plan §2.4.

  Lines are the string-keyed maps `Kerf.Eval.Harness.Run.read/1` returns.
  Manifest items are read with `Map.get/2` only, so plain maps and the
  `%Kerf.Eval.Manifest.Item{}` struct both work. The report is string-keyed
  throughout (JSON-shaped).
  """

  alias Kerf.Eval.Harness.Run

  @type report :: %{String.t() => term()}
  @type item :: map()

  @spec score(Run.line(), [Run.line()], [item()], keyword()) :: report()
  def score(_header, _lines, _items, _opts), do: not_implemented("F09.1")

  @spec accuracy([Run.line()], [item()]) :: %{String.t() => map()}
  def accuracy(_lines, _items), do: not_implemented("F09.1")

  @spec ece([{float(), boolean()}]) :: float() | nil
  def ece(_samples), do: not_implemented("F09.2")

  @spec fit_temperature([{[float()], non_neg_integer()}]) :: float()
  def fit_temperature(_samples), do: not_implemented("F09.2")

  @spec apply_temperature([float()], float()) :: [float()]
  def apply_temperature(_probs, _t), do: not_implemented("F09.2")

  @spec flip_rate([Run.line()]) :: map()
  def flip_rate(_lines), do: not_implemented("F09.3")

  @spec isolation([Run.line()]) :: map()
  def isolation(_lines), do: not_implemented("F09.4")

  @spec latency([Run.line()]) :: map()
  def latency(_lines), do: not_implemented("F09.5")

  @spec coverage([Run.line()], non_neg_integer()) :: map()
  def coverage(_lines, _expected), do: not_implemented("F09.6")

  @spec contrastive([Run.line()], [item()]) :: map()
  def contrastive(_lines, _items), do: not_implemented("F09.7")

  @spec histograms(%{model_id: String.t(), confidences: %{String.t() => [float()]}}) ::
          %{String.t() => map()}
  def histograms(_input), do: not_implemented("F07.3")

  @spec gates(report()) :: %{String.t() => map()}
  def gates(_report), do: not_implemented("F09.1")

  # RED skeleton. The dynamic apply/3 keeps Elixir's cross-module type inference
  # from typing every caller's result as none(), which would turn each test that
  # uses a result into a compile warning.
  defp not_implemented(check),
    do: apply(:erlang, :error, [RuntimeError.exception("not implemented (SPEC_H #{check})")])
end
