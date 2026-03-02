#!/usr/bin/env bash
set -e

VM_NAME="${1:-}"

if [ -z "$VM_NAME" ]; then
  echo "ERROR: no VM name provided"
  echo "Usage: $0 <vm-name>"
  exit 1
fi

IMG_DIR="/var/lib/libvirt/images"
CLOUD_DIR="$HOME/cloudinit-$VM_NAME"

echo "=== Purging VM: $VM_NAME ==="

# -------------------------------------------------
# fail if VM does not exist
# -------------------------------------------------
if ! virsh dominfo "$VM_NAME" &>/dev/null; then
  echo "ERROR: VM '$VM_NAME' does not exist."
  exit 1
fi

# -------------------------------------------------
# destroy + undefine
# -------------------------------------------------
echo "Destroying existing VM..."
virsh destroy "$VM_NAME" 2>/dev/null || true
virsh undefine "$VM_NAME"

# -------------------------------------------------
# remove old disks + seed
# -------------------------------------------------
echo "Removing old images..."
sudo rm -f "$IMG_DIR/"*"$VM_NAME"*

# -------------------------------------------------
# remove cloud-init dir
# -------------------------------------------------
rm -rf "$CLOUD_DIR"

echo "=== $VM_NAME purged successfully === ✅"
