# AWS EBS Direct Installation Guide

This guide walks through installing a bootc image directly to an EBS volume on your builder VM, then creating an AMI from it.

## Prerequisites

- Builder VM running RHEL 9 with bootc installed
- Bootc container image built: `localhost/rhoim-vllm-bootc:latest`
- AWS permissions to create/manage EBS volumes and snapshots

## Method 1: Using AWS Console (Recommended - No Credentials on VM)

### Step 1: Create EBS Volume via AWS Console

1. Go to [AWS EC2 Console](https://console.aws.amazon.com/ec2/)
2. Navigate to **Volumes** (left sidebar)
3. Click **Create volume**
4. Configure:
   - **Size**: 20 GiB (or larger)
   - **Volume type**: gp3
   - **Availability Zone**: Must match your builder VM's AZ (check with: `curl http://169.254.169.254/latest/meta-data/placement/availability-zone`)
   - **Snapshot**: None
5. Click **Create volume**
6. **Note the Volume ID** (e.g., `vol-0123456789abcdef0`)

### Step 2: Attach Volume to Builder VM

1. In the Volumes list, select your new volume
2. Click **Actions** → **Attach volume**
3. Configure:
   - **Instance**: Select your builder VM instance
   - **Device**: `/dev/sdf` (or `/dev/xvdf`)
4. Click **Attach**

### Step 3: Find the Attached Device on VM

SSH into your builder VM and run:

```bash
# Wait a few seconds for attachment
sleep 5

# List block devices
lsblk

# Look for the new device (will be /dev/nvme1n1 if using NVMe interface)
# Or /dev/xvdf if using older interface
```

**Note**: AWS uses NVMe interface on newer instance types, so the device will appear as `/dev/nvme1n1` even though you attached it as `/dev/sdf`.

### Step 4: Install Bootc Image to EBS Volume

```bash
# On builder VM
# Replace /dev/nvme1n1 with your actual device from lsblk

sudo bootc install \
  --root-fs-type ext4 \
  --karg console=ttyS0,115200n8 \
  --karg root=LABEL=root \
  localhost/rhoim-vllm-bootc:latest \
  /dev/nvme1n1

# Verify installation
sudo partprobe /dev/nvme1n1
sudo lsblk -f /dev/nvme1n1
```

### Step 5: Detach Volume via AWS Console

1. Go to **Volumes** → Select your volume
2. Click **Actions** → **Detach volume**
3. Wait for status to change to **available**

### Step 6: Create Snapshot

1. Select the volume
2. Click **Actions** → **Create snapshot**
3. Configure:
   - **Name**: `rhoim-vllm-bootc-$(date +%Y%m%d)`
   - **Description**: "RHOIM vLLM Bootc Image"
4. Click **Create snapshot**
5. Wait for snapshot status to be **completed** (may take a few minutes)

### Step 7: Create AMI from Snapshot

1. Go to **Snapshots** (left sidebar)
2. Select your snapshot
3. Click **Actions** → **Create image from snapshot**
4. Configure:
   - **Image name**: `rhoim-vllm-bootc-YYYYMMDD`
   - **Image description**: "RHOIM vLLM Bootc Image"
   - **Virtualization type**: Hardware-assisted virtualization
   - **Architecture**: x86_64
   - **Root device name**: `/dev/sda1`
   - **Volume type**: gp3
   - **Size**: 20 GiB (or match your volume size)
5. Click **Create image**
6. Wait for AMI status to be **available** (may take 5-10 minutes)

### Step 8: Launch Instance from AMI

1. Go to **AMIs** (left sidebar) → **Owned by me**
2. Select your AMI
3. Click **Launch instance from AMI**
4. Configure instance as needed
5. Launch the instance

## Method 2: Using AWS CLI (Automated)

If you prefer to use AWS CLI, you'll need to configure credentials on the VM first.

### Configure AWS CLI on VM

```bash
# On builder VM
aws configure
# Enter your Access Key ID, Secret Access Key, Region (us-east-1), and output format (json)
```

### Automated Script

```bash
#!/bin/bash
set -e

# Get instance metadata
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
REGION=${AZ%?}

echo "Instance ID: $INSTANCE_ID"
echo "Region: $REGION"
echo "Availability Zone: $AZ"

# Step 1: Create EBS volume
echo "Creating EBS volume..."
VOLUME_ID=$(aws ec2 create-volume \
  --region $REGION \
  --availability-zone $AZ \
  --size 20 \
  --volume-type gp3 \
  --query 'VolumeId' --output text)

echo "Volume ID: $VOLUME_ID"
echo $VOLUME_ID > /tmp/volume-id.txt

# Wait for volume to be available
aws ec2 wait volume-available --volume-ids $VOLUME_ID --region $REGION

# Step 2: Attach volume
echo "Attaching volume..."
aws ec2 attach-volume \
  --region $REGION \
  --volume-id $VOLUME_ID \
  --instance-id $INSTANCE_ID \
  --device /dev/sdf

# Wait for attachment
sleep 10

# Step 3: Find device (usually /dev/nvme1n1 on newer instances)
echo "Finding attached device..."
sleep 5
DEVICE=$(lsblk -rno NAME,TYPE | grep -E '^nvme[0-9]+n1$' | grep -v nvme0n1 | head -1)
if [ -z "$DEVICE" ]; then
  DEVICE=$(lsblk -rno NAME,TYPE | grep -E '^xvdf$' | head -1)
fi

if [ -z "$DEVICE" ]; then
  echo "Error: Could not find attached device"
  lsblk
  exit 1
fi

DEVICE_PATH="/dev/$DEVICE"
echo "Using device: $DEVICE_PATH"

# Step 4: Install bootc image
echo "Installing bootc image to $DEVICE_PATH..."
sudo bootc install \
  --root-fs-type ext4 \
  --karg console=ttyS0,115200n8 \
  --karg root=LABEL=root \
  localhost/rhoim-vllm-bootc:latest \
  $DEVICE_PATH

# Verify
sudo partprobe $DEVICE_PATH
sudo lsblk -f $DEVICE_PATH

# Step 5: Detach volume
echo "Detaching volume..."
aws ec2 detach-volume \
  --region $REGION \
  --volume-id $VOLUME_ID

aws ec2 wait volume-available --volume-ids $VOLUME_ID --region $REGION

# Step 6: Create snapshot
echo "Creating snapshot..."
SNAPSHOT_ID=$(aws ec2 create-snapshot \
  --region $REGION \
  --volume-id $VOLUME_ID \
  --description "RHOIM vLLM Bootc Image $(date +%Y%m%d)" \
  --query 'SnapshotId' --output text)

echo "Snapshot ID: $SNAPSHOT_ID"
echo $SNAPSHOT_ID > /tmp/snapshot-id.txt

# Wait for snapshot to complete
echo "Waiting for snapshot to complete (this may take several minutes)..."
aws ec2 wait snapshot-completed \
  --region $REGION \
  --snapshot-ids $SNAPSHOT_ID

# Step 7: Create AMI
echo "Creating AMI..."
AMI_ID=$(aws ec2 register-image \
  --region $REGION \
  --name "rhoim-vllm-bootc-$(date +%Y%m%d)" \
  --root-device-name /dev/sda1 \
  --virtualization-type hvm \
  --architecture x86_64 \
  --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"SnapshotId\":\"$SNAPSHOT_ID\",\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
  --query 'ImageId' --output text)

echo "AMI created: $AMI_ID"
echo $AMI_ID > /tmp/ami-id.txt

echo ""
echo "=== Summary ==="
echo "Volume ID: $VOLUME_ID"
echo "Snapshot ID: $SNAPSHOT_ID"
echo "AMI ID: $AMI_ID"
echo ""
echo "You can now launch an instance using:"
echo "  aws ec2 run-instances --image-id $AMI_ID --instance-type g4dn.xlarge --key-name your-key-pair"
```

## Troubleshooting

### Device Not Found After Attachment

- Wait a few more seconds: `sleep 10`
- Check with: `lsblk`
- On newer instances, device appears as `/dev/nvme1n1` even if attached as `/dev/sdf`

### Bootc Install Fails

- Ensure device is not mounted: `sudo umount /dev/nvme1n1*` (if mounted)
- Check device is writable: `sudo test -w /dev/nvme1n1 && echo "writable" || echo "not writable"`
- Verify container image exists: `sudo podman images localhost/rhoim-vllm-bootc:latest`

### AMI Creation Fails

- Ensure snapshot is in "completed" state
- Check snapshot size matches volume size
- Verify root device name matches partition layout

### Instance Doesn't Boot from AMI

- Check EC2 console logs for boot errors
- Verify UEFI boot support is enabled
- Ensure instance type supports the image architecture (x86_64)
