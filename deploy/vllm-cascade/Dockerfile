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

# --- FlashInfer: apply GDC fix for SM 12.x MoE kernels (PR #2913) ---
WORKDIR /tmp/flashinfer
RUN git clone --depth=1 https://github.com/flashinfer-ai/flashinfer.git . && \
    git fetch --depth=1 origin pull/2913/head:fix-gdc-moe && \
    git checkout fix-gdc-moe

ENV FLASHINFER_CUDA_ARCH_LIST="12.1a"
RUN pip install -e . -v

# --- vLLM: apply NVFP4 SM12x tile constraint fix (PR #38423) ---
WORKDIR /tmp/vllm-patch
RUN git clone --depth=1 https://github.com/vllm-project/vllm.git . && \
    git fetch --depth=1 origin pull/38423/head:fix-nvfp4-spark && \
    git checkout fix-nvfp4-spark

RUN pip install -e . -v

# Clean up build artifacts to reduce image size
RUN rm -rf /tmp/flashinfer/.git /tmp/vllm-patch/.git /root/.cache/pip

WORKDIR /workspace
