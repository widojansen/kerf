defmodule ExClaw.Telemetry.SupervisorTest do
  use ExUnit.Case, async: true

  @moduletag :telemetry

  describe "supervisor" do
    test "starts successfully" do
      fallback_dir = Path.join(System.tmp_dir!(), "exclaw_sup_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(fallback_dir)

      name = :"telem_sup_#{System.unique_integer([:positive])}"
      logger_name = :"telem_sup_logger_#{System.unique_integer([:positive])}"

      {:ok, pid} = ExClaw.Telemetry.Supervisor.start_link(
        name: name,
        logger_name: logger_name,
        logger_opts: [
          enabled: true,
          flush_interval_ms: 60_000,
          max_buffer_size: 100,
          fallback_dir: fallback_dir,
          ch_opts: nil
        ]
      )

      assert Process.alive?(pid)
      assert Process.whereis(logger_name) != nil

      File.rm_rf!(fallback_dir)
    end

    test "Logger is a child of the supervisor" do
      fallback_dir = Path.join(System.tmp_dir!(), "exclaw_sup_child_#{System.unique_integer([:positive])}")
      File.mkdir_p!(fallback_dir)

      name = :"telem_sup2_#{System.unique_integer([:positive])}"
      logger_name = :"telem_sup2_logger_#{System.unique_integer([:positive])}"

      {:ok, sup_pid} = ExClaw.Telemetry.Supervisor.start_link(
        name: name,
        logger_name: logger_name,
        logger_opts: [
          enabled: true,
          flush_interval_ms: 60_000,
          max_buffer_size: 100,
          fallback_dir: fallback_dir,
          ch_opts: nil
        ]
      )

      children = Supervisor.which_children(sup_pid)
      assert length(children) == 1

      File.rm_rf!(fallback_dir)
    end

    test "Logger restarts on crash" do
      fallback_dir = Path.join(System.tmp_dir!(), "exclaw_sup_restart_#{System.unique_integer([:positive])}")
      File.mkdir_p!(fallback_dir)

      name = :"telem_sup3_#{System.unique_integer([:positive])}"
      logger_name = :"telem_sup3_logger_#{System.unique_integer([:positive])}"

      {:ok, _sup_pid} = ExClaw.Telemetry.Supervisor.start_link(
        name: name,
        logger_name: logger_name,
        logger_opts: [
          enabled: true,
          flush_interval_ms: 60_000,
          max_buffer_size: 100,
          fallback_dir: fallback_dir,
          ch_opts: nil
        ]
      )

      old_pid = Process.whereis(logger_name)
      assert old_pid != nil

      Process.exit(old_pid, :kill)
      Process.sleep(50)

      new_pid = Process.whereis(logger_name)
      assert new_pid != nil
      assert new_pid != old_pid

      File.rm_rf!(fallback_dir)
    end
  end
end
