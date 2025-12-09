#!/usr/bin/env bash
set -euo pipefail

# 1. Load /etc/sysconfig/rhoim if present
if [ -f "/etc/sysconfig/rhoim" ]; then
    # shellcheck disable=SC1091
    source /etc/sysconfig/rhoim
fi

# 2. Map old names -> new names (backward compatible)
VLLM_MODEL="${VLLM_MODEL:-${MODEL_ID:-TinyLlama/TinyLlama-1.1B-Chat-v1.0}}"
HOST="${HOST:-${VLLM_HOST:-0.0.0.0}}"
PORT="${PORT:-${VLLM_PORT:-8000}}"
MODEL_PATH="${MODEL_PATH:-/tmp/models}"
DTYPE="${DTYPE:-float32}"
VLLM_DEVICE_TYPE="${VLLM_DEVICE_TYPE:-auto}"
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}"

# 3. GPU detection
have_gpu() {
    command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1
}

DEVICE="cpu"
if [[ "${VLLM_DEVICE_TYPE}" == "cuda" ]]; then
    DEVICE="cuda"
elif [[ "${VLLM_DEVICE_TYPE}" == "auto" ]] && have_gpu; then
    DEVICE="cuda"
fi

echo "[RHOIM] VLLM_MODEL=${VLLM_MODEL}"
echo "[RHOIM] HOST=${HOST} PORT=${PORT}"
echo "[RHOIM] MODEL_PATH=${MODEL_PATH}"
echo "[RHOIM] Requested VLLM_DEVICE_TYPE=${VLLM_DEVICE_TYPE}, selected DEVICE=${DEVICE}"

# 4. Ensure model is present
mkdir -p "${MODEL_PATH}"
LOCAL_MODEL_DIR="${MODEL_PATH}/${VLLM_MODEL}"

if [ ! -d "${LOCAL_MODEL_DIR}" ] || [ -z "$(ls -A "${LOCAL_MODEL_DIR}" 2>/dev/null || true)" ]; then
    echo "[RHOIM] Downloading ${VLLM_MODEL} to ${LOCAL_MODEL_DIR}"
    HF_CLI="/opt/vllm-venv/bin/huggingface-cli"
    if ! command -v "${HF_CLI}" >/dev/null 2>&1; then
        echo "[RHOIM] ERROR: huggingface-cli not found in /opt/vllm-venv" >&2
        exit 1
    fi
    "${HF_CLI}" download "${VLLM_MODEL}" \
        --local-dir "${LOCAL_MODEL_DIR}" \
        --local-dir-use-symlinks False
fi

# 5. Build vLLM args
ARGS=(
  --model "${LOCAL_MODEL_DIR}"
  --host "${HOST}"
  --port "${PORT}"
)

if [[ "${DEVICE}" == "cuda" ]]; then
    echo "[RHOIM] Starting vLLM in CUDA mode"
    ARGS+=(--device cuda)
else
    echo "[RHOIM] Starting vLLM in CPU mode"
    ARGS+=(--device cpu --dtype "${DTYPE}" --enforce-eager)
    export CUDA_VISIBLE_DEVICES=
    export VLLM_NO_CUDA=1
    export VLLM_CPU_ONLY=1
    export VLLM_PLATFORM=cpu
    export VLLM_SKIP_PLATFORM_CHECK=1
    export VLLM_USE_FLASHINFER=0
fi

if [[ -n "${VLLM_EXTRA_ARGS}" ]]; then
    # shellcheck disable=SC2206
    EXTRA_ARR=(${VLLM_EXTRA_ARGS})
    ARGS+=("${EXTRA_ARR[@]}")
fi

PYTHON_CMD="/opt/vllm-venv/bin/python"

echo "[RHOIM] Using Python: ${PYTHON_CMD}"
echo "[RHOIM] Final vLLM args: ${ARGS[*]}"

exec "${PYTHON_CMD}" -m vllm.entrypoints.openai.api_server "${ARGS[@]}"