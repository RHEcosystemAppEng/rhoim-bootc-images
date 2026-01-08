terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Variables
variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "instance_name" {
  description = "Name tag for the EC2 instance"
  type        = string
  default     = "rhoim-builder"
}

variable "key_name" {
  description = "SSH key pair name"
  type        = string
}

variable "ssh_cidr_blocks" {
  description = "CIDR blocks allowed for SSH access (e.g., [\"YOUR_IP/32\"])"
  type        = list(string)
}

variable "api_cidr_blocks" {
  description = "CIDR blocks allowed for API access (unused in builder, declared for shared tfvars compatibility)"
  type        = list(string)
  default     = []
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "m6i.xlarge"
}

variable "ami_id" {
  description = "AMI ID for the instance (RHEL 9.6)"
  type        = string
  default     = "ami-0d8d3b1122e36c000"
}

variable "root_volume_size" {
  description = "Size of root volume in GB"
  type        = number
  default     = 200
}

# Sensitive variables for registry authentication
variable "rhsm_activation_key" {
  description = "Red Hat Subscription Manager activation key"
  type        = string
  sensitive   = true
}

variable "rhsm_org_id" {
  description = "Red Hat Subscription Manager organization ID"
  type        = string
  sensitive   = true
}

variable "redhat_registry_username" {
  description = "Red Hat registry (registry.redhat.io) username"
  type        = string
  sensitive   = true
}

variable "redhat_registry_token" {
  description = "Red Hat registry (registry.redhat.io) token/password"
  type        = string
  sensitive   = true
}

variable "quay_username" {
  description = "Quay.io robot account username"
  type        = string
  sensitive   = true
}

variable "quay_token" {
  description = "Quay.io robot account token/password"
  type        = string
  sensitive   = true
}

# Get common networking info
module "network" {
  source = "../modules/aws-network"
}

# Security group for the builder instance
resource "aws_security_group" "builder" {
  name        = "${var.instance_name}-sg"
  description = "Security group for RHEL image builder instance"
  vpc_id      = module.network.vpc_id

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.instance_name}-sg"
  }
}

# Builder instance
resource "aws_instance" "builder" {
  ami           = var.ami_id
  instance_type = var.instance_type

  subnet_id                   = module.network.first_subnet_id
  vpc_security_group_ids      = [aws_security_group.builder.id]
  associate_public_ip_address = true

  key_name = var.key_name

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data_base64 = base64encode(local.user_data)

  tags = {
    Name = var.instance_name
  }
}

locals {
  user_data = <<-EOF
    #!/bin/bash
    set -ex

    # Log output to file for debugging
    exec > >(tee /var/log/user-data.log) 2>&1

    echo "Starting RHEL image builder setup - $(date)"

    # Step 1: Update system packages
    echo "=== Updating system packages ==="
    dnf -y update

    # Step 2: Install container tools
    echo "=== Installing container tools ==="
    dnf -y install \
      podman \
      buildah \
      skopeo \
      containernetworking-plugins

    # Step 3: Register with Red Hat subscription manager
    echo "=== Registering with Red Hat subscription manager ==="
    subscription-manager register --activationkey="${var.rhsm_activation_key}" --org="${var.rhsm_org_id}"

    # Step 4: Enable CDN repos for bootc-image-builder
    # RHUI repos don't work in containers, so we need CDN repos enabled
    echo "=== Enabling CDN repos for bootc-image-builder ==="
    subscription-manager config --rhsm.manage_repos=1
    subscription-manager repos \
      --enable=rhel-9-for-x86_64-baseos-rpms \
      --enable=rhel-9-for-x86_64-appstream-rpms

    # Step 5: Login to Red Hat registry
    echo "=== Logging into Red Hat registry ==="
    echo "${var.redhat_registry_token}" | podman login --username "${var.redhat_registry_username}" --password-stdin registry.redhat.io

    # Step 6: Login to Quay.io registry
    echo "=== Logging into Quay.io registry ==="
    echo "${var.quay_token}" | podman login --username "${var.quay_username}" --password-stdin quay.io

    # Step 7: Copy registry credentials to ec2-user
    echo "=== Setting up registry credentials for ec2-user ==="
    mkdir -p /home/ec2-user/.config/containers
    cp /run/containers/0/auth.json /home/ec2-user/.config/containers/auth.json
    chown -R ec2-user:ec2-user /home/ec2-user/.config

    # Step 8: Install bootc and image building tools
    echo "=== Installing bootc and image building tools ==="
    dnf -y install \
      bootc \
      osbuild \
      osbuild-selinux \
      lorax \
      anaconda-tui

    # Step 9: Install development and build tools
    echo "=== Installing development tools ==="
    dnf -y install \
      git \
      make \
      jq \
      wget \
      curl \
      unzip \
      vim \
      tmux

    # Step 10: Install AWS CLI for pushing to ECR
    echo "=== Installing AWS CLI ==="
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
    unzip -q /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install
    rm -rf /tmp/aws /tmp/awscliv2.zip

    # Step 11: Configure podman for rootless operation
    echo "=== Configuring podman ==="
    # Enable podman socket for current user
    systemctl enable --now podman.socket

    # Increase container storage
    mkdir -p /etc/containers
    cat > /etc/containers/storage.conf <<'STORAGE_EOF'
    [storage]
    driver = "overlay"
    runroot = "/run/containers/storage"
    graphroot = "/var/lib/containers/storage"

    [storage.options]
    additionalimagestores = []
    size = ""
    STORAGE_EOF

    # Step 12: Configure system for large image builds
    echo "=== Configuring system for image builds ==="
    # Increase inotify watches for large builds
    echo "fs.inotify.max_user_watches = 524288" >> /etc/sysctl.conf
    echo "fs.inotify.max_user_instances = 512" >> /etc/sysctl.conf
    sysctl -p

    # Step 13: Create development directory structure for container builds
    # RHUI repos don't work in containers due to REGION DNS resolution issues
    # We need CDN repos with entitlement certificates for container builds
    echo "=== Setting up container build environment ==="
    mkdir -p /home/ec2-user/development/{repos,entitlement,rhsm,rpm-gpg}
    mkdir -p /home/ec2-user/output

    # Copy entitlements for container builds
    cp /etc/pki/entitlement/*.pem /home/ec2-user/development/entitlement/
    chmod 600 /home/ec2-user/development/entitlement/*.pem

    # Copy RHSM config
    cp -r /etc/rhsm/* /home/ec2-user/development/rhsm/
    chmod -R 644 /home/ec2-user/development/rhsm/ca/*

    # Copy RPM GPG keys
    cp -r /etc/pki/rpm-gpg/* /home/ec2-user/development/rpm-gpg/

    # Get entitlement ID for CDN repo config
    ENTITLEMENT_CERT=$(ls /etc/pki/entitlement/*.pem | grep -v '\-key\.pem' | head -1)
    ENTITLEMENT_ID=$(basename "$ENTITLEMENT_CERT" .pem)

    # Create CDN repo file for container builds
    cat > /home/ec2-user/development/repos/rhel9-cdn.repo <<REPO_EOF
    [rhel-9-baseos-cdn]
    name=Red Hat Enterprise Linux 9 - BaseOS
    baseurl=https://cdn.redhat.com/content/dist/rhel9/9/x86_64/baseos/os
    enabled=1
    gpgcheck=1
    gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
    sslverify=1
    sslcacert=/etc/rhsm/ca/redhat-uep.pem
    sslclientkey=/etc/pki/entitlement/$${ENTITLEMENT_ID}-key.pem
    sslclientcert=/etc/pki/entitlement/$${ENTITLEMENT_ID}.pem

    [rhel-9-appstream-cdn]
    name=Red Hat Enterprise Linux 9 - AppStream
    baseurl=https://cdn.redhat.com/content/dist/rhel9/9/x86_64/appstream/os
    enabled=1
    gpgcheck=1
    gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-redhat-release
    sslverify=1
    sslcacert=/etc/rhsm/ca/redhat-uep.pem
    sslclientkey=/etc/pki/entitlement/$${ENTITLEMENT_ID}-key.pem
    sslclientcert=/etc/pki/entitlement/$${ENTITLEMENT_ID}.pem
    REPO_EOF

    # Download NVIDIA repos for GPU-enabled builds
    echo "=== Downloading NVIDIA repos ==="
    curl -sL https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo \
      -o /home/ec2-user/development/repos/cuda-rhel9.repo
    curl -sL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
      -o /home/ec2-user/development/repos/nvidia-container-toolkit.repo

    # Fix ownership
    chown -R ec2-user:ec2-user /home/ec2-user/development
    chown -R ec2-user:ec2-user /home/ec2-user/output

    # Step 14: Create useful aliases
    echo "=== Creating shell aliases ==="
    cat >> /etc/profile.d/builder-aliases.sh <<'ALIAS_EOF'
    alias pd='podman'
    alias pdi='podman images'
    alias pdc='podman ps -a'
    alias pdl='podman logs -f'
    alias bb='buildah bud'

    # Container build with CDN repos (for RHEL images that need repos)
    build-with-repos() {
      podman build --platform linux/amd64 \
        -v ~/development/repos:/etc/yum.repos.d:z \
        -v ~/development/entitlement:/etc/pki/entitlement:ro,z \
        -v ~/development/rhsm:/etc/rhsm:ro,z \
        -v ~/development/rpm-gpg:/etc/pki/rpm-gpg:ro,z \
        "$@"
    }

    # Build ISO from bootc image
    build-iso() {
      sudo podman run --rm -it --privileged --pull=newer \
        --security-opt label=type:unconfined_t \
        -v ~/output:/output \
        -v /var/lib/containers/storage:/var/lib/containers/storage \
        registry.redhat.io/rhel9/bootc-image-builder:latest \
        --type iso \
        "$@"
    }
    ALIAS_EOF

    # Step 15: Enable lingering for ec2-user (allows user services after logout)
    echo "=== Enabling lingering for ec2-user ==="
    loginctl enable-linger ec2-user

    # Step 16: Verify installations
    echo "=== Verifying installations ==="
    echo "Podman version: $(podman --version)"
    echo "Buildah version: $(buildah --version)"
    echo "Skopeo version: $(skopeo --version)"
    echo "Bootc version: $(bootc --version 2>/dev/null || echo 'bootc installed')"
    echo "Git version: $(git --version)"
    echo "AWS CLI version: $(aws --version)"

    # Verify CDN repos are accessible
    echo "=== Verifying CDN repos ==="
    dnf repolist | grep -E "(rhel-9-for-x86_64-baseos|rhel-9-for-x86_64-appstream)" || echo "Warning: CDN repos not found"

    # Mark setup complete
    touch /var/lib/builder-setup-complete

    echo "=== Builder setup complete - $(date) ==="
    echo "Ready for bootc image building!"
    echo ""
    echo "Container build usage:"
    echo "  build-with-repos -t <tag> -f ./Containerfile ."
    echo ""
    echo "ISO build usage:"
    echo "  build-iso <image-ref>"
  EOF
}

# Outputs
output "instance_id" {
  value = aws_instance.builder.id
}

output "public_ip" {
  value = aws_instance.builder.public_ip
}

output "public_dns" {
  value = aws_instance.builder.public_dns
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.builder.public_ip}"
}
