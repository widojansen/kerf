defmodule ExClaw.Agents.EmailTriage.Classifier do
  @moduledoc """
  StructuredOutput wrapper for email classification.
  """

  @doc """
  Classify an email using structured output.
  Returns `{:ok, classification}` or `{:error, reason}`.
  """
  def classify(email, opts \\ []) do
    provider_fn = Keyword.get(opts, :provider_fn, &default_provider/4)
    context = Keyword.get(opts, :context, %{})
    model = Keyword.get(opts, :model, "nvidia/Qwen3-32B-NVFP4")

    messages = [%{"role" => "user", "content" => build_prompt(email, context)}]

    case provider_fn.(:email_classification, model, messages, []) do
      {:ok, result} ->
        {:ok, %{
          category: result["category"],
          priority: result["priority"],
          action: result["action"],
          confidence: result["confidence"] || 0.5,
          summary: result["summary"]
        }}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Returns the JSON schema definition for email classification.
  """
  def schema_definition do
    %{
      "type" => "object",
      "required" => ["category", "priority", "action", "summary"],
      "properties" => %{
        "category" => %{
          "type" => "string",
          "enum" => ["business", "personal", "newsletter", "transactional", "spam"]
        },
        "priority" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 5
        },
        "action" => %{
          "type" => "string",
          "enum" => ["follow_up", "archive", "flag", "ignore"]
        },
        "confidence" => %{
          "type" => "number",
          "minimum" => 0.0,
          "maximum" => 1.0
        },
        "summary" => %{
          "type" => "string",
          "maxLength" => 500
        }
      }
    }
  end

  defp build_prompt(email, context) do
    sender_ctx =
      case context[:sender_info] do
        %{is_priority: true, priority_score: score} ->
          "\nSender is a priority contact (score: #{score})."

        %{priority_score: score} when score > 0 ->
          "\nSender has priority score: #{score}."

        _ ->
          ""
      end

    interest_ctx =
      case context[:interest_matches] do
        [_ | _] = matches ->
          topics = Enum.map_join(matches, ", ", fn m -> "#{m.topic} (#{m.score})" end)
          "\nInterest matches: #{topics}"

        _ ->
          ""
      end

    """
    /no_think
    Classify this email and provide a brief summary.

    From: #{email.from.name || ""} <#{email.from.email}>
    Subject: #{email.subject}

    Body:
    #{String.slice(email.body_text || "", 0..2000)}
    #{sender_ctx}#{interest_ctx}
    """
  end

  defp default_provider(schema_name, model, messages, opts) do
    ExClaw.StructuredOutput.complete(schema_name, model, messages, opts)
  end
end
