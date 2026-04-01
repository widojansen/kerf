defmodule ExClaw.KnowledgeBase.ChunkerTest do
  use ExUnit.Case, async: true

  alias ExClaw.KnowledgeBase.Chunker

  describe "chunk/2 with :paragraph strategy" do
    test "splits on double newlines" do
      text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
      chunks = Chunker.chunk(text, strategy: :paragraph, max_tokens: 2)

      assert length(chunks) == 3
      assert Enum.at(chunks, 0).content == "First paragraph."
      assert Enum.at(chunks, 1).content == "Second paragraph."
      assert Enum.at(chunks, 2).content == "Third paragraph."
    end

    test "merges small paragraphs up to max_tokens" do
      text = "Short.\n\nAlso short.\n\nStill short."
      # Each para is ~2-3 tokens, with max_tokens: 20 they should all merge
      chunks = Chunker.chunk(text, strategy: :paragraph, max_tokens: 20)

      assert length(chunks) == 1
      assert chunks |> hd() |> Map.get(:content) =~ "Short."
      assert chunks |> hd() |> Map.get(:content) =~ "Also short."
    end

    test "does not merge paragraphs that would exceed max_tokens" do
      para1 = String.duplicate("word ", 100) |> String.trim()
      para2 = String.duplicate("other ", 100) |> String.trim()
      text = para1 <> "\n\n" <> para2

      chunks = Chunker.chunk(text, strategy: :paragraph, max_tokens: 120)
      assert length(chunks) == 2
    end

    test "assigns sequential chunk indices" do
      text = "A.\n\nB.\n\nC."
      chunks = Chunker.chunk(text, strategy: :paragraph, max_tokens: 1)
      indices = Enum.map(chunks, & &1.index)
      assert indices == [0, 1, 2]
    end

    test "includes token_count for each chunk" do
      text = "Hello world this is a test."
      chunks = Chunker.chunk(text, strategy: :paragraph, max_tokens: 100)
      assert hd(chunks).token_count > 0
    end
  end

  describe "chunk/2 with :sentence strategy" do
    test "splits on sentence boundaries" do
      text = "First sentence. Second sentence. Third sentence."
      chunks = Chunker.chunk(text, strategy: :sentence, max_tokens: 3)

      assert length(chunks) >= 2
      assert hd(chunks).content =~ "First sentence."
    end

    test "merges short sentences up to max_tokens" do
      text = "Hi. OK. Yes. No. Fine."
      chunks = Chunker.chunk(text, strategy: :sentence, max_tokens: 50)
      assert length(chunks) == 1
    end
  end

  describe "chunk/2 with :fixed strategy" do
    test "creates fixed-size windows" do
      words = 1..100 |> Enum.map(&"word#{&1}") |> Enum.join(" ")
      chunks = Chunker.chunk(words, strategy: :fixed, max_tokens: 20, overlap_tokens: 5)

      assert length(chunks) > 1
      # Each chunk should be approximately max_tokens in size
      for chunk <- chunks do
        assert chunk.token_count <= 25
      end
    end

    test "overlap creates shared content between chunks" do
      words = 1..50 |> Enum.map(&"w#{&1}") |> Enum.join(" ")
      chunks = Chunker.chunk(words, strategy: :fixed, max_tokens: 15, overlap_tokens: 5)

      if length(chunks) >= 2 do
        first_words = String.split(Enum.at(chunks, 0).content)
        second_words = String.split(Enum.at(chunks, 1).content)
        # Last N words of first chunk should overlap with start of second
        overlap = MapSet.intersection(MapSet.new(first_words), MapSet.new(second_words))
        assert MapSet.size(overlap) > 0
      end
    end
  end

  describe "edge cases" do
    test "empty text returns empty list" do
      assert Chunker.chunk("", strategy: :paragraph) == []
    end

    test "whitespace-only text returns empty list" do
      assert Chunker.chunk("   \n\n  ", strategy: :paragraph) == []
    end

    test "single paragraph stays as one chunk" do
      text = "Just one paragraph with several words in it."
      chunks = Chunker.chunk(text, strategy: :paragraph, max_tokens: 100)
      assert length(chunks) == 1
    end

    test "very long single paragraph gets split by fixed fallback" do
      text = String.duplicate("word ", 1000) |> String.trim()
      chunks = Chunker.chunk(text, strategy: :paragraph, max_tokens: 100)
      assert length(chunks) > 1
    end

    test "default strategy is :paragraph" do
      text = "Para one.\n\nPara two."
      chunks = Chunker.chunk(text, max_tokens: 2)
      assert length(chunks) == 2
    end

    test "default max_tokens is 512" do
      # A short text should fit in one chunk with default max_tokens
      text = "Short text here."
      chunks = Chunker.chunk(text)
      assert length(chunks) == 1
    end
  end

  describe "estimate_tokens/1" do
    test "estimates roughly 1 token per 4 chars" do
      text = "Hello world"
      tokens = Chunker.estimate_tokens(text)
      assert tokens > 0
      assert tokens < 20
    end

    test "empty string returns 0" do
      assert Chunker.estimate_tokens("") == 0
    end
  end
end
