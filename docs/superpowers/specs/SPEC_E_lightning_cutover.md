# SPEC_E — Phase 2: Lightning Production Cutover (Email Triage)

**Status:** Draft for review
**Depends on:** Phase 1 GO (phase1-results-2026-08-15.md); SPEC_C deployed; Stage B verification record
**Nature:** Operations spec — all steps owner-run (systemd, docker, env). **Zero Kerf code changes.** Claude Code is not involved; Claude Desktop verifies soak output.

---

## 1. Design decisions (settled in Phase 1, recorded here)

- **Thinking-off is a server default**, via `--default-chat-template-kwargs '{"enable_thinking": false}'` — the pattern verified in production by the extraction project's vllm-qwen3 unit (empty `reasoning` confirmed on real request shapes). Kerf sends plain requests, unchanged. The per-request `chat_template_kwargs` passthrough built in SPEC_D remains in the provider for future selective-thinking tiers; unused in production.
- **Same Docker/systemd shape as the incumbent** unit (docker run, `--gpus all --ipc=host --network host`, port 8000) so Kerf's `VLLM_URL` is untouched.
- **The 512-token schema cap is unchanged**: unreachable under thinking-off (observed 44–96 output tokens); the truncation failure mode is structurally gone.
- **Memory:** `--gpu-memory-utilization 0.35` — modest bump from the eval's 0.30 now that Cascade's 0.30 vacates, leaving headroom for vllm-qwen3 (0.15), Ollama, Postgres, BEAM. Not the recipe's 0.91 (a solo-box assumption Kerf's Spark doesn't meet).
- **Context:** `--max-model-len 131072` (eval-verified; the 1M default costs memory with no current consumer).

## 2. New unit definition

Replace `ExecStart` in `/etc/systemd/system/vllm.service` (backup first — §5) with:

```
/usr/bin/docker run \
  --gpus all --ipc=host --network host --name vllm \
  -v /home/wido/models:/models \
  vllm/vllm-openai:v0.27.1 \
  --model /models/lightning-nvfp4 \
  --served-model-name lightning \
  --port 8000 \
  --moe-backend marlin \
  --kv-cache-dtype fp8 \
  --enable-prefix-caching \
  --gpu-memory-utilization 0.35 \
  --mamba-backend flashinfer \
  --mamba-cache-mode align \
  --reasoning-parser nemotron_v3 \
  --tool-call-parser qwen3_coder --enable-auto-tool-choice \
  --max-model-len 131072 \
  --default-chat-template-kwargs '{"enable_thinking": false}' \
  --speculative_config.model /models/lightning-dspark \
  --speculative_config.num_speculative_tokens 3
```

`ExecStartPre` docker stop/rm lines and the rest of the unit stay as-is. (The old unit's `-v /data/huggingface:...` mount is not needed — local checkpoint paths.)

## 3. Kerf config change

One line in `/opt/kerf/.env`: `VLLM_MODEL=lightning` (from the Cascade model name). Read at boot by runtime.exs → requires `systemctl restart kerf` after the vLLM swap. No other Kerf change. ⚠ Standard warning: view/edit `.env` knowing it holds live secrets; don't paste its contents anywhere.

## 4. Cutover sequence (one sitting, ~15 min; triage tolerates the gap)

1. Pre-flight: `docker rm -f lightning-eval` (free the eval container's 0.30); confirm `free -h` headroom; confirm both checkpoint dirs present.
2. `sudo cp /etc/systemd/system/vllm.service /etc/systemd/system/vllm.service.cascade2.bak` — the rollback artifact.
3. Edit unit per §2; `sudo systemctl daemon-reload`.
4. `sudo systemctl restart vllm` — expect ~5–6 min cold to "Application startup complete" (`journalctl -u vllm -f`).
5. Smoke: one curl to `:8000/v1/chat/completions` with the production schema (Stage B B3 pattern) — valid JSON, no thinking residue.
6. Edit `.env` (§3); `sudo systemctl restart kerf`.
7. Watch first live triage: `journalctl -u kerf -f` until an email classifies; confirm the `kb_feedback` row lands with a sane category.
8. Ingestion-gap note: emails arriving during the window are handled by the standard retry/reconciler path — verify no orphans at end of soak (§6 Q4).

## 5. Rollback (one edit, ~10 min)

`sudo cp /etc/systemd/system/vllm.service.cascade2.bak /etc/systemd/system/vllm.service && sudo systemctl daemon-reload && sudo systemctl restart vllm`, revert `VLLM_MODEL`, restart kerf. Keep `vllm-cascade:latest` image and the Cascade checkpoints on disk until soak passes (§7). Nothing else to undo.

## 6. Soak (72 h, read-only queries; naive-UTC discipline throughout)

- **Q1 — label distribution shift:** category × source counts, 72 h post vs the 30-day pre baseline. **Expected and accepted:** llm-source `spam` share falls sharply, `business` share rises (Phase 1 finding 3 — the pre-cutover spam bias was the error). Watch that `business` share of llm rows stays below ~55%; sustained above that, hand-review a sample before judging.
- **Q2 — latency from production telemetry:** p50/p95 of `llm.call.stop` `duration_ms` (telemetry_events, metadata model='lightning'). Target: p50 ≤ 2,000 ms (eval: 1,341). Compare against pre-cutover Cascade telemetry over the prior week — the honest production A/B the eval approximated.
- **Q3 — validation failures:** triage rows with an `error` context key or `decision='unclassified'` in the 72 h window. Target: 0 beyond genuine empty-content cases.
- **Q4 — pipeline integrity:** orphan check (kb_documents without triage feedback, post-reconciler) = 0; Oban discarded jobs unchanged; NotifyGuard + personal-ping behavior spot-checked against real arrivals.
- **Q5 — digest eyeball:** owner reads three consecutive daily digests. Subjective, decisive: is triage quality felt-better — especially previously-spam-swallowed business mail now appearing?

## 7. Exit criteria

**Pass:** Q2 target met, Q3 = 0, Q4 clean, Q1 within expectation, Q5 acceptable → Phase 2 closes; the Cascade image/checkpoints may be reclaimed (or kept — disk is cheap, certainty cheaper); the follow-up ledger (phase1-results §Decision) becomes the Phase 4 backlog, with business↔newsletter prompt tailoring first.
**Fail/abort:** any sustained regression, or Q5 clearly worse → §5 rollback, findings appended to the results doc, and prompt tailoring happens *before* a second attempt.

## 8. Out of scope

Prompt changes, schema changes (confidence-required), taxonomy changes (`security`), golden-v2, extraction-project consolidation, Switchyard anything. One variable at a time: this spec changes the model, nothing else.
