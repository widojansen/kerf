defmodule Kerf.Agents.EmailTriage.BodyPrep do
  @moduledoc """
  Pure, deterministic body preparation for email summarisation.

  RED-PHASE SKELETON — NOT YET IMPLEMENTED.

  Intended contract (see `body_prep_test.exs`): strip recognised boilerplate
  (view-in-browser lines, unsubscribe/footer blocks, URL/tracking-dominant
  lines, repeated separator rules, leading edition/TOC headers), collapse
  whitespace runs, then return the cleaned content within a byte budget
  (default `@default_budget`). Empty/whitespace-only input returns "".

  The body below is a placeholder pass-through so the suite COMPILES and every
  test fails for the expected reason (feature missing). Do not treat it as the
  implementation.
  """

  @default_budget 4000

  @doc "Default byte budget applied when `:budget` is not supplied."
  def default_budget, do: @default_budget

  @doc """
  Prepare `raw_text` for summarisation within `opts[:budget]` bytes.

  Not implemented — placeholder pass-through.
  """
  @spec prepare(String.t() | nil, keyword()) :: String.t()
  def prepare(raw_text, opts \\ [])

  def prepare(raw_text, _opts) when is_binary(raw_text), do: raw_text
  def prepare(_raw_text, _opts), do: ""
end
