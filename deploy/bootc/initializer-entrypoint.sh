#!/bin/bash
# Exit immediately if a command exits with a non-zero status
set -eo pipefail

# Output will be captured by systemd and sent to console via StandardOutput/StandardError
echo "=========================================="
echo "Starting RHOIM vLLM Initializer..."
echo "Timestamp: $(date)"
echo "=========================================="

# 1. Source Environment Variables (Crucial for Systemd)
# This loads MODEL_ID, MODEL_PATH, VLLM_HOST, VLLM_PORT, and VLLM_TARGET_DEVICE=cpu
if [ -f "/etc/sysconfig/rhoim" ]; then
    echo "Loading environment from /etc/sysconfig/rhoim..."
    source /etc/sysconfig/rhoim
    echo "Info: Environment variables loaded from /etc/sysconfig/rhoim."
    echo "  MODEL_ID: ${MODEL_ID:-not set}"
    echo "  MODEL_PATH: ${MODEL_PATH:-not set}"
    echo "  VLLM_DEVICE_TYPE: ${VLLM_DEVICE_TYPE:-not set}"
else
    echo "Warning: /etc/sysconfig/rhoim not found. Relying on Containerfile ENV."
fi

# CUDA environment variables are set in Containerfile (harmless if no GPU)
# vLLM will auto-detect and use CPU if no GPU is available

# 2. VLLM Device Configuration
# Read device type from environment (defaults to "cpu" if not set)
DEVICE_TYPE="${VLLM_DEVICE_TYPE:-cpu}"

# Configure device-specific settings based on VLLM_DEVICE_TYPE
# Default to CPU mode (safe default), override only for CUDA
# Assumes NVIDIA GPUs (CUDA) for GPU mode - other GPU types not supported
export VLLM_TARGET_DEVICE="cpu"
export VLLM_NO_CUDA=1
export VLLM_USE_CUDA=0
export VLLM_USE_FLASHINFER=0
VLLM_DEVICE_FLAG="--device cpu"
VLLM_DTYPE="float32"
VLLM_ENFORCE_EAGER="--enforce-eager"

if [ "$DEVICE_TYPE" = "cuda" ]; then
    # CUDA mode: Uses NVIDIA GPUs via CUDA API
    echo "Configuring vLLM for CUDA mode (NVIDIA GPU)..."
    export VLLM_TARGET_DEVICE="cuda"
    export VLLM_NO_CUDA=0
    export VLLM_USE_CUDA=1
    # Don't set device flag - vLLM will auto-detect NVIDIA GPUs via CUDA
    VLLM_DEVICE_FLAG=""
    VLLM_DTYPE="auto"
    VLLM_ENFORCE_EAGER=""
else
    # CPU mode (default) or unknown device type
    if [ "$DEVICE_TYPE" != "cpu" ]; then
        echo "Warning: Unknown device type '$DEVICE_TYPE'. Defaulting to CPU mode."
        echo "Valid values: 'cpu' or 'cuda' (NVIDIA GPU)"
    else
        echo "Configuring vLLM for CPU mode..."
    fi
fi

# 3. Determine model path
# vLLM can handle HuggingFace model IDs directly and will download automatically
# If MODEL_PATH is set and contains a local path, use it; otherwise use MODEL_ID directly
if [ -n "$MODEL_PATH" ] && [ -d "$MODEL_PATH" ] && [ "$(ls -A "$MODEL_PATH" 2>/dev/null)" ]; then
    # Use local path if it exists and is not empty
    MODEL_ARG="$MODEL_PATH"
    echo "Using local model path: $MODEL_ARG"
else
    # Let vLLM handle the download automatically
    MODEL_ARG="$MODEL_ID"
    echo "Using HuggingFace model ID: $MODEL_ARG (vLLM will download automatically)"
fi

# 4. Start vLLM OpenAI-compatible API Server
echo "=========================================="
echo "Starting vLLM OpenAI-compatible API Server"
echo "  Model: $MODEL_ARG"
echo "  Device: $DEVICE_TYPE"
echo "  Host: ${VLLM_HOST:-0.0.0.0}"
echo "  Port: ${VLLM_PORT:-8000}"
echo "  Dtype: $VLLM_DTYPE"
echo "=========================================="

# Verify Python and vLLM are available
echo "Checking Python installation..."
python3 --version || { echo "ERROR: python3 not found!"; exit 1; }

echo "Checking vLLM installation..."
python3 -c "import vllm; print(f'vLLM version: {vllm.__version__}')" || { echo "ERROR: vLLM not installed!"; exit 1; }

# Build vLLM command arguments array
VLLM_ARGS=(
    -m vllm.entrypoints.openai.api_server
    --model "$MODEL_ARG"
    --host "$VLLM_HOST"
    --port "$VLLM_PORT"
    --dtype "$VLLM_DTYPE"
    --attention-backend torch
    --max-model-len 2048
    --disable-log-requests
)

# Add device flag if specified (CPU mode)
if [ -n "$VLLM_DEVICE_FLAG" ]; then
    VLLM_ARGS+=(--device cpu)
    echo "Added CPU device flag"
fi

# Add enforce-eager flag if specified (CPU mode)
if [ -n "$VLLM_ENFORCE_EAGER" ]; then
    VLLM_ARGS+=(--enforce-eager)
    echo "Added enforce-eager flag"
fi

echo "=========================================="
echo "Executing vLLM with args: ${VLLM_ARGS[*]}"
echo "=========================================="

# Execute the command (using python3 from system installation)
exec python3 "${VLLM_ARGS[@]}"