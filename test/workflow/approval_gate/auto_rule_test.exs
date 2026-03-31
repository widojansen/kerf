defmodule ExClaw.Workflow.ApprovalGate.AutoRuleTest do
  use ExClaw.DataCase, async: true

  alias ExClaw.Workflow.ApprovalGate.AutoRule

  describe "create/1" do
    test "creates a rule with valid attributes" do
      attrs = %{
        agent_module: "Elixir.ExClaw.Agents.EmailTriage",
        action: "add_priority_sender",
        context_pattern: %{domain: "example.com"},
        decision: "approve"
      }

      assert {:ok, rule} = AutoRule.create(attrs)
      assert rule.agent_module == "Elixir.ExClaw.Agents.EmailTriage"
      assert rule.action == "add_priority_sender"
      assert rule.context_pattern == %{domain: "example.com"}
      assert rule.decision == "approve"
      assert rule.enabled == true
      assert rule.times_matched == 0
      assert rule.last_matched_at == nil
    end

    test "validates required fields" do
      assert {:error, changeset} = AutoRule.create(%{})
      assert {"can't be blank", _} = changeset.errors[:agent_module]
      assert {"can't be blank", _} = changeset.errors[:action]
    end

    test "defaults decision to approve" do
      attrs = %{
        agent_module: "Elixir.ExClaw.Agents.EmailTriage",
        action: "label_email"
      }

      assert {:ok, rule} = AutoRule.create(attrs)
      assert rule.decision == "approve"
    end

    test "defaults context_pattern to empty map" do
      attrs = %{
        agent_module: "Elixir.ExClaw.Agents.EmailTriage",
        action: "label_email"
      }

      assert {:ok, rule} = AutoRule.create(attrs)
      assert rule.context_pattern == %{}
    end
  end

  describe "delete/1" do
    test "deletes an existing rule" do
      {:ok, rule} = AutoRule.create(valid_attrs())

      assert :ok = AutoRule.delete(rule.id)
      assert {:error, :not_found} = AutoRule.delete(rule.id)
    end

    test "returns error for non-existent rule" do
      assert {:error, :not_found} = AutoRule.delete(Ecto.UUID.generate())
    end
  end

  describe "list/1" do
    test "lists all rules" do
      {:ok, _r1} = AutoRule.create(valid_attrs(action: "action_1"))
      {:ok, _r2} = AutoRule.create(valid_attrs(action: "action_2"))

      rules = AutoRule.list()
      assert length(rules) >= 2
    end

    test "filters by agent" do
      {:ok, _} = AutoRule.create(valid_attrs(agent_module: "Elixir.AgentA", action: "a1"))
      {:ok, _} = AutoRule.create(valid_attrs(agent_module: "Elixir.AgentB", action: "b1"))

      rules = AutoRule.list(agent: "Elixir.AgentA")
      assert Enum.all?(rules, &(&1.agent_module == "Elixir.AgentA"))
    end

    test "filters by action" do
      {:ok, _} = AutoRule.create(valid_attrs(action: "label_email"))
      {:ok, _} = AutoRule.create(valid_attrs(action: "delete_email"))

      rules = AutoRule.list(action: "label_email")
      assert Enum.all?(rules, &(&1.action == "label_email"))
    end
  end

  describe "match/1" do
    test "matches on exact agent_module and action" do
      {:ok, rule} = AutoRule.create(valid_attrs())

      request = %{
        agent: ExClaw.Agents.EmailTriage,
        action: "add_priority_sender",
        context: %{sender: "john@example.com"}
      }

      assert {:ok, matched} = AutoRule.match(request)
      assert matched.id == rule.id
    end

    test "matches with context_pattern as subset of request context" do
      {:ok, rule} =
        AutoRule.create(
          valid_attrs(context_pattern: %{domain: "example.com"})
        )

      request = %{
        agent: ExClaw.Agents.EmailTriage,
        action: "add_priority_sender",
        context: %{domain: "example.com", sender: "john@example.com"}
      }

      assert {:ok, matched} = AutoRule.match(request)
      assert matched.id == rule.id
    end

    test "does not match when context_pattern has keys not in request context" do
      {:ok, _rule} =
        AutoRule.create(
          valid_attrs(context_pattern: %{domain: "example.com", vip: true})
        )

      request = %{
        agent: ExClaw.Agents.EmailTriage,
        action: "add_priority_sender",
        context: %{domain: "example.com"}
      }

      assert :no_match = AutoRule.match(request)
    end

    test "does not match when context_pattern values differ" do
      {:ok, _rule} =
        AutoRule.create(
          valid_attrs(context_pattern: %{domain: "corp.com"})
        )

      request = %{
        agent: ExClaw.Agents.EmailTriage,
        action: "add_priority_sender",
        context: %{domain: "example.com"}
      }

      assert :no_match = AutoRule.match(request)
    end

    test "disabled rules are skipped" do
      {:ok, rule} = AutoRule.create(valid_attrs())
      # Disable the rule
      rule |> Ecto.Changeset.change(enabled: false) |> ExClaw.Repo.update!()

      request = %{
        agent: ExClaw.Agents.EmailTriage,
        action: "add_priority_sender",
        context: %{}
      }

      assert :no_match = AutoRule.match(request)
    end

    test "increments times_matched on match" do
      {:ok, rule} = AutoRule.create(valid_attrs())
      assert rule.times_matched == 0

      request = %{
        agent: ExClaw.Agents.EmailTriage,
        action: "add_priority_sender",
        context: %{}
      }

      {:ok, matched} = AutoRule.match(request)
      assert matched.times_matched == 1

      {:ok, matched2} = AutoRule.match(request)
      assert matched2.times_matched == 2
    end

    test "returns :no_match when no rules exist" do
      request = %{
        agent: ExClaw.Agents.SomeAgent,
        action: "nonexistent_action",
        context: %{}
      }

      assert :no_match = AutoRule.match(request)
    end

    test "empty context_pattern matches any context" do
      {:ok, rule} = AutoRule.create(valid_attrs(context_pattern: %{}))

      request = %{
        agent: ExClaw.Agents.EmailTriage,
        action: "add_priority_sender",
        context: %{anything: "goes", here: true}
      }

      assert {:ok, matched} = AutoRule.match(request)
      assert matched.id == rule.id
    end
  end

  defp valid_attrs(overrides \\ []) do
    Enum.into(overrides, %{
      agent_module: "Elixir.ExClaw.Agents.EmailTriage",
      action: "add_priority_sender",
      context_pattern: %{},
      decision: "approve"
    })
  end
end
