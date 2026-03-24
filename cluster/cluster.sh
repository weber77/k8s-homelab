#!/usr/bin/env bash
set -e

print_manual() {
  echo "Manual:"
  echo "  ./cluster.sh --control-plane --workers 2"
  echo "  ./cluster.sh --workers 2"
  echo "  ./cluster.sh --workers 2 --worker-only"
  echo "  ./cluster.sh --prepare-image"
  echo "  ./cluster.sh --base-image <path>"
  echo "  sudo ./purge-cluster.sh   # tear down VMs (see purge-cluster.sh --help)"
}

ensure_sshpass() {
  if command -v sshpass >/dev/null 2>&1; then
    return 0
  fi
  echo "sshpass not found; installing..."
  case "$(uname -s)" in
    Darwin)
      if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew is required to install sshpass on macOS." >&2
        exit 1
      fi
      if ! brew install hudochenkov/sshpass/sshpass 2>/dev/null; then
        brew tap esolitos/ipa >/dev/null 2>&1 || true
        brew install esolitos/ipa/sshpass || {
          echo "Could not install sshpass via Homebrew." >&2
          exit 1
        }
      fi
      ;;
    Linux)
      if [ -f /etc/debian_version ]; then
        sudo apt-get update -qq && sudo apt-get install -y sshpass
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y sshpass
      elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y sshpass
      elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm sshpass
      else
        echo "Could not detect package manager; install sshpass manually." >&2
        exit 1
      fi
      ;;
    *)
      echo "Unsupported OS; install sshpass manually." >&2
      exit 1
      ;;
  esac
  command -v sshpass >/dev/null 2>&1 || {
    echo "sshpass install failed." >&2
    exit 1
  }
}
SSH_PASS="ubuntu"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

BASE_IMAGE="/var/lib/libvirt/images/k8s-base.qcow2"
WORKERS=0
WORKER_ONLY=false
CONTROL_PLANE=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      print_manual
      exit 0
      ;;
    --workers)
      WORKERS="$2"
      shift 2
      ;;
    --worker-only)
      WORKER_ONLY=true
      CONTROL_PLANE=false
      shift
      ;;
    --control-plane)
      CONTROL_PLANE=true
      shift
      ;;
    --prepare-image)
      ensure_sshpass
      ./prepare-image.sh
      exit 0
      ;;
    --base-image)
      BASE_IMAGE="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1"
      exit 1
      ;;
  esac
done

if [ ! -f "$BASE_IMAGE" ]; then
  echo "Base image not found. Preparing..."
  ensure_sshpass
  ./prepare-image.sh --output "$BASE_IMAGE"
else
  echo "Using existing base image: $BASE_IMAGE"
fi

TOTAL=$WORKERS
if [ "$CONTROL_PLANE" = true ]; then
  TOTAL=$((WORKERS + 1))
fi

echo "Creating $TOTAL VMs..."
BASE_IMAGE_OVERRIDE="$BASE_IMAGE" ./create-vms.sh "$TOTAL"

echo "Waiting for VMs to get IPs..."
sleep 10

IPS=()

echo "Waiting for VMs to get IPs..."

IPS=()

for vm in $(virsh list --name | grep k8s); do
  echo "Resolving IP for $vm..."

  VM_IP=""

  while [ -z "$VM_IP" ]; do
    VM_MAC=$(virsh dumpxml "$vm" | awk -F\' '/mac address/ {print $2}')

    VM_IP=$(virsh net-dhcp-leases default \
      | grep -i "$VM_MAC" \
      | awk '{for(i=1;i<=NF;i++) if($i ~ /\//) print $i}' \
      | cut -d/ -f1)

    if [ -z "$VM_IP" ]; then
      echo "  waiting for DHCP..."
      sleep 2
    fi
  done

  echo "$vm IP: $VM_IP"
  IPS+=("$VM_IP")
done

CONTROL_IP=""
WORKER_IPS=()

if [ "$CONTROL_PLANE" = true ]; then
  CONTROL_IP=${IPS[0]}
  WORKER_IPS=("${IPS[@]:1}")
else
  WORKER_IPS=("${IPS[@]}")
fi

ensure_sshpass

if [ "$CONTROL_PLANE" = true ]; then
  echo "Waiting for SSH on control plane..."

until sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@$CONTROL_IP "echo ok" 2>/dev/null; do
  sleep 3
done

echo "Initializing control plane..."

sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@$CONTROL_IP 'bash -s' <<'EOF'
cloud-init status --wait

sudo systemctl restart containerd
sudo systemctl restart kubelet

sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --kubernetes-version=v1.33.0 \
  --ignore-preflight-errors=all \
  --cri-socket unix:///run/containerd/containerd.sock

mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl apply -f https://github.com/coreos/flannel/raw/master/Documentation/kube-flannel.yml

kubectl taint nodes $(hostname) node-role.kubernetes.io/control-plane:NoSchedule-

kubeadm token create --print-join-command > /tmp/join.sh
EOF

JOIN_CMD=$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@$CONTROL_IP "cat /tmp/join.sh")
fi

for ip in "${WORKER_IPS[@]}"; do
  echo "Waiting for SSH on worker $ip..."

  until sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@$ip "echo ok" 2>/dev/null; do
    sleep 3
  done

  echo "Joining worker $ip"
  sshpass -p "$SSH_PASS" ssh $SSH_OPTS ubuntu@$ip "cloud-init status --wait && sudo $JOIN_CMD"
done

echo "Cluster ready 🚀"