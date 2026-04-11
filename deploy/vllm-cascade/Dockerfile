# Custom vLLM image for Nemotron-Cascade-2 NVFP4 on DGX Spark (SM 12.1).
#
# Extends the NGC vLLM image with two upstream fixes:
#   - FlashInfer PR #2913: GDC compile flags for CUTLASS fused MoE on SM 12.x
#   - vLLM PR #38423: CUTLASS v4.4.2 + FlashInfer 0.6.7, SM12x NVFP4 tile fixes
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

# --- vLLM: apply NVFP4 SM12x tile constraint fix (PR #38423) ---
# Strategy: overlay the PR's Python source on top of NGC's compiled installation.
# This keeps the pre-compiled C extensions (.so) intact while applying the Python
# fixes (tile constraints, runtime guards). Much faster than a full rebuild.
WORKDIR /tmp/vllm-patch
RUN git clone --depth=1 https://github.com/vllm-project/vllm.git . && \
    git fetch --depth=1 origin pull/38423/head:fix-nvfp4-spark && \
    git checkout fix-nvfp4-spark

# Clear stale bytecode, then overlay PR's Python files over NGC's vLLM
RUN find /usr/local/lib/python3.12/dist-packages/vllm/ -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true && \
    cp -r /tmp/vllm-patch/vllm/* /usr/local/lib/python3.12/dist-packages/vllm/

# Clean up build artifacts to reduce image size
RUN rm -rf /tmp/flashinfer/.git /tmp/vllm-patch /root/.cache/pip

WORKDIR /workspace
