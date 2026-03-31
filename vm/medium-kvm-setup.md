# Setting Up KVM on Ubuntu: A Foundation for Your Kubernetes Homelab

Before you can run a local Kubernetes cluster, you need somewhere to run it. Unless you have a rack of spare machines, that usually means virtual machines — and on Linux, KVM is the hypervisor that's already built into your kernel.
This guide walks through installing and configuring KVM on Ubuntu so you can spin up VMs for a Kubernetes lab (or anything else) on a single physical machine.

---

## Why KVM?

KVM (Kernel-based Virtual Machine) turns your Linux host into a Type-1 hypervisor. It's not an application sitting on top of your OS like VirtualBox — it runs directly in the kernel, which means near-native performance for your VMs.
For a Kubernetes homelab, this matters. You'll be running multiple VMs simultaneously (control planes, workers, maybe a load balancer), and the overhead adds up. KVM keeps it minimal.

---

## What you need

- An Ubuntu host (22.04+ recommended, but any recent LTS works)
- CPU virtualization enabled in BIOS/UEFI (Intel VT-x or AMD-V)
- sudo privileges
- Enough RAM and disk for the VMs you plan to create (2 GB RAM and 20 GB disk per VM is a reasonable baseline for Kubernetes nodes)
  Check if your CPU supports virtualization:

```bash
egrep -c '(vmx|svm)' /proc/cpuinfo
```

## If the output is `0`, you need to enable virtualization in your BIOS settings before continuing.

## Step 1: Install the virtualization stack

KVM itself is just the kernel module. You also need the userspace tools to manage VMs, networks, and disk images.

```bash
sudo apt update
sudo apt install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  virtinst \
  bridge-utils \
  cloud-image-utils \
  qemu-utils
```

What each package does:
| Package | Purpose |
|---|---|
| `qemu-kvm` | The QEMU emulator with KVM acceleration |
| `libvirt-daemon-system` | The libvirt daemon that manages VMs, networks, and storage |
| `libvirt-clients` | CLI tools like `virsh` for interacting with libvirt |
| `virtinst` | `virt-install` command for creating VMs from the terminal |
| `bridge-utils` | Network bridge utilities (used by libvirt's default NAT network) |
| `cloud-image-utils` | Tools for building cloud-init seed ISOs (used to configure VMs on first boot) |
| `qemu-utils` | Disk image utilities like `qemu-img` for creating and resizing VM disks |

---

## Step 2: Enable and start libvirt

```bash
sudo systemctl enable --now libvirtd
```

## This starts the libvirt daemon and ensures it comes back after a reboot.

## Step 3: Add your user to the right groups

By default, managing VMs through libvirt requires root. Adding your user to the `libvirt` and `kvm` groups lets you run VM commands without `sudo`:

```bash
sudo usermod -aG libvirt "$USER"
sudo usermod -aG kvm "$USER"
```

## **Important:** Group membership changes don't take effect in your current session. You need to **log out and back in** (or reboot) before this works.

## Step 4: Set up the default network

Libvirt ships with a default NAT network (`192.168.122.0/24`) that gives your VMs internet access through the host. Sometimes it needs a nudge to start, especially if you've had Docker or another container runtime installed (they can conflict with the `virbr0` bridge).

```bash
# Recreate the default network if it's missing or broken
if ! sudo virsh net-info default &>/dev/null; then
  echo "Recreating default libvirt network..."
  sudo virsh net-define /usr/share/libvirt/networks/default.xml
fi
sudo virsh net-autostart default
sudo virsh net-start default
```

Verify:

```bash
sudo virsh net-list
```

## You should see `default` listed as active and autostarting.

## Step 5: Prepare the storage directory

Libvirt stores VM disk images in `/var/lib/libvirt/images` by default. Make sure it exists with the right permissions:

```bash
sudo mkdir -p /var/lib/libvirt/images
sudo chown root:libvirt /var/lib/libvirt/images
sudo chmod 2770 /var/lib/libvirt/images
```

## The `2770` permission (setgid) means files created in this directory inherit the `libvirt` group, which avoids permission issues when creating and managing VM disks.

## Verify the installation

After logging out and back in (for the group changes), run:

```bash
virsh list --all
```

If you get an empty table (no VMs yet) instead of a permission error, KVM is ready.
You can also confirm the KVM kernel module is loaded:

```bash
lsmod | grep kvm
```

## You should see `kvm_intel` or `kvm_amd` depending on your CPU.

## What's next?

With KVM installed, you can start creating Ubuntu VMs for your Kubernetes cluster. The typical next step is:

1. Download an Ubuntu cloud image
2. Create VMs using `virt-install` with cloud-init for automated configuration
3. Bootstrap Kubernetes on those VMs with `kubeadm`
   If you're following along with the homelab series, the next post covers creating VMs and standing up a Kubernetes cluster from scratch.

---

## Troubleshooting

**"Cannot access storage file" errors:**
Permissions on `/var/lib/libvirt/images`. Re-run the `chown`/`chmod` commands from Step 5.
**`virsh` commands fail with "Failed to connect to the hypervisor":**
Either libvirtd isn't running (`sudo systemctl start libvirtd`) or your user isn't in the `libvirt` group (log out and back in).
**Default network won't start ("network is already in use"):**
Usually a conflict with Docker's bridge. Stop Docker (`sudo systemctl stop docker`), destroy and restart the default network:

```bash
sudo virsh net-destroy default
sudo virsh net-start default
```

**VM creation is extremely slow:**
Check that KVM acceleration is actually active, not falling back to pure QEMU emulation:

```bash
sudo kvm-ok
```

If it says "KVM acceleration can NOT be used", enable virtualization in your BIOS.
