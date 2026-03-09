# k8s utils

## new-user.sh

**Where:** Run from your workstation (needs `kubectl` and cluster admin access).  
**What:** Creates a client certificate for a user via the Kubernetes CSR API and applies a Role + RoleBinding so that user has configurable RBAC permissions in a namespace. By default: read-only access to pods (`get`, `watch`, `list`) in the `default` namespace.

**Outputs:** All files are written into `<username>/`: `<username>.key`, `<username>.csr`, `<username>.crt`, `csr.yaml`, `rbac.yaml`.

**Usage:**

```bash
chmod +x new-user.sh
./new-user.sh [options] <username>
```

**Options:**

| Option | Description |
|--------|-------------|
| `-n`, `--namespace <ns>` | Namespace for Role/RoleBinding (default: `default`) |
| `-r`, `--roles <verbs>` | Comma-separated RBAC verbs (default: `get,watch,list`) |
| `-R`, `--resource <res>` | Comma-separated resources (default: `pods`) |
| `-h`, `--help` | Show help |

**Examples:**

```bash
./new-user.sh alice
./new-user.sh -n kube-system -R pods,services alice
./new-user.sh -r get,list -R pods,configmaps bob
```

---

## reset-k8s-node.sh

**Where:** Run **inside a VM** (e.g. over SSH or `virsh console`).  
**What:** Resets the node’s Kubernetes state: stops kubelet and containerd, runs `kubeadm reset`, removes Kubernetes/etcd/CNI configs and data, flushes iptables, then restarts containerd and kubelet. Use before re-joining a node or when rebuilding a cluster from scratch.

**Usage (inside the VM):**

```bash
chmod +x reset-k8s-node.sh
./reset-k8s-node.sh
```

If you copy the script into the VM, make it executable and run as user `ubuntu`. The script uses **sudo** for system and Kubernetes commands.
