# Custom vLLM image for Nemotron-Cascade-2 NVFP4 on DGX Spark (SM 12.1).
#
# Extends the NGC vLLM image with:
#   - FlashInfer PR #2913: GDC compile flags for CUTLASS fused MoE on SM 12.x
#   - nvidia-cutlass-dsl v4.4.2 (upgraded from NGC's 4.3.5) for SM12x tile fixes
#
# vLLM PR #38423 is NOT applied — it targets a newer vLLM version incompatible
# with NGC 26.02's vLLM 0.15.1. The core fix (CUTLASS v4.4.2 tile constraints)
# is delivered via the FlashInfer dependency upgrade. The PR's additional runtime
# guards (Python + CUDA) are defensive checks, not required for functionality.
#
# Build on the Spark:
#   docker build -t vllm-cascade:latest deploy/vllm-cascade/
#
# Model weights are NOT baked in — mount /data/huggingface at runtime.

FROM nvcr.io/nvidia/vllm:26.02-py3

# Disable NGC's pip constraint file — we're deliberately upgrading packages
# (FlashInfer 0.6.7 needs nvidia-cutlass-dsl>=4.4.2, NGC pins 4.3.5)
ENV PIP_CONSTRAINT=""

# --- FlashInfer: apply GDC fix for SM 12.x MoE kernels (PR #2913) ---
WORKDIR /tmp/flashinfer
RUN git clone --depth=1 https://github.com/flashinfer-ai/flashinfer.git . && \
    git fetch --depth=1 origin pull/2913/head:fix-gdc-moe && \
    git checkout fix-gdc-moe

ENV FLASHINFER_CUDA_ARCH_LIST="12.1a"
RUN pip install -e . -v

# Clean up build artifacts to reduce image size
RUN rm -rf /tmp/flashinfer/.git /root/.cache/pip

WORKDIR /workspace
