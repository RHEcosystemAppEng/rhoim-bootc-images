# Podman Desktop Development Workflow

This guide covers setting up and using Podman Desktop for local development and testing of bootc images.

## Table of Contents

- [Installation](#installation)
- [Initial Setup](#initial-setup)
- [Building Images](#building-images)
- [Running Containers](#running-containers)
- [Creating Bootable Disks](#creating-bootable-disks)
- [Troubleshooting](#troubleshooting)

## Installation

### macOS

1. Download Podman Desktop from [podman-desktop.io](https://podman-desktop.io)
2. Install the application
3. Start Podman Desktop from Applications

### Linux

```bash
# Install Podman Desktop via Flatpak
flatpak install flathub io.podman_desktop.PodmanDesktop
```

### Windows

1. Download Podman Desktop from [podman-desktop.io](https://podman-desktop.io)
2. Run the installer
3. Start Podman Desktop

## Initial Setup

### 1. Start Podman Machine

Podman Desktop automatically manages Podman machines. On first launch:
- A default machine will be created
- Wait for the machine to be ready (green status indicator)

### 2. Configure Machine Resources (Optional)

If you need more resources for building large images:

```bash
# Stop the machine
podman machine stop

# Increase disk size (default is 100GB)
podman machine set --disk-size 200

# Increase CPU and memory (if needed)
podman machine set --cpus 4 --memory 8192

# Start the machine
podman machine start
```

### 3. Verify Installation

```bash
podman version
podman info
```

## Building Images

### Basic Build

```bash
# Navigate to your project directory
cd /path/to/rhoim-bootc-images

# Build the container image
podman build -t localhost/rhoim-bootc:latest -f vllm-bootc/Containerfile .
```

### Build with Specific Platform

For ARM64 (Apple Silicon Macs):
```bash
podman build --platform linux/arm64 -t localhost/rhoim-bootc:arm64 -f vllm-bootc/Containerfile .
```

For AMD64:
```bash
podman build --platform linux/amd64 -t localhost/rhoim-bootc:amd64 -f vllm-bootc/Containerfile .
```

**Note**: Cross-architecture builds may be slower and some tools (like `bootc-image-builder`) may not work correctly with emulation.

### View Images in Podman Desktop

1. Open Podman Desktop
2. Navigate to "Images" tab
3. Your built images will appear in the list

## Running Containers

### Run with Systemd (Required for Bootc Images)

Bootc images require systemd to run properly:

```bash
podman run -d \
  --name rhoim-bootc-test \
  --privileged \
  --systemd=always \
  -p 8000:8000 \
  localhost/rhoim-bootc:latest
```

### Check Container Status

```bash
# List running containers
podman ps

# View container logs (systemd logs are in journald, not stdout)
podman exec rhoim-bootc-test journalctl --no-pager | tail -50

# Check service status
podman exec rhoim-bootc-test systemctl status rhoim-vllm.service

# View service logs
podman exec rhoim-bootc-test journalctl -u rhoim-vllm.service --no-pager
```

### Access Container Shell

```bash
podman exec -it rhoim-bootc-test /bin/bash
```

### Test vLLM API

```bash
# Health check
curl http://localhost:8000/health

# List models
curl http://localhost:8000/v1/models
```

### Stop and Remove Container

```bash
podman stop rhoim-bootc-test
podman rm rhoim-bootc-test
```

## Creating Bootable Disks

### Prerequisites

Install `bootc-image-builder`:

```bash
# On macOS (using Homebrew)
brew install bootc-image-builder

# On Linux (RHEL/Fedora)
sudo dnf install bootc-image-builder
```

### Create Bootable Disk Image

**Important**: Cross-architecture builds (e.g., amd64 on arm64) may not work correctly. For amd64 images, consider:
- Using a native amd64 Linux VM
- Using CI/CD (GitHub Actions, etc.)
- Using a cloud instance

#### For Native Architecture (arm64 on Apple Silicon)

```bash
bootc-image-builder \
  --type raw \
  --output-dir ./output \
  localhost/rhoim-bootc:arm64
```

#### For Different Architecture

If you need to build amd64 images on an arm64 Mac, cross-architecture builds with `bootc-image-builder` are unreliable due to QEMU emulation issues. Use one of these options:

##### Option 1: Use UTM (Free) - Recommended

1. Install UTM:
   ```bash
   brew install --cask utm
   ```

2. Download Ubuntu 22.04 Server ISO (amd64)

3. Create a new VM in UTM with:
   - 4+ CPU cores
   - 8GB+ RAM
   - 50GB+ disk

4. Install Ubuntu in the VM

5. In the VM, install Podman:
   ```bash
   sudo apt update && sudo apt install -y podman
   ```

6. Copy your container image to the VM or pull it from registry

7. Run bootc-image-builder in the VM (see commands below)

##### Option 2: Use GitHub Actions (CI/CD)

Create a GitHub Actions workflow that:
1. Runs on `ubuntu-latest` (amd64)
2. Installs Podman
3. Builds your container image
4. Runs bootc-image-builder
5. Uploads the bootable image as an artifact

##### Option 3: Use AWS EC2 or Cloud Instance

1. Launch an amd64 Linux instance (Ubuntu/RHEL)
2. Install Podman
3. Pull your container image
4. Run bootc-image-builder
5. Download the resulting image

##### Option 4: Use Docker Desktop Linux VM (if available)

If you have Docker Desktop with Linux VM support:
1. Enable Docker Desktop
2. Use docker commands instead of podman
3. Run bootc-image-builder in Docker

#### Commands to Run in Linux VM (After Setup)

Once you have a Linux VM or cloud instance set up:

```bash
# 1. Pull your container image
podman pull quay.io/olavtar/rhoim-bootc-rhel:latest
podman tag quay.io/olavtar/rhoim-bootc-rhel:latest localhost/rhoim-bootc-rhel:latest

# 2. Build bootable image
mkdir -p images
podman run --rm --privileged \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$(pwd)/images":/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  --type raw \
  --type vhd \
  --type ami \
  localhost/rhoim-bootc-rhel:latest

# 3. Copy images back to Mac (if using VM)
# Use shared folder or scp
```

### View Disk Images in Podman Desktop

1. Open Podman Desktop
2. Navigate to "Images" tab
3. Bootable disk images may appear as additional artifacts

## Troubleshooting

### "No space left on device"

**Solution**: Increase Podman machine disk size:

```bash
podman machine stop
podman machine set --disk-size 200
podman machine start
```

### "Cross-architecture building may not work correctly"

**Cause**: Attempting to build amd64 bootable disk on arm64 host.

**Solution**: 
- Build for native architecture (arm64), or
- Use a native amd64 environment (VM, cloud instance, CI/CD)

### Container exits immediately

**Cause**: Bootc images require systemd and privileged mode.

**Solution**: Run with `--privileged` and `--systemd=always`:

```bash
podman run --privileged --systemd=always -p 8000:8000 your-image:tag
```

### No logs from `podman logs`

**Cause**: Bootc containers use systemd, which logs to journald, not stdout.

**Solution**: Use `journalctl` inside the container:

```bash
podman exec <container> journalctl --no-pager
podman exec <container> journalctl -u rhoim-vllm.service --no-pager
```

### Service not starting

**Check service status**:
```bash
podman exec <container> systemctl status rhoim-vllm.service
podman exec <container> systemctl list-units --failed
```

**View detailed logs**:
```bash
podman exec <container> journalctl -u rhoim-vllm.service --no-pager -n 100
```

### Port not accessible

**Check if service is listening**:
```bash
podman exec <container> netstat -tlnp | grep 8000
# or
podman exec <container> ss -tlnp | grep 8000
```

**Verify port mapping**:
```bash
podman port <container>
```

### Clean Up Resources

```bash
# Remove stopped containers
podman container prune

# Remove unused images
podman image prune

# Remove all unused resources
podman system prune -a
```

## Best Practices

1. **Regular Cleanup**: Periodically clean up unused images and containers to save disk space.
2. **Resource Management**: Monitor Podman machine resources and adjust as needed.
3. **Image Tagging**: Use meaningful tags for different builds (e.g., `:dev`, `:test`, `:latest`).
4. **Testing**: Always test containers locally before deploying to cloud.
5. **Architecture Awareness**: Be aware of architecture differences when building and testing.

## Additional Resources

- [Podman Desktop Documentation](https://docs.podman-desktop.io)
- [Bootc Documentation](https://www.bootc.dev)
- [Podman Documentation](https://docs.podman.io)

