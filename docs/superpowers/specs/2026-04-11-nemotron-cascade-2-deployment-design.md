# Nemotron-Cascade-2 Deployment — Design Spec

**Date**: 2026-04-11
**Status**: Approved
**Objective**: Replace Qwen3-32B-NVFP4 (dense, ~50s/email) with Nemotron-Cascade-2-30B-A3B-NVFP4 (MoE, 3B active) on DGX Spark for 5-10x throughput improvement.

## Background

ExClaw's email triage pipeline currently uses Qwen3-32B-NVFP4 via vLLM on the DGX Spark. At ~50s per email with `guided_json` constraint decoding, a batch of 50 emails takes ~45 minutes. Nemotron-Cascade-2 is an MoE model (30B total / 3B active parameters) that should dramatically reduce per-token latency while maintaining classification quality.

**Why build from source**: The current NGC `vllm:26.02-py3` container (vLLM 0.15.1, CUDA 13.1) doesn't fully support Nemotron-Cascade-2 NVFP4 on SM 12.1. Two upstream PRs are required:
- **FlashInfer PR #2913** — GDC compile flag fix for CUTLASS fused MoE on SM 12.x
- **vLLM PR #38423** — CUTLASS v4.4.2 + FlashInfer 0.6.7 bump, SM12x NVFP4 tile constraints

### Current State on Spark

vLLM runs as a **Docker container managed by systemd**:
- Image: `nvcr.io/nvidia/vllm:26.02-py3` (vLLM 0.15.1, CUDA 13.1)
- systemd unit: `/etc/systemd/system/vllm.service`
- Model cache: `/data/huggingface` mounted to `/root/.cache/huggingface`
- Flags: `--gpu-memory-utilization 0.7 --tool-call-parser hermes`
- Disk: 3.3 TB free on `/data`

## Scope

### In Scope

1. **Dockerfile** (`deploy/vllm-cascade/Dockerfile`) — custom image based on NGC with patched FlashInfer + vLLM
2. **Build + deploy script** (`deploy/vllm-cascade.sh`) — builds Docker image, downloads model, swaps systemd service
3. **systemd unit** (`deploy/vllm-cascade.service`) — Docker-based vLLM service for Nemotron-Cascade-2
4. **ExClaw code changes** — update default model references
5. **Validation** — automated health checks in the deploy script

### Out of Scope

- ModelRouter changes (existing `^nemotron` regex already routes correctly)
- `<think>` tag handling (already works in JSONParser and Telegram)
- VLLMProvider protocol changes (same OpenAI-compatible API)
- Tool calling format changes (same Qwen3-style format)
- Test model name changes (tests use injected mock providers)

## Architecture

No architectural changes. The substitution is at the model layer only:

```
ExClaw (unchanged) → VLLMProvider (unchanged) → vLLM API :8000 → Nemotron-Cascade-2 (new)
                                                                    ↑ was: Qwen3-32B-NVFP4
```

The `--served-model-name nemotron-cascade-2` maps to the existing ModelRouter route `{~r/^nemotron/i, VLLMProvider}`.

## Part 1: Custom Docker Image (`deploy/vllm-cascade/Dockerfile`)

Build a custom image on top of the NGC base that patches FlashInfer and vLLM:

```dockerfile
FROM nvcr.io/nvidia/vllm:26.02-py3

# --- FlashInfer: apply GDC fix for SM 12.x MoE kernels (PR #2913) ---
WORKDIR /tmp/flashinfer
RUN git clone https://github.com/flashinfer-ai/flashinfer.git . && \
    git fetch origin pull/2913/head:fix-gdc-moe && \
    git merge fix-gdc-moe
ENV FLASHINFER_CUDA_ARCH_LIST="12.1a"
RUN pip install -e . -v

# --- vLLM: apply NVFP4 SM12x tile constraint fix (PR #38423) ---
WORKDIR /tmp/vllm-patch
RUN git clone https://github.com/vllm-project/vllm.git . && \
    git fetch origin pull/38423/head:fix-nvfp4-spark && \
    git merge fix-nvfp4-spark
RUN pip install -e . -v

WORKDIR /workspace
```

**Why extend NGC instead of building from scratch**: The NGC image already has CUDA 13.1, PyTorch, TensorRT, NCCL, and all GPU driver bindings correctly configured. Starting from scratch would mean rebuilding all of that.

**Build time**: The FlashInfer and vLLM rebuilds inside Docker will take a while (CUDA kernel compilation). This is a one-time cost — subsequent `docker run` starts use the cached image.

## Part 2: Build + Deploy Script (`deploy/vllm-cascade.sh`)

### Purpose

Single script to build the Docker image, download the model, and swap the systemd service. Run via SSH:
```bash
ssh spark
cd ~/Projects/exClaw/exclaw
./deploy/vllm-cascade.sh
```

### Phases

**Phase 1 — Preflight checks**
- Verify Docker is running
- Verify `HF_TOKEN` is set (needed for model download)
- Verify sufficient disk space on `/data` (~25 GB for model)
- Check if existing vllm service is running (warn, will be stopped)

**Phase 2 — Download model (before build, to fail fast)**
- `docker run --rm -v /data/huggingface:/root/.cache/huggingface -e HF_TOKEN nvcr.io/nvidia/vllm:26.02-py3 huggingface-cli download chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4`
- Skips if already cached (huggingface-cli is idempotent)

**Phase 3 — Build custom Docker image**
- `docker build -t vllm-cascade:latest deploy/vllm-cascade/`
- Tag with timestamp: `vllm-cascade:20260411-143000`

**Phase 4 — Backup and swap systemd service**
- Copy current `/etc/systemd/system/vllm.service` to `/etc/systemd/system/vllm-qwen3.service.bak`
- Stop running vllm service
- Install new `deploy/vllm-cascade.service` as `/etc/systemd/system/vllm.service`
- `systemctl daemon-reload && systemctl start vllm`

**Phase 5 — Validation**
- Wait up to 300s for vLLM to start (first boot JIT compiles CUDA kernels)
- Poll `http://localhost:8000/v1/models`
- Verify response contains `nemotron-cascade-2`
- Run a simple completion test
- Report success or failure with next steps

### Script flags

| Flag | Behavior |
|------|----------|
| (none) | Full pipeline: preflight → download → build → swap → validate |
| `--build-only` | Build Docker image only (no service changes) |
| `--service-only` | Just reinstall systemd unit and restart (skip build) |
| `--validate` | Only run validation checks against running service |
| `--rollback` | Restore the backed-up Qwen3 service and restart |

## Part 3: systemd Unit (`deploy/vllm-cascade.service`)

Mirrors the current Docker-based pattern:

```ini
[Unit]
Description=vLLM Nemotron-Cascade-2 NVFP4
After=docker.service
Requires=docker.service
Before=exclaw.service

[Service]
Type=simple
Restart=always
RestartSec=10
ExecStartPre=-/usr/bin/docker stop vllm
ExecStartPre=-/usr/bin/docker rm vllm
ExecStart=/usr/bin/docker run \
  --gpus all \
  --network host \
  --name vllm \
  -v /data/huggingface:/root/.cache/huggingface \
  vllm-cascade:latest \
  vllm serve chankhavu/Nemotron-Cascade-2-30B-A3B-NVFP4 \
    --host 0.0.0.0 \
    --port 8000 \
    --served-model-name nemotron-cascade-2 \
    --tensor-parallel-size 1 \
    --gpu-memory-utilization 0.85 \
    --max-model-len 131072 \
    --mamba-ssm-cache-dtype float32 \
    --kv-cache-dtype fp8 \
    --trust-remote-code \
    --enable-auto-tool-choice \
    --tool-call-parser qwen3_coder \
    --reasoning-parser nemotron_v3
ExecStop=/usr/bin/docker stop vllm

[Install]
WantedBy=multi-user.target
```

Key differences from current service:
- Image: `vllm-cascade:latest` (custom, not NGC)
- `--gpu-memory-utilization 0.85` (was 0.7 — more headroom available)
- `--tool-call-parser qwen3_coder` (was `hermes`)
- Added: `--served-model-name`, `--mamba-ssm-cache-dtype`, `--kv-cache-dtype`, `--reasoning-parser`
- Added: `Before=exclaw.service`

## Part 4: ExClaw Code Changes

### 4a. `config/runtime.exs`

Update default values:
- Line 24: `"nvidia/Qwen3-32B-NVFP4"` → `"nemotron-cascade-2"` (VLLM_MODEL default)
- Line 68: comment example updated
- Line 211: `"nvidia/Qwen3-32B-NVFP4"` → `"nemotron-cascade-2"` (CLASSIFICATION_MODEL default)

### 4b. `lib/exclaw/llm/vllm_provider.ex`

- Line 17 (moduledoc example): `"nvidia/Qwen3-32B-NVFP4"` → `"nemotron-cascade-2"`
- Line 57 (init default): `"nvidia/Qwen3-32B-NVFP4"` → `"nemotron-cascade-2"`

### 4c. `lib/exclaw/agents/email_triage/classifier.ex`

- Line 13: `"nvidia/Qwen3-32B-NVFP4"` → `"nemotron-cascade-2"`

### 4d. `env.example.txt`

- Line 21: `VLLM_MODEL=nemotron-cascade-2`
- Line 22: `EXCLAW_DEFAULT_MODEL=nemotron-cascade-2`
- Line 41: `# CLASSIFICATION_MODEL=nemotron-cascade-2`

### 4e. `deploy/exclaw.service`

- Add `After=vllm.service` and `Wants=vllm.service` so ExClaw waits for vLLM

### 4f. `CLAUDE.md`

- Update runtime section comments about vLLM model
- Update env var examples

## Part 5: Rollback

If Nemotron-Cascade-2 doesn't work:

**Quick rollback (< 30 seconds):**
```bash
./deploy/vllm-cascade.sh --rollback
```
This restores the backed-up Qwen3 systemd service and restarts vLLM with the old NGC image.

**Manual rollback:**
1. `sudo systemctl stop vllm`
2. `sudo cp /etc/systemd/system/vllm-qwen3.service.bak /etc/systemd/system/vllm.service`
3. `sudo systemctl daemon-reload && sudo systemctl start vllm`

ExClaw model defaults don't need reverting — just set `VLLM_MODEL=nvidia/Qwen3-32B-NVFP4` in `/opt/exclaw/.env` (runtime config overrides compiled defaults).

Old model weights and the NGC image remain cached. No re-download needed.

## Validation Checklist

1. `curl http://localhost:8000/v1/models` returns `nemotron-cascade-2`
2. Simple completion returns coherent text
3. Tool calling works (model responds with `tool_calls`)
4. ExClaw `mix test` passes (all 872 tests)
5. Email triage processes a test email successfully
6. Throughput improvement measurable (< 10s/email vs ~50s baseline)

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| PR #2913 or #38423 has merge conflicts with NGC base | Pin to specific commits; Docker build fails clearly |
| Docker build takes too long | Build once, image is cached; subsequent `docker run` is instant |
| Model quality regression | `--rollback` flag restores Qwen3 in 30 seconds |
| Memory pressure with other services | Conservative 0.85 GPU utilization; 88-98 GB headroom |
| vLLM first-boot slow (kernel JIT) | Script waits up to 300s, suggests `journalctl -u vllm -f` |
| Custom image diverges from NGC updates | Rebuild script makes it easy to rebase on newer NGC tags |
