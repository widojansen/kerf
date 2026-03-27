defmodule ExClaw.Memory.EmbedderTest do
  use ExUnit.Case, async: true

  alias ExClaw.Memory.Embedder

  defp start_embedder(adapter) do
    suffix = System.unique_integer([:positive])
    name = :"embedder_test_#{suffix}"

    {:ok, pid} =
      Embedder.start_link(
        name: name,
        base_url: "http://localhost:11434",
        model: "nomic-embed-text",
        adapter: adapter
      )

    {name, pid}
  end

  defp fake_embedding(dims \\ 768) do
    Enum.map(1..dims, fn i -> i / dims end)
  end

  describe "embed/2" do
    test "returns embedding vector for single text" do
      embedding = fake_embedding()

      adapter = fn request ->
        {request, Req.Response.json(%{"embeddings" => [embedding]})}
      end

      {name, _} = start_embedder(adapter)
      assert {:ok, result} = Embedder.embed(name, "hello world")
      assert length(result) == 768
      assert is_float(hd(result))
    end

    test "sends correct request format to Ollama" do
      test_pid = self()
      embedding = fake_embedding()

      adapter = fn request ->
        send(test_pid, {:request, request})
        {request, Req.Response.json(%{"embeddings" => [embedding]})}
      end

      {name, _} = start_embedder(adapter)
      Embedder.embed(name, "test input")

      assert_receive {:request, req}
      body = Jason.decode!(req.body)
      assert body["model"] == "nomic-embed-text"
      assert body["input"] == "test input"
    end

    test "returns error for empty text" do
      {name, _} = start_embedder(fn req -> {req, Req.Response.json(%{"embeddings" => []})} end)
      assert {:error, _reason} = Embedder.embed(name, "")
    end

    test "handles API error response" do
      adapter = fn request ->
        {request, %Req.Response{status: 500, body: "internal server error"}}
      end

      {name, _} = start_embedder(adapter)
      assert {:error, reason} = Embedder.embed(name, "hello")
      assert reason =~ "500"
    end

    test "handles network error" do
      adapter = fn _request ->
        raise "connection refused"
      end

      {name, _} = start_embedder(adapter)
      assert {:error, reason} = Embedder.embed(name, "hello")
      assert is_binary(reason)
    end

    test "handles malformed response" do
      adapter = fn request ->
        {request, Req.Response.json(%{"unexpected" => "format"})}
      end

      {name, _} = start_embedder(adapter)
      assert {:error, _reason} = Embedder.embed(name, "hello")
    end
  end

  describe "embed_batch/2" do
    test "returns embeddings for multiple texts" do
      e1 = fake_embedding()
      e2 = fake_embedding()

      adapter = fn request ->
        {request, Req.Response.json(%{"embeddings" => [e1, e2]})}
      end

      {name, _} = start_embedder(adapter)
      assert {:ok, results} = Embedder.embed_batch(name, ["hello", "world"])
      assert length(results) == 2
      assert length(hd(results)) == 768
    end

    test "sends list input to Ollama" do
      test_pid = self()
      e1 = fake_embedding()
      e2 = fake_embedding()

      adapter = fn request ->
        send(test_pid, {:request, request})
        {request, Req.Response.json(%{"embeddings" => [e1, e2]})}
      end

      {name, _} = start_embedder(adapter)
      Embedder.embed_batch(name, ["hello", "world"])

      assert_receive {:request, req}
      body = Jason.decode!(req.body)
      assert body["input"] == ["hello", "world"]
    end

    test "returns error for empty list" do
      {name, _} = start_embedder(fn req -> {req, Req.Response.json(%{"embeddings" => []})} end)
      assert {:error, _reason} = Embedder.embed_batch(name, [])
    end
  end
end
