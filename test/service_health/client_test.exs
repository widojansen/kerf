defmodule Kerf.ServiceHealth.ClientTest do
  # async: false — test 10 mutates Application env to exercise the default-resolution path.
  use ExUnit.Case, async: false

  alias Kerf.ServiceHealth.Client
  alias Kerf.ServiceHealth.Context

  @api_key_credential "izimotive/izi_monitoring_api_key"
  @telegram_credential "izimotive/izi2connect_telegram_token"

  # Synthetic body — NO real tenant data, keys, or tokens.
  @valid_body Jason.encode!(%{
                "status" => "healthy",
                "is_anomalous" => false,
                "anomalies" => [],
                "alerts" => [],
                "current" => %{
                  "queues" => %{"total" => 5, "healthy" => 5, "at_ceiling" => 0, "high_wait" => 0},
                  "request_rps" => 10.0,
                  "service_error_rate" => 0.0
                },
                "baseline" => %{"requests" => %{}, "services" => %{}, "jobs" => %{}}
              })

  # Always-200 HTTP stub returning the valid synthetic body.
  defp ok_http do
    fn _method, _url, _body, _headers, _opts -> {:ok, %{status: 200, body: @valid_body}} end
  end

  # Vault stub returning a fake key for any name.
  defp ok_vault(value \\ "fake-monitoring-key") do
    fn _name -> {:ok, value} end
  end

  describe "fetch_health_context/1 — happy path" do
    test "8. injected HTTP 200 + valid body returns {:ok, %Context{}}" do
      assert {:ok, %Context{} = ctx} =
               Client.fetch_health_context(http_client: ok_http(), vault_fetch: ok_vault())

      assert ctx.status == "healthy"
      assert ctx.current.queues.total == 5
    end

    test "9. vault is consulted for the api key and the key reaches the request header" do
      test_pid = self()

      vault_fetch = fn name ->
        send(test_pid, {:vault_called, name})
        {:ok, "secret-monitoring-key-123"}
      end

      http_client = fn _method, _url, _body, headers, _opts ->
        send(test_pid, {:http_headers, headers})
        {:ok, %{status: 200, body: @valid_body}}
      end

      assert {:ok, %Context{}} =
               Client.fetch_health_context(http_client: http_client, vault_fetch: vault_fetch)

      assert_received {:vault_called, @api_key_credential}
      assert_received {:http_headers, headers}

      assert Enum.any?(headers, fn {k, v} ->
               String.downcase(to_string(k)) == "x-api-key" and v == "secret-monitoring-key-123"
             end),
             "expected x-api-key header carrying the vault value, got: #{inspect(headers)}"
    end

    test "10. production-shaped call (/0 -> /1 []) resolves defaults via app config" do
      original = Application.get_env(:kerf, Client)

      Application.put_env(:kerf, Client,
        http_client: ok_http(),
        vault_fetch: ok_vault()
      )

      on_exit(fn ->
        if original do
          Application.put_env(:kerf, Client, original)
        else
          Application.delete_env(:kerf, Client)
        end
      end)

      assert {:ok, %Context{}} = Client.fetch_health_context()
      assert {:ok, %Context{}} = Client.fetch_health_context([])
    end
  end

  describe "fetch_health_context/1 — failure paths" do
    test "11. 4xx (401) returns {:error, _} and does NOT retry" do
      counter = :counters.new(1, [])

      http_client = fn _method, _url, _body, _headers, _opts ->
        :counters.add(counter, 1, 1)
        {:ok, %{status: 401, body: "unauthorized"}}
      end

      assert {:error, _} =
               Client.fetch_health_context(
                 http_client: http_client,
                 vault_fetch: ok_vault(),
                 retry_delay: 0
               )

      assert :counters.get(counter, 1) == 1
    end

    test "12. 5xx is retried, bounded at 3 total attempts, then returns {:error, _}" do
      counter = :counters.new(1, [])

      http_client = fn _method, _url, _body, _headers, _opts ->
        :counters.add(counter, 1, 1)
        {:ok, %{status: 503, body: "unavailable"}}
      end

      assert {:error, _} =
               Client.fetch_health_context(
                 http_client: http_client,
                 vault_fetch: ok_vault(),
                 retry_delay: 0
               )

      assert :counters.get(counter, 1) == 3
    end

    test "13. transient failure then success returns {:ok, _} on attempt 2" do
      counter = :counters.new(1, [])

      http_client = fn _method, _url, _body, _headers, _opts ->
        attempt = :counters.get(counter, 1) + 1
        :counters.add(counter, 1, 1)

        if attempt == 1 do
          {:ok, %{status: 500, body: "transient"}}
        else
          {:ok, %{status: 200, body: @valid_body}}
        end
      end

      assert {:ok, %Context{}} =
               Client.fetch_health_context(
                 http_client: http_client,
                 vault_fetch: ok_vault(),
                 retry_delay: 0
               )

      assert :counters.get(counter, 1) == 2
    end

    test "14. timeout surfaces as {:error, {:timeout, _}}-shaped, no raise" do
      http_client = fn _method, _url, _body, _headers, _opts -> {:error, :timeout} end

      assert {:error, {:timeout, _}} =
               Client.fetch_health_context(
                 http_client: http_client,
                 vault_fetch: ok_vault(),
                 retry_delay: 0
               )
    end

    test "15. malformed JSON body returns {:error, _}, no raise, no partial struct" do
      http_client = fn _method, _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: "this is not json{"}}
      end

      result =
        Client.fetch_health_context(http_client: http_client, vault_fetch: ok_vault())

      assert {:error, _} = result
      refute match?({:ok, %Context{}}, result)
    end

    test "16. vault fetch failure for the api key returns {:error, _}; request never issued" do
      counter = :counters.new(1, [])

      http_client = fn _method, _url, _body, _headers, _opts ->
        :counters.add(counter, 1, 1)
        {:ok, %{status: 200, body: @valid_body}}
      end

      vault_fetch = fn _name -> {:error, :not_found} end

      assert {:error, _} =
               Client.fetch_health_context(
                 http_client: http_client,
                 vault_fetch: vault_fetch
               )

      assert :counters.get(counter, 1) == 0
    end
  end

  describe "fetch_telegram_token/1 — vault wiring only (not otherwise used in this spec)" do
    test "17. vault fetch for the telegram token key succeeds and returns the value" do
      test_pid = self()

      vault_fetch = fn name ->
        send(test_pid, {:vault_called, name})
        {:ok, "fake-telegram-token-xyz"}
      end

      assert {:ok, "fake-telegram-token-xyz"} =
               Client.fetch_telegram_token(vault_fetch: vault_fetch)

      assert_received {:vault_called, @telegram_credential}
    end
  end
end
