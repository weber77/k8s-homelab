#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  update-user-rbac.sh (--add | --remove) [options] <username>

  Add or remove Role + RoleBinding for <username>. Checks that the current
  context user has permission before applying changes.

Options:
  --add                    Create/update RBAC (apply from <username>/rbac.yaml)
  --remove                 Remove RBAC for user in the given namespace
  -n, --namespace <ns>      Namespace (required for --remove; for --add used with -r/-R)
  -r, --roles <verbs>      Comma-separated verbs (only with --add and -n; default: get,watch,list)
  -R, --resource <res>      Comma-separated resources (only with --add and -n; default: pods)
  -h, --help                Show help

Examples:
  update-user-rbac.sh --add alice
  update-user-rbac.sh --add -n default -r get,list -R pods alice
  update-user-rbac.sh --remove -n default alice
EOF
}

trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

csv_to_inline_yaml_array() {
  local csv="${1:-}"
  local -a parts
  local out=""

  IFS=',' read -r -a parts <<<"${csv}"
  for part in "${parts[@]}"; do
    part="$(trim "${part}")"
    [[ -n "${part}" ]] || continue
    part="${part//\"/\\\"}"
    if [[ -n "${out}" ]]; then
      out+=", "
    fi
    out+="\"${part}\""
  done

  if [[ -z "${out}" ]]; then
    echo "Error: list cannot be empty: '${csv}'" >&2
    exit 2
  fi

  printf '%s' "${out}"
}

# Check if current context user can perform an action. Exits if not.
check_can_i() {
  local result
  result="$(kubectl auth can-i "$@" 2>/dev/null || true)"
  if [[ "${result}" != "yes" ]]; then
    echo "Error: current user cannot '$*' (got: ${result:-unknown})" >&2
    echo "Run with a context that has permission to manage Role and RoleBinding in the namespace." >&2
    exit 1
  fi
}

ACTION=""
USERNAME=""
NAMESPACE=""
RBAC_VERBS="get,watch,list"
RBAC_RESOURCES="pods"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --add)
      ACTION="add"
      shift
      ;;
    --remove)
      ACTION="remove"
      shift
      ;;
    -n|--namespace)
      NAMESPACE="${2:-}"
      shift 2
      ;;
    -r|--roles)
      RBAC_VERBS="${2:-}"
      shift 2
      ;;
    -R|--resource|--resources)
      RBAC_RESOURCES="${2:-}"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [[ -z "${USERNAME}" ]]; then
        USERNAME="$1"
        shift
      else
        echo "Error: unexpected extra argument: $1" >&2
        usage >&2
        exit 2
      fi
      ;;
  esac
done

if [[ -z "${USERNAME}" && $# -gt 0 ]]; then
  USERNAME="$1"
  shift
fi

if [[ -z "${ACTION}" ]]; then
  echo "Error: specify --add or --remove" >&2
  usage >&2
  exit 2
fi

if [[ -z "${USERNAME}" ]]; then
  echo "Error: username required" >&2
  usage >&2
  exit 2
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Error: kubectl not found" >&2
  exit 1
fi

OUT_DIR="${USERNAME}"
RBAC_YAML="${OUT_DIR}/rbac.yaml"

if [[ "${ACTION}" == "add" ]]; then
  if [[ -n "${NAMESPACE}" ]]; then
    # Regenerate rbac.yaml with -n and optional -r, -R
    check_can_i create role -n "${NAMESPACE}"
    check_can_i create rolebinding -n "${NAMESPACE}"
    mkdir -p "${OUT_DIR}"
    cat > "${RBAC_YAML}" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: ${NAMESPACE}
  name: pod-reader
rules:
  - apiGroups: [""]
    resources: [$(csv_to_inline_yaml_array "${RBAC_RESOURCES}")]
    verbs: [$(csv_to_inline_yaml_array "${RBAC_VERBS}")]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: ${NAMESPACE}
subjects:
  - kind: User
    name: ${USERNAME}
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF
  else
    if [[ ! -f "${RBAC_YAML}" ]]; then
      echo "Error: ${RBAC_YAML} not found. Run with -n <namespace> (and optional -r, -R) to create RBAC." >&2
      exit 1
    fi
    # Get namespace from file for permission check (first namespace: in Role metadata)
    NAMESPACE="$(grep -m1 '^\s*namespace:' "${RBAC_YAML}" | sed 's/.*:\s*//' | tr -d ' ')"
    if [[ -z "${NAMESPACE}" ]]; then
      echo "Error: could not determine namespace from ${RBAC_YAML}" >&2
      exit 1
    fi
    check_can_i create role -n "${NAMESPACE}"
    check_can_i create rolebinding -n "${NAMESPACE}"
  fi

  kubectl apply -f "${RBAC_YAML}"
  echo "Applied RBAC for ${USERNAME} in namespace ${NAMESPACE}."

elif [[ "${ACTION}" == "remove" ]]; then
  if [[ -z "${NAMESPACE}" ]]; then
    echo "Error: --remove requires -n, --namespace" >&2
    usage >&2
    exit 2
  fi

  check_can_i delete role -n "${NAMESPACE}"
  check_can_i delete rolebinding -n "${NAMESPACE}"

  kubectl delete role pod-reader -n "${NAMESPACE}" --ignore-not-found
  kubectl delete rolebinding read-pods -n "${NAMESPACE}" --ignore-not-found
  echo "Removed RBAC for ${USERNAME} in namespace ${NAMESPACE}."
fi
