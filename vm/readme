# VM provisioning – order of use

## Order of use

1. **Install KVM on the host** (once per machine)  
   From the repo root:
   ```bash
   chmod +x install-kvm.sh
   ./install-kvm.sh
   ```
   You need **sudo** for this. After running, log out and back in (or reboot) so your user is in the `libvirt` and `kvm` groups.

2. **Create Kubernetes VMs**  
   From the `vm/` directory:
   ```bash
   chmod +x create-vms.sh
   ./create-vms.sh <number_of_vms>
   ```
   Example: `./create-vms.sh 4` creates `k8s-a`, `k8s-b`, `k8s-c`, `k8s-d`.  
   Each VM gets **20 GB disk** and **2 GB RAM** (recommended for k8s). You can reduce disk in **create-vms.sh** at **line 163**; do **not** reduce RAM (line 170) or the node may crash.  
   The script may prompt for **sudo** to install packages, manage libvirt, and write images. After KVM setup, `virsh` commands usually work without sudo if you are in the `libvirt` group.

## What the utils are for

| Util | Purpose |
|------|--------|
| **k8s/utils/reset-k8s-node.sh** | Run **inside a VM** to wipe Kubernetes (kubeadm reset, remove configs, free ports). Use when re-joining a node or starting a cluster from scratch. |
| **recreate-vm.sh** | Run **on the host**: destroy one VM, delete its disks, and recreate it from the same cloud image (fresh OS, new MAC). |
| **purge-vm.sh** | Run **on the host**: permanently remove one VM and all its disks. |

See `vm/utils/README.md` for how each file works and when to use **chmod +x** or **sudo**.

## chmod +x and sudo

- **Scripts:** Make them executable once:
  ```bash
  chmod +x create-vms.sh
  chmod +x utils/recreate-vm.sh
  chmod +x utils/purge-vm.sh
  chmod +x k8s/utils/reset-k8s-node.sh   # copy to VM or run from shared mount; run inside VM
  ```
- **When to use sudo:**
  - **install-kvm.sh** – always run as your user; the script uses `sudo` inside.
  - **create-k8s-vms.sh** – run as your user; it will use `sudo` when needed (apt, virsh net-define, image dir, etc.).
  - **recreate-vm.sh** / **purge-vm.sh** – run as your user; they use `sudo` only for removing files in `/var/lib/libvirt/images`. `virsh destroy/undefine` typically work without sudo if you are in `libvirt` group.
  - **k8s/utils/reset-k8s-node.sh** – run **inside the VM** as user `ubuntu`; the script uses `sudo` for system/kubernetes commands.

## List, start, stop, console (on the host)

- **List all VMs (including shut down):**
  ```bash
  virsh list --all
  ```
- **Start a VM:**
  ```bash
  virsh start <vm-name>
  ```
  Example: `virsh start k8s-a`
- **Stop a VM:**
  ```bash
  virsh shutdown <vm-name>
  ```
  Or force: `virsh destroy <vm-name>`
- **Open console (serial) into a VM:**
  ```bash
  virsh console <vm-name>
  ```
  To leave the console: press **Ctrl+]**  
  **Login:** username `ubuntu`, password `ubuntu`

## Get VM IPs (on the host)

```bash
virsh net-dhcp-leases default
```

Use the `ubuntu` / `ubuntu` login to SSH once you have the IP.
