# Podman Desktop Development Workflow

This guide covers setting up and using Podman Desktop for local development and testing of bootc images.

## Table of Contents

- [Installation](#installation)
- [Initial Setup](#initial-setup)
  - [Install Bootc Extension](#1-install-bootc-extension)
  - [Start Podman Machine](#2-start-podman-machine)
  - [Configure Machine Resources](#3-configure-machine-resources-optional)
  - [Verify Installation](#4-verify-installation)
- [Building Images](#building-images)
- [Running Containers](#running-containers)
- [Creating Bootable Disks](#creating-bootable-disks)
- [Troubleshooting](#troubleshooting)

## Installation

### macOS

**Option 1: Download and Install**
1. Download Podman Desktop from [podman-desktop.io](https://podman-desktop.io)
2. Install the application
3. Start Podman Desktop from Applications

**Option 2: Install via Homebrew**
```bash
brew install --cask podman-desktop
```

### Linux

1. Install Podman Desktop via Flatpak from [Flathub](https://flathub.org/apps/io.podman_desktop.PodmanDesktop)
2. Or download from [podman-desktop.io](https://podman-desktop.io)
3. Start Podman Desktop

### Windows

1. Download Podman Desktop from [podman-desktop.io](https://podman-desktop.io)
2. Run the installer
3. Start Podman Desktop

## Initial Setup

### 1. Install Bootc Extension

**Important**: The bootc extension is required to work with bootc images in Podman Desktop.

1. Open Podman Desktop
2. Go to **Settings** (gear icon) or **Preferences**
3. Navigate to **Extensions** or **Plugins** section
4. Search for "Bootable Container extension" or "bootc extension"
5. Click **Install** on the bootc extension
6. Wait for installation to complete
7. Restart Podman Desktop if prompted

**Note**: The bootc extension enables bootc-specific features in Podman Desktop, such as:
- Building bootable disk images from container images
- Managing bootc images
- Converting between container and disk formats

### 2. Start Podman Machine

Podman Desktop automatically manages Podman machines. On first launch:
- A default machine will be created
- Wait for the machine to be ready (green status indicator)

### 3. Configure Machine Resources (Optional)

If you need more resources for building large images:

1. Open Podman Desktop
2. Go to **Settings** (gear icon)
3. Navigate to **Resources** or **Machine** section
4. Adjust the following settings:
   - **Disk size**: Increase from default 100GB to 200GB or more (for large image builds)
   - **CPU cores**: Increase if needed (e.g., 4 cores)
   - **Memory**: Increase if needed (e.g., 8GB)
5. Click **Apply** or **Save**
6. Restart the Podman machine if prompted

### 4. Verify Installation

1. Open Podman Desktop
2. Check the status indicator in the top-right corner - it should show "Running" (green)
3. Navigate to **Images** tab - you should see the interface without errors
4. Navigate to **Containers** tab - should display empty list or existing containers

## Building Images

### Using Podman Desktop UI

1. Open Podman Desktop
2. Navigate to **Images** tab (left sidebar)
3. Click **Build Image** button (usually at the top)
4. Fill in the build form:
   - **Containerfile path**: Browse and select `vllm-bootc/Containerfile` from your project directory
   - **Image name**: Enter `localhost/rhoim-bootc:latest`
   - **Build context**: Select the project root directory (e.g., `/path/to/rhoim-bootc-images`)
   - **Platform** (optional): Select `linux/amd64` for x86_64 or `linux/arm64` for ARM64
5. Click **Build** button
6. Monitor the build progress in the build log window
7. Once complete, the image will appear in the **Images** list

**Note**: For bootc images, you typically need to build for `linux/amd64` platform. The platform dropdown in Podman Desktop allows you to select the target architecture regardless of your host machine's architecture. However, cross-architecture builds may be slower and some tools may not work correctly with emulation.

### View Images in Podman Desktop

1. Open Podman Desktop
2. Navigate to **Images** tab
3. Your built images will appear in the list with:
   - Image name and tag
   - Size
   - Created date
   - Actions (run, delete, etc.)

## Running Containers

### Using Podman Desktop UI

**Important**: Bootc images require systemd and privileged mode to run properly.

1. Open Podman Desktop
2. Navigate to **Images** tab
3. Find your image (e.g., `localhost/rhoim-bootc:latest`)
4. Click the **Run** button (play icon) next to the image
5. In the "Create Container" dialog:
   - **Container name**: Enter a name (e.g., `rhoim-bootc-test`)
   - **Privileged mode**: **Enable this** (required for bootc images)
   - **Systemd**: **Enable this** (required for bootc images)
   - **Port mappings**: Add port mapping:
     - Host port: `8000`
     - Container port: `8000`
     - Protocol: `TCP`
   - Click **Start Container**
6. The container will appear in the **Containers** tab

### Check Container Status

1. Navigate to **Containers** tab
2. Find your container in the list
3. View status: **Running** (green), **Stopped** (gray), or **Error** (red)
4. Click on the container name to view details:
   - **Logs**: View container logs (note: bootc containers use systemd, so logs are in journald)
   - **Inspect**: View container configuration
   - **Terminal**: Open a shell inside the container

### View Systemd Logs

Since bootc containers use systemd, logs are in journald, not stdout. To view systemd logs:

1. Navigate to **Containers** tab
2. Click on your container name
3. Click **Terminal** tab to open a shell inside the container
4. In the terminal, you can run:
   - `journalctl --no-pager | tail -50` - View recent system logs
   - `systemctl status rhoim-vllm.service` - Check vLLM service status
   - `journalctl -u rhoim-vllm.service --no-pager` - View vLLM service logs

### Access Container Shell

1. Navigate to **Containers** tab
2. Click on your container name
3. Click **Terminal** tab
4. A terminal window will open inside the container

### Test vLLM API

Once the container is running, you can test the vLLM API:

1. Open a web browser or API testing tool (like Postman or curl)
2. Test the API endpoints:
   - Health check: `http://localhost:8000/health`
   - List models: `http://localhost:8000/v1/models`

**Note**: These endpoints are accessible from your host machine on port 8000 (mapped from container port 8000).

### Stop and Remove Container

1. Navigate to **Containers** tab
2. Find your container
3. Click the **Stop** button (square icon) to stop the container
4. Click the **Delete** button (trash icon) to remove the container

## Creating Bootable Disks

### Using Podman Desktop UI (Bootable Container Extension)

The Bootable Container extension in Podman Desktop provides UI functionality to create bootable disk images:

1. Open Podman Desktop
2. Navigate to **Images** tab
3. Find your bootc image (e.g., `localhost/rhoim-bootc:latest`)
4. Click on the image to view details
5. Look for **Bootable Container** or **Bootc** actions/options
6. Select the disk format you want to create (qcow2, raw, vhd, ami)
7. Choose the output directory
8. Click **Build** or **Create Disk Image**
9. Monitor the progress in the build log

**Important**: Cross-architecture builds (e.g., amd64 on arm64) may not work correctly in Podman Desktop due to QEMU emulation limitations. For best results, build images on a host machine that matches your target architecture.

### View Disk Images in Podman Desktop

1. Open Podman Desktop
2. Navigate to "Images" tab
3. Bootable disk images may appear as additional artifacts

### Next Steps: Deploy to Cloud

Once you have created your bootable disk images, you can deploy them to cloud platforms. For detailed instructions on deploying to Azure, AWS, and other cloud platforms, see the [Cloud Deployment Guide](CLOUD_DEPLOYMENT.md).

## Troubleshooting

### "No space left on device"

**Solution**: Increase Podman machine disk size:

1. Open Podman Desktop
2. Go to **Settings** (gear icon)
3. Navigate to **Resources** or **Machine** section
4. Increase **Disk size** from 100GB to 200GB or more
5. Click **Apply** or **Save**
6. Restart the Podman machine if prompted

### "Cross-architecture building may not work correctly"

**Cause**: Attempting to build amd64 bootable disk on arm64 host.

**Solution**: 
- Build for native architecture (arm64) in Podman Desktop, or
- Use a native amd64 environment for building (VM, cloud instance, or CI/CD pipeline)

### Container exits immediately

**Cause**: Bootc images require systemd and privileged mode.

**Solution**: When creating a container in Podman Desktop:
1. Make sure **Privileged mode** is enabled
2. Make sure **Systemd** is enabled
3. These options are available in the "Create Container" dialog when clicking Run on an image

### No logs from container logs tab

**Cause**: Bootc containers use systemd, which logs to journald, not stdout.

**Solution**: 
1. Navigate to **Containers** tab
2. Click on your container name
3. Click **Terminal** tab (this opens a shell inside the container)
4. In the container's terminal, run:
   - `journalctl --no-pager` - View all system logs
   - `journalctl -u rhoim-vllm.service --no-pager` - View vLLM service logs

**Note**: `journalctl` is a systemd utility that comes with the Linux system inside the container (RHEL 9), not from Podman Desktop. Podman Desktop provides the Terminal tab to access the container's shell where you can run these commands.

### Service not starting

1. Navigate to **Containers** tab
2. Click on your container name
3. Click **Terminal** tab
4. In the terminal, check service status:
   - `systemctl status rhoim-vllm.service` - Check vLLM service status
   - `systemctl list-units --failed` - List all failed services
5. View detailed logs:
   - `journalctl -u rhoim-vllm.service --no-pager -n 100` - View last 100 log lines

### Port not accessible

1. Verify port mapping in Podman Desktop:
   - Navigate to **Containers** tab
   - Click on your container
   - Check the **Ports** section to verify port 8000 is mapped correctly
2. Check if service is listening inside the container:
   - Click **Terminal** tab
   - Run: `netstat -tlnp | grep 8000` or `ss -tlnp | grep 8000`
3. Verify the service is running:
   - In the terminal, run: `systemctl status rhoim-vllm.service`

### Clean Up Resources

1. Navigate to **Containers** tab
2. Click **Cleanup** or **Prune** button (if available) to remove stopped containers
3. Navigate to **Images** tab
4. Select unused images and click **Delete** to remove them
5. Navigate to **Settings** → **Resources** to view disk usage

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

