# Rebuild Guide: Container and AMI

This guide walks you through cleaning up old AWS resources and rebuilding the container image and AMI.

## Step 1: Cleanup AWS Resources

First, delete the old AWS resources (instances, AMIs, snapshots, volumes) to save costs:

```bash
# Run the cleanup script (will prompt for confirmation)
./scripts/cleanup-aws-resources.sh us-east-1

# Or use --force to skip confirmations
./scripts/cleanup-aws-resources.sh us-east-1 --force
```

The script will:
- Terminate running instances
- Deregister AMIs
- Delete snapshots
- Delete volumes

**Note**: The script will find resources both from the README (if still present) and resources tagged by `create-bootc-ami-script`.

## Step 2: Build Container Image

Build the bootc container image with NVIDIA support:

```bash
cd vllm-bootc

# Build with RHEL subscription secrets (required for RHEL repos)
podman build \
  --platform linux/amd64 \
  --secret id=rhsm,src=/path/to/rhsm.conf \
  --secret id=ca,src=/path/to/redhat-uep.pem \
  --secret id=key,src=/path/to/key.pem \
  --secret id=cert,src=/path/to/cert.pem \
  -t localhost/rhoim-bootc-nvidia:latest \
  -f ./Containerfile .
```

**Required Secrets** (RHEL subscription files):
- `rhsm.conf`: `/etc/rhsm/rhsm.conf`
- `redhat-uep.pem`: `/etc/rhsm/ca/redhat-uep.pem`
- `key.pem`: `/etc/pki/entitlement/[ENTITLEMENT_ID]-key.pem`
- `cert.pem`: `/etc/pki/entitlement/[ENTITLEMENT_ID].pem`

**Alternative**: If you're building on an AWS EC2 instance with RHEL subscription already configured, you can use the builder infrastructure from `infra/builder/`.

## Step 3: Create AMI from Container Image

Once the container image is built, create an AMI using the `create-bootc-ami.sh` script:

```bash
# On an AWS EC2 instance with bootc installed
cd scripts

# Run the AMI creation script
./create-bootc-ami.sh \
  us-east-1 \
  us-east-1a \
  your-org-id \
  your-username \
  your-token
```

**Parameters**:
- `us-east-1`: AWS region
- `us-east-1a`: Availability zone
- `your-org-id`: Red Hat organization ID (for registry credentials)
- `your-username`: Red Hat username (for registry credentials)
- `your-token`: Red Hat token (for registry credentials)

**What the script does**:
1. Creates a 50GB EBS volume
2. Installs the bootc image to the volume (with SSH keys)
3. Injects registry credentials
4. Creates a snapshot
5. Creates an AMI with UEFI boot mode and ENA support

## Step 4: Test the AMI

Launch an instance from the new AMI:

```bash
# Get the AMI ID from the script output
AMI_ID="ami-xxxxxxxxxxxxx"

# Launch a GPU instance
aws ec2 run-instances \
  --region us-east-1 \
  --image-id "$AMI_ID" \
  --instance-type g4dn.xlarge \
  --key-name your-key-pair \
  --security-group-ids sg-xxxxxxxxx \
  --subnet-id subnet-xxxxxxxxx \
  --associate-public-ip-address
```

## Troubleshooting

### Container Build Fails
- Verify RHEL subscription secrets are correct
- Check that you have access to RHEL repositories
- Ensure podman is in rootful mode (for bootc-image-builder)

### AMI Creation Fails
- Ensure you're running on an EC2 instance (not locally)
- Verify bootc is installed: `bootc --version`
- Check SSH key file exists: `~/.ssh/authorized_keys`
- Ensure instance has sufficient disk space

### Instance Won't Boot
- Verify AMI has UEFI boot mode: `aws ec2 describe-images --image-ids $AMI_ID --query 'Images[0].BootMode'`
- Check ENA support is enabled: `aws ec2 describe-images --image-ids $AMI_ID --query 'Images[0].EnaSupport'`
- Review instance console output in AWS Console

## Cleanup After Testing

After testing, clean up resources again:

```bash
./scripts/cleanup-aws-resources.sh us-east-1
```
