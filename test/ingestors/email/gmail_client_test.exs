defmodule Kerf.Ingestors.Email.GmailClientTest do
  use ExUnit.Case, async: true

  alias Kerf.Ingestors.Email.GmailClient

  @sample_message_response %{
    "id" => "msg_001",
    "threadId" => "thread_001",
    "labelIds" => ["INBOX", "UNREAD"],
    "snippet" => "Hey, just following up on...",
    "historyId" => "12345",
    "payload" => %{
      "headers" => [
        %{"name" => "From", "value" => "Alice Smith <alice@example.com>"},
        %{"name" => "To", "value" => "Alice <alice@example.com>"},
        %{"name" => "Cc", "value" => "Bob <bob@example.com>, Carol <carol@example.com>"},
        %{"name" => "Subject", "value" => "Q2 Update"},
        %{"name" => "Date", "value" => "Mon, 31 Mar 2026 10:00:00 +0000"}
      ],
      "mimeType" => "multipart/alternative",
      "parts" => [
        %{
          "mimeType" => "text/plain",
          "body" => %{
            "data" => Base.url_encode64("Hello, this is the plain text body.")
          }
        },
        %{
          "mimeType" => "text/html",
          "body" => %{
            "data" => Base.url_encode64("<p>Hello, this is the <b>HTML</b> body.</p>")
          }
        }
      ]
    }
  }

  describe "parse_message/1" do
    test "extracts all fields from Gmail message" do
      email = GmailClient.parse_message(@sample_message_response)

      assert email.id == "msg_001"
      assert email.thread_id == "thread_001"
      assert email.from.email == "alice@example.com"
      assert email.from.name == "Alice Smith"
      assert email.subject == "Q2 Update"
      assert email.body_text == "Hello, this is the plain text body."
      assert email.body_html =~ "<b>HTML</b>"
      assert email.labels == ["INBOX", "UNREAD"]
      assert email.snippet == "Hey, just following up on..."
      assert email.history_id == "12345"
    end

    test "parses To and Cc recipients" do
      email = GmailClient.parse_message(@sample_message_response)

      assert length(email.to) == 1
      assert hd(email.to).email == "alice@example.com"
      assert length(email.cc) == 2
      assert Enum.any?(email.cc, &(&1.email == "bob@example.com"))
    end

    test "handles missing Cc header" do
      msg = put_in(@sample_message_response, ["payload", "headers"], [
        %{"name" => "From", "value" => "alice@example.com"},
        %{"name" => "To", "value" => "alice@example.com"},
        %{"name" => "Subject", "value" => "Test"}
      ])

      email = GmailClient.parse_message(msg)
      assert email.cc == []
    end

    test "handles plain email address without name" do
      msg = put_in(@sample_message_response, ["payload", "headers"], [
        %{"name" => "From", "value" => "alice@example.com"},
        %{"name" => "To", "value" => "alice@example.com"},
        %{"name" => "Subject", "value" => "Test"}
      ])

      email = GmailClient.parse_message(msg)
      assert email.from.email == "alice@example.com"
      assert email.from.name == nil
    end

    test "extracts text body from non-multipart message" do
      msg = %{
        "id" => "msg_002",
        "threadId" => "thread_002",
        "labelIds" => ["INBOX"],
        "snippet" => "Simple",
        "historyId" => "99",
        "payload" => %{
          "headers" => [
            %{"name" => "From", "value" => "bob@example.com"},
            %{"name" => "To", "value" => "alice@example.com"},
            %{"name" => "Subject", "value" => "Simple"}
          ],
          "mimeType" => "text/plain",
          "body" => %{
            "data" => Base.url_encode64("Plain body only.")
          }
        }
      }

      email = GmailClient.parse_message(msg)
      assert email.body_text == "Plain body only."
      assert email.body_html == nil
    end
  end

  describe "parse_address/1" do
    test "parses Name <email>" do
      assert %{name: "Alice", email: "alice@example.com"} =
               GmailClient.parse_address("Alice <alice@example.com>")
    end

    test "parses bare email" do
      assert %{name: nil, email: "alice@example.com"} =
               GmailClient.parse_address("alice@example.com")
    end

    test "parses quoted name" do
      assert %{name: "Alice Smith", email: "alice@example.com"} =
               GmailClient.parse_address("\"Alice Smith\" <alice@example.com>")
    end
  end

  describe "parse_address_list/1" do
    test "parses comma-separated addresses" do
      result = GmailClient.parse_address_list("Alice <a@x.com>, Bob <b@x.com>")
      assert length(result) == 2
    end

    test "returns empty list for nil" do
      assert GmailClient.parse_address_list(nil) == []
    end
  end

  describe "fetch_new/3" do
    test "uses history API when history_id provided" do
      test_pid = self()

      http_client = fn method, url, _body, _headers, _opts ->
        send(test_pid, {:request, method, url})

        cond do
          String.contains?(url, "/history") ->
            {:ok, %{status: 200, body: Jason.encode!(%{
              "history" => [
                %{"messagesAdded" => [%{"message" => %{"id" => "msg_new"}}]}
              ],
              "historyId" => "99999"
            })}}

          String.contains?(url, "/messages/msg_new") ->
            {:ok, %{status: 200, body: Jason.encode!(%{
              "id" => "msg_new", "threadId" => "t1", "labelIds" => ["INBOX"],
              "snippet" => "New", "historyId" => "99999",
              "payload" => %{
                "headers" => [
                  %{"name" => "From", "value" => "a@x.com"},
                  %{"name" => "To", "value" => "b@x.com"},
                  %{"name" => "Subject", "value" => "New msg"}
                ],
                "mimeType" => "text/plain",
                "body" => %{"data" => Base.url_encode64("body")}
              }
            })}}

          true ->
            {:ok, %{status: 404, body: "not found"}}
        end
      end

      assert {:ok, emails, new_history_id} =
               GmailClient.fetch_new("token123", http_client: http_client, history_id: "11111")

      assert length(emails) == 1
      assert hd(emails).id == "msg_new"
      assert new_history_id == "99999"
      assert_receive {:request, :get, url}
      assert url =~ "/history"
    end

    test "falls back to messages.list when no history_id" do
      http_client = fn _method, url, _body, _headers, _opts ->
        cond do
          String.contains?(url, "/messages") and not String.contains?(url, "/messages/") ->
            {:ok, %{status: 200, body: Jason.encode!(%{
              "messages" => [%{"id" => "msg_list1"}]
            })}}

          String.contains?(url, "/messages/msg_list1") ->
            {:ok, %{status: 200, body: Jason.encode!(%{
              "id" => "msg_list1", "threadId" => "t1", "labelIds" => ["INBOX"],
              "snippet" => "Listed", "historyId" => "55555",
              "payload" => %{
                "headers" => [
                  %{"name" => "From", "value" => "x@y.com"},
                  %{"name" => "To", "value" => "w@y.com"},
                  %{"name" => "Subject", "value" => "Listed msg"}
                ],
                "mimeType" => "text/plain",
                "body" => %{"data" => Base.url_encode64("listed body")}
              }
            })}}

          true ->
            {:ok, %{status: 404, body: "not found"}}
        end
      end

      assert {:ok, emails, history_id} =
               GmailClient.fetch_new("token", http_client: http_client)

      assert length(emails) == 1
      assert history_id == "55555"
    end

    test "returns error on HTTP failure" do
      http_client = fn _method, _url, _body, _headers, _opts ->
        {:ok, %{status: 401, body: "Unauthorized"}}
      end

      assert {:error, _} = GmailClient.fetch_new("bad_token", http_client: http_client)
    end
  end

  describe "fetch_new/3 — history expiry" do
    test "returns :history_expired on 404 from history API" do
      http_client = fn _method, url, _body, _headers, _opts ->
        if String.contains?(url, "/history") do
          {:ok, %{status: 404, body: Jason.encode!(%{"error" => %{"code" => 404}})}}
        else
          {:ok, %{status: 200, body: Jason.encode!(%{"messages" => []})}}
        end
      end

      assert {:error, :history_expired} =
               GmailClient.fetch_new("token", http_client: http_client, history_id: "old_id")
    end
  end

  describe "fetch_new/3 — pagination" do
    test "fetches first page of messages.list without paginating" do
      http_client = fn _method, url, _body, _headers, _opts ->
        cond do
          String.contains?(url, "/messages") and not String.contains?(url, "/messages/") ->
            {:ok, %{status: 200, body: Jason.encode!(%{
              "messages" => [%{"id" => "msg_a"}],
              "nextPageToken" => "page2"
            })}}

          String.contains?(url, "/messages/msg_a") ->
            {:ok, %{status: 200, body: Jason.encode!(msg_payload("msg_a", "11111"))}}

          true ->
            {:ok, %{status: 404, body: ""}}
        end
      end

      assert {:ok, emails, _history_id} =
               GmailClient.fetch_new("token", http_client: http_client)

      # Only first page fetched — no pagination on messages.list
      ids = Enum.map(emails, & &1.id)
      assert ids == ["msg_a"]
    end

    test "follows nextPageToken in history API" do
      http_client = fn _method, url, _body, _headers, _opts ->
        cond do
          String.contains?(url, "pageToken=hpage2") ->
            {:ok, %{status: 200, body: Jason.encode!(%{
              "history" => [
                %{"messagesAdded" => [%{"message" => %{"id" => "msg_h2"}}]}
              ],
              "historyId" => "99999"
            })}}

          String.contains?(url, "/history") ->
            {:ok, %{status: 200, body: Jason.encode!(%{
              "history" => [
                %{"messagesAdded" => [%{"message" => %{"id" => "msg_h1"}}]}
              ],
              "historyId" => "99998",
              "nextPageToken" => "hpage2"
            })}}

          String.contains?(url, "/messages/msg_h1") ->
            {:ok, %{status: 200, body: Jason.encode!(msg_payload("msg_h1", "99998"))}}

          String.contains?(url, "/messages/msg_h2") ->
            {:ok, %{status: 200, body: Jason.encode!(msg_payload("msg_h2", "99999"))}}

          true ->
            {:ok, %{status: 404, body: ""}}
        end
      end

      assert {:ok, emails, history_id} =
               GmailClient.fetch_new("token", http_client: http_client, history_id: "90000")

      ids = Enum.map(emails, & &1.id) |> Enum.sort()
      assert ids == ["msg_h1", "msg_h2"]
      assert history_id == "99999"
    end
  end

  describe "search/3" do
    test "searches with query parameter" do
      test_pid = self()

      http_client = fn _method, url, _body, _headers, _opts ->
        send(test_pid, {:search_url, url})

        cond do
          String.contains?(url, "/messages") and not String.contains?(url, "/messages/") ->
            {:ok, %{status: 200, body: Jason.encode!(%{"messages" => []})}}

          true ->
            {:ok, %{status: 404, body: ""}}
        end
      end

      assert {:ok, []} =
               GmailClient.search("token", "from:alice@example.com", http_client: http_client)

      assert_receive {:search_url, url}
      assert url =~ "q=from%3Aalice%40example.com"
    end
  end

  describe "modify_message/4" do
    test "adds and removes labels in one call" do
      test_pid = self()

      http_client = fn method, url, body, _headers, _opts ->
        send(test_pid, {:modify, method, url, Jason.decode!(body)})
        {:ok, %{status: 200, body: Jason.encode!(%{"id" => "msg_001"})}}
      end

      assert :ok =
               GmailClient.modify_message("token", "msg_001",
                 add: ["Label_1"],
                 remove: ["UNREAD"],
                 http_client: http_client
               )

      assert_receive {:modify, :post, url, body}
      assert url =~ "/messages/msg_001/modify"
      assert body["addLabelIds"] == ["Label_1"]
      assert body["removeLabelIds"] == ["UNREAD"]
    end

    test "handles add-only" do
      test_pid = self()

      http_client = fn _method, _url, body, _headers, _opts ->
        send(test_pid, {:body, Jason.decode!(body)})
        {:ok, %{status: 200, body: Jason.encode!(%{"id" => "msg_001"})}}
      end

      assert :ok =
               GmailClient.modify_message("token", "msg_001",
                 add: ["STARRED"],
                 http_client: http_client
               )

      assert_receive {:body, body}
      assert body["addLabelIds"] == ["STARRED"]
      assert body["removeLabelIds"] == []
    end

    test "returns error on failure" do
      http_client = fn _method, _url, _body, _headers, _opts ->
        {:ok, %{status: 403, body: "Forbidden"}}
      end

      assert {:error, msg} =
               GmailClient.modify_message("token", "msg_001",
                 add: ["Label_1"],
                 http_client: http_client
               )

      assert msg =~ "403"
    end
  end

  describe "build_auth_headers/1" do
    test "builds Bearer authorization header" do
      headers = GmailClient.build_auth_headers("my_token")
      assert {"authorization", "Bearer my_token"} in headers
    end
  end

  # --- Helpers ---

  defp msg_payload(id, history_id) do
    %{
      "id" => id, "threadId" => "t_#{id}", "labelIds" => ["INBOX"],
      "snippet" => "test", "historyId" => history_id,
      "payload" => %{
        "headers" => [
          %{"name" => "From", "value" => "x@y.com"},
          %{"name" => "To", "value" => "w@y.com"},
          %{"name" => "Subject", "value" => "Msg #{id}"}
        ],
        "mimeType" => "text/plain",
        "body" => %{"data" => Base.url_encode64("body of #{id}")}
      }
    }
  end
end
