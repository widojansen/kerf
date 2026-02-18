defmodule ExClaw.Security.PromptGuard do
  @moduledoc """
  Detects prompt injection attempts in user input and tool arguments.
  """
  use GenServer

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def check(_input) do
    # TODO: Implement injection detection
    :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{}}
end
