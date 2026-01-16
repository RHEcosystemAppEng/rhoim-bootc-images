#!/bin/bash
set -euo pipefail

# Debug: Check if files exist
echo "[DEBUG] Checking for credentials file..."
if [ -f "/etc/sysconfig/rhoim" ]; then
    echo "[DEBUG] Found /etc/sysconfig/rhoim"
    # shellcheck disable=SC1091
    source /etc/sysconfig/rhoim
elif [ -f "/var/lib/rhoim/rhoim.template" ]; then
    echo "[DEBUG] Found /var/lib/rhoim/rhoim.template, using as fallback"
    # shellcheck disable=SC1091
    source /var/lib/rhoim/rhoim.template
else
    echo "[DEBUG] Neither /etc/sysconfig/rhoim nor /var/lib/rhoim/rhoim.template found"
    ls -la /etc/sysconfig/ 2>&1 | head -10 || true
    ls -la /var/lib/rhoim/ 2>&1 || true
fi

# Check if registry credentials are provided
if [ -z "${REDHAT_REGISTRY_USERNAME:-}" ] || [ -z "${REDHAT_REGISTRY_TOKEN:-}" ]; then
    echo "[WARNING] Red Hat registry credentials not found in /etc/sysconfig/rhoim"
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
