defmodule Kerf.Decide.Server do
  @moduledoc """
  SPEC_H F02 — a GenServer that asks decisions as a peer process.

  From any callback, return `{:reply, {tag, %Kerf.Decide.State{}, questions}, s}`
  or `{:reply, {tag, %Kerf.Decide.State{}, questions, opts}, s}` to ask a
  decision; any other `{:reply, value, s}` from handle_call is an ordinary
  GenServer reply (addendum A1.6). The request runs under
  Kerf.Decide.TaskSupervisor and the answer arrives as
  `handle_answer(tag, results | {:error, reason}, s)` — SPEC_H argument
  order, tag first. Failures are `{:error, {:raise, exception}}`,
  `{:error, {:exit, reason}}` or `{:error, :timeout}` (`opts[:timeout]`,
  default 2_000 ms); a result arriving after its timeout is discarded.

  Return `{:branch, branch_id, callback_return}` from handle_answer to commit
  a speculative branch: only then are that branch's answers emitted as
  `[:kerf, :decide, :answer]` (F02.4, A1.5).

  The server traps exits, so on stop it kills its in-flight requests before
  delegating `terminate/2`; `code_change/3` is delegated too (F02.2b).
  """

  # Pattern vendored from dannote/jev 0.1.0, lib/jev/server.ex:96-163.
  # MIT License — Copyright (c) 2026 Danila Poyarkov.

  @behaviour GenServer

  alias Kerf.Decide.State

  @default_timeout 2_000

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
  @callback terminate(reason :: term(), term()) :: term()
  @callback code_change(old_vsn :: term(), term(), extra :: term()) ::
              {:ok, term()} | {:error, term()}
  @optional_callbacks handle_call: 3,
                      handle_cast: 2,
                      handle_info: 2,
                      handle_continue: 2,
                      terminate: 2,
                      code_change: 3

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
  def start_link(module, arg, opts \\ []),
    do: GenServer.start_link(__MODULE__, {module, arg}, opts)

  # ---------- GenServer callbacks ----------

  @impl GenServer
  def init({mod, arg}) do
    # So terminate/2 also runs on a supervisor shutdown, not only GenServer.stop.
    Process.flag(:trap_exit, true)

    case mod.init(arg) do
      {:ok, s} -> {:ok, %{mod: mod, s: s, pending: %{}}}
      {:ok, s, extra} -> {:ok, %{mod: mod, s: s, pending: %{}}, extra}
      other -> other
    end
  end

  @impl GenServer
  def handle_call(msg, from, %{mod: mod} = st) do
    if function_exported?(mod, :handle_call, 3),
      do: handle_return(mod.handle_call(msg, from, st.s), st, :call),
      else: {:stop, {:bad_call, msg}, st}
  end

  @impl GenServer
  def handle_cast(msg, %{mod: mod} = st) do
    if function_exported?(mod, :handle_cast, 2),
      do: handle_return(mod.handle_cast(msg, st.s), st, :cast),
      else: {:stop, {:bad_cast, msg}, st}
  end

  @impl GenServer
  def handle_continue(msg, %{mod: mod} = st),
    do: handle_return(mod.handle_continue(msg, st.s), st, :continue)

  @impl GenServer
  def handle_info({ref, result}, %{pending: pending} = st)
      when is_reference(ref) and is_map_key(pending, ref) do
    Process.demonitor(ref, [:flush])
    answer(ref, result, st)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{pending: pending} = st)
      when is_map_key(pending, ref),
      do: answer(ref, {:error, {:exit, reason}}, st)

  def handle_info({:decide_timeout, ref}, %{pending: pending} = st) do
    case pending do
      %{^ref => %{task: task}} ->
        # Kills the task and flushes its reply and :DOWN, so a late result can
        # never become a second answer.
        Task.shutdown(task, :brutal_kill)
        answer(ref, {:error, :timeout}, st)

      _answered ->
        {:noreply, st}
    end
  end

  def handle_info(msg, %{mod: mod} = st) do
    if function_exported?(mod, :handle_info, 2),
      do: handle_return(mod.handle_info(msg, st.s), st, :info),
      else: {:noreply, st}
  end

  @impl GenServer
  def terminate(reason, %{mod: mod, s: s, pending: pending}) do
    # Requests are async_nolink: without this they would outlive the server.
    Enum.each(pending, fn {_ref, %{task: task, timer: timer}} ->
      Process.cancel_timer(timer)
      Task.Supervisor.terminate_child(Kerf.Decide.TaskSupervisor, task.pid)
    end)

    if function_exported?(mod, :terminate, 2), do: mod.terminate(reason, s), else: :ok
  end

  @impl GenServer
  def code_change(old_vsn, %{mod: mod, s: s} = st, extra) do
    if function_exported?(mod, :code_change, 3) do
      case mod.code_change(old_vsn, s, extra) do
        {:ok, s} -> {:ok, %{st | s: s}}
        error -> error
      end
    else
      {:ok, st}
    end
  end

  # ---------- requests and answers ----------

  defp handle_return({:reply, {tag, %State{} = state, questions}, s}, st, _origin)
       when is_list(questions),
       do: {:noreply, request(tag, state, questions, [], %{st | s: s})}

  defp handle_return({:reply, {tag, %State{} = state, questions, opts}, s}, st, _origin)
       when is_list(questions) and is_list(opts),
       do: {:noreply, request(tag, state, questions, opts, %{st | s: s})}

  defp handle_return({:reply, value, s}, st, :call), do: {:reply, value, %{st | s: s}}

  defp handle_return({:reply, value, s, extra}, st, :call),
    do: {:reply, value, %{st | s: s}, extra}

  defp handle_return({:noreply, s}, st, _origin), do: {:noreply, %{st | s: s}}
  defp handle_return({:noreply, s, extra}, st, _origin), do: {:noreply, %{st | s: s}, extra}
  defp handle_return({:stop, reason, s}, st, _origin), do: {:stop, reason, %{st | s: s}}

  defp handle_return({:stop, reason, value, s}, st, :call),
    do: {:stop, reason, value, %{st | s: s}}

  defp handle_return(other, st, _origin), do: {:stop, {:bad_return_value, other}, st}

  defp request(tag, state, questions, opts, st) do
    task =
      Task.Supervisor.async_nolink(Kerf.Decide.TaskSupervisor, fn ->
        ask(state, questions, opts)
      end)

    timer =
      Process.send_after(
        self(),
        {:decide_timeout, task.ref},
        Keyword.get(opts, :timeout, @default_timeout)
      )

    entry = %{task: task, timer: timer, tag: tag, state: state, questions: questions}
    %{st | pending: Map.put(st.pending, task.ref, entry)}
  end

  # Runs in the task. Raises and exits become answers, not crash reports.
  defp ask(state, questions, opts) do
    Kerf.Decide.ask(state, questions, opts)
  rescue
    exception -> {:error, {:raise, exception}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  defp answer(ref, result, st) do
    {entry, pending} = Map.pop!(st.pending, ref)
    Process.cancel_timer(entry.timer)
    st = %{st | pending: pending}
    results = answer_payload(result)

    case st.mod.handle_answer(entry.tag, results, st.s) do
      {:branch, branch_id, return} when is_map(results) ->
        Kerf.Decide.commit_branch({entry.state, entry.questions, results}, branch_id)
        handle_return(return, st, :answer)

      {:branch, _branch_id, return} ->
        handle_return(return, st, :answer)

      return ->
        handle_return(return, st, :answer)
    end
  end

  defp answer_payload({:ok, results}) when is_map(results), do: results
  defp answer_payload({:error, _reason} = error), do: error
  defp answer_payload(other), do: {:error, {:exit, {:bad_answer, other}}}
end
