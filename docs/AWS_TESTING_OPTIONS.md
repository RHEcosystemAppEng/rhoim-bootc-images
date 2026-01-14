# AWS Testing Options for Bootc Images

## The Problem: Running Bootc Images in Containers

**You're right to be skeptical!** Running a bootc image (which is designed to be the **host OS**) inside a container on an AWS VM has significant limitations:

### Why It's Problematic

1. **Bootc images are OS images, not application containers**
   - They run `systemd` as PID 1
   - They expect to be the root filesystem, not a container
   - They're designed to boot directly from disk

2. **Systemd in containers requires special privileges**
   - Need `--privileged` flag (security risk)
   - Need `--systemd=always` flag
   - Still may not work correctly for all systemd features

3. **Nested container issues**
   - Your bootc image contains Podman
   - Running Podman inside a container that's itself in a container = complex
   - Storage driver conflicts, cgroup issues, etc.

4. **Not the intended use case**
   - Bootc images are meant to be **installed to disk** and **booted as the OS**
   - Testing as a container is limited and may not reflect real behavior

## Better Approaches for AWS Testing

### Option 1: Create AMI from Bootc Image (Recommended for Production)

This is the **proper way** to deploy bootc images to AWS:

```bash
# 1. Build bootc container image (already done)
# Image: localhost/rhoim-vllm-bootc:latest

# 2. Create bootable qcow2 disk image
mkdir -p images
podman run --rm --privileged \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$(pwd)/images":/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  localhost/rhoim-vllm-bootc:latest

# 3. Convert qcow2 to raw format
qemu-img convert -f qcow2 -O raw images/qcow2/disk.qcow2 images/qcow2/disk.raw

# 4. Upload to S3
aws s3 mb s3://your-bootc-images-bucket
aws s3 cp images/qcow2/disk.raw s3://your-bootc-images-bucket/rhoim-vllm-bootc.raw

# 5. Import snapshot
IMPORT_TASK_ID=$(aws ec2 import-snapshot \
  --disk-container Format=RAW,UserBucket="{S3Bucket=your-bootc-images-bucket,S3Key=rhoim-vllm-bootc.raw}" \
  --query 'ImportTaskId' --output text)

# 6. Wait for import to complete (check status)
aws ec2 describe-import-snapshot-tasks --import-task-ids $IMPORT_TASK_ID

# 7. Get snapshot ID and create AMI
SNAPSHOT_ID=$(aws ec2 describe-import-snapshot-tasks \
  --import-task-ids $IMPORT_TASK_ID \
  --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.SnapshotId' \
  --output text)

aws ec2 register-image \
  --name rhoim-vllm-bootc \
  --root-device-name /dev/sda1 \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"SnapshotId\":\"$SNAPSHOT_ID\"}}]"

# 8. Launch EC2 instance from AMI
aws ec2 run-instances \
  --image-id <AMI-ID> \
  --instance-type g4dn.xlarge \  # For GPU support
  --key-name your-key-pair \
  --security-group-ids sg-xxxxxxxxx
```

**Pros:**
- ✅ Proper deployment method
- ✅ Image runs as the actual OS
- ✅ Full systemd functionality
- ✅ Can use GPU instances
- ✅ Production-ready

**Cons:**
- ❌ Takes longer (upload, import, AMI creation)
- ❌ Requires S3 bucket
- ❌ More steps

### Option 2: Install Bootc Image Directly to EBS Volume (Faster Testing)

Install the bootc image directly to an EBS volume attached to an existing EC2 instance:

```bash
# On your AWS builder VM (RHEL 9 with bootc installed)

# 1. Create and attach EBS volume to your builder VM
# (via AWS Console or CLI)

# 2. Find the attached volume
lsblk
# Example: /dev/nvme1n1

# 3. Install bootc image to the volume
sudo bootc install \
  --root-fs-type ext4 \
  --karg console=ttyS0,115200n8 \
  localhost/rhoim-vllm-bootc:latest \
  /dev/nvme1n1

# 4. Detach volume from builder VM
# 5. Create snapshot from volume
# 6. Create AMI from snapshot
# 7. Launch new EC2 instance from AMI
```

**Pros:**
- ✅ Faster than S3 import method
- ✅ Direct installation
- ✅ Good for testing

**Cons:**
- ❌ Requires bootc on builder VM
- ❌ Need to manage EBS volumes

### Option 3: Limited Container Testing (Quick Validation)

Test the **container image structure** without full bootc functionality:

```bash
# On AWS builder VM

# 1. Test that image builds and has correct structure
podman run --rm \
  localhost/rhoim-vllm-bootc:latest \
  ls -la /usr/local/bin/

# 2. Verify systemd services are present
podman run --rm \
  localhost/rhoim-vllm-bootc:latest \
  systemctl list-unit-files | grep rhoim

# 3. Check scripts are executable
podman run --rm \
  localhost/rhoim-vllm-bootc:latest \
  test -x /usr/local/bin/run-vllm-container.sh && echo "Script is executable"

# 4. Verify configuration files
podman run --rm \
  localhost/rhoim-vllm-bootc:latest \
  cat /etc/sysconfig/rhoim
```

**Pros:**
- ✅ Very fast
- ✅ Good for validating image structure
- ✅ No additional setup needed

**Cons:**
- ❌ Doesn't test actual bootc functionality
- ❌ Doesn't test systemd services running
- ❌ Limited validation

### Option 4: Use bootc-image-builder on AWS VM (Hybrid Approach)

Build the disk image directly on your AWS builder VM:

```bash
# On AWS builder VM (already has podman and bootc-image-builder)

# 1. Build container image (already done)
# Image: localhost/rhoim-vllm-bootc:latest

# 2. Create qcow2 disk image
mkdir -p ~/bootc-images
sudo podman run --rm --privileged \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "$HOME/bootc-images":/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  localhost/rhoim-vllm-bootc:latest

# 3. Convert to raw
qemu-img convert -f qcow2 -O raw \
  ~/bootc-images/qcow2/disk.qcow2 \
  ~/bootc-images/disk.raw

# 4. Upload to S3 and create AMI (same as Option 1, steps 4-8)
```

**Pros:**
- ✅ Build happens on AWS (no large uploads from local)
- ✅ Can test qcow2 locally with QEMU first
- ✅ Full control over the process

**Cons:**
- ❌ Requires bootc-image-builder on VM
- ❌ Still need S3 and AMI creation steps

## Recommendation

**For initial testing:** Use **Option 3** (limited container testing) to quickly validate:
- Image builds correctly
- Files are in the right places
- Scripts are executable
- Configuration is correct

**For real testing:** Use **Option 2** (direct EBS install) or **Option 4** (build on AWS) to:
- Test actual bootc functionality
- Verify systemd services work
- Test with real hardware (GPU if needed)

**For production:** Use **Option 1** (full AMI workflow) for:
- Proper deployment pipeline
- Version control of AMIs
- Easy rollback

## What We Should Do Now

Since we've already built the image on the AWS VM, let's:

1. **Quick validation** (Option 3): Test the image structure
2. **Create disk image** (Option 4): Use bootc-image-builder on the VM
3. **Test locally** (if possible): Use QEMU to boot the qcow2 image
4. **Deploy to AWS**: Create AMI and launch instance

Would you like me to proceed with Option 4 (building the disk image on the AWS VM)?
