#!/bin/bash
# Script to SSH into a test instance with multiple methods
# Usage: ./ssh-to-instance.sh [instance-id]

set -euo pipefail

INSTANCE_ID="${1:-}"

if [ -z "$INSTANCE_ID" ]; then
    echo "=== Finding Test Instance ==="
    INSTANCE_ID=$(aws ec2 describe-instances \
        --region us-east-1 \
        --filters 'Name=tag:Name,Values=rhoim-bootc-test*' 'Name=instance-state-name,Values=running' \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text 2>/dev/null || echo "")
    
    if [ -z "$INSTANCE_ID" ] || [ "$INSTANCE_ID" = "None" ]; then
        echo "❌ No running test instance found"
        echo "Usage: $0 <instance-id>"
        exit 1
    fi
fi

echo "Instance ID: $INSTANCE_ID"

# Get public IP
PUBLIC_IP=$(aws ec2 describe-instances \
    --region us-east-1 \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

if [ -z "$PUBLIC_IP" ] || [ "$PUBLIC_IP" = "None" ]; then
    echo "❌ No public IP found for instance"
    exit 1
fi

echo "Public IP: $PUBLIC_IP"
echo ""

# Try SSH with key-based authentication
echo "=== Attempting SSH with Key-Based Authentication ==="
echo ""

# Check if SSH key exists
SSH_KEY="${HOME}/.ssh/id_rsa"
if [ ! -f "$SSH_KEY" ]; then
    SSH_KEY="${HOME}/.ssh/id_ed25519"
fi

if [ -f "$SSH_KEY" ]; then
    echo "Using SSH key: $SSH_KEY"
    ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        root@"$PUBLIC_IP" 'echo "✅ SSH SUCCESS!" && hostname && whoami' || {
        echo "❌ SSH with key failed"
        echo ""
        echo "=== Alternative: Use EC2 Instance Connect ==="
        echo "Run: aws ec2-instance-connect send-ssh-public-key \\"
        echo "  --region us-east-1 \\"
        echo "  --instance-id $INSTANCE_ID \\"
        echo "  --availability-zone us-east-1d \\"
        echo "  --instance-os-user root \\"
        echo "  --ssh-public-key file://${HOME}/.ssh/id_rsa.pub"
        echo ""
        echo "Then SSH: ssh -i $SSH_KEY root@$PUBLIC_IP"
        echo ""
        echo "=== Or use AWS SSM Session Manager ==="
        echo "Run: aws ssm start-session --target $INSTANCE_ID --region us-east-1"
    }
else
    echo "❌ No SSH key found at ~/.ssh/id_rsa or ~/.ssh/id_ed25519"
    echo ""
    echo "=== Use EC2 Instance Connect ==="
    echo "Run: aws ec2-instance-connect send-ssh-public-key \\"
    echo "  --region us-east-1 \\"
    echo "  --instance-id $INSTANCE_ID \\"
    echo "  --availability-zone us-east-1d \\"
    echo "  --instance-os-user root \\"
    echo "  --ssh-public-key file://${HOME}/.ssh/id_rsa.pub"
    echo ""
    echo "=== Or use AWS SSM Session Manager (Recommended) ==="
    echo "Run: aws ssm start-session --target $INSTANCE_ID --region us-east-1"
fi
