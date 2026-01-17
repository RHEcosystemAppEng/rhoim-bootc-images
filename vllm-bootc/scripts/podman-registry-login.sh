#!/bin/bash
set -euo pipefail

# Debug: Check if files exist
echo "[DEBUG] Checking for credentials file..."
CREDENTIALS_FOUND=false

# Try /etc/sysconfig/rhoim first
if [ -f "/etc/sysconfig/rhoim" ]; then
    echo "[DEBUG] Found /etc/sysconfig/rhoim"
    # shellcheck disable=SC1091
    source /etc/sysconfig/rhoim
    # Check if variables were actually set
    if [ -n "${REDHAT_REGISTRY_USERNAME:-}" ] && [ -n "${REDHAT_REGISTRY_TOKEN:-}" ]; then
        echo "[DEBUG] Credentials found in /etc/sysconfig/rhoim"
        CREDENTIALS_FOUND=true
    else
        echo "[DEBUG] /etc/sysconfig/rhoim exists but credentials not set, trying template"
    fi
fi

# If credentials not found, try template file from /usr/share/rhoim (base filesystem)
if [ "$CREDENTIALS_FOUND" = false ] && [ -f "/usr/share/rhoim/rhoim.template" ]; then
    echo "[DEBUG] Found /usr/share/rhoim/rhoim.template, using as fallback"
    # shellcheck disable=SC1091
    source /usr/share/rhoim/rhoim.template
    # Check if variables were actually set
    if [ -n "${REDHAT_REGISTRY_USERNAME:-}" ] && [ -n "${REDHAT_REGISTRY_TOKEN:-}" ]; then
        echo "[DEBUG] Credentials found in /usr/share/rhoim/rhoim.template"
        CREDENTIALS_FOUND=true
    fi
fi

# If still not found, check if files exist for debugging
if [ "$CREDENTIALS_FOUND" = false ]; then
    echo "[DEBUG] Neither file contains credentials"
    if [ -f "/etc/sysconfig/rhoim" ]; then
        echo "[DEBUG] /etc/sysconfig/rhoim exists but is empty or malformed"
        echo "[DEBUG] First 5 lines of /etc/sysconfig/rhoim:"
        head -5 /etc/sysconfig/rhoim 2>&1 || true
    fi
    if [ -f "/usr/share/rhoim/rhoim.template" ]; then
        echo "[DEBUG] /usr/share/rhoim/rhoim.template exists"
        echo "[DEBUG] Checking for credentials in template:"
        grep -E "REDHAT_REGISTRY_(USERNAME|TOKEN)=" /usr/share/rhoim/rhoim.template 2>&1 | sed 's/\(TOKEN=\)[^"]*/\1***HIDDEN***/' || true
    else
        echo "[DEBUG] /usr/share/rhoim/rhoim.template not found"
        ls -la /usr/share/rhoim/ 2>&1 || true
    fi
    echo "[WARNING] Red Hat registry credentials not found"
    echo "[WARNING] Set REDHAT_REGISTRY_USERNAME and REDHAT_REGISTRY_TOKEN to enable registry login"
    echo "[WARNING] Continuing without login - image pull may fail if authentication is required"
    exit 0
fi

# Construct username: Red Hat registry requires format org_id|username
# If username already contains '|', use it as-is; otherwise construct from org_id
if [[ "${REDHAT_REGISTRY_USERNAME}" == *"|"* ]]; then
    # Username already in correct format
    REDHAT_REGISTRY_USER="${REDHAT_REGISTRY_USERNAME}"
else
    # Construct from org_id if available, otherwise use username as-is
    if [ -n "${REDHAT_REGISTRY_ORG_ID:-}" ]; then
        REDHAT_REGISTRY_USER="${REDHAT_REGISTRY_ORG_ID}|${REDHAT_REGISTRY_USERNAME}"
    else
        # Fallback: try to get org_id from subscription-manager
        ORG_ID=$(subscription-manager orgs 2>/dev/null | grep -oP 'ID:\s*\K[0-9]+' | head -1 || echo "")
        if [ -n "${ORG_ID}" ]; then
            REDHAT_REGISTRY_USER="${ORG_ID}|${REDHAT_REGISTRY_USERNAME}"
        else
            # Last resort: use username as-is (may fail, but we'll try)
            REDHAT_REGISTRY_USER="${REDHAT_REGISTRY_USERNAME}"
        fi
    fi
fi

# Ensure auth file directory exists
mkdir -p /root/.config/containers

# Login to Red Hat registry with explicit authfile
echo "=== Logging into Red Hat registry ==="
if echo "${REDHAT_REGISTRY_TOKEN}" | podman login --authfile /root/.config/containers/auth.json --username "${REDHAT_REGISTRY_USER}" --password-stdin registry.redhat.io 2>&1; then
    echo "[SUCCESS] Red Hat registry login completed"
    # Mark login as successful
    touch /var/lib/podman-registry-login-complete
    exit 0
else
    echo "[ERROR] Red Hat registry login failed"
    exit 1
fi
