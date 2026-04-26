defmodule Mix.Tasks.Kerf.SeedInterests do
  @shortdoc "Seed interests and generate embeddings via bge-m3"
  @moduledoc """
  Re-generates embeddings for all interests using the configured embedding service.

  ## Usage

      mix exclaw.seed_interests
  """
  use Mix.Task

  def run(_args) do
    Mix.Task.run("app.start")

    interests = Kerf.Repo.all(Kerf.KnowledgeBase.Interest)

    if interests == [] do
      IO.puts("No interests found. Seed the kb_interests table first.")
    else
      IO.puts("Generating embeddings for #{length(interests)} interests...")

      for interest <- interests do
        text = interest.topic <> " " <> Enum.join(interest.keywords || [], " ")

        case Kerf.KnowledgeBase.Embedder.embed(text) do
          {:ok, embedding} ->
            interest
            |> Ecto.Changeset.change(%{embedding: Pgvector.new(embedding)})
            |> Kerf.Repo.update!()

            IO.puts("  OK #{interest.topic}")

          {:error, reason} ->
            IO.puts("  FAIL #{interest.topic} -- #{inspect(reason)}")
        end
      end
    end
  end
end
