#!/bin/bash
# Exit immediately if a command exits with a non-zero status
set -eo pipefail

echo "Starting RHOIM vLLM Initializer..."

# 1. Source Environment Variables (Crucial for Systemd)
# This loads MODEL_ID, MODEL_PATH, VLLM_HOST, VLLM_PORT, and VLLM_TARGET_DEVICE=cpu
if [ -f "/etc/sysconfig/rhoim" ]; then
    source /etc/sysconfig/rhoim
    echo "Info: Environment variables loaded from /etc/sysconfig/rhoim."
else
    echo "Warning: /etc/sysconfig/rhoim not found. Relying on Containerfile ENV."
fi

# 2. Define Execution Paths
# These paths are now hardcoded to the Python 3.11 VENV location defined in the Containerfile.
VENV_PYTHON="/opt-app-root/venv/bin/python3.11"
HF_COMMAND="/opt-app-root/venv/bin/huggingface-cli"

# 3. VLLM Device Configuration
# This export is explicitly defined in the script AND loaded from the environment 
# file (rhoim.env) for maximum robustness against the CUDA inference failure.
export VLLM_TARGET_DEVICE="cpu"

# --- 4. Model Download/Persistence Check ---

MODEL_FULL_PATH="$MODEL_PATH/$MODEL_ID"

# Check if the model directory exists AND is non-empty
if [ -d "$MODEL_FULL_PATH" ] && [ "$(ls -A "$MODEL_FULL_PATH")" ]; then
    echo "✅ Model found in persistent storage at $MODEL_FULL_PATH. Skipping download."
else
    echo "⚠️ Model not found locally. Starting download for $MODEL_ID..."
    mkdir -p "$MODEL_PATH"
    
    # Use the VENV's huggingface-cli to download the model
    $HF_COMMAND download "$MODEL_ID" \
        --local-dir "$MODEL_FULL_PATH" \
        --local-dir-use-symlinks False
    
    if [ $? -ne 0 ]; then
        echo "❌ Model download failed! Status: $?. Ensure network access and check model ID."
        exit 1
    fi
    echo "✅ Model download complete."
fi

# --- 5. Start vLLM OpenAI-compatible API Server ---
echo "Starting vLLM OpenAI-compatible API Server for $MODEL_ID..."

# Use the VENV's Python executable explicitly to launch the server with TinyLlama CPU parameters.
exec $VENV_PYTHON -m vllm.entrypoints.openai.api_server \
    --model "$MODEL_FULL_PATH" \
    --host "$VLLM_HOST" \
    --port "$VLLM_PORT" \
    --device cpu \
    --dtype float32 \
    --attention-backend torch \
    --max-model-len 2048 \
    --enforce-eager \
    --disable-log-requests