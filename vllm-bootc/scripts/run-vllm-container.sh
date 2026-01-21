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

# Clean up any existing container with the same name (in case of previous crash)
if podman ps -a --format "{{.Names}}" | grep -q "^rhoim-vllm$"; then
    echo "Removing existing container 'rhoim-vllm'..."
    podman rm -f rhoim-vllm 2>/dev/null || true
fi

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

# Set NVIDIA environment variables for container GPU access
NVIDIA_ENV=""
if [ -n "$GPU_DEVICE" ]; then
    # Make all GPUs visible to container
    # CUDA_VISIBLE_DEVICES is needed for vLLM to detect GPUs
    # NVIDIA_VISIBLE_DEVICES is for NVIDIA Container Toolkit
    NVIDIA_ENV="-e NVIDIA_VISIBLE_DEVICES=all -e NVIDIA_DRIVER_CAPABILITIES=compute,utility -e CUDA_VISIBLE_DEVICES=0"
    # Also explicitly set device type for vLLM
    # Note: vLLM checks for device type during import, so we need to set it early
    # VLLM_DEVICE_TYPE=cuda tells vLLM to use CUDA explicitly
    # VLLM_LOGGING_LEVEL=DEBUG helps diagnose device detection issues
    NVIDIA_ENV="${NVIDIA_ENV} -e VLLM_DEVICE_TYPE=cuda -e VLLM_LOGGING_LEVEL=DEBUG"
fi

# The vLLM container image has its own entrypoint that runs vLLM directly
# We need to ensure environment variables are set before vLLM tries to detect the device
# vLLM detects device type during module import, so we must set VLLM_DEVICE_TYPE early
# Override entrypoint to set env vars before Python imports vLLM
# Use proper export syntax (multiple export statements)
# Add comprehensive debugging to see what PyTorch detects
exec /usr/bin/podman run \
    --rm \
    --name rhoim-vllm \
    --network=host \
    ${GPU_DEVICE} \
    ${NVIDIA_ENV} \
    --security-opt label=disable \
    -v "${MODEL_PATH}:/models:Z" \
    -v /usr/lib64/libnvidia-ml.so.1:/usr/lib64/libnvidia-ml.so.1:ro \
    -v /usr/lib64/libnvidia-ml.so.570.211.01:/usr/lib64/libnvidia-ml.so.570.211.01:ro \
    -e VLLM_MODEL="${VLLM_MODEL}" \
    -e HOST="${HOST}" \
    -e PORT="${PORT}" \
    --entrypoint /bin/bash \
    "${VLLM_IMAGE}" \
    -c "export VLLM_DEVICE_TYPE=cuda && export CUDA_VISIBLE_DEVICES=0 && export NVIDIA_VISIBLE_DEVICES=all && export NVIDIA_DRIVER_CAPABILITIES=compute,utility && export VLLM_LOGGING_LEVEL=DEBUG && echo '=== CUDA/PyTorch Debugging ===' && echo 'Environment variables:' && env | grep -E 'CUDA|NVIDIA|VLLM' | sort && echo '' && echo 'NVIDIA devices in container:' && ls -la /dev/nvidia* 2>&1 || echo 'No NVIDIA devices found' && echo '' && echo 'CUDA library paths:' && find /usr -name 'libcuda.so*' 2>/dev/null | head -5 || echo 'libcuda.so not found' && find /usr -name 'libcudart.so*' 2>/dev/null | head -5 || echo 'libcudart.so not found' && echo '' && echo 'PyTorch CUDA detection:' && python3 -c \"
import sys
import os
print('Python version:', sys.version)
print('Python executable:', sys.executable)
print('')
print('Environment variables:')
for key in ['CUDA_VISIBLE_DEVICES', 'NVIDIA_VISIBLE_DEVICES', 'NVIDIA_DRIVER_CAPABILITIES', 'VLLM_DEVICE_TYPE', 'VLLM_LOGGING_LEVEL']:
    val = os.environ.get(key, 'NOT SET')
    print('  {}={}'.format(key, val))
print('')
try:
    import torch
    print('PyTorch version:', torch.__version__)
    print('PyTorch CUDA available:', torch.cuda.is_available())
    if torch.cuda.is_available():
        print('CUDA version (PyTorch):', torch.version.cuda)
        cudnn_ver = torch.backends.cudnn.version() if torch.backends.cudnn.is_available() else 'N/A'
        print('cuDNN version:', cudnn_ver)
        print('Number of GPUs:', torch.cuda.device_count())
        for i in range(torch.cuda.device_count()):
            print('  GPU {}: {}'.format(i, torch.cuda.get_device_name(i)))
            mem_gb = torch.cuda.get_device_properties(i).total_memory / (1024**3)
            print('    Memory: {:.2f} GB'.format(mem_gb))
    else:
        print('PyTorch CUDA is NOT available')
        print('Checking why...')
        try:
            import torch._C
            print('torch._C loaded:', torch._C is not None)
        except Exception as e:
            print('Failed to load torch._C:', e)
        try:
            cuda_ver = torch.version.cuda if hasattr(torch.version, 'cuda') else 'N/A'
            print('CUDA compiled version:', cuda_ver)
        except Exception as e:
            print('Error getting CUDA version:', e)
except ImportError as e:
    print('Failed to import torch:', e)
except Exception as e:
    print('Error checking PyTorch:', e)
    import traceback
    traceback.print_exc()
print('')
print('=== End of PyTorch debugging ===')
\" && echo '' && echo 'Starting vLLM server...' && export HF_HUB_OFFLINE=0 && export TRANSFORMERS_OFFLINE=0 && export HF_HOME=/tmp/.cache/huggingface && exec python3 -m vllm.entrypoints.openai.api_server --model ${VLLM_MODEL} --host ${HOST} --port ${PORT}"
