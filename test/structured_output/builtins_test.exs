defmodule Kerf.StructuredOutput.BuiltinsTest do
  use ExUnit.Case, async: true

  alias Kerf.StructuredOutput.Builtins

  # SPEC_C §3 T1/T3 — docs/superpowers/specs/SPEC_C_triage_enum_fix.md
  #
  # This is the canonical, runtime-wired schema (registered under
  # :email_classification via Builtins.schemas() at app boot and resolved by
  # Kerf.StructuredOutput.complete/4 through SchemaRegistry). A parallel,
  # unwired schema copy previously lived on the email_triage Classifier
  # module — deferred at Stage 1 read-back, later deleted as dead-code
  # drift risk (post-SPEC_C cleanup).

  defp email_classification_schema do
    {:email_classification, schema} =
      Enum.find(Builtins.schemas(), fn {name, _schema} -> name == :email_classification end)

    schema
  end

  defp category_enum do
    email_classification_schema().json_schema["properties"]["category"]["enum"]
  end

  describe "email_classification category enum" do
    test "T1 — equals the six-value set including social" do
      assert MapSet.new(category_enum()) ==
               MapSet.new([
                 "business",
                 "personal",
                 "newsletter",
                 "transactional",
                 "spam",
                 "social"
               ])
    end

    test "T3 — marketing is not in the enum (it never was; this pins the pre-commit-2 state)" do
      refute "marketing" in category_enum()
    end
  end
end
