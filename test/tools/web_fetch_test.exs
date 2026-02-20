defmodule ExClaw.Tools.WebFetchTest do
  use ExUnit.Case, async: true

  alias ExClaw.Tools.WebFetch

  # --- URL validation ---

  describe "validate_url/1" do
    test "rejects empty URL" do
      assert {:error, reason} = WebFetch.validate_url("")
      assert reason =~ "empty"
    end

    test "rejects non-http schemes" do
      assert {:error, _} = WebFetch.validate_url("ftp://example.com")
      assert {:error, _} = WebFetch.validate_url("file:///etc/passwd")
      assert {:error, _} = WebFetch.validate_url("javascript:alert(1)")
    end

    test "accepts http and https URLs" do
      assert :ok = WebFetch.validate_url("https://example.com")
      assert :ok = WebFetch.validate_url("http://example.com/path?q=1")
    end

    test "rejects malformed URLs" do
      assert {:error, _} = WebFetch.validate_url("not-a-url")
    end
  end

  # --- SSRF protection ---

  describe "check_ssrf/1" do
    test "blocks loopback addresses" do
      assert {:error, reason} = WebFetch.check_ssrf("127.0.0.1")
      assert reason =~ "blocked"
      assert {:error, _} = WebFetch.check_ssrf("127.0.0.254")
    end

    test "blocks localhost" do
      assert {:error, _} = WebFetch.check_ssrf("localhost")
    end

    test "blocks private 10.x range" do
      assert {:error, _} = WebFetch.check_ssrf("10.0.0.1")
      assert {:error, _} = WebFetch.check_ssrf("10.255.255.255")
    end

    test "blocks private 172.16.x range" do
      assert {:error, _} = WebFetch.check_ssrf("172.16.0.1")
      assert {:error, _} = WebFetch.check_ssrf("172.31.255.255")
    end

    test "blocks private 192.168.x range" do
      assert {:error, _} = WebFetch.check_ssrf("192.168.1.1")
    end

    test "blocks cloud metadata endpoint" do
      assert {:error, _} = WebFetch.check_ssrf("169.254.169.254")
    end

    test "allows public IPs" do
      # example.com's IP
      assert :ok = WebFetch.check_ssrf("93.184.216.34")
    end
  end

  # --- Content extraction ---

  describe "extract_content/1" do
    test "extracts title from <title> tag" do
      html = "<html><head><title>Test Page</title></head><body><p>Hello</p></body></html>"
      assert {:ok, %{title: "Test Page"}} = WebFetch.extract_content(html)
    end

    test "strips script and style elements" do
      html = """
      <html><body>
        <script>alert('xss')</script>
        <style>.red { color: red; }</style>
        <p>Visible content</p>
      </body></html>
      """

      {:ok, %{content: content}} = WebFetch.extract_content(html)
      refute content =~ "alert"
      refute content =~ "color"
      assert content =~ "Visible content"
    end

    test "strips nav, footer, header elements" do
      html = """
      <html><body>
        <nav>Menu items</nav>
        <header>Site header</header>
        <article><p>Article content here</p></article>
        <footer>Copyright 2024</footer>
      </body></html>
      """

      {:ok, %{content: content}} = WebFetch.extract_content(html)
      refute content =~ "Menu items"
      refute content =~ "Site header"
      refute content =~ "Copyright 2024"
      assert content =~ "Article content here"
    end

    test "extracts article content preferentially" do
      html = """
      <html><body>
        <div>Sidebar stuff</div>
        <article><p>Main article content</p></article>
        <div>More sidebar</div>
      </body></html>
      """

      {:ok, %{content: content}} = WebFetch.extract_content(html)
      assert content =~ "Main article content"
    end

    test "falls back to body when no article or main" do
      html = "<html><body><div><p>Body content only</p></div></body></html>"

      {:ok, %{content: content}} = WebFetch.extract_content(html)
      assert content =~ "Body content only"
    end

    test "handles empty/malformed HTML gracefully" do
      assert {:ok, %{content: ""}} = WebFetch.extract_content("")
      assert {:ok, %{content: _}} = WebFetch.extract_content("<div>no html structure</div>")
    end
  end

  # --- Truncation ---

  describe "truncate/2" do
    test "truncates content exceeding max chars" do
      long_text = String.duplicate("a", 1000)
      result = WebFetch.truncate(long_text, 100)
      assert String.length(result) <= 115  # 100 + "[truncated]" marker
      assert result =~ "[truncated]"
    end

    test "does not truncate short content" do
      result = WebFetch.truncate("short", 100)
      assert result == "short"
    end
  end

  # --- Fetch integration (mocked HTTP) ---

  describe "fetch/2" do
    test "returns formatted result on 200 with HTML" do
      html = "<html><head><title>Test</title></head><body><p>Hello world</p></body></html>"

      http_client = fn _url, _opts ->
        {:ok, %{status: 200, headers: %{"content-type" => "text/html"}, body: html}}
      end

      assert {:ok, result} = WebFetch.fetch(
        %{"url" => "https://example.com"},
        http_client: http_client
      )

      assert result =~ "URL: https://example.com"
      assert result =~ "Title: Test"
      assert result =~ "Hello world"
    end

    test "handles 404 errors" do
      http_client = fn _url, _opts ->
        {:ok, %{status: 404, headers: %{}, body: "Not Found"}}
      end

      assert {:error, reason} = WebFetch.fetch(
        %{"url" => "https://example.com/missing"},
        http_client: http_client
      )

      assert reason =~ "404"
    end

    test "handles 500 errors" do
      http_client = fn _url, _opts ->
        {:ok, %{status: 500, headers: %{}, body: "Internal Server Error"}}
      end

      assert {:error, reason} = WebFetch.fetch(
        %{"url" => "https://example.com/broken"},
        http_client: http_client
      )

      assert reason =~ "500"
    end

    test "returns non-HTML body as plain text" do
      http_client = fn _url, _opts ->
        {:ok, %{status: 200, headers: %{"content-type" => "text/plain"}, body: "Plain text content"}}
      end

      assert {:ok, result} = WebFetch.fetch(
        %{"url" => "https://example.com/file.txt"},
        http_client: http_client
      )

      assert result =~ "Plain text content"
    end

    test "handles connection errors gracefully" do
      http_client = fn _url, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end

      assert {:error, reason} = WebFetch.fetch(
        %{"url" => "https://example.com"},
        http_client: http_client
      )

      assert reason =~ "request failed"
    end

    test "rejects invalid URLs" do
      assert {:error, _} = WebFetch.fetch(%{"url" => "ftp://bad.com"}, [])
    end

    test "rejects missing url parameter" do
      assert {:error, reason} = WebFetch.fetch(%{}, [])
      assert reason =~ "url"
    end
  end
end
