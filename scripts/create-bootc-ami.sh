#!/bin/bash
# Script to create a bootc AMI with all fixes from CLOUD_DEPLOYMENT.md
# This script ensures:
# 1. SSH keys are included in bootc install
# 2. UEFI boot mode is set when creating AMI
# 3. ENA support is enabled
# 4. Registry credentials are injected with correct format
# 5. Volume size is 50GB minimum
# 6. All resources (Volume, Snapshot, AMI) are tagged for easy cleanup
#
# Usage: ./create-bootc-ami.sh [region] [availability-zone] [org-id] [username] [token]
#
# Example:
#   ./create-bootc-ami.sh us-east-1 us-east-1a your-org-id your-username your-token
#
# Resource Tags:
#   All resources are tagged with:
#   - Name: Descriptive name with timestamp
#   - Project: rhoim-bootc
#   - ManagedBy: create-bootc-ami-script
#   - Purpose: bootc-ami-creation
#   - CreatedDate: YYYYMMDD-HHMMSS
#
# Cleanup:
#   To find and delete all resources created by this script:
#   # List resources
#   aws ec2 describe-volumes --region us-east-1 --filters "Name=tag:ManagedBy,Values=create-bootc-ami-script"
#   aws ec2 describe-snapshots --region us-east-1 --filters "Name=tag:ManagedBy,Values=create-bootc-ami-script"
#   aws ec2 describe-images --region us-east-1 --filters "Name=tag:ManagedBy,Values=create-bootc-ami-script"
#
#   # Delete resources (be careful!)
#   aws ec2 deregister-image --region us-east-1 --image-id <AMI-ID>
#   aws ec2 delete-snapshot --region us-east-1 --snapshot-id <SNAPSHOT-ID>
#   aws ec2 delete-volume --region us-east-1 --volume-id <VOLUME-ID>

set -euo pipefail

# Configuration
REGION=${1:-us-east-1}
AZ=${2:-us-east-1a}
ORG_ID=${3:-}
USERNAME=${4:-}
TOKEN=${5:-}
IMAGE_NAME="localhost/rhoim-bootc-nvidia:latest"
VOLUME_SIZE=50  # Minimum 50GB as per CLOUD_DEPLOYMENT.md
TIMESTAMP=$(date +%Y%m%d-%H%M%S)  # Timestamp for resource naming and tagging

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== Bootc AMI Creation Script ==="
echo "This script addresses all issues from CLOUD_DEPLOYMENT.md:"
echo "  ✅ SSH keys included in bootc install"
echo "  ✅ UEFI boot mode set when creating AMI"
echo "  ✅ ENA support enabled"
echo "  ✅ Registry credentials injected with correct format (org_id|username)"
echo "  ✅ Volume size: 50GB minimum"
echo ""

# Check prerequisites
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI not found${NC}"
    exit 1
fi

if ! command -v bootc &> /dev/null; then
    echo -e "${RED}Error: bootc not found${NC}"
    exit 1
fi

# Check if image exists
if ! podman images | grep -q "rhoim-bootc-nvidia.*latest"; then
    echo -e "${RED}Error: Image $IMAGE_NAME not found${NC}"
    echo "Build the image first with: podman build ..."
    exit 1
fi

# Get instance ID
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
if [ -z "$INSTANCE_ID" ]; then
    echo -e "${RED}Error: Could not determine instance ID${NC}"
    exit 1
fi

# Get current availability zone
CURRENT_AZ=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
if [ "$AZ" != "$CURRENT_AZ" ]; then
    echo -e "${YELLOW}Warning: Specified AZ ($AZ) doesn't match current instance AZ ($CURRENT_AZ)${NC}"
    echo "Using current AZ: $CURRENT_AZ"
    AZ=$CURRENT_AZ
fi

# Check SSH key
SSH_KEY_FILE="$HOME/.ssh/authorized_keys"
if [ ! -f "$SSH_KEY_FILE" ]; then
    echo -e "${RED}Error: SSH key file not found: $SSH_KEY_FILE${NC}"
    echo "This is required for --root-ssh-authorized-keys"
    exit 1
fi
echo -e "${GREEN}✅ SSH key found: $SSH_KEY_FILE${NC}"

# Step 1: Create EBS Volume (50GB minimum)
echo ""
echo "=== Step 1: Creating EBS Volume (${VOLUME_SIZE}GB) ==="
VOLUME_NAME="rhoim-bootc-ami-volume-${TIMESTAMP}"

VOLUME_ID=$(aws ec2 create-volume \
    --region "$REGION" \
    --availability-zone "$AZ" \
    --size "$VOLUME_SIZE" \
    --volume-type gp3 \
    --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${VOLUME_NAME}},{Key=Project,Value=rhoim-bootc},{Key=ManagedBy,Value=create-bootc-ami-script},{Key=Purpose,Value=bootc-ami-creation},{Key=CreatedDate,Value=${TIMESTAMP}}]" \
    --query 'VolumeId' --output text)

echo "Volume ID: $VOLUME_ID"
echo "Volume Name: $VOLUME_NAME"
echo "$VOLUME_ID" > /tmp/bootc-volume-id.txt

# Wait for volume to be available
echo "Waiting for volume to be available..."
aws ec2 wait volume-available --volume-ids "$VOLUME_ID" --region "$REGION"
echo -e "${GREEN}✅ Volume created${NC}"

# Step 2: Attach Volume
echo ""
echo "=== Step 2: Attaching Volume to Instance ==="
# Check if /dev/sdf is already in use and detach if needed
EXISTING_VOLUME=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=attachment.instance-id,Values=$INSTANCE_ID" "Name=attachment.device,Values=/dev/sdf" \
    --query 'Volumes[0].VolumeId' --output text 2>/dev/null || echo "")

if [ -n "$EXISTING_VOLUME" ] && [ "$EXISTING_VOLUME" != "None" ]; then
    echo "Detaching existing volume from /dev/sdf: $EXISTING_VOLUME"
    aws ec2 detach-volume --region "$REGION" --volume-id "$EXISTING_VOLUME" > /dev/null 2>&1
    aws ec2 wait volume-available --region "$REGION" --volume-ids "$EXISTING_VOLUME" 2>/dev/null || true
fi

aws ec2 attach-volume \
    --region "$REGION" \
    --volume-id "$VOLUME_ID" \
    --instance-id "$INSTANCE_ID" \
    --device /dev/sdf

echo "Waiting for attachment..."
sleep 10

# Step 3: Find the Attached Device
echo ""
echo "=== Step 3: Finding Attached Device ==="
# Find the largest unpartitioned nvme disk (excluding root device nvme0n1)
# This ensures we get the newly attached volume, not an existing one
DEVICE=$(lsblk -rno NAME,TYPE,SIZE | awk '$2=="disk" && $1~/^nvme[0-9]+n1$/ && $1!="nvme0n1" {print $1, $3}' | sort -k2 -h | tail -1 | awk '{print $1}')
if [ -z "$DEVICE" ]; then
    # Fallback to xvdf for older instance types
    DEVICE=$(lsblk -rno NAME,TYPE | awk '$2=="disk" && $1=="xvdf" {print $1}' | head -1)
fi

if [ -z "$DEVICE" ]; then
    echo -e "${RED}Error: Could not find attached device${NC}"
    echo "Available block devices:"
    lsblk
    exit 1
fi

DEVICE_PATH="/dev/$DEVICE"
echo "Using device: $DEVICE_PATH"
lsblk "$DEVICE_PATH"

# Step 4: Install Bootc Image with SSH Keys
echo ""
echo "=== Step 4: Installing Bootc Image (with SSH keys) ==="
echo "This will install the bootc image to $DEVICE_PATH"
echo "SSH keys from $SSH_KEY_FILE will be included"
echo ""

# Run bootc install from inside the container (required per bootc docs)
# The container must be run with --privileged, --pid=host, and device access to see block devices
sudo podman run --rm --privileged --pid=host \
    --device-cgroup-rule='b *:* rmw' \
    -v /dev:/dev \
    -v "$SSH_KEY_FILE:/tmp/ssh_keys:ro" \
    "$IMAGE_NAME" \
    bootc install to-disk \
    --wipe \
    --filesystem ext4 \
    --karg console=ttyS0,115200n8 \
    --karg root=LABEL=root \
    --root-ssh-authorized-keys /tmp/ssh_keys \
    "$DEVICE_PATH"

echo -e "${GREEN}✅ Bootc image installed${NC}"

# Verify installation
sudo partprobe "$DEVICE_PATH"
echo ""
echo "Partition layout:"
sudo lsblk -f "$DEVICE_PATH"

# Step 5: Inject Registry Credentials (if provided)
if [ -n "$ORG_ID" ] && [ -n "$USERNAME" ] && [ -n "$TOKEN" ]; then
    echo ""
    echo "=== Step 5: Injecting Registry Credentials ==="
    
    # Find root partition (usually the largest partition)
    ROOT_PARTITION=$(lsblk -rno NAME,TYPE,SIZE "$DEVICE_PATH" | grep part | sort -k3 -h | tail -1 | awk '{print "/dev/"$1}')
    echo "Root partition: $ROOT_PARTITION"
    
    # Use the inject script
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$SCRIPT_DIR/inject-registry-credentials.sh" ]; then
        if sudo "$SCRIPT_DIR/inject-registry-credentials.sh" \
            "$ROOT_PARTITION" \
            "$ORG_ID" \
            "$USERNAME" \
            "$TOKEN"; then
            echo -e "${GREEN}✅ Registry credentials injected${NC}"
            
            # Verify credentials were written correctly
            MOUNT_POINT="/mnt/bootc-root"
            if mount "$ROOT_PARTITION" "$MOUNT_POINT" 2>/dev/null; then
                if grep -q "^REDHAT_REGISTRY_USERNAME=" "$MOUNT_POINT/etc/sysconfig/rhoim" 2>/dev/null && \
                   grep -q "^REDHAT_REGISTRY_TOKEN=" "$MOUNT_POINT/etc/sysconfig/rhoim" 2>/dev/null; then
                    echo -e "${GREEN}✅ Credentials verified in /etc/sysconfig/rhoim${NC}"
                else
                    echo -e "${YELLOW}⚠️  Warning: Credentials may not have been written correctly${NC}"
                fi
                umount "$MOUNT_POINT" 2>/dev/null
            fi
        else
            echo -e "${RED}❌ Error: Failed to inject registry credentials${NC}"
            echo "The AMI will be created but registry login will need to be done manually"
        fi
    else
        echo -e "${YELLOW}Warning: inject-registry-credentials.sh not found${NC}"
        echo "You'll need to inject credentials manually or after AMI creation"
    fi
else
    echo ""
    echo "=== Step 5: Skipping Registry Credentials Injection ==="
    echo "No credentials provided. You can inject them later using:"
    echo "  ./scripts/inject-registry-credentials.sh <device> <org-id> <username> <token>"
fi

# Step 6: Detach Volume
echo ""
echo "=== Step 6: Detaching Volume ==="
aws ec2 detach-volume \
    --region "$REGION" \
    --volume-id "$VOLUME_ID"

aws ec2 wait volume-available --volume-ids "$VOLUME_ID" --region "$REGION"
echo -e "${GREEN}✅ Volume detached${NC}"

# Step 7: Create Snapshot
echo ""
echo "=== Step 7: Creating Snapshot ==="
SNAPSHOT_NAME="rhoim-bootc-ami-snapshot-${TIMESTAMP}"
SNAPSHOT_DESCRIPTION="RHOIM vLLM Bootc Image with NVIDIA drivers ${TIMESTAMP}"

SNAPSHOT_ID=$(aws ec2 create-snapshot \
    --region "$REGION" \
    --volume-id "$VOLUME_ID" \
    --description "$SNAPSHOT_DESCRIPTION" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=${SNAPSHOT_NAME}},{Key=Project,Value=rhoim-bootc},{Key=ManagedBy,Value=create-bootc-ami-script},{Key=Purpose,Value=bootc-ami-creation},{Key=CreatedDate,Value=${TIMESTAMP}},{Key=SourceVolume,Value=${VOLUME_ID}}]" \
    --query 'SnapshotId' --output text)

echo "Snapshot ID: $SNAPSHOT_ID"
echo "Snapshot Name: $SNAPSHOT_NAME"
echo "$SNAPSHOT_ID" > /tmp/bootc-snapshot-id.txt

echo "Waiting for snapshot to complete (this may take several minutes)..."
aws ec2 wait snapshot-completed \
    --region "$REGION" \
    --snapshot-ids "$SNAPSHOT_ID"
echo -e "${GREEN}✅ Snapshot created${NC}"

# Step 8: Create AMI with UEFI Boot Mode (CRITICAL)
echo ""
echo "=== Step 8: Creating AMI with UEFI Boot Mode ==="
echo -e "${YELLOW}⚠️  CRITICAL: Setting --boot-mode uefi (required for bootc images)${NC}"

AMI_NAME="rhoim-vllm-bootc-nvidia-${TIMESTAMP}"
AMI_ID=$(aws ec2 register-image \
    --region "$REGION" \
    --name "$AMI_NAME" \
    --root-device-name /dev/sda1 \
    --virtualization-type hvm \
    --architecture x86_64 \
    --boot-mode uefi \
    --block-device-mappings "[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"SnapshotId\":\"$SNAPSHOT_ID\",\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]" \
    --query 'ImageId' --output text)

# Tag the AMI
echo "Tagging AMI..."
aws ec2 create-tags \
    --region "$REGION" \
    --resources "$AMI_ID" \
    --tags \
        Key=Name,Value="$AMI_NAME" \
        Key=Project,Value=rhoim-bootc \
        Key=ManagedBy,Value=create-bootc-ami-script \
        Key=Purpose,Value=bootc-ami-creation \
        Key=CreatedDate,Value="$TIMESTAMP" \
        Key=SourceSnapshot,Value="$SNAPSHOT_ID" \
        Key=SourceVolume,Value="$VOLUME_ID"

echo "AMI ID: $AMI_ID"
echo "AMI Name: $AMI_NAME"
echo "$AMI_ID" > /tmp/bootc-ami-id.txt
echo "$AMI_NAME" > /tmp/bootc-ami-name.txt

# Verify boot mode was set correctly
echo ""
echo "=== Verifying Boot Mode ==="
BOOT_MODE=$(aws ec2 describe-images --region "$REGION" --image-ids "$AMI_ID" --query 'Images[0].BootMode' --output text)
if [ "$BOOT_MODE" != "uefi" ]; then
    echo -e "${RED}❌ ERROR: Boot mode is not UEFI: $BOOT_MODE${NC}"
    echo "This will cause boot failure. The AMI needs to be recreated."
    exit 1
fi
echo -e "${GREEN}✅ Boot mode verified: $BOOT_MODE${NC}"

# Step 9: Enable ENA Support (required for enhanced networking)
echo ""
echo "=== Step 9: Enabling ENA Support ==="
echo "ENA support is required for enhanced networking on certain instance types (e.g., g4dn.xlarge)"
aws ec2 modify-image-attribute \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --ena-support
echo -e "${GREEN}✅ ENA support enabled${NC}"

# Summary
echo ""
echo "=== Summary ==="
echo -e "${GREEN}✅ All steps completed successfully!${NC}"
echo ""
echo "AMI ID: $AMI_ID"
echo "AMI Name: $AMI_NAME"
echo "Boot Mode: $BOOT_MODE"
echo "Volume Size: ${VOLUME_SIZE}GB"
echo "Volume ID: $VOLUME_ID"
echo "Volume Name: $VOLUME_NAME"
echo "Snapshot ID: $SNAPSHOT_ID"
echo "Snapshot Name: $SNAPSHOT_NAME"
echo ""
echo "All resources are tagged for easy cleanup:"
echo "  - Project: rhoim-bootc"
echo "  - ManagedBy: create-bootc-ami-script"
echo "  - Purpose: bootc-ami-creation"
echo "  - CreatedDate: $TIMESTAMP"
echo ""
echo "To find and clean up resources:"
echo "  # List all resources created by this script:"
echo "  aws ec2 describe-volumes --region $REGION --filters \"Name=tag:ManagedBy,Values=create-bootc-ami-script\" --query 'Volumes[*].[VolumeId,Tags[?Key==\`Name\`].Value|[0]]' --output table"
echo "  aws ec2 describe-snapshots --region $REGION --filters \"Name=tag:ManagedBy,Values=create-bootc-ami-script\" --query 'Snapshots[*].[SnapshotId,Tags[?Key==\`Name\`].Value|[0]]' --output table"
echo "  aws ec2 describe-images --region $REGION --filters \"Name=tag:ManagedBy,Values=create-bootc-ami-script\" --query 'Images[*].[ImageId,Name]' --output table"
echo ""
echo "To launch an instance from this AMI:"
echo "  aws ec2 run-instances \\"
echo "    --region $REGION \\"
echo "    --image-id $AMI_ID \\"
echo "    --instance-type g4dn.xlarge \\"
echo "    --key-name your-key-pair \\"
echo "    --security-group-ids sg-xxxxxxxxx \\"
echo "    --subnet-id subnet-xxxxxxxxx"
echo ""
echo "Note: SSH access is configured with keys from $SSH_KEY_FILE"
echo "      Use the same key pair when launching the instance"
