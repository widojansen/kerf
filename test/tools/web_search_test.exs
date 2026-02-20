defmodule ExClaw.Tools.WebSearchTest do
  use ExUnit.Case, async: true

  alias ExClaw.Tools.WebSearch

  # --- Input validation ---

  describe "validate_input/1" do
    test "rejects missing query" do
      assert {:error, reason} = WebSearch.validate_input(%{})
      assert reason =~ "query"
    end

    test "rejects empty query" do
      assert {:error, reason} = WebSearch.validate_input(%{"query" => ""})
      assert reason =~ "query"
    end

    test "rejects non-string query" do
      assert {:error, _} = WebSearch.validate_input(%{"query" => 123})
    end

    test "accepts valid input with defaults" do
      assert {:ok, %{query: "elixir otp", count: 5}} =
               WebSearch.validate_input(%{"query" => "elixir otp"})
    end

    test "accepts valid input with custom count" do
      assert {:ok, %{query: "test", count: 3}} =
               WebSearch.validate_input(%{"query" => "test", "count" => 3})
    end

    test "clamps count below 1 to 1" do
      assert {:ok, %{count: 1}} = WebSearch.validate_input(%{"query" => "test", "count" => 0})
      assert {:ok, %{count: 1}} = WebSearch.validate_input(%{"query" => "test", "count" => -5})
    end

    test "clamps count above 10 to 10" do
      assert {:ok, %{count: 10}} = WebSearch.validate_input(%{"query" => "test", "count" => 50})
    end
  end

  # --- URL construction ---

  describe "build_url/3" do
    test "constructs correct SearXNG URL" do
      url = WebSearch.build_url("http://localhost:8080", "elixir otp", 5)
      assert url =~ "http://localhost:8080/search"
      assert url =~ "format=json"
      assert url =~ "pageno=1"
      assert url =~ "q=elixir"
    end

    test "encodes special characters in query" do
      url = WebSearch.build_url("http://localhost:8080", "hello world & foo=bar", 5)
      # Should be URL-encoded
      refute url =~ " "
      assert url =~ "hello"
    end

    test "uses custom base URL" do
      url = WebSearch.build_url("http://search.example.com:9090", "test", 3)
      assert url =~ "http://search.example.com:9090/search"
    end
  end

  # --- Response parsing ---

  describe "parse_response/1" do
    test "parses valid SearXNG JSON response" do
      body = %{
        "results" => [
          %{
            "title" => "Elixir Guide",
            "url" => "https://example.com/elixir",
            "content" => "A guide to Elixir programming."
          },
          %{
            "title" => "OTP Basics",
            "url" => "https://example.com/otp",
            "content" => "Learn OTP fundamentals."
          }
        ]
      }

      assert {:ok, results} = WebSearch.parse_response(body)
      assert length(results) == 2
      assert hd(results)["title"] == "Elixir Guide"
    end

    test "returns empty list when no results key" do
      assert {:ok, []} = WebSearch.parse_response(%{})
    end

    test "returns empty list for empty results" do
      assert {:ok, []} = WebSearch.parse_response(%{"results" => []})
    end

    test "handles non-map body" do
      assert {:error, _} = WebSearch.parse_response("not a map")
    end
  end

  # --- Result formatting ---

  describe "format_results/2" do
    test "formats numbered results correctly" do
      results = [
        %{"title" => "First", "url" => "https://a.com", "content" => "First desc"},
        %{"title" => "Second", "url" => "https://b.com", "content" => "Second desc"}
      ]

      formatted = WebSearch.format_results("test query", results)
      assert formatted =~ "Search results for: \"test query\""
      assert formatted =~ "1. First"
      assert formatted =~ "https://a.com"
      assert formatted =~ "First desc"
      assert formatted =~ "2. Second"
      assert formatted =~ "https://b.com"
    end

    test "handles missing fields in result entries" do
      results = [
        %{"title" => "No URL or Content"},
        %{"url" => "https://no-title.com"}
      ]

      formatted = WebSearch.format_results("q", results)
      assert formatted =~ "No URL or Content"
      # Should not crash on missing fields
      assert is_binary(formatted)
    end

    test "returns no-results message for empty list" do
      formatted = WebSearch.format_results("nothing here", [])
      assert formatted =~ "No results found"
      assert formatted =~ "nothing here"
    end
  end

  # --- Search execution (mocked HTTP) ---

  describe "search/2" do
    test "returns formatted results from mocked SearXNG response" do
      searxng_body = %{
        "results" => [
          %{
            "title" => "Elixir Lang",
            "url" => "https://elixir-lang.org",
            "content" => "Elixir is a dynamic, functional language."
          }
        ]
      }

      http_client = fn _url, _opts ->
        {:ok, %{status: 200, body: searxng_body}}
      end

      assert {:ok, result} = WebSearch.search(
        %{"query" => "elixir"},
        http_client: http_client
      )

      assert result =~ "Elixir Lang"
      assert result =~ "https://elixir-lang.org"
      assert result =~ "Search results for"
    end

    test "returns no-results message for empty SearXNG response" do
      http_client = fn _url, _opts ->
        {:ok, %{status: 200, body: %{"results" => []}}}
      end

      assert {:ok, result} = WebSearch.search(
        %{"query" => "nonexistent gibberish xyz"},
        http_client: http_client
      )

      assert result =~ "No results found"
    end

    test "handles SearXNG 500 error" do
      http_client = fn _url, _opts ->
        {:ok, %{status: 500, body: "Internal Server Error"}}
      end

      assert {:error, reason} = WebSearch.search(
        %{"query" => "test"},
        http_client: http_client
      )

      assert reason =~ "500"
    end

    test "handles SearXNG connection errors" do
      http_client = fn _url, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end

      assert {:error, reason} = WebSearch.search(
        %{"query" => "test"},
        http_client: http_client
      )

      assert reason =~ "request failed"
    end

    test "handles malformed JSON response body" do
      http_client = fn _url, _opts ->
        {:ok, %{status: 200, body: "not json"}}
      end

      assert {:error, reason} = WebSearch.search(
        %{"query" => "test"},
        http_client: http_client
      )

      assert reason =~ "parse" or reason =~ "unexpected"
    end

    test "rejects invalid input" do
      assert {:error, _} = WebSearch.search(%{}, [])
    end

    test "respects count parameter" do
      results = Enum.map(1..10, fn i ->
        %{"title" => "Result #{i}", "url" => "https://r#{i}.com", "content" => "Desc #{i}"}
      end)

      http_client = fn _url, _opts ->
        {:ok, %{status: 200, body: %{"results" => results}}}
      end

      assert {:ok, result} = WebSearch.search(
        %{"query" => "test", "count" => 3},
        http_client: http_client
      )

      # Should only format the first 3
      assert result =~ "1. Result 1"
      assert result =~ "3. Result 3"
      refute result =~ "4. Result 4"
    end
  end
end
