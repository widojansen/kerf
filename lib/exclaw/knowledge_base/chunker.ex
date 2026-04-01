defmodule ExClaw.KnowledgeBase.Chunker do
  @moduledoc """
  Splits documents into chunks for embedding.
  """

  @default_max_tokens 512
  @default_overlap_tokens 50

  @doc """
  Chunk a text into embedding-sized pieces.

  Options:
    - `:strategy` — `:paragraph` (default), `:sentence`, or `:fixed`
    - `:max_tokens` — target chunk size (default 512)
    - `:overlap_tokens` — overlap between chunks for `:fixed` strategy (default 50)
  """
  def chunk(text, opts \\ []) do
    text = String.trim(text)

    if text == "" do
      []
    else
      strategy = Keyword.get(opts, :strategy, :paragraph)
      max_tokens = Keyword.get(opts, :max_tokens, @default_max_tokens)
      overlap_tokens = Keyword.get(opts, :overlap_tokens, @default_overlap_tokens)

      segments =
        case strategy do
          :paragraph -> chunk_by_paragraph(text, max_tokens)
          :sentence -> chunk_by_sentence(text, max_tokens)
          :fixed -> chunk_by_fixed(text, max_tokens, overlap_tokens)
        end

      segments
      |> Enum.with_index()
      |> Enum.map(fn {content, index} ->
        %{content: content, index: index, token_count: estimate_tokens(content)}
      end)
    end
  end

  @doc """
  Estimate token count for a text. Approximates ~1 token per 4 characters
  (rough heuristic matching typical BPE tokenizers).
  """
  def estimate_tokens(""), do: 0

  def estimate_tokens(text) do
    # Word-based estimate: split by whitespace, count words.
    # This is closer to actual tokenization than char/4.
    text |> String.split(~r/\s+/, trim: true) |> length()
  end

  # --- Paragraph strategy ---

  defp chunk_by_paragraph(text, max_tokens) do
    paragraphs =
      text
      |> String.split(~r/\n\s*\n/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    merge_segments(paragraphs, max_tokens, "\n\n")
  end

  # --- Sentence strategy ---

  defp chunk_by_sentence(text, max_tokens) do
    sentences =
      text
      |> String.split(~r/(?<=[.!?])\s+/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    merge_segments(sentences, max_tokens, " ")
  end

  # --- Fixed window strategy ---

  defp chunk_by_fixed(text, max_tokens, overlap_tokens) do
    words = String.split(text, ~r/\s+/, trim: true)
    step = max(max_tokens - overlap_tokens, 1)

    words
    |> Stream.unfold(fn
      [] -> nil
      remaining ->
        {chunk_words, _rest} = Enum.split(remaining, max_tokens)
        next = Enum.drop(remaining, step)
        {Enum.join(chunk_words, " "), next}
    end)
    |> Enum.to_list()
  end

  # --- Shared helpers ---

  # Merges small segments together until they'd exceed max_tokens.
  # If a single segment exceeds max_tokens, it falls back to fixed splitting.
  defp merge_segments(segments, max_tokens, joiner) do
    segments
    |> Enum.reduce([], fn segment, acc ->
      seg_tokens = estimate_tokens(segment)

      if seg_tokens > max_tokens do
        # Single segment too large — split it with fixed strategy
        sub_chunks = chunk_by_fixed(segment, max_tokens, 0)
        acc ++ sub_chunks
      else
        case acc do
          [] ->
            [segment]

          _ ->
            last = List.last(acc)
            merged = last <> joiner <> segment
            merged_tokens = estimate_tokens(merged)

            if merged_tokens <= max_tokens do
              List.replace_at(acc, -1, merged)
            else
              acc ++ [segment]
            end
        end
      end
    end)
  end
end
