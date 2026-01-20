#!/bin/bash
# Create a systemd service that sets root password at boot
# This works around ostree overlay filesystem issues
# Usage: ./create-password-service.sh <device> <password>

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <device> <password>"
    exit 1
fi

DEVICE_PATH="$1"
PASSWORD="$2"

# Generate password hash
if command -v openssl >/dev/null 2>&1; then
    PASSWORD_HASH=$(openssl passwd -6 "$PASSWORD")
elif command -v python3 >/dev/null 2>&1; then
    PASSWORD_HASH=$(python3 -c "import crypt; print(crypt.crypt('$PASSWORD', crypt.mksalt(crypt.METHOD_SHA512)))")
else
    echo "Error: Need openssl or python3"
    exit 1
fi

MOUNT_POINT="/mnt/bootc-root-$$"
mkdir -p "$MOUNT_POINT"

if ! mount "$DEVICE_PATH" "$MOUNT_POINT"; then
    echo "Error: Failed to mount $DEVICE_PATH"
    exit 1
fi

# Find ostree deployment directory
DEPLOY_DIR=$(find "$MOUNT_POINT/ostree/deploy/default/deploy" -maxdepth 1 -type d -name "*.0" 2>/dev/null | head -1)
if [ -z "$DEPLOY_DIR" ]; then
    echo "Error: Could not find ostree deployment directory"
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
    exit 1
fi

echo "Found deployment: $DEPLOY_DIR"

# Create systemd service that sets password at boot
SERVICE_DIR="$DEPLOY_DIR/etc/systemd/system"
mkdir -p "$SERVICE_DIR"

cat > "$SERVICE_DIR/set-root-password.service" <<EOF
[Unit]
Description=Set root password at boot
After=systemd-tmpfiles-setup.service
Before=sshd.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'if ! grep -q "^root:${PASSWORD_HASH}:" /etc/shadow 2>/dev/null; then if grep -q "^root:" /etc/shadow 2>/dev/null; then sed -i "s|^root:[^:]*:|root:${PASSWORD_HASH}:|" /etc/shadow; else echo "root:${PASSWORD_HASH}:\$(date +%s)/0:99999:7:::" >> /etc/shadow; fi; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# Enable the service
mkdir -p "$DEPLOY_DIR/etc/systemd/system/multi-user.target.wants"
ln -sf ../set-root-password.service "$DEPLOY_DIR/etc/systemd/system/multi-user.target.wants/set-root-password.service"

echo "✅ Created systemd service to set password at boot"
echo "✅ Service will run before SSH starts"

umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"
echo "✅ Done"
