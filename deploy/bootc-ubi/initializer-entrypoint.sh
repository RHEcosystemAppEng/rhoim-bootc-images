#!/usr/bin/env bash
set -euo pipefail

# Environment-driven startup for vLLM OpenAI server (CPU mode)
# Vars (with defaults):
#   VLLM_MODEL      - HF model id (default TinyLlama/TinyLlama-1.1B-Chat-v1.0)
#   HOST            - bind host (default 0.0.0.0)
#   PORT            - port (default 8000)
#   DTYPE           - float32|... (default float32 for CPU)
#   VLLM_EXTRA_ARGS - extra args passed to api_server

MODEL="${VLLM_MODEL:-TinyLlama/TinyLlama-1.1B-Chat-v1.0}"
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8000}"
DTYPE="${DTYPE:-float32}"
EXTRA_ARGS=${VLLM_EXTRA_ARGS:-}

# Force CPU mode - hide CUDA devices
export CUDA_VISIBLE_DEVICES=""
export VLLM_TARGET_DEVICE="cpu"

echo "Starting vLLM with CPU support (model=${MODEL}, host=${HOST}, port=${PORT}, dtype=${DTYPE})"

ARGS=(
  --host "${HOST}"
  --port "${PORT}"
  --model "${MODEL}"
  --dtype "${DTYPE}"
)

if [[ -n "${EXTRA_ARGS}" ]]; then
  # shellcheck disable=SC2206
  ARGS+=(${EXTRA_ARGS})
fi

exec /opt/vllm-venv/bin/python -m vllm.entrypoints.openai.api_server "${ARGS[@]}"