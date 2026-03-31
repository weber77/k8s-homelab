# KVM Kubernetes Lab Automation

This repository automates a local KVM-based lab: **first install KVM on the host**, then **create n Ubuntu VMs** for Kubernetes (control plane, workers, load balancer, etc.) and related use cases.

## Project objectives

1. **Install and configure KVM** on an Ubuntu host (libvirt, networking, storage).
2. **Create n virtual machines** in one step for:
   - Kubernetes learning labs
   - Local cluster testing (control plane + workers)
   - Load balancer or extra nodes
   - Networking experiments
   - Infrastructure automation practice
   - Reproducible dev environments

Goal: quickly and repeatably spin up multi-node virtual infrastructure on a single machine with minimal manual setup.

---

## Quick start (order of operations)

### 1. Install KVM (once per host)

From the repo root:

```bash
chmod +x install-kvm.sh
./install-kvm.sh
```

The script uses **sudo** for packages and libvirt. After it finishes, **log out and back in** (or reboot) so your user is in the `libvirt` and `kvm` groups.

### 2. Create VMs

From the `vm/` directory:

```bash
chmod +x create-vms.sh
./create-vms.sh <number_of_vms>
```

Example: `./create-vms.sh 4` creates `k8s-a`, `k8s-b`, `k8s-c`, `k8s-d`.  
The script may use **sudo** when needed; you do not need to run the script itself with `sudo`.

More detail (list/start/stop/console, utils, credentials): see **vm/readme**.

---

## VM resources (per VM)

Each VM is created with **20 GB disk** and **2 GB RAM** — recommended for running Kubernetes nodes.

- **Storage:** You can reduce disk size by editing **vm/create-vms.sh** at **line 163** (`qemu-img resize`). Use a smaller value than `20G` if you need to save host disk space.
- **RAM:** Do **not** reduce the 2 GB memory (line 170, `--memory 2048`). Lower values can cause nodes to crash or become unstable under Kubernetes.

---

## What’s included

| Component            | Description                                                                                                                                                                                      |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| **install-kvm.sh**   | Installs KVM, libvirt, virtinst, cloud-image-utils; configures default network and storage; adds user to `libvirt`/`kvm` groups. Handles common conflicts (e.g. container runtimes and bridges). |
| **vm/create-vms.sh** | Creates any number of Ubuntu 22.04 cloud-init VMs (batch, SSH-ready, suitable for Kubernetes nodes).                                                                                             |
| **vm/utils/**        | Host scripts: recreate one VM from scratch, or purge one VM. See **vm/utils/README.md**.                                                                                                         |
| **k8s/utils/**       | **k8s/utils/reset-k8s-node.sh** — run inside a VM to reset that node’s Kubernetes state.                                                                                                         |

---

## Bootstrap control plane and worker nodes

After VMs are created (for example `k8s-a` and `k8s-b`), use two terminals:

### 1. Configure control plane (`k8s-a`)

On your host:

```bash
virsh console k8s-a
```

Inside `k8s-a`, run:

```bash
cd /path/to/Self-Hosted-Kubernetes-/k8s/setup
chmod +x control-plane-node.sh
./control-plane-node.sh
```

At the end, copy the `kubeadm join ...` command shown by the control-plane setup.

### 2. Configure worker (`k8s-b`) in another terminal

On your host (second terminal):

```bash
virsh console k8s-b
```

Inside `k8s-b`, create and run the worker setup script:

```bash
cd /path/to/Self-Hosted-Kubernetes-/k8s/setup
chmod +x worker-node.sh
./worker-node.sh
```

Then paste and run the join command copied from `k8s-a`:

```bash
sudo kubeadm join <control-plane-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

### 3. Verify nodes from control plane

Back on `k8s-a`, check cluster nodes:

```bash
kubectl get nodes
```

You should see both control-plane and worker nodes in `Ready` state.

---

## Roadmap: scripts to guided setup

The project is currently script-first. Public roadmap updates are shared one phase at a time.

### Phase 1 (near term): stabilize and standardize script workflows

Progress checklist:

- [x] Script-first automation baseline exists (`install-kvm.sh`, VM creation scripts, reset utilities).
- [x] Create cluster script.
- [x] Consolidate VM and Kubernetes setup flags into one documented config file (defaults + overrides).
- [x] Add stronger preflight checks (CPU virtualization, disk space, libvirt status, network bridge availability).
- [ ] Improve error messages and recovery steps so failures are actionable.
- [ ] Add non-interactive mode support for repeatable local automation and CI-style validation.

---

## Requirements

- Ubuntu host (recommended)
- Internet connection
- sudo privileges
- CPU virtualization enabled (Intel VT-x / AMD-V)

---

## VM credentials

- **Username:** `ubuntu`
- **Password:** `ubuntu`

Use these for console login (`virsh console <vm-name>`) and SSH.

---

## chmod +x and sudo

- **chmod +x** (run once per script):
  - `chmod +x install-kvm.sh`
  - `chmod +x vm/create-vms.sh`
  - For utils: `chmod +x vm/utils/recreate-vm.sh vm/utils/purge-vm.sh` and `chmod +x k8s/utils/reset-k8s-node.sh` (run the latter inside a VM when resetting that node).
- **sudo:** Run scripts as your normal user. They call `sudo` internally when needed. Do **not** run the scripts as `sudo` (e.g. `sudo ./install-kvm.sh`); run `./install-kvm.sh` and enter your password when prompted.
