#!/usr/bin/env bash
# Script to build bootable image and convert to Azure-compliant VHD
# Run this on your AWS RHEL instance after pulling the container image

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}=== Building Bootable Image and Converting to Azure VHD ===${NC}"
echo ""

# Configuration
IMAGE_NAME="localhost/rhoim-bootc-rhel-olga:v2"
OUTPUT_DIR="$HOME/bootable-images"
AZURE_VHD_SIZE_MB=46080  # 45 GiB in MB (whole number required by Azure)

# Step 1: Pull image into root's podman storage (if not already done)
echo -e "${BLUE}Step 1: Ensuring image is in root's podman storage...${NC}"
if ! sudo podman images --format "{{.Repository}}:{{.Tag}}" | grep -q "^${IMAGE_NAME}$"; then
    echo "Pulling image into root's storage..."
    sudo podman pull quay.io/olavtar/rhoim-bootc-rhel:latest
    sudo podman tag quay.io/olavtar/rhoim-bootc-rhel:latest "${IMAGE_NAME}"
else
    echo "✓ Image already in root's storage"
fi

# Step 2: Create output directory
echo -e "${BLUE}Step 2: Creating output directory...${NC}"
mkdir -p "${OUTPUT_DIR}"
echo "✓ Output directory: ${OUTPUT_DIR}"

# Step 3: Build bootable disk images (qcow2, raw, vhd, ami)
echo -e "${BLUE}Step 3: Building bootable disk images...${NC}"
echo "This may take 10-20 minutes..."
sudo podman run --rm --privileged \
  -v /var/lib/containers/storage:/var/lib/containers/storage \
  -v "${OUTPUT_DIR}":/output \
  quay.io/centos-bootc/bootc-image-builder:latest \
  --type qcow2 \
  --type raw \
  --type vhd \
  --type ami \
  "${IMAGE_NAME}"

if [ $? -ne 0 ]; then
    echo -e "${RED}✗ Bootable image build failed${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Bootable images created${NC}"

# Step 4: Convert to Azure-compliant VHD
echo -e "${BLUE}Step 4: Converting to Azure-compliant VHD...${NC}"

# Find the qcow2 file
QCOW2_FILE=$(find "${OUTPUT_DIR}" -name "*.qcow2" -type f | head -1)
if [ -z "$QCOW2_FILE" ]; then
    echo -e "${RED}✗ qcow2 file not found${NC}"
    exit 1
fi

echo "Found qcow2: ${QCOW2_FILE}"

# Calculate exact size in bytes (Azure requires whole number in MBs)
# 46080 MB = 46080 * 1024 * 1024 = 48,316,108,800 bytes
AZURE_SIZE_BYTES=$((AZURE_VHD_SIZE_MB * 1024 * 1024))
RAW_FILE="${OUTPUT_DIR}/disk.raw"
VHD_FILE="${OUTPUT_DIR}/disk.vhd"

echo "Converting qcow2 to raw..."
qemu-img convert -f qcow2 -O raw "${QCOW2_FILE}" "${RAW_FILE}"

echo "Resizing raw to exact Azure-compliant size (${AZURE_VHD_SIZE_MB} MB)..."
qemu-img resize -f raw "${RAW_FILE}" "${AZURE_SIZE_BYTES}"

echo "Converting raw to fixed-size VHD..."
qemu-img convert -f raw -O vpc -o subformat=fixed,force_size=on "${RAW_FILE}" "${VHD_FILE}"

# Step 5: Verify VHD
echo -e "${BLUE}Step 5: Verifying VHD...${NC}"
echo ""
echo "VHD Information:"
qemu-img info "${VHD_FILE}"
echo ""

# Check for VHD footer (conectix)
if tail -c 512 "${VHD_FILE}" | strings | grep -qi conectix; then
    echo -e "${GREEN}✓ VHD footer (conectix) found${NC}"
else
    echo -e "${YELLOW}⚠ Warning: VHD footer not found${NC}"
fi

# Verify size
VHD_SIZE=$(stat -f%z "${VHD_FILE}" 2>/dev/null || stat -c%s "${VHD_FILE}" 2>/dev/null)
EXPECTED_SIZE=$((AZURE_SIZE_BYTES + 512))  # VHD size = virtual size + 512 byte footer

if [ "$VHD_SIZE" -eq "$EXPECTED_SIZE" ]; then
    echo -e "${GREEN}✓ VHD size is correct: ${VHD_SIZE} bytes (${AZURE_VHD_SIZE_MB} MB + 512 byte footer)${NC}"
else
    echo -e "${YELLOW}⚠ VHD size: ${VHD_SIZE} bytes (expected: ${EXPECTED_SIZE} bytes)${NC}"
fi

# Step 6: Summary
echo ""
echo -e "${GREEN}=== Build Complete ===${NC}"
echo ""
echo "Generated files:"
ls -lh "${OUTPUT_DIR}"/*.{qcow2,raw,vhd,ami} 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
echo ""
echo -e "${BLUE}Azure VHD: ${VHD_FILE}${NC}"
echo -e "${BLUE}Size: ${AZURE_VHD_SIZE_MB} MB (${AZURE_VHD_SIZE_MB} * 1024 * 1024 bytes)${NC}"
echo ""
echo "Next steps for Azure deployment:"
echo "1. Upload VHD to Azure Blob Storage (as Page blob)"
echo "2. Create Managed Disk from the VHD"
echo "3. Create VM from the Managed Disk"
echo ""
echo "Upload command (Azure CLI):"
echo ""
echo "Option 1: Using storage account key (recommended if you have access):"
echo "  # Get storage account key first:"
echo "  STORAGE_KEY=\$(az storage account keys list \\"
echo "    --account-name lokibootcstorage \\"
echo "    --resource-group <your-resource-group> \\"
echo "    --query '[0].value' -o tsv)"
echo ""
echo "  az storage blob upload \\"
echo "    --account-name lokibootcstorage \\"
echo "    --account-key \"\${STORAGE_KEY}\" \\"
echo "    --container-name vhds \\"
echo "    --name rhoim-bootc-rhel.vhd \\"
echo "    --file ${VHD_FILE} \\"
echo "    --type page"
echo ""
echo "Option 2: Using Azure AD (requires RBAC role assignment):"
echo "  # You need 'Storage Blob Data Contributor' role on the storage account"
echo "  az storage blob upload \\"
echo "    --account-name lokibootcstorage \\"
echo "    --container-name vhds \\"
echo "    --name rhoim-bootc-rhel.vhd \\"
echo "    --file ${VHD_FILE} \\"
echo "    --type page \\"
echo "    --auth-mode login"

