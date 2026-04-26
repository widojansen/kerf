# Import Gmail OAuth tokens from gog CLI into the Kerf Credential Vault.
#
# Prerequisites:
#   1. Export token: gog auth tokens export alice@gmail.com --out /tmp/gmail_token.json
#   2. Credentials file: ~/.config/gogcli/credentials.json
#
# Run (while Kerf is running):
#   MIX_ENV=prod mix run priv/scripts/import_gmail_oauth.exs
#
# Run (standalone, Kerf not running):
#   MIX_ENV=prod mix run --no-start -e '
#     Application.ensure_all_started(:postgrex)
#     Application.ensure_all_started(:ecto)
#     {:ok, _} = Kerf.Repo.start_link(Application.get_env(:exclaw, Kerf.Repo))
#   ' priv/scripts/import_gmail_oauth.exs

token_path = System.get_env("GMAIL_TOKEN_PATH", "/tmp/gmail_token.json")
creds_path = System.get_env("GMAIL_CREDS_PATH", Path.expand("~/.config/gogcli/credentials.json"))

IO.puts("Reading token from: #{token_path}")
IO.puts("Reading credentials from: #{creds_path}")

token_data = File.read!(token_path) |> Jason.decode!()
creds_data = File.read!(creds_path) |> Jason.decode!()

vault_data = %{
  "access_token" => nil,
  "refresh_token" => token_data["refresh_token"],
  "client_id" => creds_data["client_id"],
  "client_secret" => creds_data["client_secret"],
  "token_url" => "https://oauth2.googleapis.com/token",
  "email" => token_data["email"],
  "scopes" => token_data["scopes"]
}

IO.puts("Email: #{vault_data["email"]}")
IO.puts("Scopes: #{length(vault_data["scopes"])} scopes")
IO.puts("Refresh token: #{String.slice(vault_data["refresh_token"], 0..20)}...")

# Store in Credential Vault
# If Kerf is running, use the GenServer. Otherwise, use the backend directly.
case Process.whereis(Kerf.CredentialVault) do
  nil ->
    IO.puts("\nCredentialVault not running — using backend directly.")

    encryption_key_base = Application.get_env(:exclaw, Kerf.CredentialVault, [])[:encryption_key_base]

    if is_nil(encryption_key_base) do
      IO.puts("ERROR: SECRET_KEY_BASE not set. Export it first.")
      System.halt(1)
    end

    encryption_key = :crypto.hash(:sha256, encryption_key_base)

    case Kerf.CredentialVault.Backend.LocalEncrypted.store(
           "gmail_oauth",
           :oauth2,
           vault_data,
           encryption_key,
           scopes: vault_data["scopes"]
         ) do
      {:ok, meta} ->
        IO.puts("Stored credential: #{meta.name} (id: #{meta.id})")

      {:error, reason} ->
        IO.puts("ERROR: #{inspect(reason)}")
        System.halt(1)
    end

  _pid ->
    IO.puts("\nCredentialVault running — using GenServer.")

    case Kerf.CredentialVault.store(
           "gmail_oauth",
           :oauth2,
           vault_data,
           scopes: vault_data["scopes"]
         ) do
      {:ok, meta} ->
        IO.puts("Stored credential: #{meta.name} (id: #{meta.id})")

      {:error, reason} ->
        IO.puts("ERROR: #{inspect(reason)}")
        System.halt(1)
    end
end

IO.puts("\nDone. The TokenRefreshWorker will obtain a fresh access_token on next check.")
IO.puts("Clean up: rm #{token_path}")
