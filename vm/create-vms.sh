#!/usr/bin/env bash
set -e

usage() {
  cat <<'EOF'
Usage:
  create-vms.sh [options] <number_of_vms>

Options:
  -p, --prefix <prefix>   VM name prefix (default: k8s)
  -h, --help              Show this help

Examples:
  create-vms.sh 3
  create-vms.sh --prefix dev 2
EOF
}

PREFIX="k8s"
VM_COUNT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--prefix)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --prefix requires a value" >&2
        usage
        exit 1
      fi
      PREFIX="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      if [[ -n "$VM_COUNT" ]]; then
        echo "Error: unexpected argument: $1" >&2
        usage
        exit 1
      fi
      VM_COUNT="$1"
      shift
      ;;
  esac
done

if [[ -z "$VM_COUNT" ]]; then
  usage
  exit 1
fi

if ! [[ "$VM_COUNT" =~ ^[0-9]+$ ]] || [[ "$VM_COUNT" -le 0 ]]; then
  echo "Error: <number_of_vms> must be a positive integer" >&2
  exit 1
fi

BASE_IMAGE="/var/lib/libvirt/images/jammy-server-cloudimg-amd64.img"
IMAGE_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
IMAGE_DIR="/var/lib/libvirt/images"

# Per-VM resource usage (must match virt-install and qemu-img below)
DISK_PER_VM_GB=20
RAM_PER_VM_MB=2048
# Minimum to leave for the host so it stays usable
HOST_RAM_RESERVE_MB=2048
HOST_DISK_RESERVE_GB=5

echo "======================================"
echo "Kubernetes VM Provisioner"
echo "VMs requested: $VM_COUNT"
echo "VM name prefix: $PREFIX"
echo "======================================"

# ------------------------------------------------
# Ensure required tools exist
# ------------------------------------------------
echo "Checking required packages..."

REQUIRED_PKGS=(
  qemu-kvm
  libvirt-daemon-system
  libvirt-clients
  virtinst
  cloud-image-utils
  wget
)

for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! dpkg -s "$pkg" &>/dev/null; then
    echo "Installing $pkg"
    sudo apt-get update
    sudo apt-get install -y "$pkg"
  fi
done

# ------------------------------------------------
# Ensure libvirt service running
# ------------------------------------------------
echo "Checking libvirtd..."

sudo systemctl enable --now libvirtd

# ------------------------------------------------
# Ensure default network exists
# ------------------------------------------------
if ! sudo virsh net-info default &>/dev/null; then
  echo "Creating default libvirt network..."

  cat <<EOF | sudo tee /tmp/default-network.xml
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.122.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.122.100' end='192.168.122.254'/>
    </dhcp>
  </ip>
</network>
EOF

  sudo virsh net-define /tmp/default-network.xml
  sudo virsh net-start default
  sudo virsh net-autostart default
fi

if [ ! -d "$IMAGE_DIR" ]; then
  echo "Creating image directory $IMAGE_DIR"
  sudo mkdir -p "$IMAGE_DIR"
fi

# ------------------------------------------------
# Ensure Ubuntu cloud image exists
# ------------------------------------------------
echo "=== Checking Ubuntu cloud image... ==="

if [ ! -f "$BASE_IMAGE" ]; then
  echo "Downloading Ubuntu 22.04 cloud image..."
  sudo wget -O "$BASE_IMAGE" "$IMAGE_URL"
else
  echo "Image already exists"
fi

echo
echo "======================================"
echo "Creating VMs"
echo "======================================"

START_INDEX=0
while IFS= read -r existing_name; do
  [[ -z "$existing_name" ]] && continue
  if [[ "$existing_name" == "$PREFIX"-[a-z] ]]; then
    suffix="${existing_name#"$PREFIX"-}"
    ord=$(printf '%d' "'$suffix")
    idx=$((ord - 97))
    if [[ "$idx" -ge "$START_INDEX" ]]; then
      START_INDEX=$((idx + 1))
    fi
  fi
done < <(sudo virsh list --all --name || true)

# ------------------------------------------------
# Check host has enough resources for requested VMs
# ------------------------------------------------
echo "Checking host resources..."
DISK_NEEDED_KB=$(( (VM_COUNT * DISK_PER_VM_GB * 1024 * 1024) + (HOST_DISK_RESERVE_GB * 1024 * 1024) ))
RAM_NEEDED_KB=$(( (VM_COUNT * RAM_PER_VM_MB * 1024) + (HOST_RAM_RESERVE_MB * 1024) ))

CHECK_DIR="$IMAGE_DIR"
[[ ! -d "$CHECK_DIR" ]] && CHECK_DIR="/var/lib/libvirt"
AVAIL_DISK_KB=$(df -k "/var/lib/libvirt/images" 2>/dev/null | tail -1 | awk '{print $4}')
AVAIL_RAM_KB=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || awk '/MemFree:/ {print $2}' /proc/meminfo 2>/dev/null)

FAIL=0
if [[ -z "$AVAIL_DISK_KB" ]] || [[ "$AVAIL_DISK_KB" -lt "$DISK_NEEDED_KB" ]]; then
  echo "Error: Not enough disk space."
  echo "  Need: $(( DISK_NEEDED_KB / 1024 / 1024 )) GB (${VM_COUNT} VMs × ${DISK_PER_VM_GB} GB + ${HOST_DISK_RESERVE_GB} GB reserve)"
  echo "  Available on $(df -h "$CHECK_DIR" 2>/dev/null | tail -1 | awk '{print $1}'): $(df -h "$CHECK_DIR" 2>/dev/null | tail -1 | awk '{print $4}')"
  FAIL=1
fi
if [[ -z "$AVAIL_RAM_KB" ]] || [[ "$AVAIL_RAM_KB" -lt "$RAM_NEEDED_KB" ]]; then
  echo "Error: Not enough memory."
  echo "  Need: $(( RAM_NEEDED_KB / 1024 )) MB (${VM_COUNT} VMs × ${RAM_PER_VM_MB} MB + ${HOST_RAM_RESERVE_MB} MB reserve)"
  if [[ -n "$AVAIL_RAM_KB" ]]; then
    echo "  Available: $(( AVAIL_RAM_KB / 1024 )) MB"
  else
    echo "  Available: unknown (could not read /proc/meminfo — are you on Linux?)"
  fi
  FAIL=1
fi
if [[ "$FAIL" -eq 1 ]]; then
  # Compute max VMs that could be created with current resources
  DISK_PER_VM_KB=$(( DISK_PER_VM_GB * 1024 * 1024 ))
  RAM_PER_VM_KB=$(( RAM_PER_VM_MB * 1024 ))
  HOST_DISK_RESERVE_KB=$(( HOST_DISK_RESERVE_GB * 1024 * 1024 ))
  HOST_RAM_RESERVE_KB=$(( HOST_RAM_RESERVE_MB * 1024 ))
  MAX_FROM_DISK=0
  MAX_FROM_RAM=0
  [[ -n "$AVAIL_DISK_KB" ]] && [[ "$AVAIL_DISK_KB" -gt "$HOST_DISK_RESERVE_KB" ]] && MAX_FROM_DISK=$(( (AVAIL_DISK_KB - HOST_DISK_RESERVE_KB) / DISK_PER_VM_KB ))
  [[ -n "$AVAIL_RAM_KB" ]] && [[ "$AVAIL_RAM_KB" -gt "$HOST_RAM_RESERVE_KB" ]] && MAX_FROM_RAM=$(( (AVAIL_RAM_KB - HOST_RAM_RESERVE_KB) / RAM_PER_VM_KB ))
  if [[ "$MAX_FROM_DISK" -le "$MAX_FROM_RAM" ]]; then MAX_VMS=$MAX_FROM_DISK; else MAX_VMS=$MAX_FROM_RAM; fi
  echo "With current resources you can create at most $MAX_VMS VM(s)."
  echo "Refusing to create VMs to avoid running critically low on resources." >&2
  exit 1
fi
echo "  Disk: OK (need $(( DISK_NEEDED_KB / 1024 / 1024 )) GB, have $(( AVAIL_DISK_KB / 1024 / 1024 )) GB)"
echo "  RAM:  OK (need $(( RAM_NEEDED_KB / 1024 )) MB, have $(( AVAIL_RAM_KB / 1024 )) MB)"
echo

for i in $(seq "$START_INDEX" $((START_INDEX + VM_COUNT - 1))); do

  LETTER=$(printf "\\$(printf '%03o' $((97+i)))")
  VM_NAME="${PREFIX}-${LETTER}"

  DISK="/var/lib/libvirt/images/${VM_NAME}.qcow2"
  SEED="/var/lib/libvirt/images/${VM_NAME}-seed.iso"
  WORKDIR="/tmp/${VM_NAME}-cloudinit"

  echo "----- $VM_NAME -----"

  if sudo virsh dominfo "$VM_NAME" &>/dev/null; then
    echo "$VM_NAME already exists — skipping"
    continue
  fi

  mkdir -p "$WORKDIR"

  # ------------------------------------------------
  # Generate MAC
  # ------------------------------------------------
  MAC=$(printf '52:54:00:%02x:%02x:%02x\n' \
      $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)))

  echo "MAC: $MAC"

  # ------------------------------------------------
  # Cloud-init user-data
  # ------------------------------------------------
  cat > "$WORKDIR/user-data" <<EOF
#cloud-config
hostname: $VM_NAME

users:
  - name: ubuntu
    groups: sudo
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL

ssh_pwauth: true

chpasswd:
  list: |
    ubuntu:ubuntu
  expire: false

package_update: true

packages:
  - qemu-guest-agent

runcmd:
  - systemctl enable --now qemu-guest-agent
EOF

  cat > "$WORKDIR/meta-data" <<EOF
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF

  cloud-localds "$WORKDIR/seed.iso" "$WORKDIR/user-data" "$WORKDIR/meta-data"

  sudo mv "$WORKDIR/seed.iso" "$SEED"

  # ------------------------------------------------
  # Create VM disk
  # ------------------------------------------------
  sudo qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$DISK"
  sudo qemu-img resize "$DISK" ${DISK_PER_VM_GB}G 
  
  # ------------------------------------------------
  # Create VM
  # ------------------------------------------------
  virt-install \
    --name "$VM_NAME" \
    --memory "$RAM_PER_VM_MB" \
    --vcpus 2 \
    --disk path="$DISK",format=qcow2 \
    --disk path="$SEED",device=cdrom \
    --import \
    --network network=default,mac="$MAC" \
    --graphics none \
    --osinfo ubuntu22.04 \
    --noautoconsole

  echo "$VM_NAME created"
  echo

done

echo "======================================"
echo "VM creation finished"
echo "======================================"

# Remaining capacity: how many more VMs can be created with current resources
CHECK_DIR="$IMAGE_DIR"
[[ ! -d "$CHECK_DIR" ]] && CHECK_DIR="/var/lib/libvirt"
AVAIL_DISK_KB=$(df -k "$CHECK_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
AVAIL_RAM_KB=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || awk '/MemFree:/ {print $2}' /proc/meminfo 2>/dev/null)
DISK_PER_VM_KB=$(( DISK_PER_VM_GB * 1024 * 1024 ))
RAM_PER_VM_KB=$(( RAM_PER_VM_MB * 1024 ))
HOST_DISK_RESERVE_KB=$(( HOST_DISK_RESERVE_GB * 1024 * 1024 ))
HOST_RAM_RESERVE_KB=$(( HOST_RAM_RESERVE_MB * 1024 ))
MAX_FROM_DISK=0
MAX_FROM_RAM=0
[[ -n "$AVAIL_DISK_KB" ]] && [[ "$AVAIL_DISK_KB" -gt "$HOST_DISK_RESERVE_KB" ]] && MAX_FROM_DISK=$(( (AVAIL_DISK_KB - HOST_DISK_RESERVE_KB) / DISK_PER_VM_KB ))
[[ -n "$AVAIL_RAM_KB" ]] && [[ "$AVAIL_RAM_KB" -gt "$HOST_RAM_RESERVE_KB" ]] && MAX_FROM_RAM=$(( (AVAIL_RAM_KB - HOST_RAM_RESERVE_KB) / RAM_PER_VM_KB ))
if [[ "$MAX_FROM_DISK" -le "$MAX_FROM_RAM" ]]; then REMAINING_MAX_VMS=$MAX_FROM_DISK; else REMAINING_MAX_VMS=$MAX_FROM_RAM; fi
echo
echo "With remaining resources you can create up to $REMAINING_MAX_VMS more VM(s) (${DISK_PER_VM_GB}G disk, ${RAM_PER_VM_MB}MB RAM each)."

echo
echo "VM list:"
echo "virsh list --all"

echo
echo "Get VM IPs:"
echo "virsh net-dhcp-leases default"
