defmodule Kerf.Agents.EmailTriage.RoutingConfigTest do
  # async: false: tests touch the filesystem and start FileSystem watchers,
  # which are global resources. Don't try to "fix" the synchronicity.
  # (DataCase isn't needed — this GenServer doesn't touch the DB.)
  use ExUnit.Case, async: false

  alias Kerf.Agents.EmailTriage.RoutingConfig

  @valid_config """
  %{
    version: "test-1",
    rules: [
      %{name: "ping_security", match: %{category: "security"}, action: :telegram_ping},
      %{name: "default_silent", match: %{}, action: :silent}
    ]
  }
  """

  # ---------- setup ----------

  setup do
    test_id = System.unique_integer([:positive])
    tmp_dir = Path.join(System.tmp_dir!(), "kerf_routing_config_#{test_id}")
    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)
    {:ok, tmp_dir: tmp_dir}
  end

  defp default_path(tmp_dir), do: Path.join(tmp_dir, "default.exs")
  defp override_path(tmp_dir), do: Path.join(tmp_dir, "override.exs")

  defp write!(path, contents) do
    File.write!(path, contents)
    path
  end

  defp start_routing_config!(opts) do
    name = :"routing_config_#{System.unique_integer([:positive])}"
    opts = Keyword.put(opts, :name, name)
    {:ok, _pid} = RoutingConfig.start_link(opts)
    # Sync round-trip: ensures init/1 has fully completed.
    _ = RoutingConfig.current(name)
    # macOS fsevents drops events delivered within ~50ms of subscription
    # (port handshake startup latency). The probe-write-then-wait approach
    # doesn't help here because reconcile/1 only emits telemetry on changes,
    # not on every event. A small sleep is the most reliable warmup.
    # Production is unaffected — the watcher is started once at boot and
    # events arrive whenever they arrive.
    Process.sleep(150)
    name
  end

  # Telemetry hook: attaches a handler that forwards events to the test pid.
  # Detached in on_exit so handlers don't leak across tests.
  defp attach_telemetry(event_suffix, ref) do
    handler_id = "test_handler_#{:erlang.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:kerf, :routing_config, event_suffix],
      fn _event, measurements, metadata, _config ->
        send(ref, {event_suffix, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp attach_reload_handler(ref \\ self()), do: attach_telemetry(:reloaded, ref)
  defp attach_error_handler(ref \\ self()), do: attach_telemetry(:error, ref)

  # ---------- current/0 ----------

  describe "current/0" do
    test "returns loaded rules after boot", %{tmp_dir: tmp_dir} do
      write!(default_path(tmp_dir), @valid_config)

      name =
        start_routing_config!(
          default_path: default_path(tmp_dir),
          override_path: override_path(tmp_dir)
        )

      config = RoutingConfig.current(name)
      assert config.version == "test-1"
      assert is_list(config.rules)
      assert length(config.rules) == 2
      assert Enum.all?(config.rules, &is_map/1)
    end

    test "is fast (no file I/O per call) — 100 calls under 50ms", %{tmp_dir: tmp_dir} do
      write!(default_path(tmp_dir), @valid_config)

      name =
        start_routing_config!(
          default_path: default_path(tmp_dir),
          override_path: override_path(tmp_dir)
        )

      {time_us, _} =
        :timer.tc(fn -> for _ <- 1..100, do: RoutingConfig.current(name) end)

      assert time_us < 50_000,
             "100 current/0 calls took #{time_us}µs; expected < 50_000µs (file I/O suspected)"
    end
  end

  # ---------- path resolution ----------

  describe "path resolution" do
    test "uses override path when present at boot", %{tmp_dir: tmp_dir} do
      override_content = String.replace(@valid_config, "test-1", "override-1")
      write!(default_path(tmp_dir), @valid_config)
      write!(override_path(tmp_dir), override_content)

      name =
        start_routing_config!(
          default_path: default_path(tmp_dir),
          override_path: override_path(tmp_dir)
        )

      assert RoutingConfig.current(name).version == "override-1"
    end

    test "uses release default when override absent at boot", %{tmp_dir: tmp_dir} do
      write!(default_path(tmp_dir), @valid_config)
      # no override file written

      name =
        start_routing_config!(
          default_path: default_path(tmp_dir),
          override_path: override_path(tmp_dir)
        )

      assert RoutingConfig.current(name).version == "test-1"
    end

    test "both absent at boot → init returns {:stop, _}", %{tmp_dir: tmp_dir} do
      # No config files anywhere on the configured paths.
      Process.flag(:trap_exit, true)

      result =
        RoutingConfig.start_link(
          name: :"routing_config_stop_#{System.unique_integer([:positive])}",
          default_path: default_path(tmp_dir),
          override_path: override_path(tmp_dir)
        )

      assert {:error, _reason} = result
    end
  end

  # ---------- validation ----------

  describe "validation" do
    test ":version must be a string", %{tmp_dir: tmp_dir} do
      bad = """
      %{
        version: 42,
        rules: [%{name: "default_silent", match: %{}, action: :silent}]
      }
      """

      write!(default_path(tmp_dir), @valid_config)
      write!(override_path(tmp_dir), bad)

      attach_error_handler()

      name =
        start_routing_config!(
          default_path: default_path(tmp_dir),
          override_path: override_path(tmp_dir)
        )

      # Falls back to release default at boot — and emits error telemetry.
      assert RoutingConfig.current(name).version == "test-1"
      assert_receive {:error, _, metadata}, 1000
      assert metadata.reason == :invalid_version
    end

    test "each rule must have :name, :match, and :action", %{tmp_dir: tmp_dir} do
      bad = """
      %{
        version: "test",
        rules: [%{name: "incomplete"}]
      }
      """

      write!(default_path(tmp_dir), @valid_config)
      write!(override_path(tmp_dir), bad)

      attach_error_handler()

      name =
        start_routing_config!(
          default_path: default_path(tmp_dir),
          override_path: override_path(tmp_dir)
        )

      assert RoutingConfig.current(name).version == "test-1"
      assert_receive {:error, _, metadata}, 1000
      # Prefix-atom matching: pin the error kind, not the full tuple payload.
      assert is_tuple(metadata.reason) and elem(metadata.reason, 0) == :invalid_rule
    end

    test ":action must be in :telegram_ping | :telegram_digest | :silent", %{tmp_dir: tmp_dir} do
      bad = """
      %{
        version: "test",
        rules: [%{name: "bad_action", match: %{}, action: :totally_invented}]
      }
      """

      write!(default_path(tmp_dir), @valid_config)
      write!(override_path(tmp_dir), bad)

      attach_error_handler()

      name =
        start_routing_config!(
          default_path: default_path(tmp_dir),
          override_path: override_path(tmp_dir)
        )

      assert RoutingConfig.current(name).version == "test-1"
      assert_receive {:error, _, metadata}, 1000
      assert is_tuple(metadata.reason) and elem(metadata.reason, 0) == :invalid_action
    end

    test "duplicate rule names → load fails, fall back to release default at boot", %{
      tmp_dir: tmp_dir
    } do
      bad = """
      %{
        version: "test",
        rules: [
          %{name: "dup", match: %{}, action: :silent},
          %{name: "dup", match: %{}, action: :telegram_ping}
        ]
      }
      """

      write!(default_path(tmp_dir), @valid_config)
      write!(override_path(tmp_dir), bad)

      attach_error_handler()

      name =
        start_routing_config!(
          default_path: default_path(tmp_dir),
          override_path: override_path(tmp_dir)
        )

      assert RoutingConfig.current(name).version == "test-1"
      assert_receive {:error, _, metadata}, 1000
      assert is_tuple(metadata.reason) and elem(metadata.reason, 0) == :duplicate_rule_names
    end
  end

  # ---------- watcher ----------

  describe "watcher" do
    test "valid file edit reloads (assert via telemetry event)", %{tmp_dir: tmp_dir} do
      write!(default_path(tmp_dir), @valid_config)

      name =
        start_routing_config!(
          default_path: default_path(tmp_dir),
          override_path: override_path(tmp_dir)
        )

      attach_reload_handler()

      new_config = String.replace(@valid_config, "test-1", "edit-1")
      write!(override_path(tmp_dir), new_config)

      # FileSystem events can take a moment on macOS fsevents / Linux inotify.
      assert_receive {:reloaded, _measurements, %{path: path}}, 5000
      assert path == override_path(tmp_dir)

      assert RoutingConfig.current(name).version == "edit-1"
    end

    test "invalid file edit at runtime keeps current state + emits error telemetry", %{
      tmp_dir: tmp_dir
    } do
      write!(default_path(tmp_dir), @valid_config)

      name =
        start_routing_config!(
          default_path: default_path(tmp_dir),
          override_path: override_path(tmp_dir)
        )

      assert RoutingConfig.current(name).version == "test-1"

      attach_error_handler()

      # Bad Elixir — eval will raise.
      write!(override_path(tmp_dir), "this is not valid elixir code(((")

      assert_receive {:error, _, _}, 5000

      # In-memory state untouched.
      assert RoutingConfig.current(name).version == "test-1"
    end

    test "mid-run recovery: invalid edit → fix file → next reload succeeds", %{
      tmp_dir: tmp_dir
    } do
      write!(default_path(tmp_dir), @valid_config)

      name =
        start_routing_config!(
          default_path: default_path(tmp_dir),
          override_path: override_path(tmp_dir)
        )

      attach_error_handler()
      attach_reload_handler()

      # Bad edit.
      write!(override_path(tmp_dir), "broken elixir")
      assert_receive {:error, _, _}, 5000

      # Memory state stays at the release default.
      assert RoutingConfig.current(name).version == "test-1"

      # Fix the file — proves the previous error didn't taint the state machine.
      fixed = String.replace(@valid_config, "test-1", "recovered-1")
      write!(override_path(tmp_dir), fixed)
      assert_receive {:reloaded, _, _}, 5000

      assert RoutingConfig.current(name).version == "recovered-1"
    end

    test "creating override file post-boot triggers a reload from release-default to override",
         %{tmp_dir: tmp_dir} do
      # Watcher must subscribe to the parent directory (not the file) so a
      # post-boot file creation fires events.
      write!(default_path(tmp_dir), @valid_config)

      name =
        start_routing_config!(
          default_path: default_path(tmp_dir),
          override_path: override_path(tmp_dir)
        )

      assert RoutingConfig.current(name).version == "test-1"

      attach_reload_handler()

      post_boot_config = String.replace(@valid_config, "test-1", "post-boot-1")
      write!(override_path(tmp_dir), post_boot_config)

      assert_receive {:reloaded, _, _}, 5000

      assert RoutingConfig.current(name).version == "post-boot-1"
    end
  end

  # ---------- boot with invalid override ----------

  describe "boot with invalid override" do
    test "invalid override + valid release default → loads release default + emits error telemetry",
         %{tmp_dir: tmp_dir} do
      write!(default_path(tmp_dir), @valid_config)
      write!(override_path(tmp_dir), "this is broken at boot")

      attach_error_handler()

      name =
        start_routing_config!(
          default_path: default_path(tmp_dir),
          override_path: override_path(tmp_dir)
        )

      assert RoutingConfig.current(name).version == "test-1"
      assert_receive {:error, _, _}, 1000
    end
  end
end
