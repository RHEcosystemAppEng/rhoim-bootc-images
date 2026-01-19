#!/bin/bash
# Script to cleanup AWS resources created during bootc AMI testing
# This script deletes instances, AMIs, snapshots, and volumes
#
# Usage: ./cleanup-aws-resources.sh [region] [--force] [--instance-id ID] [--ami-id ID] [--snapshot-id ID] [--volume-id ID]
#
# Examples:
#   # Auto-discover resources by tags (recommended)
#   ./cleanup-aws-resources.sh us-east-1
#
#   # Auto-discover + specific IDs from README
#   ./cleanup-aws-resources.sh us-east-1 --instance-id i-0cf733bcc00bdad59 --ami-id ami-09d7086a3c731421a
#
#   # Skip confirmation prompts
#   ./cleanup-aws-resources.sh us-east-1 --force
#
# Discovery Methods:
#   1. Resources tagged with ManagedBy=create-bootc-ami-script (automatic)
#   2. Specific IDs passed via command-line arguments
#   3. Hardcoded IDs from README (if present in script)
#
# Safety: By default, this script will prompt for confirmation before deleting resources

set -euo pipefail

REGION=${1:-us-east-1}
FORCE=""
INSTANCE_IDS_ARG=()
AMI_IDS_ARG=()
SNAPSHOT_IDS_ARG=()
VOLUME_IDS_ARG=()

# Parse arguments
shift || true
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE="--force"
            shift
            ;;
        --instance-id)
            INSTANCE_IDS_ARG+=("$2")
            shift 2
            ;;
        --ami-id)
            AMI_IDS_ARG+=("$2")
            shift 2
            ;;
        --snapshot-id)
            SNAPSHOT_IDS_ARG+=("$2")
            shift 2
            ;;
        --volume-id)
            VOLUME_IDS_ARG+=("$2")
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [region] [--force] [--instance-id ID] [--ami-id ID] [--snapshot-id ID] [--volume-id ID]"
            exit 1
            ;;
    esac
done

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== AWS Resource Cleanup Script ==="
echo "Region: $REGION"
echo ""
echo "Discovery methods:"
if [ ${#INSTANCE_IDS_ARG[@]} -gt 0 ] || [ ${#AMI_IDS_ARG[@]} -gt 0 ] || \
   [ ${#SNAPSHOT_IDS_ARG[@]} -gt 0 ] || [ ${#VOLUME_IDS_ARG[@]} -gt 0 ]; then
    echo "  ✓ Command-line arguments provided"
fi
echo "  ✓ Tag-based discovery (ManagedBy=create-bootc-ami-script)"
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

# Function to delete instance
delete_instance() {
    local INSTANCE_ID=$1
    echo -e "${YELLOW}Terminating instance: $INSTANCE_ID${NC}"
    if confirm_delete; then
        aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" > /dev/null
        echo "Waiting for instance to terminate..."
        aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"
        echo -e "${GREEN}✅ Instance terminated: $INSTANCE_ID${NC}"
    else
        echo -e "${YELLOW}⏭️  Skipped instance: $INSTANCE_ID${NC}"
    fi
}

# Function to delete AMI
delete_ami() {
    local AMI_ID=$1
    echo -e "${YELLOW}Deregistering AMI: $AMI_ID${NC}"
    
    # Get snapshot ID from AMI
    SNAPSHOT_ID=$(aws ec2 describe-images --region "$REGION" --image-ids "$AMI_ID" \
        --query 'Images[0].BlockDeviceMappings[0].Ebs.SnapshotId' --output text 2>/dev/null || echo "")
    
    if confirm_delete; then
        # Deregister AMI
        aws ec2 deregister-image --region "$REGION" --image-id "$AMI_ID" > /dev/null
        echo -e "${GREEN}✅ AMI deregistered: $AMI_ID${NC}"
        
        # Delete associated snapshot if it exists
        if [ -n "$SNAPSHOT_ID" ] && [ "$SNAPSHOT_ID" != "None" ]; then
            echo -e "${YELLOW}Deleting snapshot: $SNAPSHOT_ID${NC}"
            if confirm_delete; then
                aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$SNAPSHOT_ID" > /dev/null
                echo -e "${GREEN}✅ Snapshot deleted: $SNAPSHOT_ID${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}⏭️  Skipped AMI: $AMI_ID${NC}"
    fi
}

# Function to delete snapshot
delete_snapshot() {
    local SNAPSHOT_ID=$1
    echo -e "${YELLOW}Deleting snapshot: $SNAPSHOT_ID${NC}"
    if confirm_delete; then
        aws ec2 delete-snapshot --region "$REGION" --snapshot-id "$SNAPSHOT_ID" > /dev/null
        echo -e "${GREEN}✅ Snapshot deleted: $SNAPSHOT_ID${NC}"
    else
        echo -e "${YELLOW}⏭️  Skipped snapshot: $SNAPSHOT_ID${NC}"
    fi
}

# Function to delete volume
delete_volume() {
    local VOLUME_ID=$1
    echo -e "${YELLOW}Deleting volume: $VOLUME_ID${NC}"
    
    # Check if volume is attached
    ATTACHMENT_STATE=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$VOLUME_ID" \
        --query 'Volumes[0].Attachments[0].State' --output text 2>/dev/null || echo "detached")
    
    if [ "$ATTACHMENT_STATE" != "None" ] && [ "$ATTACHMENT_STATE" != "detached" ]; then
        echo -e "${RED}⚠️  Volume is attached. Detaching first...${NC}"
        INSTANCE_ID=$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$VOLUME_ID" \
            --query 'Volumes[0].Attachments[0].InstanceId' --output text)
        aws ec2 detach-volume --region "$REGION" --volume-id "$VOLUME_ID" > /dev/null
        aws ec2 wait volume-available --region "$REGION" --volume-ids "$VOLUME_ID"
    fi
    
    if confirm_delete; then
        aws ec2 delete-volume --region "$REGION" --volume-id "$VOLUME_ID" > /dev/null
        echo -e "${GREEN}✅ Volume deleted: $VOLUME_ID${NC}"
    else
        echo -e "${YELLOW}⏭️  Skipped volume: $VOLUME_ID${NC}"
    fi
}

# Parse resources from multiple sources
echo "=== Finding Resources to Cleanup ==="

# Start with command-line arguments (highest priority)
INSTANCE_IDS=("${INSTANCE_IDS_ARG[@]}")
AMI_IDS=("${AMI_IDS_ARG[@]}")
SNAPSHOT_IDS=("${SNAPSHOT_IDS_ARG[@]}")
VOLUME_IDS=("${VOLUME_IDS_ARG[@]}")

# Add hardcoded IDs from README (if you want to keep them)
# These are the IDs that were in the README at the time of script creation
# You can remove this section if you prefer tag-based discovery only
if [ ${#INSTANCE_IDS[@]} -eq 0 ] && [ ${#AMI_IDS[@]} -eq 0 ] && \
   [ ${#SNAPSHOT_IDS[@]} -eq 0 ] && [ ${#VOLUME_IDS[@]} -eq 0 ]; then
    echo "No specific IDs provided, using tag-based discovery..."
    # Uncomment below if you want to include hardcoded IDs as fallback:
    # INSTANCE_IDS=("i-0cf733bcc00bdad59")
    # AMI_IDS=("ami-09d7086a3c731421a" "ami-07a72249ce1edfd14")
    # SNAPSHOT_IDS=("snap-072a32f78e3da88fd")
    # VOLUME_IDS=("vol-025cf0c2df8922452")
fi

# Find resources tagged by the create-bootc-ami script (automatic discovery)
echo "Finding resources tagged by create-bootc-ami-script..."
TAGGED_INSTANCES=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:ManagedBy,Values=create-bootc-ami-script" "Name=instance-state-name,Values=running,stopped,stopping" \
    --query 'Reservations[*].Instances[*].InstanceId' --output text 2>/dev/null || echo "")

TAGGED_AMIS=$(aws ec2 describe-images --region "$REGION" \
    --filters "Name=tag:ManagedBy,Values=create-bootc-ami-script" \
    --query 'Images[*].ImageId' --output text 2>/dev/null || echo "")

TAGGED_SNAPSHOTS=$(aws ec2 describe-snapshots --region "$REGION" \
    --filters "Name=tag:ManagedBy,Values=create-bootc-ami-script" \
    --query 'Snapshots[*].SnapshotId' --output text 2>/dev/null || echo "")

TAGGED_VOLUMES=$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=tag:ManagedBy,Values=create-bootc-ami-script" \
    --query 'Volumes[*].VolumeId' --output text 2>/dev/null || echo "")

# Combine arrays
if [ -n "$TAGGED_INSTANCES" ]; then
    INSTANCE_IDS+=($TAGGED_INSTANCES)
fi
if [ -n "$TAGGED_AMIS" ]; then
    AMI_IDS+=($TAGGED_AMIS)
fi
if [ -n "$TAGGED_SNAPSHOTS" ]; then
    SNAPSHOT_IDS+=($TAGGED_SNAPSHOTS)
fi
if [ -n "$TAGGED_VOLUMES" ]; then
    VOLUME_IDS+=($TAGGED_VOLUMES)
fi

# Remove duplicates
INSTANCE_IDS=($(printf '%s\n' "${INSTANCE_IDS[@]}" | sort -u))
AMI_IDS=($(printf '%s\n' "${AMI_IDS[@]}" | sort -u))
SNAPSHOT_IDS=($(printf '%s\n' "${SNAPSHOT_IDS[@]}" | sort -u))
VOLUME_IDS=($(printf '%s\n' "${VOLUME_IDS[@]}" | sort -u))

# Verify resources exist
EXISTING_INSTANCES=()
EXISTING_AMIS=()
EXISTING_SNAPSHOTS=()
EXISTING_VOLUMES=()

for INSTANCE_ID in "${INSTANCE_IDS[@]}"; do
    if aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" > /dev/null 2>&1; then
        EXISTING_INSTANCES+=("$INSTANCE_ID")
    fi
done

for AMI_ID in "${AMI_IDS[@]}"; do
    if aws ec2 describe-images --region "$REGION" --image-ids "$AMI_ID" > /dev/null 2>&1; then
        EXISTING_AMIS+=("$AMI_ID")
    fi
done

for SNAPSHOT_ID in "${SNAPSHOT_IDS[@]}"; do
    if aws ec2 describe-snapshots --region "$REGION" --snapshot-ids "$SNAPSHOT_ID" > /dev/null 2>&1; then
        EXISTING_SNAPSHOTS+=("$SNAPSHOT_ID")
    fi
done

for VOLUME_ID in "${VOLUME_IDS[@]}"; do
    if aws ec2 describe-volumes --region "$REGION" --volume-ids "$VOLUME_ID" > /dev/null 2>&1; then
        EXISTING_VOLUMES+=("$VOLUME_ID")
    fi
done

# Summary
echo ""
echo "=== Resources Found ==="
if [ ${#EXISTING_INSTANCES[@]} -gt 0 ]; then
    echo "Instances (${#EXISTING_INSTANCES[@]}): ${EXISTING_INSTANCES[*]}"
fi
if [ ${#EXISTING_AMIS[@]} -gt 0 ]; then
    echo "AMIs (${#EXISTING_AMIS[@]}): ${EXISTING_AMIS[*]}"
fi
if [ ${#EXISTING_SNAPSHOTS[@]} -gt 0 ]; then
    echo "Snapshots (${#EXISTING_SNAPSHOTS[@]}): ${EXISTING_SNAPSHOTS[*]}"
fi
if [ ${#EXISTING_VOLUMES[@]} -gt 0 ]; then
    echo "Volumes (${#EXISTING_VOLUMES[@]}): ${EXISTING_VOLUMES[*]}"
fi
echo ""

if [ ${#EXISTING_INSTANCES[@]} -eq 0 ] && [ ${#EXISTING_AMIS[@]} -eq 0 ] && \
   [ ${#EXISTING_SNAPSHOTS[@]} -eq 0 ] && [ ${#EXISTING_VOLUMES[@]} -eq 0 ]; then
    echo -e "${GREEN}✅ No resources found to cleanup${NC}"
    exit 0
fi

# Delete resources
echo "=== Deleting Resources ==="
echo ""

# Delete instances first
for INSTANCE_ID in "${EXISTING_INSTANCES[@]}"; do
    delete_instance "$INSTANCE_ID"
    echo ""
done

# Delete AMIs (this will also handle associated snapshots)
for AMI_ID in "${EXISTING_AMIS[@]}"; do
    delete_ami "$AMI_ID"
    echo ""
done

# Delete remaining snapshots
for SNAPSHOT_ID in "${EXISTING_SNAPSHOTS[@]}"; do
    # Check if snapshot still exists (might have been deleted with AMI)
    if aws ec2 describe-snapshots --region "$REGION" --snapshot-ids "$SNAPSHOT_ID" > /dev/null 2>&1; then
        delete_snapshot "$SNAPSHOT_ID"
        echo ""
    fi
done

# Delete volumes
for VOLUME_ID in "${EXISTING_VOLUMES[@]}"; do
    # Check if volume still exists
    if aws ec2 describe-volumes --region "$REGION" --volume-ids "$VOLUME_ID" > /dev/null 2>&1; then
        delete_volume "$VOLUME_ID"
        echo ""
    fi
done

echo "=== Cleanup Complete ==="
echo -e "${GREEN}✅ All resources have been processed${NC}"
