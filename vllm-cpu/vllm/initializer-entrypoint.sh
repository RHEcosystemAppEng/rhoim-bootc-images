#!/usr/bin/env bash
set -euo pipefail

# Environment-driven startup for vLLM OpenAI server (CPU-first, optional GPU at runtime)
# Vars (with defaults):
#   VLLM_MODEL      - HF model id (default TinyLlama/TinyLlama-1.1B-Chat-v1.0)
#   HOST            - bind host (default 0.0.0.0)
#   PORT            - port (default 8000)
#   DTYPE           - float32|... (default float32)
#   VLLM_EXTRA_ARGS - extra args passed to api_server

# Source environment file if it exists (for backward compatibility)
if [ -f "/etc/sysconfig/rhoim" ]; then
    source /etc/sysconfig/rhoim
    # Map old variable names to new ones if needed
    VLLM_MODEL="${VLLM_MODEL:-${MODEL_ID:-TinyLlama/TinyLlama-1.1B-Chat-v1.0}}"
    HOST="${HOST:-${VLLM_HOST:-0.0.0.0}}"
    PORT="${PORT:-${VLLM_PORT:-8000}}"
else
    VLLM_MODEL="${VLLM_MODEL:-TinyLlama/TinyLlama-1.1B-Chat-v1.0}"
    HOST="${HOST:-0.0.0.0}"
    PORT="${PORT:-8000}"
fi

DTYPE="${DTYPE:-float32}"
EXTRA_ARGS=${VLLM_EXTRA_ARGS:-}

# Force CPU mode for environments without GPU
# Based on working configuration from deploy/appliance-cpu/start.sh
# These environment variables are required for vLLM to properly detect CPU mode
export CUDA_VISIBLE_DEVICES=""
export VLLM_TARGET_DEVICE=cpu
export VLLM_DEVICE=cpu
export VLLM_USE_CUDA=0
export VLLM_CPU_ONLY=1
export VLLM_PLATFORM=cpu
export VLLM_SKIP_PLATFORM_CHECK=1
export VLLM_USE_FLASHINFER=0
export VLLM_LOGGING_LEVEL=${VLLM_LOGGING_LEVEL:-INFO}

echo "Starting vLLM (model=${VLLM_MODEL}, host=${HOST}, port=${PORT}, dtype=${DTYPE})"
echo "CPU mode: VLLM_PLATFORM=cpu, VLLM_SKIP_PLATFORM_CHECK=1, VLLM_CPU_ONLY=1"

ARGS=(
  --host "${HOST}"
  --port "${PORT}"
  --model "${VLLM_MODEL}"
  --dtype "${DTYPE}"
)

if [[ -n "${EXTRA_ARGS}" ]]; then
  # shellcheck disable=SC2206
  ARGS+=(${EXTRA_ARGS})
fi

# Set environment variables before Python import (critical for platform detection)
# vLLM detects platform during import, so these must be set before running Python
export CUDA_VISIBLE_DEVICES=""
export VLLM_TARGET_DEVICE=cpu
export VLLM_DEVICE=cpu
export VLLM_USE_CUDA=0
export VLLM_CPU_ONLY=1
export VLLM_PLATFORM=cpu
export VLLM_SKIP_PLATFORM_CHECK=1
export VLLM_USE_FLASHINFER=0

# vLLM is installed in /opt/vllm-venv
# Use the venv Python which has vLLM installed
PYTHON_CMD="/opt/vllm-venv/bin/python"

echo "Using Python: $PYTHON_CMD"
echo "Environment variables set for CPU mode"
echo "Starting vLLM with args: ${ARGS[*]}"

# Execute vLLM directly (built from source with CPU support)
exec "$PYTHON_CMD" -m vllm.entrypoints.openai.api_server "${ARGS[@]}"