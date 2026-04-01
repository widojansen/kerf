defmodule ExClaw.KnowledgeBase.EmbedderTest do
  use ExUnit.Case, async: true

  alias ExClaw.KnowledgeBase.Embedder

  @fake_embedding List.duplicate(0.1, 768)

  describe "embed/2" do
    test "returns embedding vector for single text" do
      http_client = fn _method, _url, _body, _headers, _opts ->
        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "data" => [%{"embedding" => @fake_embedding, "index" => 0}],
               "model" => "nomic-embed-text",
               "usage" => %{"prompt_tokens" => 5, "total_tokens" => 5}
             })
         }}
      end

      assert {:ok, embedding} = Embedder.embed("Hello world", http_client: http_client)
      assert length(embedding) == 768
    end

    test "sends correct request format" do
      test_pid = self()

      http_client = fn method, url, body, headers, _opts ->
        send(test_pid, {:request, method, url, body, headers})

        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "data" => [%{"embedding" => @fake_embedding, "index" => 0}]
             })
         }}
      end

      Embedder.embed("test text",
        http_client: http_client,
        url: "http://localhost:8001",
        model: "nomic-embed-text"
      )

      assert_receive {:request, :post, "http://localhost:8001/v1/embeddings", body, headers}
      decoded = Jason.decode!(body)
      assert decoded["input"] == ["test text"]
      assert decoded["model"] == "nomic-embed-text"
      assert {"content-type", "application/json"} in headers
    end

    test "returns error on HTTP failure" do
      http_client = fn _method, _url, _body, _headers, _opts ->
        {:ok, %{status: 500, body: "Internal Server Error"}}
      end

      assert {:error, "embedding API error 500" <> _} =
               Embedder.embed("text", http_client: http_client)
    end

    test "returns error on network failure" do
      http_client = fn _method, _url, _body, _headers, _opts ->
        {:error, %{reason: :econnrefused}}
      end

      assert {:error, "embedding request failed: " <> _} =
               Embedder.embed("text", http_client: http_client)
    end

    test "returns error for empty text" do
      assert {:error, "text cannot be empty"} = Embedder.embed("")
      assert {:error, "text cannot be empty"} = Embedder.embed("   ")
    end
  end

  describe "embed_batch/2" do
    test "returns embeddings for multiple texts" do
      http_client = fn _method, _url, body, _headers, _opts ->
        decoded = Jason.decode!(body)
        count = length(decoded["input"])

        embeddings =
          Enum.map(0..(count - 1), fn i ->
            %{"embedding" => @fake_embedding, "index" => i}
          end)

        {:ok,
         %{
           status: 200,
           body: Jason.encode!(%{"data" => embeddings})
         }}
      end

      texts = ["Hello", "World", "Test"]
      assert {:ok, embeddings} = Embedder.embed_batch(texts, http_client: http_client)
      assert length(embeddings) == 3
      assert Enum.all?(embeddings, &(length(&1) == 768))
    end

    test "sends all texts in single request" do
      test_pid = self()

      http_client = fn _method, _url, body, _headers, _opts ->
        send(test_pid, {:batch_request, Jason.decode!(body)})

        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "data" => [
                 %{"embedding" => @fake_embedding, "index" => 0},
                 %{"embedding" => @fake_embedding, "index" => 1}
               ]
             })
         }}
      end

      Embedder.embed_batch(["a", "b"], http_client: http_client)
      assert_receive {:batch_request, %{"input" => ["a", "b"]}}
    end

    test "returns error for empty list" do
      assert {:error, "texts cannot be empty"} = Embedder.embed_batch([])
    end

    test "orders results by index" do
      # API might return results out of order
      http_client = fn _method, _url, _body, _headers, _opts ->
        emb1 = List.duplicate(0.1, 768)
        emb2 = List.duplicate(0.2, 768)

        {:ok,
         %{
           status: 200,
           body:
             Jason.encode!(%{
               "data" => [
                 %{"embedding" => emb2, "index" => 1},
                 %{"embedding" => emb1, "index" => 0}
               ]
             })
         }}
      end

      assert {:ok, [first, second]} = Embedder.embed_batch(["a", "b"], http_client: http_client)
      assert hd(first) == 0.1
      assert hd(second) == 0.2
    end
  end
end
