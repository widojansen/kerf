defmodule Kerf.KnowledgeBase.Graph do
  @moduledoc """
  AGE graph helpers for the Kerf knowledge graph.
  Wraps raw Cypher queries executed via Ecto.Adapters.SQL.query!/3.

  AGE returns `agtype` columns which Postgrex can't decode natively.
  Write operations use `count(*)` wrapper; read operations cast to text.
  """

  @graph_name "kerf_kg"

  @doc """
  Ensure AGE extension is loaded and search_path is set for the current connection.
  """
  def ensure_age_loaded(repo) do
    repo.query!("LOAD 'age'")
    repo.query!("SET search_path = ag_catalog, \"$user\", public")
    :ok
  end

  @doc """
  Create or update a Sender node.
  """
  def upsert_sender_node(repo, email, props \\ %{}) do
    name = props[:name] || ""
    priority_score = props[:priority_score] || 0.0

    cypher_write(repo, """
    MERGE (s:Sender {email: '#{escape(email)}'})
    SET s.name = '#{escape(name)}', s.priority_score = #{priority_score}
    RETURN s
    """)

    :ok
  end

  @doc """
  Create or update a Thread node.
  """
  def upsert_thread_node(repo, thread_id, props \\ %{}) do
    subject = props[:subject] || ""

    cypher_write(repo, """
    MERGE (t:Thread {gmail_thread_id: '#{escape(thread_id)}'})
    SET t.subject = '#{escape(subject)}'
    RETURN t
    """)

    :ok
  end

  @doc """
  Create a SENT edge from Sender to a Document node.
  """
  def create_sent_edge(repo, sender_email, document_id) do
    cypher_write(repo, """
    MERGE (s:Sender {email: '#{escape(sender_email)}'})
    MERGE (d:Document {id: '#{escape(document_id)}'})
    MERGE (s)-[:SENT]->(d)
    RETURN 1
    """)

    :ok
  end

  @doc """
  Create a PARTICIPATES_IN edge from Sender to Thread.
  """
  def create_participates_edge(repo, sender_email, thread_id) do
    cypher_write(repo, """
    MERGE (s:Sender {email: '#{escape(sender_email)}'})
    MERGE (t:Thread {gmail_thread_id: '#{escape(thread_id)}'})
    MERGE (s)-[:PARTICIPATES_IN]->(t)
    RETURN 1
    """)

    :ok
  end

  @doc """
  Find priority senders participating in a thread.
  Returns `{:ok, [%{email: String.t(), name: String.t(), priority_score: float()}]}`.
  """
  def priority_senders_in_thread(repo, thread_id, opts \\ []) do
    min_score = Keyword.get(opts, :min_score, 0.5)

    result = cypher_read(repo, """
    MATCH (s:Sender)-[:PARTICIPATES_IN]->(t:Thread {gmail_thread_id: '#{escape(thread_id)}'})
    WHERE s.priority_score > #{min_score}
    RETURN s.email, s.name, s.priority_score
    """, 3)

    senders =
      result
      |> Enum.map(fn [email, name, priority_score] ->
        %{
          email: parse_agtext(email),
          name: parse_agtext(name),
          priority_score: parse_agtext_number(priority_score)
        }
      end)

    {:ok, senders}
  end

  # --- Private ---

  # Write operations: wrap in count(*) to avoid returning agtype to Postgrex
  defp cypher_write(repo, cypher) do
    sql = """
    SELECT count(*) FROM ag_catalog.cypher('#{@graph_name}', $$
      #{cypher}
    $$) as (v ag_catalog.agtype)
    """

    repo.query!(sql)
  end

  # Read operations: cast each column to text to avoid agtype decoding issues
  defp cypher_read(repo, cypher, num_cols) do
    col_defs =
      1..num_cols
      |> Enum.map(&"c#{&1} ag_catalog.agtype")
      |> Enum.join(", ")

    col_casts =
      1..num_cols
      |> Enum.map(&"c#{&1}::text")
      |> Enum.join(", ")

    sql = """
    SELECT #{col_casts} FROM ag_catalog.cypher('#{@graph_name}', $$
      #{cypher}
    $$) as (#{col_defs})
    """

    case repo.query!(sql) do
      %{rows: nil} -> []
      %{rows: rows} -> rows
    end
  end

  defp parse_agtext(nil), do: nil

  defp parse_agtext(val) when is_binary(val) do
    val
    |> String.trim("\"")
    |> case do
      "" -> nil
      v -> v
    end
  end

  defp parse_agtext(val), do: val

  defp parse_agtext_number(nil), do: 0.0

  defp parse_agtext_number(val) when is_binary(val) do
    cleaned = String.trim(val, "\"")

    case Float.parse(cleaned) do
      {num, _} -> num
      :error -> 0.0
    end
  end

  defp parse_agtext_number(val) when is_number(val), do: val / 1

  defp escape(str) when is_binary(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
  end

  defp escape(val), do: to_string(val) |> escape()
end
