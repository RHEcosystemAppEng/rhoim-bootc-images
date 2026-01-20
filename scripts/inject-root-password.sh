#!/bin/bash
# Inject root password into bootc-installed filesystem
# Usage: inject-root-password.sh <device> <password>

set -euo pipefail

if [ $# -lt 2 ]; then
    echo "Usage: $0 <device> <password>"
    echo "Example: $0 /dev/nvme1n1p3 mypassword123"
    exit 1
fi

DEVICE_PATH="$1"
PASSWORD="$2"

if [ ! -b "$DEVICE_PATH" ]; then
    echo "Error: $DEVICE_PATH is not a block device"
    exit 1
fi

# Create mount point
MOUNT_POINT="/mnt/bootc-root-$$"
mkdir -p "$MOUNT_POINT"

# Mount the root filesystem
echo "Mounting bootc root filesystem..."
if ! mount "$DEVICE_PATH" "$MOUNT_POINT"; then
    echo "Error: Failed to mount $DEVICE_PATH"
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    exit 1
fi

# Generate password hash using openssl (if available) or Python
if command -v openssl >/dev/null 2>&1; then
    # Use openssl to generate SHA-512 password hash
    PASSWORD_HASH=$(openssl passwd -6 "$PASSWORD")
elif command -v python3 >/dev/null 2>&1; then
    # Use Python's crypt module
    PASSWORD_HASH=$(python3 -c "import crypt; print(crypt.crypt('$PASSWORD', crypt.mksalt(crypt.METHOD_SHA512)))")
else
    echo "Error: Need either openssl or python3 to generate password hash"
    umount "$MOUNT_POINT" 2>/dev/null || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true
    exit 1
fi

echo "Generated password hash for root user"

# Backup original shadow file
if [ -f "$MOUNT_POINT/etc/shadow" ]; then
    cp "$MOUNT_POINT/etc/shadow" "$MOUNT_POINT/etc/shadow.bak"
fi

# In bootc/ostree, /etc is read-only, so we need to use systemd-tmpfiles or write to deployment
# Write to the ostree deployment directory (this is what gets used at runtime)
DEPLOY_DIR=$(find "$MOUNT_POINT/ostree/deploy/default/deploy" -maxdepth 1 -type d -name "*.0" 2>/dev/null | head -1)
if [ -n "$DEPLOY_DIR" ]; then
    echo "Found ostree deployment directory: $DEPLOY_DIR"
    DEPLOY_SHADOW="$DEPLOY_DIR/etc/shadow"
    mkdir -p "$(dirname "$DEPLOY_SHADOW")"
    
    # Copy existing shadow if it exists, otherwise create minimal one
    if [ -f "$MOUNT_POINT/etc/shadow" ]; then
        cp "$MOUNT_POINT/etc/shadow" "$DEPLOY_SHADOW"
    else
        # Create minimal shadow file with root entry
        echo "root:${PASSWORD_HASH}:$(date +%s)/0:99999:7:::" > "$DEPLOY_SHADOW"
    fi
    
    # Update root password in deployment shadow file
    if grep -q "^root:" "$DEPLOY_SHADOW" 2>/dev/null; then
        # Replace existing root password hash
        sed -i "s|^root:[^:]*:|root:${PASSWORD_HASH}:|" "$DEPLOY_SHADOW"
        echo "✅ Updated root password in deployment shadow file"
    else
        # Add root entry if it doesn't exist
        echo "root:${PASSWORD_HASH}:$(date +%s)/0:99999:7:::" >> "$DEPLOY_SHADOW"
        echo "✅ Added root password entry to deployment shadow file"
    fi
    
    # Also create a systemd-tmpfiles script to ensure password is set at boot
    # This is a backup in case the deployment shadow doesn't work
    TMPFILES_SCRIPT="$DEPLOY_DIR/usr/local/bin/set-root-password.sh"
    mkdir -p "$(dirname "$TMPFILES_SCRIPT")"
    cat > "$TMPFILES_SCRIPT" <<EOF
#!/bin/bash
# Set root password at boot (backup method)
if ! grep -q "^root:${PASSWORD_HASH}:" /etc/shadow 2>/dev/null; then
    if grep -q "^root:" /etc/shadow 2>/dev/null; then
        sed -i "s|^root:[^:]*:|root:${PASSWORD_HASH}:|" /etc/shadow
    else
        echo "root:${PASSWORD_HASH}:$(date +%s)/0:99999:7:::" >> /etc/shadow
    fi
fi
EOF
    chmod +x "$TMPFILES_SCRIPT"
    echo "✅ Created backup password setting script"
    
    # Verify password was set
    if grep -q "^root:${PASSWORD_HASH}:" "$DEPLOY_SHADOW"; then
        echo "✅ Password hash verified in deployment shadow file"
    else
        echo "❌ Error: Password hash verification failed"
        umount "$MOUNT_POINT" 2>/dev/null || true
        rmdir "$MOUNT_POINT" 2>/dev/null || true
        exit 1
    fi
else
    echo "Warning: Could not find ostree deployment directory, writing to root /etc/shadow"
    if [ -f "$MOUNT_POINT/etc/shadow" ]; then
        if grep -q "^root:" "$MOUNT_POINT/etc/shadow" 2>/dev/null; then
            sed -i "s|^root:[^:]*:|root:${PASSWORD_HASH}:|" "$MOUNT_POINT/etc/shadow"
            echo "✅ Updated root password in root /etc/shadow"
        else
            echo "root:${PASSWORD_HASH}:$(date +%s)/0:99999:7:::" >> "$MOUNT_POINT/etc/shadow"
            echo "✅ Added root password entry to root /etc/shadow"
        fi
    else
        echo "root:${PASSWORD_HASH}:$(date +%s)/0:99999:7:::" > "$MOUNT_POINT/etc/shadow"
        echo "✅ Created root /etc/shadow with password"
    fi
fi

# Unmount
umount "$MOUNT_POINT"
rmdir "$MOUNT_POINT"
echo "✅ Root password injection complete"
