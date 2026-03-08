# VM utils – what each file does

These utilities help you manage VMs (recreate or purge). Run them on your **KVM host**.  
For resetting Kubernetes on a node (inside a VM), see **k8s/utils/reset-k8s-node.sh**.

---

## Make scripts executable (once)

```bash
chmod +x recreate-vm.sh
chmod +x purge-vm.sh
```

---

## recreate-vm.sh

**Where:** On the **host**.  
**What:** Destroys the given VM, deletes its disk and seed ISO, then recreates it from the same Ubuntu cloud image (new MAC, fresh cloud-init). Use when you want one VM reset to a clean OS without touching the others.

**Usage:**

```bash
./recreate-vm.sh <vm-name>
```

Example: `./recreate-vm.sh k8s-a`

**sudo:** Run as your user. The script uses `sudo` only when removing or writing files in `/var/lib/libvirt/images`. `virsh destroy` / `virsh undefine` / `virt-install` usually work without sudo if you are in the `libvirt` group.

**Note:** Expects the base image at `/var/lib/libvirt/images/jammy-server-cloudimg-amd64.img` (same as `create-k8s-vms.sh`). Seed ISO naming is `seed-<vm-name>.iso` (slightly different from `create-k8s-vms.sh`, which uses `<vm-name>-seed.iso`).

---

## purge-vm.sh

**Where:** On the **host**.  
**What:** Permanently removes one VM: shuts it down, undefines it, and deletes its disk(s) and seed ISO. Use when you no longer need that VM.

**Usage:**

```bash
./purge-vm.sh <vm-name>
```

Example: `./purge-vm.sh k8s-d`

**sudo:** Run as your user. The script uses `sudo` only for deleting files in `/var/lib/libvirt/images`. `virsh destroy` / `virsh undefine` work without sudo if you are in the `libvirt` group.

---

## Summary

| File             | Run on  | Purpose                          | chmod +x | sudo (inside script) |
|------------------|---------|----------------------------------|----------|-----------------------|
| recreate-vm.sh   | Host    | Rebuild one VM from cloud image  | Yes      | For image dir only    |
| purge-vm.sh      | Host    | Remove one VM and its disks      | Yes      | For image dir only    |

**Kubernetes node reset** (run inside a VM): **k8s/utils/reset-k8s-node.sh** — see that file or run `chmod +x reset-k8s-node.sh && ./reset-k8s-node.sh` inside the VM.
