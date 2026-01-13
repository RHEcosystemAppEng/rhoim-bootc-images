#!/bin/bash
set -euo pipefail

# Load configuration from /etc/sysconfig/rhoim if present
if [ -f "/etc/sysconfig/rhoim" ]; then
    # shellcheck disable=SC1091
    source /etc/sysconfig/rhoim
fi

# Set default values
VLLM_MODEL="${VLLM_MODEL:-${MODEL_ID:-TinyLlama/TinyLlama-1.1B-Chat-v1.0}}"
HOST="${VLLM_HOST:-0.0.0.0}"
PORT="${VLLM_PORT:-8000}"
MODEL_PATH="${MODEL_PATH:-/tmp/models}"

# vLLM container image
VLLM_IMAGE="registry.redhat.io/rhaiis/vllm-cuda-rhel9@sha256:094db84a1da5e8a575d0c9eade114fa30f4a2061064a338e3e032f3578f8082a"

# Ensure model directory exists
mkdir -p "${MODEL_PATH}"

# Run podman container with GPU support
exec /usr/bin/podman run \
    --rm \
    --name rhoim-vllm \
    --network=host \
    --device=nvidia.com/gpu=all \
    --security-opt label=disable \
    -v "${MODEL_PATH}:/models:Z" \
    -e VLLM_MODEL="${VLLM_MODEL}" \
    -e HOST="${HOST}" \
    -e PORT="${PORT}" \
    "${VLLM_IMAGE}"
