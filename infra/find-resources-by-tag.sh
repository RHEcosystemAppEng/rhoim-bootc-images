#!/bin/bash
# Script to find ALL AWS resources by tag across multiple services
# Usage: ./find-resources-by-tag.sh [region] [tag-key] [tag-value]
# Example: ./find-resources-by-tag.sh us-east-1 ResourcePrefix dev-rhoim-builder
# Example: ./find-resources-by-tag.sh us-east-1 Project rhoim-bootc

REGION=${1:-us-east-1}
TAG_KEY=${2:-ResourcePrefix}
TAG_VALUE=${3:-dev-rhoim-builder}

echo "=== Finding ALL AWS resources with tag ${TAG_KEY}=${TAG_VALUE} in region ${REGION} ==="
echo ""

# EC2 Instances
echo "📦 EC2 Instances:"
aws ec2 describe-instances --region $REGION --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" --query 'Reservations[*].Instances[*].[InstanceId, Tags[?Key==`Name`].Value | [0], State.Name]' --output table 2>/dev/null || echo "  None found"

# Security Groups
echo ""
echo "🔒 Security Groups:"
aws ec2 describe-security-groups --region $REGION --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" --query 'SecurityGroups[*].[GroupId, GroupName, Tags[?Key==`Name`].Value | [0]]' --output table 2>/dev/null || echo "  None found"

# EBS Volumes
echo ""
echo "💾 EBS Volumes:"
aws ec2 describe-volumes --region $REGION --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" --query 'Volumes[*].[VolumeId, Size, Tags[?Key==`Name`].Value | [0], State]' --output table 2>/dev/null || echo "  None found"

# VPCs
echo ""
echo "🌐 VPCs:"
aws ec2 describe-vpcs --region $REGION --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" --query 'Vpcs[*].[VpcId, Tags[?Key==`Name`].Value | [0], CidrBlock]' --output table 2>/dev/null || echo "  None found"

# Subnets
echo ""
echo "🔗 Subnets:"
aws ec2 describe-subnets --region $REGION --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" --query 'Subnets[*].[SubnetId, Tags[?Key==`Name`].Value | [0], CidrBlock]' --output table 2>/dev/null || echo "  None found"

# Internet Gateways
echo ""
echo "🌍 Internet Gateways:"
aws ec2 describe-internet-gateways --region $REGION --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" --query 'InternetGateways[*].[InternetGatewayId, Tags[?Key==`Name`].Value | [0]]' --output table 2>/dev/null || echo "  None found"

# NAT Gateways
echo ""
echo "🔀 NAT Gateways:"
aws ec2 describe-nat-gateways --region $REGION --filter "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" --query 'NatGateways[*].[NatGatewayId, Tags[?Key==`Name`].Value | [0], State]' --output table 2>/dev/null || echo "  None found"

# Elastic IPs
echo ""
echo "📍 Elastic IPs:"
aws ec2 describe-addresses --region $REGION --filters "Name=tag:${TAG_KEY},Values=${TAG_VALUE}" --query 'Addresses[*].[AllocationId, PublicIp, Tags[?Key==`Name`].Value | [0]]' --output table 2>/dev/null || echo "  None found"

# RDS Instances
echo ""
echo "🗄️  RDS Instances:"
aws rds describe-db-instances --region $REGION --query "DBInstances[?contains(DBInstanceIdentifier, '${TAG_VALUE}')].[DBInstanceIdentifier, DBInstanceStatus]" --output table 2>/dev/null || echo "  None found"

# Lambda Functions
echo ""
echo "⚡ Lambda Functions:"
aws lambda list-functions --region $REGION --query "Functions[?contains(FunctionName, '${TAG_VALUE}')].[FunctionName, Runtime]" --output table 2>/dev/null || echo "  None found"

# S3 Buckets (Note: S3 bucket tagging requires listing and checking each bucket)
echo ""
echo "🪣 S3 Buckets:"
echo "  (Note: S3 bucket tagging requires per-bucket checks, not shown here)"

echo ""
echo "=== Search complete ==="

