defmodule Kerf.Decide.Server do
  @moduledoc """
  SPEC_H F02 — RED skeleton.

  A GenServer that asks decisions as a peer process. From any callback,
  return `{:reply, {tag, state, questions}, s}` or
  `{:reply, {tag, state, questions, opts}, s}`; the request runs under
  Kerf.Decide.TaskSupervisor and the answer arrives as
  `handle_answer(tag, results | {:error, reason}, s)` (SPEC_H argument order,
  tag first). Return `{:branch, branch_id, callback_return}` from
  handle_answer to commit a speculative branch (F02.4).
  """

  # Pattern vendored from dannote/jev 0.1.0, lib/jev/server.ex:96-163.
  # MIT License — Copyright (c) 2026 Danila Poyarkov.

  @type reply ::
          {:reply, {term(), Kerf.Decide.State.t(), [Kerf.Decide.Question.t()]}, term()}
          | {:reply, {term(), Kerf.Decide.State.t(), [Kerf.Decide.Question.t()], keyword()},
             term()}
          | {:noreply, term()}
          | {:noreply, term(), timeout() | :hibernate | {:continue, term()}}
          | {:stop, term(), term()}

  @callback init(arg :: term()) :: {:ok, term()} | {:stop, term()} | :ignore
  @callback handle_answer(
              tag :: term(),
              %{atom() => Kerf.Decide.Result.t()} | {:error, term()},
              term()
            ) ::
              reply() | {:branch, atom(), reply()}
  @callback handle_call(term(), GenServer.from(), term()) :: reply()
  @callback handle_cast(term(), term()) :: reply()
  @callback handle_info(term(), term()) :: reply()
  @callback handle_continue(term(), term()) :: reply()
  @optional_callbacks handle_call: 3, handle_cast: 2, handle_info: 2, handle_continue: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour Kerf.Decide.Server

      def child_spec(arg) do
        %{id: __MODULE__, start: {Kerf.Decide.Server, :start_link, [__MODULE__, arg]}}
      end

      defoverridable child_spec: 1
    end
  end

  @spec start_link(module(), term(), GenServer.options()) :: GenServer.on_start()
  def start_link(_module, _arg, _opts \\ []),
    do: raise(Kerf.Decide.NotImplemented, function: "Kerf.Decide.Server.start_link/3")
end
