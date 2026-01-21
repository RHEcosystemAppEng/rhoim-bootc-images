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

variable "resource_prefix" {
  description = "Prefix for all resource names (e.g., 'dev-rhoim-tester') - used for easy filtering and cleanup"
  type        = string
  default     = "rhoim-tester"
}

variable "instance_name" {
  description = "Name tag for the EC2 instance (will use resource_prefix if not set)"
  type        = string
  default     = ""
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
  description = "CIDR blocks allowed for API access (port 8000, e.g., [\"YOUR_IP/32\"])"
  type        = list(string)
}

variable "instance_type" {
  description = "EC2 instance type (GPU instance)"
  type        = string
  default     = "g4dn.xlarge"
}

variable "ami_id" {
  description = "AMI ID for the instance (RHEL 9.6)"
  type        = string
  default     = "ami-0d8d3b1122e36c000"
}

variable "root_volume_size" {
  description = "Size of root volume in GB (minimum 50GB recommended for bootc images with vLLM)"
  type        = number
  default     = 50
}

variable "is_bootc_image" {
  description = "Whether the AMI is a bootc image (affects NVIDIA driver installation approach)"
  type        = bool
  default     = false
}

variable "install_nvidia_drivers" {
  description = "Whether to attempt NVIDIA driver installation (for GPU instances). For bootc images, drivers may need manual installation."
  type        = bool
  default     = true
}

# Local values for resource naming
locals {
  instance_name = var.instance_name != "" ? var.instance_name : var.resource_prefix
  common_tags = {
    Project     = "rhoim-bootc"
    ManagedBy   = "opentofu"
    ResourcePrefix = var.resource_prefix
  }
}

# Get common networking info
module "network" {
  source = "../modules/aws-network"
}

# IAM role for SSM Session Manager access
resource "aws_iam_role" "ssm_role" {
  name = "${local.instance_name}-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = local.common_tags
}

# Attach AWS managed policy for SSM
resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance profile to attach the role to the instance
resource "aws_iam_instance_profile" "ssm_profile" {
  name = "${local.instance_name}-ssm-profile"
  role = aws_iam_role.ssm_role.name

  tags = local.common_tags
}

# Security group for the GPU host instance
resource "aws_security_group" "gpu_host" {
  name        = "${local.instance_name}-sg"
  description = "Security group for RHEL 9.6 GPU host instance"
  vpc_id      = module.network.vpc_id

  # SSH access
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_cidr_blocks
  }

  # vLLM API port
  ingress {
    description = "vLLM API"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = var.api_cidr_blocks
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge({
    Name = "${local.instance_name}-sg"
  }, local.common_tags)
}

# GPU host instance
resource "aws_instance" "gpu_host" {
  ami           = var.ami_id
  instance_type = var.instance_type

  subnet_id                   = module.network.first_subnet_id
  vpc_security_group_ids      = [aws_security_group.gpu_host.id]
  associate_public_ip_address = true

  iam_instance_profile = aws_iam_instance_profile.ssm_profile.name

  key_name = var.key_name

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data_base64 = base64encode(local.user_data)

  tags = merge({
    Name = local.instance_name
  }, local.common_tags)

  # Tag the EBS volume with the same tags for easy filtering
  volume_tags = merge({
    Name = "${local.instance_name}-root"
  }, local.common_tags)
}

locals {
  user_data = <<-EOF
    #!/bin/bash
    set -e  # Exit on error, but handle gracefully

    # Log output to file for debugging
    exec > >(tee /var/log/user-data.log) 2>&1

    echo "Starting GPU instance setup - $(date)"
    echo "Bootc image: ${var.is_bootc_image}"
    echo "Install NVIDIA drivers: ${var.install_nvidia_drivers}"

    # Detect if this is a bootc image (check for bootc or ostree)
    if [ -f /sysroot/ostree/repo/config ] || command -v bootc > /dev/null 2>&1; then
        IS_BOOTC=true
        echo "Detected bootc/ostree image"
    else
        IS_BOOTC=false
        echo "Detected standard RHEL image"
    fi

    if [ "$IS_BOOTC" = "false" ]; then
        # Standard RHEL image setup
        echo "=== Installing bootc, podman, and container tools ==="
        dnf -y install bootc podman skopeo || echo "Warning: Some packages may not be available"

        # Enable and start podman socket
        systemctl enable --now podman.socket

    # Step 2: Upgrade OpenSSL to fix bootc library compatibility
    echo "=== Upgrading OpenSSL for bootc compatibility ==="
    dnf -y upgrade openssl openssl-libs

    # Step 3: Install specific kernel version and pin it
    echo "=== Installing kernel 5.14.0-611.5.1 and pinning ==="
    KERNEL_VERSION="5.14.0-611.5.1.el9_7"

    # Install the specific kernel version
    dnf -y install \
      kernel-$${KERNEL_VERSION} \
      kernel-core-$${KERNEL_VERSION} \
      kernel-modules-$${KERNEL_VERSION} \
      kernel-modules-core-$${KERNEL_VERSION}

    # Set the specific kernel as default
    grubby --set-default /boot/vmlinuz-$${KERNEL_VERSION}.x86_64

    # Remove all other kernels
    echo "=== Removing other kernel versions ==="
    rpm -qa | grep -E '^kernel(-core|-modules|-modules-core)?-[0-9]' | grep -v "$${KERNEL_VERSION}" | xargs -r dnf -y remove || true

    # Pin kernel packages to prevent updates
    echo "=== Pinning kernel packages ==="
    dnf -y install python3-dnf-plugin-versionlock
    dnf versionlock add kernel kernel-core kernel-modules kernel-modules-core

    # Also exclude kernel from updates in dnf.conf as backup
    if ! grep -q "^exclude=kernel" /etc/dnf/dnf.conf; then
      echo "exclude=kernel*" >> /etc/dnf/dnf.conf
    fi

        # Step 4: Add NVIDIA CUDA repository and install precompiled driver
        if [ "${var.install_nvidia_drivers}" = "true" ]; then
            echo "=== Adding NVIDIA CUDA repository ==="
            dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel9/x86_64/cuda-rhel9.repo || echo "Warning: Failed to add NVIDIA repo"

            # Step 5: Install NVIDIA driver using precompiled modules
            echo "=== Installing NVIDIA driver 570 with precompiled kernel modules ==="
            dnf -y module install nvidia-driver:570 || echo "Warning: NVIDIA driver installation failed, may need manual installation"

            # Step 6: Install NVIDIA Container Toolkit
            echo "=== Installing NVIDIA Container Toolkit ==="
            curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | \
              tee /etc/yum.repos.d/nvidia-container-toolkit.repo || echo "Warning: Failed to add NVIDIA Container Toolkit repo"

            dnf -y install --nogpgcheck nvidia-container-toolkit || echo "Warning: NVIDIA Container Toolkit installation failed"
        fi
    else
        # Bootc image setup - limited package installation
        echo "=== Bootc image detected - limited setup ==="
        echo "Note: NVIDIA drivers must be installed in the bootc image during build"
        echo "      The bootc image includes nvidia-container-setup.service which configures"
        echo "      container access to GPUs, but NVIDIA drivers must be pre-installed"
        
        if [ "${var.install_nvidia_drivers}" = "true" ]; then
            echo "=== NVIDIA driver installation on bootc images ==="
            echo "⚠️  Warning: NVIDIA drivers cannot be installed post-deployment on bootc images"
            echo "   Drivers must be included in the bootc image Containerfile during build"
            echo "   The nvidia-container-setup.service will configure GPU access if drivers exist"
        fi
    fi

    # Step 7: Create systemd service to complete NVIDIA setup after reboot (only for non-bootc)
    if [ "$IS_BOOTC" = "false" ] && [ "${var.install_nvidia_drivers}" = "true" ]; then
        echo "=== Creating post-reboot NVIDIA setup service ==="
        cat > /etc/systemd/system/nvidia-post-boot-setup.service <<'SYSTEMD_EOF'
        [Unit]
        Description=NVIDIA Driver Post-Boot Setup
        After=network.target
        ConditionPathExists=!/var/lib/nvidia-setup-complete

        [Service]
        Type=oneshot
        ExecStart=/usr/local/bin/nvidia-post-boot-setup.sh
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
        SYSTEMD_EOF

        # Create the post-boot setup script
        cat > /usr/local/bin/nvidia-post-boot-setup.sh <<'SCRIPT_EOF'
        #!/bin/bash
        set -e

        exec > >(tee -a /var/log/nvidia-post-boot-setup.log) 2>&1

        echo "Running NVIDIA post-boot setup - $(date)"

        echo "=== Verifying NVIDIA driver installation ==="
        if command -v nvidia-smi > /dev/null 2>&1 && nvidia-smi > /dev/null 2>&1; then
            echo "NVIDIA driver installed successfully"
        else
            echo "WARNING: nvidia-smi failed, driver may need attention"
            echo "         Check /var/log/user-data.log for installation errors"
            exit 0  # Don't fail, allow system to continue
        fi

        echo "=== Generating CDI configuration ==="
        if command -v nvidia-ctk > /dev/null 2>&1; then
            mkdir -p /etc/cdi
            nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml || echo "Warning: CDI generation failed"
        else
            echo "Warning: nvidia-ctk not found, skipping CDI generation"
        fi

        echo "=== Setting GPU device permissions ==="
        chmod 666 /dev/nvidia* 2>/dev/null || true

        cat > /etc/udev/rules.d/70-nvidia.rules <<'UDEV_EOF'
        KERNEL=="nvidia*", MODE="0666"
        UDEV_EOF

        udevadm control --reload-rules || echo "Warning: Failed to reload udev rules"

        echo "=== NVIDIA setup complete - $(date) ==="
        touch /var/lib/nvidia-setup-complete

        SCRIPT_EOF

        chmod +x /usr/local/bin/nvidia-post-boot-setup.sh
        systemctl enable nvidia-post-boot-setup.service

        # Step 8: Schedule reboot (only for non-bootc)
        echo "=== Setup complete, scheduling reboot ==="
        shutdown -r +1 "Rebooting to complete NVIDIA GPU setup"
    else
        echo "=== Setup complete ==="
        if [ "$IS_BOOTC" = "true" ]; then
            echo "Bootc image detected - NVIDIA drivers must be installed in the image during build"
            echo "The nvidia-container-setup.service will configure GPU access if drivers are present"
        fi
    fi
  EOF
}

# Outputs
output "instance_id" {
  value = aws_instance.gpu_host.id
}

output "public_ip" {
  value = aws_instance.gpu_host.public_ip
}

output "public_dns" {
  value = aws_instance.gpu_host.public_dns
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/${var.key_name}.pem ec2-user@${aws_instance.gpu_host.public_ip}"
}
