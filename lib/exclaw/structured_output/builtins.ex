defmodule Kerf.StructuredOutput.Builtins do
  @moduledoc """
  Built-in schemas registered at application startup.
  """

  def schemas do
    [
      {:yes_no,
       %{
         json_schema: %{
           "type" => "object",
           "properties" => %{
             "decision" => %{"type" => "string", "enum" => ["yes", "no"]},
             "reason" => %{"type" => "string"}
           },
           "required" => ["decision", "reason"]
         },
         coercions: [],
         description: "A yes/no decision with reasoning",
         max_tokens: 256
       }},
      {:priority_score,
       %{
         json_schema: %{
           "type" => "object",
           "properties" => %{
             "score" => %{"type" => "integer", "minimum" => 1, "maximum" => 10},
             "factors" => %{"type" => "array", "items" => %{"type" => "string"}},
             "explanation" => %{"type" => "string"}
           },
           "required" => ["score", "factors", "explanation"]
         },
         coercions: [score: :integer],
         description: "A priority score from 1-10 with contributing factors",
         max_tokens: 512
       }},
      {:email_classification,
       %{
         json_schema: %{
           "type" => "object",
           "properties" => %{
             "category" => %{
               "type" => "string",
               "enum" => ["business", "personal", "newsletter", "transactional", "spam"]
             },
             "priority" => %{"type" => "integer", "minimum" => 1, "maximum" => 5},
             "action" => %{
               "type" => "string",
               "enum" => ["follow_up", "archive", "flag", "ignore"]
             },
             "confidence" => %{"type" => "number", "minimum" => 0.0, "maximum" => 1.0},
             "summary" => %{"type" => "string", "maxLength" => 500}
           },
           "required" => ["category", "priority", "action", "summary"]
         },
         coercions: [priority: :integer, confidence: :float],
         description: "Classify an email by category, priority, action, and summary",
         max_tokens: 512
       }},
      {:entity_extraction,
       %{
         json_schema: %{
           "type" => "object",
           "properties" => %{
             "entities" => %{
               "type" => "array",
               "items" => %{
                 "type" => "object",
                 "properties" => %{
                   "name" => %{"type" => "string"},
                   "type" => %{
                     "type" => "string",
                     "enum" => ["person", "organization", "location", "date", "amount"]
                   },
                   "value" => %{"type" => "string"}
                 },
                 "required" => ["name", "type", "value"]
               }
             }
           },
           "required" => ["entities"]
         },
         coercions: [],
         description: "Extract named entities from text",
         max_tokens: 1024
       }}
    ]
  end
end
