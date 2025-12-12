# Cloud Deployment Guide

This guide covers deploying bootc images to various cloud platforms.

## Table of Contents

- [Azure Deployment](#azure-deployment)
- [AWS Deployment](#aws-deployment)
- [General Cloud Deployment](#general-cloud-deployment)

## Azure Deployment

### Prerequisites

- Azure account and subscription
- Azure CLI installed (optional, for command-line) or Azure Portal access
- **Important**: vLLM requires Intel CPUs with AVX-512 support. Use VM sizes like `Standard_D4s_v5` or `Standard_D2s_v5` (Intel Ice Lake). AMD-based VMs or older Intel VMs may cause SIGILL crashes.

### Step 1: Build Bootable Disk Image

First, build your bootc container image and create a bootable disk:

```bash
# Build container image
podman build -t localhost/rhoim-bootc-rhel:latest -f vllm-cpu/Containerfile .

# Create bootable qcow2 image
mkdir -p images
podman run --rm --privileged \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$(pwd)/images":/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  localhost/rhoim-bootc-rhel:latest
```

The bootable image will be created at: `images/qcow2/disk.qcow2`

### Step 2: Convert qcow2 to Azure-Compliant VHD

**Azure Requirements (ALL must be met):**
1. ✅ **Fixed-size VHD** (not dynamic) - use `-o subformat=fixed`
2. ✅ **Size must be whole number in MBs** - resize image to exact MB boundary
3. ✅ **VHD format** - use `-O vpc`
4. ✅ **Upload as Page blob** (not Block blob) in Azure Storage

**ROBUST METHOD: Convert via RAW to ensure exact alignment**

```bash
# 1. Convert qcow2 to raw
qemu-img convert -f qcow2 -O raw images/qcow2/disk.qcow2 images/qcow2/disk.raw

# 2. Calculate exact size for alignment (e.g., 46062 MB)
# 46062 * 1024 * 1024 = 48300556288 bytes
# Resize raw file to this EXACT byte count
qemu-img resize -f raw images/qcow2/disk.raw 48300556288

# 3. Convert raw to fixed-size VHD
# force_size=on prevents qemu from altering the size for geometry alignment
qemu-img convert -f raw -O vpc -o subformat=fixed,force_size=on images/qcow2/disk.raw images/qcow2/disk.vhd

# 4. Verify
# File size should be Virtual Size + 512 bytes (footer)
ls -l images/qcow2/disk.vhd
# Check for conectix footer - this should output conectix
tail -c 512 images/qcow2/disk.vhd | strings | grep -i conectix
```

**Why this method works:**

Azure has strict requirements for VHD files:
1. **Fixed-size VHD** (not dynamic) - achieved with `-o subformat=fixed`
2. **Size must be a whole number in MBs** - Azure rejects sizes like 46,061.3671875 MB
3. **Exact byte alignment** - The raw intermediate step ensures precise control

**The Problem:**
- Original qcow2: 48,299,507,712 bytes = 46,061.3671875 MB (not a whole number)
- Direct conversion to VHD often adds overhead, making it non-whole-number MBs
- Azure rejects non-whole-number sizes with: `"unsupported virtual size... must be a whole number in (MBs)"`

**The Solution:**
- Convert to raw first for precise size control
- Resize raw to exact whole-number MB (e.g., 46,062 MB = 48,300,556,288 bytes)
- Convert raw to VHD with `force_size=on` to preserve exact size
- Result: VHD with exactly 46,062 MB (or your chosen whole number) that Azure accepts

**Alternative Method: Resize qcow2 first, then convert**

```bash
# OPTION 1: Resize qcow2 first, then convert (RECOMMENDED)
qemu-img resize images/qcow2/disk.qcow2 46080M
qemu-img convert -f qcow2 -O vpc -o subformat=fixed images/qcow2/disk.qcow2 images/qcow2/disk.vhd

# OPTION 2: Convert first, then resize VHD directly (if you already have a VHD)
qemu-img convert -f qcow2 -O vpc -o subformat=fixed images/qcow2/disk.qcow2 images/qcow2/disk.vhd
qemu-img resize images/qcow2/disk.vhd 46080M

# Verify the VHD meets all Azure requirements
qemu-img info images/qcow2/disk.vhd
# Should show: virtual size: 45 GiB (48,316,108,800 bytes) = exactly 46,080 MB

# Verify VHD footer exists
tail -c 512 images/qcow2/disk.vhd | strings | grep -i conectix
# Should show: conectix
```

**Important Notes:**
- Use `force_size=on` to prevent qemu from rounding to CHS geometry
- The VHD file size will be Virtual Size + 512 bytes (VHD footer)
- When uploading to Azure Blob Storage, set **Blob type: Page blob** (required for VHD)

**Important:** If you already uploaded a VHD to Azure that failed validation, you must:
1. Delete the old VHD from Azure Blob Storage
2. Re-convert with the commands above (resize + convert with `-o subformat=fixed`)
3. Upload the new VHD (make sure to set **Blob type: Page blob**)

### Step 3: Create Azure Storage Account

1. Go to [Azure Portal](https://portal.azure.com)
2. Navigate to **Storage accounts** → **Create**
3. Fill in:
   - **Subscription**: Select your subscription
   - **Resource group**: Create new (e.g., `rhoim-bootc-rg`) or use existing
   - **Storage account name**: e.g., `rhoimbootcstorage` (must be globally unique)
   - **Region**: Choose a region (e.g., `East US`)
   - **Performance**: Standard
   - **Redundancy**: Locally-redundant storage (LRS) is fine for testing
4. Click **Review + Create** → **Create**
5. Wait for deployment to complete

### Step 4: Create Container in Storage Account

1. Go to your storage account → **Containers** (left sidebar)
2. Click **+ Container**
3. Fill in:
   - **Name**: `vhds`
   - **Public access level**: Private
4. Click **Create**

### Step 5: Upload VHD to Azure Blob Storage

**Option A: Using Azure Portal (Web Interface)**
1. Go to Storage account → **Containers** → `vhds`
2. Click **Upload**
3. Select your `disk.vhd` file
4. **Important**: Set **Blob type** to **Page blob** (required for VHD)
5. Click **Upload** (may take 10-30 minutes depending on file size)

**Option B: Using Azure CLI (Faster)**
```bash
# Login to Azure
az login

# Set your subscription
az account set --subscription "your-subscription-id"

# Create storage container (if it doesn't exist)
az storage container create \
  --name vhds \
  --account-name <storage-account-name> \
  --account-key <storage-account-key>

# Upload VHD (replace with your storage account name)
az storage blob upload \
  --account-name rhoimbootcstorage \
  --container-name vhds \
  --name rhoim-bootc-rhel.vhd \
  --file images/qcow2/disk.vhd \
  --type page
```

### Step 6: Create Managed Disk from VHD

1. Go to Azure Portal → **Disks** → **Create**
2. Fill in:
   - **Subscription**: Your subscription
   - **Resource group**: Same as storage account (e.g., `rhoim-bootc-rg`)
   - **Disk name**: `rhoim-bootc-rhel-disk`
   - **Region**: Same as storage account
   - **Source type**: **Storage blob**
   - **Source blob**: Click **Browse** → Select your storage account → Container `vhds` → Select `rhoim-bootc-rhel.vhd`
   - **OS type**: **Linux**
   - **Size**: Match your VHD size or choose larger (e.g., 64 GiB)
3. Click **Review + Create** → **Create**
4. Wait for disk creation (2-5 minutes)

### Step 7: Create VM from Managed Disk

1. Go to Azure Portal → **Virtual machines** → **Create** → **Azure virtual machine**
2. Fill in **Basics** tab:
   - **Subscription**: Your subscription
   - **Resource group**: Same as before (e.g., `rhoim-bootc-rg`)
   - **Virtual machine name**: `rhoim-bootc-vm`
   - **Region**: Same as storage account
   - **Image**: Click **See all images** → **My items** tab → Select your managed disk (`rhoim-bootc-rhel-disk`)
   - **Size**: **IMPORTANT** - Choose a VM size with Intel CPU and AVX-512 support:
     - **Recommended**: `Standard_D4s_v5` (4 vCPU, 16 GiB RAM) - Intel Ice Lake with AVX-512
     - **Minimum**: `Standard_D2s_v5` (2 vCPU, 8 GiB RAM) - Intel Ice Lake with AVX-512
     - **Avoid**: AMD-based VMs (Das_v4, Eas_v4) or older Intel VMs without AVX-512
     - **Why**: vLLM CPU backend requires AVX-512 instructions. Without it, the service will crash with SIGILL (Illegal Instruction) errors.
   - **Authentication type**: SSH public key or Password
     - If SSH: Generate new key pair or use existing
     - If Password: Set username and password
3. **Disks** tab: Leave defaults (OS disk is your managed disk)
4. **Networking** tab:
   - **Virtual network**: Create new or use existing
   - **Public IP**: Yes (to access the VM)
   - **NIC network security group**: Basic
   - **Public inbound ports**: Configure as needed for your environment
5. **Review + Create** → **Create**
6. Wait for VM deployment (2-5 minutes)

### Step 8: Test the VM

1. Get the VM's public IP:
   - Go to VM → **Overview** → Copy **Public IP address**
2. Connect to the VM using your configured authentication method
3. Check vLLM service:
   ```bash
   systemctl status rhoim-vllm.service
   journalctl -u rhoim-vllm.service -f
   ```
4. Test vLLM API:
   ```bash
   # From inside VM
   curl http://localhost:8000/v1/models
   ```

### Troubleshooting

- **Error: "Dynamic VHD type" when creating managed disk:**
  - The VHD must be **fixed-size**, not dynamic
  - Re-convert with resize + fixed-size:
    ```bash
    qemu-img resize images/qcow2/disk.qcow2 46080M
    qemu-img convert -f qcow2 -O vpc -o subformat=fixed images/qcow2/disk.qcow2 images/qcow2/disk.vhd
    ```
  - **Delete the old VHD from Azure Blob Storage** and upload the new fixed-size one

- **Error: "unsupported virtual size... must be a whole number in (MBs)":**
  - Azure requires the VHD size to be a whole number in MBs (e.g., 46,080 MB, not 46,061.3671875 MB)
  - Resize the qcow2 image first, then convert:
    ```bash
    # Resize to exact MB boundary (46,080 MB = 45 GiB)
    qemu-img resize images/qcow2/disk.qcow2 46080M
    # Then convert to VHD
    qemu-img convert -f qcow2 -O vpc -o subformat=fixed images/qcow2/disk.qcow2 images/qcow2/disk.vhd
    # Verify size is whole number in MBs
    qemu-img info images/qcow2/disk.vhd
    # Should show: 48,316,108,800 bytes = exactly 46,080 MB
    ```
  - **Delete the old VHD from Azure Blob Storage** and upload the resized one

- **If VM doesn't boot:** Check boot diagnostics in Azure Portal → VM → Help → Boot diagnostics

- **If vLLM service crashes with SIGILL (Illegal Instruction):** 
  - This indicates the VM CPU doesn't support AVX-512 instructions required by vLLM
  - **Solution**: Resize VM to `Standard_D4s_v5` or `Standard_D2s_v5` (Intel Ice Lake with AVX-512)
  - Check CPU flags: `grep flags /proc/cpuinfo | grep avx512f` (should show `avx512f`)

- **If vLLM service shows JSON decode errors:**
  - Clear Hugging Face cache: `rm -rf ~/.cache/huggingface`
  - Restart service: `systemctl restart rhoim-vllm.service`

- **VM Agent Status**: Bootc images may not have Azure VM Agent. Use Azure Serial Console for initial access.

- **SSH Access**: Configure SSH keys or passwords during image build, or use Serial Console to set up access.

- **Service Access**: Verify vLLM service is running and firewall rules allow connections.

## AWS Deployment

### Prerequisites

- AWS CLI installed and configured
- EC2 permissions
- Container image built and available
- S3 bucket for storing disk images

### Steps

1. **Build the Bootable Image**

   ```bash
   podman build -t localhost/rhoim-bootc-rhel:latest -f vllm-cpu/Containerfile .
   ```

2. **Create Bootable Disk Image**

   Create a qcow2 image first, then convert to raw:
   ```bash
   mkdir -p images
   podman run --rm --privileged \
     -v /var/lib/containers/storage:/var/lib/containers/storage \
     -v "$(pwd)/images":/output \
     quay.io/centos-bootc/bootc-image-builder:latest \
     --type qcow2 \
     localhost/rhoim-bootc-rhel:latest
   ```

3. **Convert qcow2 to Raw Format**

   ```bash
   # Convert qcow2 to raw
   qemu-img convert -f qcow2 -O raw images/qcow2/disk.qcow2 images/qcow2/disk.raw

   # Compress for faster upload (optional)
   gzip images/qcow2/disk.raw
   ```

4. **Upload to S3**

   ```bash
   # Create S3 bucket (if it doesn't exist)
   aws s3 mb s3://your-bucket-name

   # Upload raw image
   aws s3 cp images/qcow2/disk.raw s3://your-bucket/bootc-images/your-image.raw

   # Or if compressed
   aws s3 cp images/qcow2/disk.raw.gz s3://your-bucket/bootc-images/your-image.raw.gz
   ```

5. **Import Snapshot**

   ```bash
   # Import snapshot from S3
   aws ec2 import-snapshot \
     --disk-container Format=RAW,UserBucket="{S3Bucket=your-bucket,S3Key=bootc-images/your-image.raw}"
   ```

   Note the `ImportTaskId` from the output. Check import status:
   ```bash
   aws ec2 describe-import-snapshot-tasks --import-task-ids <ImportTaskId>
   ```

6. **Create AMI from Snapshot**

   Once the snapshot import is complete:
   ```bash
   # Get the snapshot ID from the import task
   SNAPSHOT_ID=$(aws ec2 describe-import-snapshot-tasks \
     --import-task-ids <ImportTaskId> \
     --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.SnapshotId' \
     --output text)

   # Create AMI from snapshot
   aws ec2 register-image \
     --name rhoim-bootc-rhel \
     --root-device-name /dev/sda1 \
     --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"SnapshotId\":\"$SNAPSHOT_ID\"}}]"
   ```

7. **Launch EC2 Instance**

   Use the AMI to launch an instance:
   ```bash
   aws ec2 run-instances \
     --image-id <AMI-ID> \
     --instance-type t3.medium \
     --key-name your-key-pair \
     --security-group-ids sg-xxxxxxxxx
   ```

   **Note**: For vLLM with CPU optimizations, consider using instances with AVX-512 support (e.g., `c5.xlarge` or `c5.2xlarge`).

## General Cloud Deployment

### Key Considerations

1. **Architecture Compatibility**: Ensure the image architecture matches the target platform (amd64 vs arm64).
2. **Boot Requirements**: Bootc images require UEFI boot support.
3. **Storage**: Use appropriate disk sizes (minimum 64GB recommended).
4. **Network**: Configure networking and security groups/firewalls appropriately.
5. **Access**: Set up SSH or console access for initial configuration.

### Testing Before Deployment

1. Test the container image locally with Podman:
   ```bash
   podman run --privileged --systemd=always -p 8000:8000 your-image:tag
   ```

2. Verify services are running:
   ```bash
   podman exec <container> systemctl status rhoim-vllm.service
   ```

3. Test API endpoints:
   ```bash
   curl http://localhost:8000/v1/models
   ```

