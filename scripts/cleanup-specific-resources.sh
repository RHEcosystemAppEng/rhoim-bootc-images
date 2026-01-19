#!/bin/bash
# Manual cleanup script for specific AWS resources
# This script deletes ONLY the resources listed in the README
# No tag-based discovery - only explicit IDs
#
# Usage: ./cleanup-specific-resources.sh [region] [--force]
#
# Example:
#   ./cleanup-specific-resources.sh us-east-1
#   ./cleanup-specific-resources.sh us-east-1 --force  # Skip confirmations

set -euo pipefail

REGION=${1:-us-east-1}
FORCE=${2:-}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== Manual AWS Resource Cleanup (Specific IDs Only) ==="
echo "Region: $REGION"
echo ""
echo "This script will delete ONLY these specific resources:"
echo "  Instance: i-0cf733bcc00bdad59"
echo "  AMIs: ami-09d7086a3c731421a, ami-07a72249ce1edfd14"
echo "  Snapshot: snap-072a32f78e3da88fd"
echo "  Volume: vol-025cf0c2df8922452"
echo ""

# Check prerequisites
if ! command -v aws &> /dev/null; then
    echo -e "${RED}Error: AWS CLI not found${NC}"
    exit 1
fi

# Function to confirm deletion
confirm_delete() {
    if [ "$FORCE" = "--force" ]; then
        return 0
    fi
    read -p "Are you sure you want to delete this resource? (yes/no): " -r
    if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        return 0
    else
        return 1
    fi
}

# Specific resource IDs from README
INSTANCE_ID="i-0cf733bcc00bdad59"
AMI_IDS=("ami-09d7086a3c731421a" "ami-07a72249ce1edfd14")
SNAPSHOT_ID="snap-072a32f78e3da88fd"
VOLUME_ID="vol-025cf0c2df8922452"

# Verify resources exist before deletion
echo "=== Verifying Resources Exist ==="
RESOURCES_FOUND=0

if aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" > /dev/null 2>&1; then
    STATE=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' --output text)
    echo -e "${GREEN}✓ Instance found: $INSTANCE_ID (state: $STATE)${NC}"
    RESOURCES_FOUND=1
else
    echo -e "${YELLOW}⚠ Instance not found: $INSTANCE_ID${NC}"
fi

for AMI_ID in "${AMI_IDS[@]}"; do
    if aws ec2 describe-images --region "$REGION" --image-ids "$AMI_ID" > /dev/null 2>&1; then
        NAME=$(aws ec2 describe-images --region "$REGION" --image-ids "$AMI_ID" \
            --query 'Images[0].Name' --output text)
        echo -e "${GREEN}✓ AMI found: $AMI_ID (name: $NAME)${NC}"
        RESOURCES_FOUND=1
    else
        echo -e "${YELLOW}⚠ AMI not found: $AMI_ID${NC}"
    fi
done

if aws ec2 describe-snapshots --region "$REGION" --snapshot-ids "$SNAPSHOT_ID" > /dev/null 2>&1; then
    SIZE=$(aws ec2 describe-snapshots --region "$REGION" --snapshot-ids "$SNAPSHOT_ID" \
        --query 'Snapshots[0].VolumeSize' --output text)
    echo -e "${GREEN}✓ Snapshot found: $SNAPSHOT_ID (size: ${SIZE}GB)${NC}"
    RESOURCES_FOUND=1
else
    echo -e "${YELLOW}⚠ Snapshot not found: $SNAPSHOT_ID${NC}"
fi

if aws ec2 describe-volumes --region "$REGION" --volume-ids "$VOLUME_ID" > /dev/null 2>&1; then
    STATE=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$VOLUME_ID" \
        --query 'Volumes[0].State' --output text)
    echo -e "${GREEN}✓ Volume found: $VOLUME_ID (state: $STATE)${NC}"
    RESOURCES_FOUND=1
else
    echo -e "${YELLOW}⚠ Volume not found: $VOLUME_ID${NC}"
fi

echo ""

if [ $RESOURCES_FOUND -eq 0 ]; then
    echo -e "${GREEN}✅ No resources found to cleanup${NC}"
    exit 0
fi

# Delete resources in correct order
echo "=== Deleting Resources ==="
echo ""

# 1. Terminate instance first
if aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" > /dev/null 2>&1; then
    STATE=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' --output text)
    
    if [ "$STATE" != "terminated" ]; then
        echo -e "${YELLOW}Terminating instance: $INSTANCE_ID${NC}"
        if confirm_delete; then
            aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" > /dev/null
            echo "Waiting for instance to terminate..."
            aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"
            echo -e "${GREEN}✅ Instance terminated: $INSTANCE_ID${NC}"
        else
            echo -e "${YELLOW}⏭️  Skipped instance: $INSTANCE_ID${NC}"
        fi
    else
        echo -e "${GREEN}✓ Instance already terminated: $INSTANCE_ID${NC}"
    fi
    echo ""
fi

# 2. Deregister AMIs (this doesn't delete snapshots)
for AMI_ID in "${AMI_IDS[@]}"; do
    if aws ec2 describe-images --region "$REGION" --image-ids "$AMI_ID" > /dev/null 2>&1; then
        echo -e "${YELLOW}Deregistering AMI: $AMI_ID${NC}"
        
        # Get snapshot ID from AMI before deregistering
        SNAPSHOT_FROM_AMI=$(aws ec2 describe-images --region "$REGION" --image-ids "$AMI_ID" \
            --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text 2>/dev/null || echo "")
        
        if confirm_delete; then
            aws ec2 deregister-image --region "$REGION" --image-id "$AMI_ID" > /dev/null
            echo -e "${GREEN}✅ AMI deregistered: $AMI_ID${NC}"
            
            # Note: We'll delete the snapshot separately below
            if [ -n "$SNAPSHOT_FROM_AMI" ] && [ "$SNAPSHOT_FROM_AMI" != "None" ]; then
                echo "  (Associated snapshot: $SNAPSHOT_FROM_AMI - will be deleted separately)"
            fi
        else
            echo -e "${YELLOW}⏭️  Skipped AMI: $AMI_ID${NC}"
        fi
        echo ""
    fi
done

# 3. Delete snapshot
if aws ec2 describe-snapshots --region "$REGION" --snapshot-ids "$SNAPSHOT_ID" > /dev/null 2>&1; then
    echo -e "${YELLOW}Deleting snapshot: $SNAPSHOT_ID${NC}"
    if confirm_delete; then
        aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$SNAPSHOT_ID" > /dev/null
        echo -e "${GREEN}✅ Snapshot deleted: $SNAPSHOT_ID${NC}"
    else
        echo -e "${YELLOW}⏭️  Skipped snapshot: $SNAPSHOT_ID${NC}"
    fi
    echo ""
fi

# 4. Delete volume (must be detached first)
if aws ec2 describe-volumes --region "$REGION" --volume-ids "$VOLUME_ID" > /dev/null 2>&1; then
    ATTACHMENT_STATE=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$VOLUME_ID" \
        --query 'Volumes[0].Attachments[0].State' --output text 2>/dev/null || echo "detached")
    
    if [ "$ATTACHMENT_STATE" != "None" ] && [ "$ATTACHMENT_STATE" != "detached" ]; then
        echo -e "${YELLOW}Volume is attached. Detaching first...${NC}"
        INSTANCE_ATTACHED=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$VOLUME_ID" \
            --query 'Volumes[0].Attachments[0].InstanceId' --output text)
        aws ec2 detach-volume --region "$REGION" --volume-id "$VOLUME_ID" > /dev/null
        aws ec2 wait volume-available --region "$REGION" --volume-ids "$VOLUME_ID"
        echo -e "${GREEN}✓ Volume detached from $INSTANCE_ATTACHED${NC}"
    fi
    
    echo -e "${YELLOW}Deleting volume: $VOLUME_ID${NC}"
    if confirm_delete; then
        aws ec2 delete-volume --region "$REGION" --volume-id "$VOLUME_ID" > /dev/null
        echo -e "${GREEN}✅ Volume deleted: $VOLUME_ID${NC}"
    else
        echo -e "${YELLOW}⏭️  Skipped volume: $VOLUME_ID${NC}"
    fi
    echo ""
fi

echo "=== Cleanup Complete ==="
echo -e "${GREEN}✅ All specified resources have been processed${NC}"
