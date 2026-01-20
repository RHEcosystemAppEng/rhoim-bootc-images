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

# Try SSH with password
echo "=== Attempting SSH with Password ==="
echo "Password: rhoim-test@123"
echo ""

if command -v sshpass >/dev/null 2>&1; then
    sshpass -p 'rhoim-test@123' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        root@"$PUBLIC_IP" 'echo "✅ SSH SUCCESS!" && hostname && whoami && echo "" && echo "You can now run commands to install the driver:" && echo "  curl -O https://raw.githubusercontent.com/lokeshrangineni/rhoim-bootc-images/feature/run-vllm-gpu-using-podman/scripts/install-nvidia-driver-on-instance.sh" && echo "  chmod +x install-nvidia-driver-on-instance.sh" && echo "  ./install-nvidia-driver-on-instance.sh 570"' || {
        echo "❌ SSH with password failed"
        echo ""
        echo "=== Alternative: Use EC2 Instance Connect ==="
        echo "Run: aws ec2-instance-connect send-ssh-public-key \\"
        echo "  --region us-east-1 \\"
        echo "  --instance-id $INSTANCE_ID \\"
        echo "  --availability-zone us-east-1d \\"
        echo "  --instance-os-user root \\"
        echo "  --ssh-public-key file://~/.ssh/id_rsa.pub"
        echo ""
        echo "Then SSH: ssh -i ~/.ssh/id_rsa root@$PUBLIC_IP"
    }
else
    echo "sshpass not installed. Install it with: brew install hudochenkov/sshpass/sshpass (macOS) or apt-get install sshpass (Linux)"
    echo ""
    echo "Or try manually:"
    echo "  ssh root@$PUBLIC_IP"
    echo "  Password: rhoim-test@123"
fi
