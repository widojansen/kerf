# Seeds for kb_interests table.
# Run with: mix run priv/repo/seeds/interests.exs

alias ExClaw.KnowledgeBase.Interest
alias ExClaw.Repo

interests = [
  %{topic: "AI/ML", keywords: ["artificial intelligence", "machine learning", "LLM", "neural network", "deep learning", "transformer", "GPT", "Claude"]},
  %{topic: "Elixir/OTP", keywords: ["elixir", "erlang", "OTP", "GenServer", "supervision", "phoenix", "liveview"]},
  %{topic: "NVIDIA", keywords: ["nvidia", "cuda", "GPU", "DGX", "tensorrt", "vllm", "blackwell"]},
  %{topic: "Automotive", keywords: ["automotive", "TecDoc", "parts", "vehicle", "car", "workshop"]},
  %{topic: "Invoice Processing", keywords: ["invoice", "extraction", "OCR", "document processing", "PDF"]},
  %{topic: "MCP", keywords: ["model context protocol", "MCP", "tool use", "function calling"]},
  %{topic: "Infrastructure", keywords: ["kubernetes", "docker", "systemd", "deployment", "CI/CD", "DevOps"]},
  %{topic: "Security", keywords: ["cybersecurity", "ransomware", "zero trust", "authentication", "OAuth"]},
  %{topic: "Business/Consulting", keywords: ["consulting", "agency", "SaaS", "client", "proposal", "contract"]},
  %{topic: "Rust", keywords: ["rust", "cargo", "crate", "ownership", "borrow checker"]},
  %{topic: "Privacy", keywords: ["privacy", "GDPR", "data protection", "encryption", "local-first"]},
  %{topic: "Open Source", keywords: ["open source", "github", "contribution", "license", "community"]}
]

for attrs <- interests do
  %Interest{}
  |> Interest.changeset(attrs)
  |> Repo.insert!(on_conflict: :nothing, conflict_target: [:topic])
end

IO.puts("Seeded #{length(interests)} interests.")
