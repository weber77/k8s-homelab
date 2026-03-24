#!/usr/bin/env bash
set -e

usage() {
  cat <<'EOF'
Tear down Kubernetes lab VMs created by create-vms.sh / cluster.sh.

Usage:
  sudo ./purge-cluster.sh [options]

Options:
  -p, --prefix <name>   VM name prefix (default: k8s)
  --base-image <path>   Base image path when using --remove-base (default:
                        /var/lib/libvirt/images/k8s-base.qcow2)
  --remove-base         Also delete the golden base qcow2 (recreate with
                        ./cluster.sh --prepare-image or prepare-image.sh)
  --include-tmp         Also destroy leftover tmp-* domains from prepare-image
  -y, --yes             Do not prompt for confirmation
  -h, --help            Show this help

Examples:
  sudo ./purge-cluster.sh
  sudo ./purge-cluster.sh -p dev -y
  sudo ./purge-cluster.sh --remove-base -y
EOF
}

PREFIX="k8s"
IMAGE_DIR="/var/lib/libvirt/images"
BASE_IMAGE="${IMAGE_DIR}/k8s-base.qcow2"
REMOVE_BASE=false
INCLUDE_TMP=false
YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--prefix)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --prefix requires a value" >&2
        exit 1
      fi
      PREFIX="$2"
      shift 2
      ;;
    --base-image)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --base-image requires a path" >&2
        exit 1
      fi
      BASE_IMAGE="$2"
      shift 2
      ;;
    --remove-base)
      REMOVE_BASE=true
      shift
      ;;
    --include-tmp)
      INCLUDE_TMP=true
      shift
      ;;
    -y|--yes)
      YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root (sudo); libvirt and image paths require it." >&2
  exit 1
fi

if ! command -v virsh >/dev/null 2>&1; then
  echo "virsh not found; install libvirt-clients." >&2
  exit 1
fi

collect_domains() {
  local names=()
  local name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if [[ "$name" == "$PREFIX"-[a-z] ]]; then
      names+=("$name")
    fi
  done < <(virsh list --all --name 2>/dev/null || true)

  if [[ "$INCLUDE_TMP" == true ]]; then
    while IFS= read -r name; do
      [[ -z "$name" ]] && continue
      if [[ "$name" == tmp-[a-z] ]]; then
        names+=("$name")
      fi
    done < <(virsh list --all --name 2>/dev/null || true)
  fi

  if [[ ${#names[@]} -eq 0 ]]; then
    return 0
  fi
  printf '%s\n' "${names[@]}" | sort -u
}

DOMAINS=()
while IFS= read -r d; do
  [[ -n "$d" ]] && DOMAINS+=("$d")
done < <(collect_domains || true)

echo "======================================"
echo "Purge cluster VMs"
echo "Prefix: $PREFIX"
echo "Image dir: $IMAGE_DIR"
if [[ ${#DOMAINS[@]} -gt 0 ]]; then
  echo "Domains to remove:"
  printf '  %s\n' "${DOMAINS[@]}"
else
  echo "No matching libvirt domains (expected names like ${PREFIX}-a, ${PREFIX}-b)."
fi
if [[ "$REMOVE_BASE" == true ]]; then
  echo "Will remove base image: $BASE_IMAGE"
fi
echo "======================================"

if [[ "$YES" != true ]]; then
  read -r -p "Continue? [y/N] " reply
  case "$reply" in
    [yY][eE][sS]|[yY]) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

for name in "${DOMAINS[@]}"; do
  state=$(virsh domstate "$name" 2>/dev/null || echo "missing")
  if [[ "$state" != "missing" ]]; then
    if [[ "$state" == "running" ]] || [[ "$state" == "paused" ]]; then
      echo "Destroying $name (was: $state)..."
      virsh destroy "$name" || true
    fi
    echo "Undefining $name..."
    virsh undefine "$name" --remove-all-storage 2>/dev/null || virsh undefine "$name" || true
  fi
done

# Remove disk and seed files even if domain was already undefined.
shopt -s nullglob
for f in "$IMAGE_DIR/${PREFIX}"-*.qcow2 "$IMAGE_DIR/${PREFIX}"-*-seed.iso; do
  [[ -e "$f" ]] || continue
  echo "Removing $f"
  rm -f "$f"
done

if [[ "$INCLUDE_TMP" == true ]]; then
  for f in "$IMAGE_DIR/tmp"-*.qcow2 "$IMAGE_DIR/tmp"-*-seed.iso; do
    [[ -e "$f" ]] || continue
    echo "Removing $f"
    rm -f "$f"
  done
fi
shopt -u nullglob

rm -rf /tmp/"${PREFIX}"-*-cloudinit
if [[ "$INCLUDE_TMP" == true ]]; then
  rm -rf /tmp/tmp-*-cloudinit
fi

if [[ "$REMOVE_BASE" == true ]]; then
  if [[ -f "$BASE_IMAGE" ]]; then
    echo "Removing base image $BASE_IMAGE"
    rm -f "$BASE_IMAGE"
  else
    echo "Base image not present: $BASE_IMAGE"
  fi
fi

echo "Done."
