#!/bin/bash
set -euo pipefail

# Load configuration from /etc/sysconfig/rhoim if present
if [ -f "/etc/sysconfig/rhoim" ]; then
    # shellcheck disable=SC1091
    source /etc/sysconfig/rhoim
fi

# Check if registry credentials are provided
if [ -z "${REDHAT_REGISTRY_USERNAME:-}" ] || [ -z "${REDHAT_REGISTRY_TOKEN:-}" ]; then
    echo "[WARNING] Red Hat registry credentials not found in /etc/sysconfig/rhoim"
    echo "[WARNING] Set REDHAT_REGISTRY_USERNAME and REDHAT_REGISTRY_TOKEN to enable registry login"
    echo "[WARNING] Continuing without login - image pull may fail if authentication is required"
    exit 0
fi

# Login to Red Hat registry
echo "=== Logging into Red Hat registry ==="
if echo "${REDHAT_REGISTRY_TOKEN}" | podman login --username "${REDHAT_REGISTRY_USERNAME}" --password-stdin registry.redhat.io 2>&1; then
    echo "[SUCCESS] Red Hat registry login completed"
    # Mark login as successful
    touch /var/lib/podman-registry-login-complete
    exit 0
else
    echo "[ERROR] Red Hat registry login failed"
    exit 1
fi
