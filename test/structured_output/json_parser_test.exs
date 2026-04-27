defmodule Kerf.StructuredOutput.JSONParserTest do
  use ExUnit.Case, async: true

  alias Kerf.StructuredOutput.JSONParser

  describe "parse/1" do
    test "parses raw JSON object" do
      assert {:ok, %{"name" => "Alice"}} = JSONParser.parse(~s({"name": "Alice"}))
    end

    test "parses raw JSON array" do
      assert {:ok, [1, 2, 3]} = JSONParser.parse("[1, 2, 3]")
    end

    test "parses JSON wrapped in ```json fences" do
      input = """
      ```json
      {"category": "business", "priority": 3}
      ```
      """

      assert {:ok, %{"category" => "business", "priority" => 3}} = JSONParser.parse(input)
    end

    test "parses JSON wrapped in ``` fences without json tag" do
      input = """
      ```
      {"key": "value"}
      ```
      """

      assert {:ok, %{"key" => "value"}} = JSONParser.parse(input)
    end

    test "parses JSON preceded by <think> tags" do
      input = """
      <think>
      Let me think about this carefully. The email is about business.
      I should classify it as priority 3.
      </think>
      {"category": "business", "priority": 3}
      """

      assert {:ok, %{"category" => "business", "priority" => 3}} = JSONParser.parse(input)
    end

    test "parses JSON with trailing text after closing brace" do
      input = ~s({"result": "yes"} some trailing text here)
      assert {:ok, %{"result" => "yes"}} = JSONParser.parse(input)
    end

    test "parses JSON with trailing text after closing bracket" do
      input = ~s([1, 2, 3] and some extra)
      assert {:ok, [1, 2, 3]} = JSONParser.parse(input)
    end

    test "parses JSON with leading text before opening brace" do
      input = ~s(Here is the result: {"answer": 42})
      assert {:ok, %{"answer" => 42}} = JSONParser.parse(input)
    end

    test "returns error for empty string" do
      assert {:error, _reason} = JSONParser.parse("")
    end

    test "returns error for nil" do
      assert {:error, _reason} = JSONParser.parse(nil)
    end

    test "returns error for invalid JSON" do
      assert {:error, _reason} = JSONParser.parse("{invalid json}")
    end

    test "returns error for plain text without JSON" do
      assert {:error, _reason} = JSONParser.parse("Hello, this is just text.")
    end

    test "handles nested objects" do
      input = ~s({"outer": {"inner": {"deep": true}}})
      assert {:ok, %{"outer" => %{"inner" => %{"deep" => true}}}} = JSONParser.parse(input)
    end

    test "handles escaped characters" do
      input = ~s({"text": "line1\\nline2", "path": "C:\\\\Users"})
      assert {:ok, %{"text" => "line1\nline2", "path" => "C:\\Users"}} = JSONParser.parse(input)
    end

    test "handles unicode" do
      input = ~s({"emoji": "\\u2764", "name": "caf\\u00e9"})
      assert {:ok, %{"emoji" => "\u2764", "name" => "caf\u00e9"}} = JSONParser.parse(input)
    end

    test "handles think tags with json fences combined" do
      input = """
      <think>
      Let me analyze this.
      </think>
      ```json
      {"decision": "yes"}
      ```
      """

      assert {:ok, %{"decision" => "yes"}} = JSONParser.parse(input)
    end

    test "takes first valid JSON when multiple objects present" do
      input = ~s({"first": true} {"second": true})
      assert {:ok, %{"first" => true}} = JSONParser.parse(input)
    end

    test "handles JSON with whitespace padding" do
      input = "   \n\n  {\"key\": \"value\"}  \n\n  "
      assert {:ok, %{"key" => "value"}} = JSONParser.parse(input)
    end
  end
end
