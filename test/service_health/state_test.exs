defmodule Kerf.ServiceHealth.StateTest do
  # Section C of SPEC_02_ALERT_STATE_MACHINE.md — Ecto schema + migration.
  # Uses the Ecto sandbox. At RED the migration is deferred to GREEN, so the
  # monitoring_state table does not yet exist (tests 28/29) and the schema
  # boundary functions raise "not implemented" (tests 30/31).
  use Kerf.DataCase, async: true

  alias Kerf.ServiceHealth.State

  describe "migration" do
    test "28. monitoring_state has all columns + a unique index on target" do
      %{rows: column_rows} =
        Repo.query!(
          "SELECT column_name FROM information_schema.columns WHERE table_name = 'monitoring_state'"
        )

      columns = List.flatten(column_rows)

      for col <-
            ~w(id target last_alert_status last_alert_time consecutive_healthy consecutive_failures inserted_at updated_at) do
        assert col in columns,
               "expected column #{col} on monitoring_state, got: #{inspect(columns)}"
      end

      %{rows: index_rows} =
        Repo.query!("SELECT indexdef FROM pg_indexes WHERE tablename = 'monitoring_state'")

      indexdefs = List.flatten(index_rows)

      assert Enum.any?(indexdefs, &(&1 =~ "UNIQUE" and &1 =~ "target")),
             "expected a UNIQUE index on target, got: #{inspect(indexdefs)}"
    end

    test "29. seed row exists with Python-default values" do
      row = Repo.get_by(State, target: "izi2connect")

      assert row, "expected a seeded target: \"izi2connect\" row"
      assert row.last_alert_status == "healthy"
      assert row.last_alert_time == nil
      assert row.consecutive_healthy == 0
      assert row.consecutive_failures == 0
    end
  end

  describe "changeset" do
    test "30. target required; counters non-negative; last_alert_status known strings or nil" do
      refute State.changeset(%State{}, %{}).valid?, "target should be required"

      assert State.changeset(%State{}, %{
               target: "izi2connect",
               consecutive_healthy: 0,
               consecutive_failures: 0
             }).valid?

      # nil last_alert_status is allowed.
      assert State.changeset(%State{}, %{target: "izi2connect", last_alert_status: nil}).valid?

      # Negative counters rejected.
      refute State.changeset(%State{}, %{target: "izi2connect", consecutive_healthy: -1}).valid?
      refute State.changeset(%State{}, %{target: "izi2connect", consecutive_failures: -1}).valid?

      # Unknown last_alert_status rejected.
      refute State.changeset(%State{}, %{target: "izi2connect", last_alert_status: "bogus"}).valid?

      # Positive test per known value (KERF_CONVENTIONS: negatives can't prove completeness).
      for status <- ~w(critical anomaly warning recovered healthy) do
        assert State.changeset(%State{}, %{target: "izi2connect", last_alert_status: status}).valid?,
               "expected last_alert_status #{status} to be accepted"
      end
    end
  end

  describe "schema boundary round-trip" do
    test "31. last_alert_status round-trips :atom -> stored string -> :atom" do
      {:ok, inserted} =
        %State{}
        |> State.changeset(%{
          target: "roundtrip-test",
          last_alert_status: State.status_to_string(:critical)
        })
        |> Repo.insert()

      assert inserted.last_alert_status == "critical"

      loaded = Repo.get!(State, inserted.id)
      assert State.status_to_atom(loaded.last_alert_status) == :critical
    end
  end
end
