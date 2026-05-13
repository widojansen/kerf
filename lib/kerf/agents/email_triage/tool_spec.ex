defmodule Kerf.Agents.EmailTriage.ToolSpec do
  @moduledoc """
  Builds the OpenAI-compatible tool spec for the Enricher (spec §4.4).

  The vocabulary lists for `topic` and `action` are interpolated into the
  parameter `description` strings, not into JSON schema `enum` constraints,
  so the LLM retains proposal freedom on those dimensions. `urgency` is
  enum-locked. `summary` carries the original-language preservation
  instruction (Step 0b finding).
  """

  @doc """
  Build the tool spec from currently-accepted vocabulary lists.

  Called fresh per Enricher job so newly-accepted taxonomy values become
  available without restart.
  """
  @spec build(accepted_topics :: [String.t()], accepted_actions :: [String.t()]) :: map()
  def build(accepted_topics, accepted_actions)
      when is_list(accepted_topics) and is_list(accepted_actions) do
    topics_str = Enum.join(accepted_topics, ", ")
    actions_str = Enum.join(accepted_actions, ", ")

    %{
      type: "function",
      function: %{
        name: "enrich_email",
        description:
          "Extract structured labels from an email. Use the curated vocabularies where they fit; propose new values only when no existing value applies.",
        parameters: %{
          type: "object",
          required: ["urgency", "action", "topic", "summary"],
          properties: %{
            urgency: %{
              type: "string",
              enum: ["high", "medium", "low", "none"],
              description:
                "How time-sensitive. 'high' = within 24h; 'none' = no action expected."
            },
            action: %{
              type: "string",
              description:
                "What to do with this email. Prefer these values: #{actions_str}. If none fit, propose a new lowercase snake_case value."
            },
            action_proposed_new: %{
              type: "boolean",
              description: "Set to true if your action value is NOT in the prefer list."
            },
            topic: %{
              type: "array",
              items: %{type: "string"},
              minItems: 1,
              maxItems: 4,
              description:
                "1-4 topics this email is about. Prefer these values: #{topics_str}. Propose new lowercase snake_case values only if needed."
            },
            topic_proposed_new: %{
              type: "array",
              items: %{type: "string"},
              description:
                "Subset of topic[] containing values NOT in the prefer list. Empty array if all topics are from the prefer list."
            },
            summary: %{
              type: "string",
              maxLength: 200,
              description:
                "One sentence describing the email. CRITICAL: write the summary in the same language as the email body. Dutch email → Dutch summary; English email → English summary. Do not translate."
            }
          },
          additionalProperties: false
        }
      }
    }
  end
end
