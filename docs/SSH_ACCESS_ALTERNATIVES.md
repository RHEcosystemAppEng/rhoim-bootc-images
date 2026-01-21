# SSH Access Alternatives for bootc/ostree Images

## Problem: Why SSH Password Injection Fails

### Root Cause: ostree Read-Only Filesystem

The issue is **not** related to RHAIIS base image (we use `rhel-bootc`). The problem is **ostree's immutable filesystem architecture**:

1. **`/etc` is read-only** in ostree deployments
   - Direct writes to `/etc/shadow` don't persist
   - Changes must go through ostree deployment directory or systemd-tmpfiles

2. **Overlay filesystem complexity**
   - `/etc` is an overlay: base (read-only) + writable overlay
   - Password changes in deployment directory may not be applied correctly
   - Systemd services that modify `/etc/shadow` at boot may fail due to timing

3. **Why our injection scripts fail:**
   - `inject-root-password.sh` writes to deployment directory, but ostree may reset it
   - `create-password-service.sh` tries to set password at boot, but `/etc/shadow` overlay may not be writable yet
   - SSH daemon may start before password is set

### Current Approach Limitations

```bash
# What we're trying:
1. Write to /ostree/deploy/default/deploy/*.0/etc/shadow  # May be reset
2. Create systemd service to set password at boot          # Timing issues
3. Use systemd-tmpfiles                                    # May not work for shadow
```

## Better Alternatives

### Option 1: AWS Systems Manager (SSM) Session Manager ⭐ **RECOMMENDED**

**Pros:**
- No SSH port needed (more secure)
- Works without SSH keys or passwords
- Session logging and auditing
- IAM-based access control
- Works from AWS Console, CLI, or SDK

**Cons:**
- Requires SSM agent installation
- Requires IAM role with SSM permissions

**Implementation:**

1. **Install SSM agent in Containerfile:**
```dockerfile
# Install AWS SSM agent
RUN dnf -y install amazon-ssm-agent && \
    systemctl enable amazon-ssm-agent
```

2. **Attach IAM role to instance with SSM permissions:**
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:UpdateInstanceInformation",
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ],
      "Resource": "*"
    }
  ]
}
```

3. **Connect via AWS CLI:**
```bash
aws ssm start-session --target i-1234567890abcdef0 --region us-east-1
```

4. **Or use AWS Console:**
   - EC2 → Instances → Select instance → Connect → Session Manager

### Option 2: EC2 Instance Connect

**Pros:**
- Temporary SSH keys (60-second validity)
- No long-lived keys to manage
- Works with standard SSH clients
- IAM-based access control

**Cons:**
- Requires `ec2-instance-connect` package
- Still uses SSH (port 22)

**Implementation:**

1. **Install EC2 Instance Connect in Containerfile:**
```dockerfile
# Install EC2 Instance Connect
RUN dnf -y install ec2-instance-connect
```

2. **Connect via AWS CLI:**
```bash
aws ec2-instance-connect send-ssh-public-key \
  --instance-id i-1234567890abcdef0 \
  --availability-zone us-east-1a \
  --instance-os-user root \
  --ssh-public-key file://~/.ssh/id_rsa.pub

# Then SSH normally
ssh root@<instance-ip>
```

3. **Or use AWS Console:**
   - EC2 → Instances → Select instance → Connect → EC2 Instance Connect

### Option 3: SSH Key Injection via cloud-init (Standard Approach)

**Pros:**
- Standard AWS approach
- Works with key pairs
- No additional packages needed

**Cons:**
- Requires cloud-init (may not be in bootc image)
- Still uses SSH

**Implementation:**

1. **Install cloud-init in Containerfile:**
```dockerfile
RUN dnf -y install cloud-init
```

2. **Launch instance with key pair:**
```bash
aws ec2 run-instances \
  --image-id ami-xxx \
  --instance-type g5.xlarge \
  --key-name your-key-pair \
  ...
```

3. **cloud-init will inject the public key into `~/.ssh/authorized_keys`**

### Option 4: User-Data Script (Alternative to cloud-init)

**Pros:**
- Works without cloud-init
- Can set password or inject keys via script

**Cons:**
- Requires script execution mechanism
- May not work with bootc/ostree

**Implementation:**

1. **Create user-data script:**
```bash
#!/bin/bash
# Set root password
echo 'root:your-password' | chpasswd

# Or inject SSH key
mkdir -p /root/.ssh
echo "ssh-rsa AAAAB3..." >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
```

2. **Launch with user-data:**
```bash
aws ec2 run-instances \
  --image-id ami-xxx \
  --user-data file://user-data.sh \
  ...
```

## Recommended Solution for Quick Testing

For **quick feedback loops during development**, use **SSM Session Manager**:

1. **Add to Containerfile:**
```dockerfile
# Install AWS SSM agent for secure access without SSH
RUN dnf -y install amazon-ssm-agent && \
    systemctl enable amazon-ssm-agent
```

2. **Ensure instance has IAM role with SSM permissions**

3. **Connect instantly:**
```bash
aws ssm start-session --target <instance-id> --region us-east-1
```

4. **No SSH keys, no passwords, no port 22 needed!**

## Why This is Better Than Password Injection

1. **Security:** No passwords in images or scripts
2. **Auditability:** All sessions logged
3. **IAM Control:** Fine-grained access control
4. **No ostree issues:** Doesn't rely on `/etc` modifications
5. **Works immediately:** No timing issues with boot services

## Migration Path

1. **Short term:** Use SSM for testing (add to Containerfile now)
2. **Medium term:** Add EC2 Instance Connect for SSH access
3. **Long term:** Remove password injection scripts entirely

## References

- [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [EC2 Instance Connect](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/Connect-using-EC2-Instance-Connect.html)
- [ostree Filesystem Layout](https://ostreedev.github.io/ostree/filesystem-layout/)
