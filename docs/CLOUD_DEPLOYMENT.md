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

### ⚠️ Critical: UEFI Boot Mode Requirement

**Bootc images REQUIRE UEFI boot mode. This is a critical requirement that must be set when creating the AMI.**

**The Problem:**
- Bootc/ostree images use UEFI boot firmware
- AWS EC2 defaults to **Legacy BIOS** boot mode if the AMI doesn't specify a boot mode
- Legacy BIOS boot will **fail** with bootc images (kernel won't boot, console output will be empty)

**The Solution:**
- **Always specify `--boot-mode uefi`** when creating the AMI using `aws ec2 register-image`
- Without this, instances will fail to boot even though the image structure is correct

**How to Verify:**
```bash
# Check if AMI has UEFI boot mode
aws ec2 describe-images --image-ids <AMI-ID> --query 'Images[0].BootMode' --output text
# Should output: uefi

# Check if instance is using UEFI
aws ec2 describe-instances --instance-ids <INSTANCE-ID> --query 'Reservations[0].Instances[0].BootMode' --output text
# Should output: uefi
```

**Symptoms of Missing UEFI Boot Mode:**
- Instance status: "initializing" (never reaches "ok")
- Console output: 0-47 bytes (essentially empty)
- System status: "ok" (AWS can reach instance)
- Instance status: "initializing" (instance can't reach AWS metadata service)
- SSH: Not accessible

### ⚠️ Important: AWS AMI Import Limitations

**AWS has strict validation rules for imported images that often cause issues with bootc images:**

1. **Partition Table Requirements**: AWS expects specific partition layouts (GPT with specific partitions)
2. **Boot Loader Compatibility**: Bootc uses ostree/GRUB2 which may not match AWS expectations
3. **Root Device Name**: Must match AWS conventions (`/dev/sda1`, `/dev/xvda`, etc.)
4. **File System Support**: Only ext4, xfs, and btrfs are fully supported
5. **Image Size**: Must meet minimum size requirements (typically 8GB+)
6. **UEFI Boot Mode**: **REQUIRED** - Must be explicitly set when creating AMI (see above)

**Result**: Direct AMI import from raw disk images often fails AWS validation, especially with bootc/ostree-based images. Use the direct EBS installation method below for better reliability.

### Recommended Approach: Direct EBS Installation (Most Reliable)

Instead of importing a disk image, install the bootc image directly to an EBS volume on an existing EC2 instance. This bypasses AWS validation issues.

#### Prerequisites

- AWS CLI installed and configured
- EC2 instance running RHEL 9 with bootc installed (your builder VM)
- EC2 permissions to create/manage EBS volumes and snapshots
- Container image built and available locally

#### Steps

1. **Build the Bootc Container Image** (if not already done)

   ```bash
   # On your builder VM
   cd ~/rhoim-bootc-images/vllm-bootc
   sudo podman build --platform linux/amd64 \
     --secret id=rhsm,src=/etc/rhsm/rhsm.conf \
     --secret id=ca,src=/etc/rhsm/ca/redhat-uep.pem \
     --secret id=key,src=/etc/pki/entitlement/4045241115620640280-key.pem \
     --secret id=cert,src=/etc/pki/entitlement/4045241115620640280.pem \
     -t localhost/rhoim-vllm-bootc:latest .
   ```

2. **Create and Attach EBS Volume**

   ```bash
   # Create a 50GB EBS volume (20GB is insufficient for vLLM container image)
   # The vLLM container image is large (~10-15GB), and you need space for:
   # - Bootc OS: ~2-3GB
   # - vLLM container image: ~10-15GB
   # - Container layers and temporary files: ~5-10GB
   # - Buffer for operations: ~5GB
   # Minimum recommended: 50GB
   VOLUME_ID=$(aws ec2 create-volume \
     --region us-east-1 \
     --availability-zone us-east-1a \
     --size 50 \
     --volume-type gp3 \
     --query 'VolumeId' --output text)

   # Attach to your builder instance
   INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
   aws ec2 attach-volume \
     --region us-east-1 \
     --volume-id $VOLUME_ID \
     --instance-id $INSTANCE_ID \
     --device /dev/sdf

   # Wait for attachment
   sleep 5
   ```

3. **Find the Attached Volume**

   ```bash
   # On the builder VM
   lsblk
   # Look for the new volume (e.g., /dev/nvme1n1 or /dev/xvdf)
   # Note: AWS uses nvme interface, so it might be /dev/nvme1n1
   ```

4. **Install Bootc Image to EBS Volume**

   ```bash
   # Install bootc image directly to the volume
   sudo bootc install to-disk \
     --wipe \
     --filesystem ext4 \
     --karg console=ttyS0,115200n8 \
     --karg root=LABEL=root \
     --root-ssh-authorized-keys ~/.ssh/authorized_keys \
     localhost/rhoim-vllm-bootc:latest \
     /dev/nvme1n1  # Use the device from lsblk

   # Verify installation
   sudo partprobe /dev/nvme1n1
   sudo lsblk -f /dev/nvme1n1
   ```

5. **Inject Registry Credentials (Required for vLLM container pull)**

   **Important Notes:**
   - Red Hat registry requires username format: `org_id|username`
   - Credentials are stored in `/etc/sysconfig/rhoim` and used by `podman-registry-login.service`
   - Podman uses explicit `--authfile /root/.config/containers/auth.json` for credential persistence
   
   ```bash
   # Find the root partition (usually the largest partition)
   ROOT_PARTITION=$(lsblk -rno NAME,TYPE /dev/nvme1n1 | grep part | tail -1 | awk '{print "/dev/"$1}')
   # Or manually: ROOT_PARTITION=/dev/nvme1n1p3
   
   # Inject credentials using the helper script
   # The script automatically formats username as "org_id|username"
   # Replace with your actual Red Hat credentials
   sudo ./scripts/inject-registry-credentials.sh \
     "$ROOT_PARTITION" \
     "your-org-id" \
     "your-redhat-username" \
     "your-redhat-token"
   
   # Or manually create the file (username must be in "org_id|username" format):
   # sudo mkdir -p /mnt/bootc-root/etc/sysconfig
   # sudo mount "$ROOT_PARTITION" /mnt/bootc-root
   # sudo tee /mnt/bootc-root/etc/sysconfig/rhoim > /dev/null <<EOF
   # RHSM_ORG_ID="your-org-id"
   # REDHAT_REGISTRY_USERNAME="your-org-id|your-username"  # Must include org_id
   # REDHAT_REGISTRY_TOKEN="your-token"
   # EOF
   # sudo chmod 600 /mnt/bootc-root/etc/sysconfig/rhoim
   # sudo umount /mnt/bootc-root
   ```

6. **Detach Volume and Create Snapshot**

   ```bash
   # Detach volume
   aws ec2 detach-volume \
     --region us-east-1 \
     --volume-id $VOLUME_ID

   # Wait for detachment
   aws ec2 wait volume-available --volume-ids $VOLUME_ID --region us-east-1

   # Create snapshot
   SNAPSHOT_ID=$(aws ec2 create-snapshot \
     --region us-east-1 \
     --volume-id $VOLUME_ID \
     --description "RHOIM vLLM Bootc Image" \
     --query 'SnapshotId' --output text)

   # Wait for snapshot to complete
   aws ec2 wait snapshot-completed \
     --region us-east-1 \
     --snapshot-ids $SNAPSHOT_ID
   ```

6. **Create AMI from Snapshot**

   ```bash
   # Create AMI from snapshot with UEFI boot mode (REQUIRED for bootc)
   # ⚠️ CRITICAL: --boot-mode uefi must be specified, otherwise AWS defaults to Legacy BIOS
   # Legacy BIOS will cause boot failure with bootc images (empty console output, instance won't boot)
   AMI_ID=$(aws ec2 register-image \
     --region us-east-1 \
     --name rhoim-vllm-bootc-$(date +%Y%m%d) \
     --root-device-name /dev/sda1 \
     --virtualization-type hvm \
     --architecture x86_64 \
     --boot-mode uefi \
     --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"SnapshotId\":\"$SNAPSHOT_ID\",\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
     --query 'ImageId' --output text)

   echo "AMI created: $AMI_ID"
   
   # Verify boot mode was set correctly
   BOOT_MODE=$(aws ec2 describe-images --region us-east-1 --image-ids $AMI_ID --query 'Images[0].BootMode' --output text)
   if [ "$BOOT_MODE" != "uefi" ]; then
     echo "⚠️ WARNING: Boot mode is not UEFI: $BOOT_MODE"
     echo "   This will cause boot failure. Recreate the AMI with --boot-mode uefi"
     exit 1
   fi
   echo "✅ Boot mode verified: $BOOT_MODE"
   
   # Enable ENA support (required for enhanced networking on certain instance types like g4dn.xlarge)
   aws ec2 modify-image-attribute \
     --region us-east-1 \
     --image-id $AMI_ID \
     --ena-support
   echo "✅ ENA support enabled"
   ```

7. **Launch EC2 Instance from AMI**

   ```bash
   # Launch instance from AMI
   aws ec2 run-instances \
     --region us-east-1 \
     --image-id $AMI_ID \
     --instance-type g4dn.xlarge \  # For GPU support
     --key-name your-key-pair \
     --security-group-ids sg-xxxxxxxxx \
     --subnet-id subnet-xxxxxxxxx
   ```

### Alternative: S3 Import Method (May Fail Validation)

If you want to try the S3 import method despite validation issues:

1. **Build Bootable Disk Image**

   ```bash
   mkdir -p images
   sudo podman run --rm --privileged \
     -v /var/lib/containers/storage:/var/lib/containers/storage \
     -v "$(pwd)/images":/output \
     quay.io/centos-bootc/bootc-image-builder:latest \
     --type qcow2 \
     localhost/rhoim-vllm-bootc:latest
   ```

2. **Convert and Prepare for AWS**

   ```bash
   # Convert to raw
   qemu-img convert -f qcow2 -O raw images/qcow2/disk.qcow2 images/qcow2/disk.raw

   # Resize to meet AWS minimum (if needed)
   qemu-img resize images/qcow2/disk.raw 10G
   ```

3. **Upload and Import**

   ```bash
   # Upload to S3
   aws s3 cp images/qcow2/disk.raw s3://your-bucket/bootc-images/disk.raw

   # Import snapshot
   IMPORT_TASK_ID=$(aws ec2 import-snapshot \
     --disk-container Format=RAW,UserBucket="{S3Bucket=your-bucket,S3Key=bootc-images/disk.raw}" \
     --query 'ImportTaskId' --output text)

   # Check status
   aws ec2 describe-import-snapshot-tasks --import-task-ids $IMPORT_TASK_ID
   ```

**⚠️ Note**: This method often fails AWS validation. Use the direct EBS installation method above for better reliability.

### Troubleshooting AWS Deployment

- **Instance doesn't boot / Console output is empty (0-47 bytes)**:
  - **Most common cause**: AMI was created without `--boot-mode uefi`
  - **Solution**: Recreate the AMI with `--boot-mode uefi` explicitly set
  - **Verify**: `aws ec2 describe-images --image-ids <AMI-ID> --query 'Images[0].BootMode'` should return `uefi`
  - **Symptoms**: System status "ok" but instance status stuck at "initializing", no console output, SSH not accessible

- **AMI validation fails**: Use the direct EBS installation method instead

- **Root device not found**: Ensure `--root-device-name` matches the partition layout (usually `/dev/sda1`)

- **Snapshot import fails**: Check S3 permissions and file format (must be uncompressed raw)

- **Instance status check fails**: 
  - If "Instance reachability check" fails, verify network configuration
  - If console output is empty, check boot mode (must be UEFI)

- **"no space left on device" during image pull**:
  - **Cause**: EBS volume is too small (20GB is insufficient for vLLM container image)
  - **Solution**: Resize EBS volume to at least 50GB:
    ```bash
    # Resize EBS volume
    aws ec2 modify-volume --volume-id <VOLUME-ID> --size 50
    
    # On the instance, resize partition and filesystem
    growpart /dev/nvme0n1 3  # Adjust partition number as needed
    resize2fs /dev/nvme0n1p3  # Adjust partition as needed
    ```
  - **Prevention**: Create EBS volumes with at least 50GB from the start

- **Registry authentication fails ("invalid username/password")**:
  - **Cause**: Red Hat registry requires username format `org_id|username`, not just `username`
  - **Solution**: Ensure `/etc/sysconfig/rhoim` has correct format:
    ```bash
    # Option 1: Set username in correct format
    REDHAT_REGISTRY_USERNAME="your-org-id|your-username"
    
    # Option 2: Set org_id separately (script will construct format)
    RHSM_ORG_ID="your-org-id"
    REDHAT_REGISTRY_USERNAME="your-username"
    ```
  - **Verify**: Check that `podman-registry-login.service` runs successfully:
    ```bash
    systemctl status podman-registry-login.service
    journalctl -u podman-registry-login.service
    ```
  - **Note**: Podman uses explicit `--authfile /root/.config/containers/auth.json` for credential persistence

- **Container fails with "unresolvable CDI devices nvidia.com/gpu=all"**:
  - **Cause**: NVIDIA drivers or CDI configuration not available (common on CPU instances)
  - **Solution**: 
    - For GPU instances: Ensure NVIDIA drivers are installed and `nvidia-container-setup.service` has run
    - For CPU instances: This is expected - vLLM CUDA container requires GPU hardware
  - **Verify NVIDIA setup**:
    ```bash
    # Check if NVIDIA devices exist
    ls -la /dev/nvidia*
    
    # Check CDI configuration
    ls -la /etc/cdi/nvidia.yaml
    
    # Check nvidia-container-setup service
    systemctl status nvidia-container-setup.service
    ```

## General Cloud Deployment

### Key Considerations

1. **Architecture Compatibility**: Ensure the image architecture matches the target platform (amd64 vs arm64).
2. **Boot Requirements**: Bootc images require UEFI boot support.
3. **Storage**: Use appropriate disk sizes:
   - **Minimum for vLLM**: 50GB (20GB is insufficient)
   - **Recommended**: 64GB+ for production workloads
   - **Why**: vLLM container image is large (~10-15GB), plus OS, layers, and temporary files
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

