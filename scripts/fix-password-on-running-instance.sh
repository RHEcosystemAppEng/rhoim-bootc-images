#!/bin/bash
# Fix password on a running EC2 instance by attaching its volume to builder
# Usage: ./fix-password-on-running-instance.sh <instance-id> [password]

set -euo pipefail

INSTANCE_ID="${1:-}"
PASSWORD="${2:-rhoim-test@123}"

if [ -z "$INSTANCE_ID" ]; then
    echo "Usage: $0 <instance-id> [password]"
    echo "Example: $0 i-0dd21168b3514b8a4 rhoim-test@123"
    exit 1
fi

REGION="${REGION:-us-east-1}"
AZ="${AZ:-us-east-1d}"

echo "=== Fixing Password on Running Instance ==="
echo "Instance ID: $INSTANCE_ID"
echo "Password: $PASSWORD"
echo ""

# Get the root volume ID
echo "=== Step 1: Getting Root Volume ID ==="
ROOT_VOLUME=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[?DeviceName==`/dev/sda1`].Ebs.VolumeId' \
    --output text 2>/dev/null || \
    aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' \
    --output text)

if [ -z "$ROOT_VOLUME" ] || [ "$ROOT_VOLUME" = "None" ]; then
    echo "❌ Could not find root volume"
    exit 1
fi

echo "Root Volume ID: $ROOT_VOLUME"

# Stop the instance
echo ""
echo "=== Step 2: Stopping Instance ==="
echo "Stopping instance (this may take a few minutes)..."
aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$INSTANCE_ID"
echo "✅ Instance stopped"

# Detach volume
echo ""
echo "=== Step 3: Detaching Volume ==="
aws ec2 detach-volume --region "$REGION" --volume-id "$ROOT_VOLUME"
aws ec2 wait volume-available --region "$REGION" --volume-ids "$ROOT_VOLUME"
echo "✅ Volume detached"

# Get builder instance ID (from tag or environment)
BUILDER_INSTANCE=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters 'Name=tag:Name,Values=rhoim-bootc-builder*' 'Name=instance-state-name,Values=running' \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || echo "")

if [ -z "$BUILDER_INSTANCE" ] || [ "$BUILDER_INSTANCE" = "None" ]; then
    echo "❌ Could not find builder instance"
    echo "Please provide builder instance ID manually:"
    read -p "Builder instance ID: " BUILDER_INSTANCE
fi

echo "Builder Instance: $BUILDER_INSTANCE"

# Attach volume to builder
echo ""
echo "=== Step 4: Attaching Volume to Builder ==="
DEVICE_NAME="/dev/xvdf"
aws ec2 attach-volume \
    --region "$REGION" \
    --volume-id "$ROOT_VOLUME" \
    --instance-id "$BUILDER_INSTANCE" \
    --device "$DEVICE_NAME"

# Wait for attachment
sleep 5
aws ec2 wait volume-in-use --region "$REGION" --volume-ids "$ROOT_VOLUME"
echo "✅ Volume attached to builder"

# Find the actual device (might be nvme)
echo ""
echo "=== Step 5: Finding Device ==="
echo "Waiting for device to be available..."
sleep 3

# SSH to builder and fix password
echo ""
echo "=== Step 6: Fixing Password (SSH to Builder) ==="
echo "You need to SSH to the builder instance and run:"
echo ""
echo "  # Find the device"
echo "  lsblk | grep -v loop"
echo ""
echo "  # Find root partition (usually largest)"
echo "  ROOT_PART=\$(lsblk -rno NAME,TYPE,SIZE | grep part | sort -k3 -h | tail -1 | awk '{print \"/dev/\"\$1}')"
echo ""
echo "  # Run password injection"
echo "  cd rhoim-bootc-images/scripts"
echo "  git pull"
echo "  sudo ./inject-root-password.sh \$ROOT_PART '$PASSWORD'"
echo ""
echo "  # Detach volume"
echo "  sudo umount /mnt/bootc-root-* 2>/dev/null || true"
echo "  aws ec2 detach-volume --region $REGION --volume-id $ROOT_VOLUME"
echo "  aws ec2 wait volume-available --region $REGION --volume-ids $ROOT_VOLUME"
echo ""
echo "Then come back here and we'll reattach to the instance."

read -p "Press Enter when password is fixed on builder..."

# Reattach to original instance
echo ""
echo "=== Step 7: Reattaching Volume to Original Instance ==="
ORIGINAL_DEVICE=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].RootDeviceName' \
    --output text)

aws ec2 attach-volume \
    --region "$REGION" \
    --volume-id "$ROOT_VOLUME" \
    --instance-id "$INSTANCE_ID" \
    --device "$ORIGINAL_DEVICE"

aws ec2 wait volume-in-use --region "$REGION" --volume-ids "$ROOT_VOLUME"
echo "✅ Volume reattached"

# Start instance
echo ""
echo "=== Step 8: Starting Instance ==="
aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
echo "✅ Instance started"

# Get new public IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

echo ""
echo "=== Done ==="
echo "Instance: $INSTANCE_ID"
echo "Public IP: $PUBLIC_IP"
echo "Password: $PASSWORD"
echo ""
echo "Try SSH: ssh root@$PUBLIC_IP"
echo "Or use: ./scripts/ssh-to-instance.sh $INSTANCE_ID"
