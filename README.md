# RHOIM Inference Platform – Repo Skeleton (OpenShift/K8s/off‑K8s)

A production‑ready skeleton to ship **images** using **bootc**, runnable on **OpenShift**, **vanilla Kubernetes**, and **off‑Kubernetes** (systemd), relying on **RHAIIS** for GPU enablement. Focus: help customers **transition to RHOAI**.

## Modes
- **Two‑container** (gateway + vLLM) for OCP/K8s
- **Single‑container Appliance** (gateway + vLLM in one image)
- **bootc VM image** (off‑K8s) with systemd: model‑pull → vLLM → gateway

## Quick Start (single‑container locally)
```bash
podman build -t rhoim:latest deploy/appliance-cpu
export HF_TOKEN=...   # if needed
podman run --rm -p 8080:8080 -v /srv/models:/models \\
  -e API_KEYS="devkey1,devkey2" \
  -e MODEL_SOURCE="hf://meta-llama/Meta-Llama-3-8B-Instruct" \
  -e MODEL_URI="/models/llama3-8b" \
  rhoim:latest

curl -H "Authorization: Bearer devkey1" -H 'Content-Type: application/json' \
  --data '{"model":"llama3-8b-instruct","messages":[{"role":"user","content":"hi"}]}' \
  http://localhost:8080/api/rhoai/v1/chat/completions
```

## CPU-only local quick start (no GPU, TinyLlama)
This uses a CPU-only image variant with `TinyLlama/TinyLlama-1.1B-Chat-v1.0` as default (a public model; no token required). Inspired by the vLLM CPU demo patterns in the bootc repo by Lokesh Rangineni.

```bash
# Build single appliance image locally
make build-appliance-cpu-local TAG=latest

# Run single-container (appliance) CPU image
podman run --rm -p 8080:8080 \
  -e API_KEYS="devkey1,devkey2" \
  -e MODEL_URI="TinyLlama/TinyLlama-1.1B-Chat-v1.0" \
  rhoim:latest

# Test health and chat
curl http://localhost:8080/healthz
curl -H "Authorization: Bearer devkey1" -H 'Content-Type: application/json' \
  --data '{"model":"TinyLlama/TinyLlama-1.1B-Chat-v1.0","messages":[{"role":"user","content":"hello"}]}' \
  http://localhost:8080/api/rhoai/v1/chat/completions

# Metrics
curl http://localhost:8080/metrics
```

### Build and store locally as tar (no registry)
```bash
# Build with local tag (no registry prefix)
make build-appliance-cpu-local TAG=latest

# Save tarball under ./image
make package-appliance-cpu TAG=latest

# Load on another machine (example)
podman load -i image/rhoim-latest.tar
podman run --rm -p 8080:8080 \
  -e API_KEYS="devkey1,devkey2" \
  -e MODEL_URI="TinyLlama/TinyLlama-1.1B-Chat-v1.0" \
  rhoim:latest
```

## Bootc VM image (off‑Kubernetes)

Requirements:
- Podman (rootful mode) and `quay.io/centos-bootc/bootc-image-builder:latest`
- QEMU to boot the qcow2 locally (or use the generated VMDK/OVF in another hypervisor)

### 1) Build the bootc container image
```bash
cd /Users/olgalavtar/repos/rhoim
podman build -t localhost/rhoim-bootc:latest -f deploy/bootc/Containerfile .
```

On macOS, ensure Podman machine is rootful:
```bash
podman machine stop
podman machine set --rootful=true
podman machine start
```

### 2) Create a qcow2 with bootc-image-builder
```bash
mkdir -p image
podman run --rm --privileged \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$PWD/image":/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  localhost/rhoim-bootc:latest
```
Artifacts will be created under `./image/` (e.g., `image/qcow2/disk.qcow2`).

### 3) Boot the VM
- Apple Silicon (ARM64) – recommended to build and run natively:
  ```bash
  podman build --platform linux/arm64 -t localhost/rhoim-bootc:arm64 -f deploy/bootc/Containerfile .
  rm -rf image && mkdir -p image
  podman run --rm --privileged \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    -v "$PWD/image":/output \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type qcow2 \
    --target-arch aarch64 \
    localhost/rhoim-bootc:arm64
  BIOS="$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd"
  qemu-system-aarch64 -accel hvf -machine virt -cpu host \
    -m 8G -smp 4 -bios "$BIOS" \
    -drive if=virtio,format=qcow2,file="$PWD/image/qcow2/disk.qcow2" \
    -netdev user,id=n1,hostfwd=tcp::8080-:8080,hostfwd=tcp::8000-:8000 \
    -device virtio-net-pci,netdev=n1 -serial mon:stdio
  ```
- x86_64 (Intel/AMD):
  ```bash
  BIOS_X64="$(brew --prefix qemu)/share/qemu/edk2-x86_64-code.fd"
  qemu-system-x86_64 -m 8G -smp 4 \
    -bios "$BIOS_X64" \
    -drive if=virtio,format=qcow2,file="$PWD/image/qcow2/disk.qcow2" \
    -net nic,model=virtio -net user,hostfwd=tcp::8080-:8080,hostfwd=tcp::8000-:8000 \
    -serial mon:stdio
  ```

### 4) Test the endpoints
```bash
# vLLM (lists models when ready)
curl http://localhost:8000/v1/models

# Gateway
curl http://localhost:8080/healthz
curl -H "Authorization: Bearer devkey1" -H 'Content-Type: application/json' \
  --data '{"model":"TinyLlama/TinyLlama-1.1B-Chat-v1.0","messages":[{"role":"user","content":"hello"}]}' \
  http://localhost:8080/api/rhoai/v1/chat/completions
```

### Pre‑pull the model (optional, faster first boot)
Set these in `deploy/bootc/rhoim.env`:
```bash
MODEL_SOURCE=hf://TinyLlama/TinyLlama-1.1B-Chat-v1.0
MODEL_URI=/models/tinyllama
```
Then rebuild the bootc image and qcow2.

### Troubleshooting
- If `curl :8080` resets, wait 1–3 min for first download or pre‑pull the model.
- Check logs inside the VM:
  ```bash
  journalctl -u rhoim-model-pull -e
  journalctl -u rhoim-vllm -e
  journalctl -u rhoim-gateway -e
  ```
- On macOS, ensure QEMU is installed (`brew install qemu`) and Podman is rootful.

### Single-image workflow (only one image)
```bash
# Build only the single appliance image locally
make build-appliance-cpu-local TAG=latest

# Optionally package only that one image
make package-appliance-cpu TAG=latest

# Run it
podman run --rm -p 8080:8080 \
  -e API_KEYS="devkey1,devkey2" \
  -e MODEL_URI="TinyLlama/TinyLlama-1.1B-Chat-v1.0" \
  rhoim:latest
```
