defmodule Kerf.Dashboard.Live.Eval.LabelPage do
  @moduledoc """
  SPEC_H F08.1–F08.4 — the owner's labelling page. Mounted only where
  `config :kerf, :eval_ui` is true (plan §2.8); the manifest path is read at
  runtime from `:eval_manifest_path` (S-36).

  The page is a thin form over `Kerf.Eval.Manifest`: every event calls the
  matching `put_*`/`add_synthetic_item`/`mark_pair`, then `save/2`, then reloads
  the file, and renders the loader's violations verbatim. It never computes
  counts, tiers, splits or languages itself. Freezing is not offered here.
  """
  use Phoenix.LiveDashboard.PageBuilder

  alias Kerf.Eval.Manifest

  @impl true
  def menu_link(_, _), do: {:ok, "Eval Labels"}

  @impl true
  def mount(_params, _session, socket) do
    path = manifest_path()

    {:ok,
     socket
     |> assign(path: path, manifest: nil, violations: [])
     |> reload()}
  end

  # -- events ------------------------------------------------------------------

  @impl true
  def handle_event("save_label", %{"item_id" => id, "labels" => labels}, socket)
      when is_map(labels) do
    mutate(socket, fn manifest ->
      Manifest.put_label(manifest, id, convert_labels(labels, manifest), now())
    end)
  end

  def handle_event("save_tier", %{"item_id" => id, "tier" => tier} = params, socket) do
    reason = Map.get(params, "tier_reason", "")
    mutate(socket, &Manifest.put_tier(&1, id, tier, reason, now()))
  end

  def handle_event("save_language", %{"item_id" => id, "language" => language}, socket) do
    mutate(socket, &Manifest.put_language(&1, id, language))
  end

  def handle_event("add_synthetic", %{"of_item_id" => id, "state" => state}, socket)
      when is_map(state) do
    mutate(socket, fn manifest ->
      with {:ok, {updated, _new_id}} <-
             Manifest.add_synthetic_item(manifest, id, synthetic_state(state), now()) do
        {:ok, updated}
      end
    end)
  end

  def handle_event(
        "mark_pair",
        %{"pair_id" => pair_id, "item_a" => a, "item_b" => b, "fact" => fact},
        socket
      ) do
    mutate(socket, &Manifest.mark_pair(&1, pair_id, a, b, fact))
  end

  def handle_event(event, _params, socket) do
    {:noreply, assign(socket, violations: [{:bad_event, nil, event}])}
  end

  # -- state -------------------------------------------------------------------

  defp manifest_path, do: Application.get_env(:kerf, :eval_manifest_path)

  defp reload(%{assigns: %{path: nil}} = socket), do: assign(socket, manifest: nil)

  defp reload(%{assigns: %{path: path}} = socket) do
    case Manifest.load(path) do
      {:ok, manifest} -> assign(socket, manifest: manifest, violations: [])
      {:error, violations} -> assign(socket, manifest: nil, violations: violations)
    end
  end

  # put_* and save/2 either succeed and the page shows the file as written, or
  # the violations are shown and the file is not touched.
  defp mutate(%{assigns: %{manifest: nil}} = socket, _fun), do: {:noreply, socket}

  defp mutate(%{assigns: %{manifest: manifest, path: path}} = socket, fun) do
    with {:ok, updated} <- fun.(manifest),
         :ok <- Manifest.save(updated, path) do
      {:noreply, socket |> assign(violations: []) |> reload()}
    else
      {:error, violations} -> {:noreply, assign(socket, violations: violations)}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # The form posts strings; the loader wants booleans and an integer. A value
  # that does not parse is passed through, so the loader names the violation.
  defp convert_labels(labels, %Manifest{question_set: question_set}) do
    Map.new(labels, fn {question, value} ->
      {question, convert(get_in(question_set, [question, "type"]), value)}
    end)
  end

  defp convert("noul", "true"), do: true
  defp convert("noul", "false"), do: false

  defp convert("score", value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp convert(_type, value), do: value

  defp synthetic_state(state) do
    %{
      from: Map.get(state, "from"),
      from_name: Map.get(state, "from_name"),
      subject: Map.get(state, "subject"),
      date: Map.get(state, "date"),
      body: Map.get(state, "body")
    }
  end

  # -- view helpers ------------------------------------------------------------

  defp options(manifest, question), do: get_in(manifest.question_set, [question, "options"]) || []

  defp levels(manifest) do
    manifest.question_set |> get_in(["urgency", "levels"]) |> List.wrap() |> Enum.with_index(1)
  end

  defp label(%{labels: labels}, question) when is_map(labels), do: Map.get(labels, question)
  defp label(_item, _question), do: nil

  defp category_value(item), do: label(item, "category") || item.seed_category

  defp state_field(%{state: state}, key) when is_map(state), do: Map.get(state, key)
  defp state_field(_item, _key), do: nil

  # -- render ------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <.card>
      <h5>Eval labels</h5>
      <%= cond do %>
        <% @path == nil -> %>
          <p>No manifest is configured. Set KERF_EVAL_MANIFEST to the manifest path and restart.</p>
        <% @manifest == nil -> %>
          <p>The manifest at <code><%= @path %></code> could not be loaded.</p>
        <% true -> %>
          <p><%= @manifest.counts.labelled %> of <%= @manifest.counts.total %> labelled</p>
      <% end %>
      <%= if @violations != [] do %>
        <ul>
          <%= for violation <- @violations do %>
            <li><code><%= inspect(violation) %></code></li>
          <% end %>
        </ul>
      <% end %>
    </.card>

    <%= if @manifest do %>
      <%= for item <- @manifest.items do %>
        <.card>
          <div id={"item-#{item.id}"}>
            <h5>
              <%= item.id %> <small>(<%= item.language %>, tier <%= item.tier || "-" %>)</small>
            </h5>
            <p>
              <strong><%= state_field(item, :subject) %></strong>
              from <%= state_field(item, :from) %> on <%= state_field(item, :date) %>
            </p>
            <pre style="white-space:pre-wrap"><%= state_field(item, :body) %></pre>

            <form phx-submit="save_label">
              <input type="hidden" name="item_id" value={item.id} />
              <label>category
                <select name="labels[category]">
                  <%= for option <- options(@manifest, "category") do %>
                    <option value={option} selected={option == category_value(item)}><%= option %></option>
                  <% end %>
                </select>
              </label>
              <label>needs_reply
                <select name="labels[needs_reply]">
                  <%= for value <- ["true", "false"] do %>
                    <option value={value} selected={value == to_string(label(item, "needs_reply"))}><%= value %></option>
                  <% end %>
                </select>
              </label>
              <label>urgency
                <select name="labels[urgency]">
                  <%= for {text, level} <- levels(@manifest) do %>
                    <option value={level} selected={level == label(item, "urgency")}><%= text %></option>
                  <% end %>
                </select>
              </label>
              <label>deadline_present
                <select name="labels[deadline_present]">
                  <%= for value <- ["true", "false"] do %>
                    <option value={value} selected={value == to_string(label(item, "deadline_present"))}><%= value %></option>
                  <% end %>
                </select>
              </label>
              <label>client
                <select name="labels[client]">
                  <%= for option <- options(@manifest, "client") do %>
                    <option value={option} selected={option == label(item, "client")}><%= option %></option>
                  <% end %>
                </select>
              </label>
              <button type="submit">Save label</button>
            </form>

            <form phx-submit="save_tier">
              <input type="hidden" name="item_id" value={item.id} />
              <select name="tier">
                <%= for tier <- ["easy", "standard", "hard"] do %>
                  <option value={tier} selected={tier == item.tier}><%= tier %></option>
                <% end %>
              </select>
              <input type="text" name="tier_reason" value={item.tier_reason} placeholder="reason" />
              <button type="submit">Save tier</button>
            </form>

            <form phx-submit="save_language">
              <input type="hidden" name="item_id" value={item.id} />
              <select name="language">
                <%= for language <- ["nl", "de", "en", "und"] do %>
                  <option value={language} selected={language == item.language}><%= language %></option>
                <% end %>
              </select>
              <button type="submit">Save language</button>
            </form>
          </div>
        </.card>
      <% end %>

      <.card>
        <h5>Add a synthetic variant</h5>
        <form phx-submit="add_synthetic">
          <input type="text" name="of_item_id" placeholder="source item id" />
          <input type="text" name="state[from]" placeholder="from" />
          <input type="text" name="state[from_name]" placeholder="from name" />
          <input type="text" name="state[subject]" placeholder="subject" />
          <input type="text" name="state[date]" placeholder="date" />
          <textarea name="state[body]" placeholder="body"></textarea>
          <button type="submit">Add</button>
        </form>
      </.card>

      <.card>
        <h5>Mark a pair</h5>
        <form phx-submit="mark_pair">
          <input type="text" name="pair_id" placeholder="pair id" />
          <input type="text" name="item_a" placeholder="item a" />
          <input type="text" name="item_b" placeholder="item b" />
          <input type="text" name="fact" placeholder="what changed" />
          <button type="submit">Mark pair</button>
        </form>
      </.card>
    <% end %>
    """
  end
end
