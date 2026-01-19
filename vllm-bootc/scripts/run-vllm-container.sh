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

# Pull the image first (will use cached credentials if logged in)
echo "=== Pulling vLLM container image ==="
# Only use --authfile if the file exists (created by podman-registry-login.service)
if [ -f "/root/.config/containers/auth.json" ]; then
    podman pull --authfile /root/.config/containers/auth.json "${VLLM_IMAGE}" || {
        echo "[ERROR] Failed to pull vLLM container image"
        echo "[ERROR] Ensure registry credentials are configured in /etc/sysconfig/rhoim"
        echo "[ERROR] Or login manually: podman login registry.redhat.io"
        exit 1
    }
else
    # Try without authfile (podman will use default credential store)
    podman pull "${VLLM_IMAGE}" || {
        echo "[ERROR] Failed to pull vLLM container image"
        echo "[ERROR] Ensure registry credentials are configured in /etc/sysconfig/rhoim"
        echo "[ERROR] Or login manually: podman login registry.redhat.io"
        exit 1
    }
fi

# Run podman container with GPU support
echo "=== Starting vLLM container ==="

# Check if CDI is available, otherwise use traditional device mounting
GPU_DEVICE=""
if [ -f "/etc/cdi/nvidia.yaml" ]; then
    # Check if podman recognizes CDI devices
    if podman info --format '{{.Host.CDIDevices}}' 2>/dev/null | grep -q nvidia || \
       podman run --rm --device=nvidia.com/gpu=all --dry-run alpine:latest 2>/dev/null; then
        echo "Using CDI for GPU access"
        GPU_DEVICE="--device=nvidia.com/gpu=all"
    else
        echo "CDI config exists but not recognized by podman, trying traditional device mounting"
    fi
fi

# Fallback to traditional device mounting if CDI not available
if [ -z "$GPU_DEVICE" ]; then
    echo "Using traditional device mounting for GPU access"
    # Mount NVIDIA devices if they exist
    if [ -c /dev/nvidia0 ]; then
        GPU_DEVICE="--device=/dev/nvidia0 --device=/dev/nvidiactl"
        [ -c /dev/nvidia-modeset ] && GPU_DEVICE="${GPU_DEVICE} --device=/dev/nvidia-modeset"
        [ -c /dev/nvidia-uvm ] && GPU_DEVICE="${GPU_DEVICE} --device=/dev/nvidia-uvm"
        [ -c /dev/nvidia-uvm-tools ] && GPU_DEVICE="${GPU_DEVICE} --device=/dev/nvidia-uvm-tools"
        echo "Found NVIDIA devices, using: ${GPU_DEVICE}"
    else
        echo "Warning: No NVIDIA devices found at /dev/nvidia*, running without GPU"
        echo "This is expected on CPU-only instances"
        GPU_DEVICE=""
    fi
fi

exec /usr/bin/podman run \
    --rm \
    --name rhoim-vllm \
    --network=host \
    ${GPU_DEVICE} \
    --security-opt label=disable \
    -v "${MODEL_PATH}:/models:Z" \
    -e VLLM_MODEL="${VLLM_MODEL}" \
    -e HOST="${HOST}" \
    -e PORT="${PORT}" \
    "${VLLM_IMAGE}"
