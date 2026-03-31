# Building a Kubernetes Cluster from Scratch on KVM Virtual Machines

You've got KVM installed, your hypervisor is ready, and you're staring at an empty `virsh list`. Now what?

This guide covers the full path from zero VMs to a running Kubernetes cluster: creating Ubuntu VMs with cloud-init, baking a reusable golden image with Kubernetes tooling pre-installed, and bootstrapping a control plane with workers using `kubeadm`.

---

## Prerequisites

- KVM and libvirt installed and working on your Ubuntu host. If you haven't done this yet, see [Setting Up KVM on Ubuntu](https://medium.com/) (the previous post in this series covers the full setup).
- `sshpass` installed on the host (the automation scripts use it to SSH into VMs with default credentials):

```bash
sudo apt install -y sshpass
```

- Enough host resources for your cluster. A reasonable starting point:
  - **1 control plane + 2 workers** = 3 VMs
  - Each VM: 2 GB RAM, 20 GB disk, 2 vCPUs
  - Total: ~6 GB RAM and ~60 GB disk dedicated to VMs

---

## The approach

Rather than manually installing Kubernetes on every VM, we'll use a **golden image** workflow:

1. Create a temporary VM from a stock Ubuntu cloud image
2. Install all Kubernetes dependencies (containerd, kubeadm, kubelet, kubectl) on it
3. Clean the VM and convert it to a reusable base image
4. Clone all cluster VMs from that image — they boot with Kubernetes tooling already in place
5. Run `kubeadm init` on the control plane, `kubeadm join` on the workers

This is faster and more reproducible than running the same apt install commands on every node.

---

## Step 1: Create VMs with cloud-init

Each VM is created from an Ubuntu 22.04 cloud image and configured at first boot using cloud-init. The cloud-init config sets up:

- Hostname matching the VM name
- A default user (`ubuntu` / `ubuntu`) with passwordless sudo
- SSH password authentication enabled
- The QEMU guest agent for better host-VM integration

Here's what a VM creation looks like under the hood. For each VM, we:

1. Generate a cloud-init seed ISO with user-data and meta-data
2. Create a copy-on-write disk backed by the base image
3. Launch the VM with `virt-install`

```bash
# Cloud-init user-data (simplified)
#cloud-config
hostname: k8s-a
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
```

```bash
# Create the disk (copy-on-write, backed by the golden image)
sudo qemu-img create -f qcow2 -F qcow2 -b /var/lib/libvirt/images/k8s-base.qcow2 \
  /var/lib/libvirt/images/k8s-a.qcow2
sudo qemu-img resize /var/lib/libvirt/images/k8s-a.qcow2 20G

# Create the seed ISO
cloud-localds seed.iso user-data meta-data

# Launch the VM
virt-install \
  --name k8s-a \
  --memory 2048 \
  --vcpus 2 \
  --disk path=/var/lib/libvirt/images/k8s-a.qcow2,format=qcow2 \
  --disk path=/var/lib/libvirt/images/k8s-a-seed.iso,device=cdrom \
  --import \
  --network network=default \
  --graphics none \
  --osinfo ubuntu22.04 \
  --noautoconsole
```

Using copy-on-write disks (`-b` flag) means each VM only stores its differences from the base image. Three VMs don't cost 60 GB — they start near zero and grow as data is written.

---

## Step 2: Build the golden image

The golden image is a regular Ubuntu VM with Kubernetes packages pre-installed. The process:

1. Spin up a temporary VM from the stock Ubuntu cloud image
2. SSH in and install containerd, kubeadm, kubelet, kubectl
3. Clean up machine-specific state (cloud-init, SSH host keys, machine-id)
4. Shut down and convert the disk to a standalone base image

The key packages installed on the image:

- **containerd** — the container runtime that Kubernetes uses to run pods
- **kubeadm** — bootstraps the cluster (init, join, cert management)
- **kubelet** — the node agent that runs on every node
- **kubectl** — the CLI for interacting with the cluster

After installing, the VM is cleaned for reuse:

```bash
sudo cloud-init clean
sudo truncate -s 0 /etc/machine-id
sudo rm -f /etc/ssh/ssh_host_*
sudo rm -rf /var/log/*
sudo apt-get clean
```

Truncating `machine-id` is critical. If you skip it, every VM cloned from this image will have the same identity, which causes DHCP conflicts, duplicate hostnames, and subtle networking bugs that are painful to debug.

The result is a clean base image at `/var/lib/libvirt/images/k8s-base.qcow2` that every future cluster VM can be cloned from.

---

## Step 3: Create the cluster VMs

With the golden image ready, create your cluster nodes. For a minimal cluster (1 control plane + 2 workers):

```bash
# This creates 3 VMs: k8s-a (control plane), k8s-b, k8s-c (workers)
BASE_IMAGE_OVERRIDE="/var/lib/libvirt/images/k8s-base.qcow2" ./create-vms.sh 3
```

Wait for the VMs to boot and get DHCP leases:

```bash
sleep 10
virsh net-dhcp-leases default
```

You'll see something like:

```
 Expiry Time           MAC address        Protocol   IP address          Hostname
 2026-03-30 12:00:00   52:54:00:xx:xx:xx  ipv4       192.168.122.101/24  k8s-a
 2026-03-30 12:00:00   52:54:00:xx:xx:xx  ipv4       192.168.122.102/24  k8s-b
 2026-03-30 12:00:00   52:54:00:xx:xx:xx  ipv4       192.168.122.103/24  k8s-c
```

Note down the IPs. The first VM (`k8s-a`) will be your control plane.

---

## Step 4: Initialize the control plane

SSH into the first VM and bootstrap Kubernetes:

```bash
sshpass -p ubuntu ssh -o StrictHostKeyChecking=no ubuntu@192.168.122.101
```

Inside the VM:

```bash
# Wait for cloud-init to finish (important on first boot)
cloud-init status --wait

# Restart the container runtime and kubelet
sudo systemctl restart containerd
sudo systemctl restart kubelet

# Initialize the control plane
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --cri-socket unix:///run/containerd/containerd.sock

# Set up kubectl for the ubuntu user
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

Key parameters:

- **`--pod-network-cidr=10.244.0.0/16`** — the IP range for pod networking. This must not overlap with your VM network (`192.168.122.0/24`). Flannel uses `10.244.0.0/16` by default.
- **`--cri-socket`** — explicitly tells kubeadm to use containerd. Avoids ambiguity if multiple runtimes are installed.

---

## Step 5: Install a CNI (pod networking)

Kubernetes doesn't ship with pod networking. You need a CNI plugin so pods on different nodes can talk to each other. Flannel is a simple, well-tested option:

```bash
kubectl apply -f https://github.com/coreos/flannel/raw/master/Documentation/kube-flannel.yml
```

Wait for the Flannel pods to come up:

```bash
kubectl get pods -n kube-flannel -w
```

Once they're `Running`, your control plane node should transition to `Ready`:

```bash
kubectl get nodes
```

---

## Step 6: (Optional) Allow workloads on the control plane

By default, Kubernetes taints control plane nodes so no regular workloads get scheduled there. In a small lab where every node counts, you can remove the taint:

```bash
kubectl taint nodes $(hostname) node-role.kubernetes.io/control-plane:NoSchedule-
```

Skip this in production. In a homelab with 3 VMs total, it makes sense.

---

## Step 7: Generate the join command

Still on the control plane, create a join token for workers:

```bash
kubeadm token create --print-join-command
```

This prints a `kubeadm join ...` command with a token and discovery hash. Copy it — you'll run it on each worker.

---

## Step 8: Join the workers

SSH into each worker VM and run the join command:

```bash
# On k8s-b (worker 1)
sshpass -p ubuntu ssh -o StrictHostKeyChecking=no ubuntu@192.168.122.102

cloud-init status --wait
sudo kubeadm join 192.168.122.101:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

Repeat for `k8s-c` (or any additional workers).

---

## Step 9: Verify the cluster

Back on the control plane:

```bash
kubectl get nodes -o wide
```

You should see all nodes in `Ready` state:

```
NAME    STATUS   ROLES           AGE   VERSION   INTERNAL-IP       OS-IMAGE
k8s-a   Ready    control-plane   5m    v1.33.0   192.168.122.101   Ubuntu 22.04
k8s-b   Ready    <none>          2m    v1.33.0   192.168.122.102   Ubuntu 22.04
k8s-c   Ready    <none>          1m    v1.33.0   192.168.122.103   Ubuntu 22.04
```

Check that system pods are healthy:

```bash
kubectl get pods -n kube-system
```

Your cluster is running.

---

## The automated version

The steps above are what the automation script does end to end. If you want to skip the manual process:

```bash
./cluster.sh --control-plane --workers 2
```

This single command:

1. Checks for (or builds) the golden base image
2. Creates 3 VMs
3. Waits for DHCP leases and SSH readiness
4. Runs `kubeadm init` on the first VM
5. Installs Flannel
6. Removes the control plane taint
7. Generates a join token and joins all workers

---

## What's next

You now have a working Kubernetes cluster, but PVCs won't work yet — there's no storage provisioner. The next post in this series covers setting up dynamic local storage with Rancher's `local-path-provisioner` so your `PersistentVolumeClaim` resources actually get provisioned.

---

## Teardown

When you want to start fresh:

```bash
# From the cluster directory
sudo ./purge-cluster.sh
```

Or manually destroy individual VMs:

```bash
virsh destroy k8s-a && virsh undefine k8s-a
sudo rm -f /var/lib/libvirt/images/k8s-a.qcow2 /var/lib/libvirt/images/k8s-a-seed.iso
```

---

## Troubleshooting

**`kubeadm init` hangs or times out:**
Usually means containerd or kubelet isn't running. Restart both and try again:

```bash
sudo systemctl restart containerd
sudo systemctl restart kubelet
```

If that doesn't help, reset and retry:

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet ~/.kube
```

**Workers show `NotReady`:**
The CNI plugin isn't installed or hasn't finished deploying. Check Flannel pods:

```bash
kubectl get pods -n kube-flannel -o wide
```

**"The connection to the server was refused":**
Your kubeconfig isn't set up. Run the `mkdir -p ~/.kube && sudo cp ...` commands from Step 4.

**VMs don't get IP addresses:**
The libvirt default network might not be running:

```bash
sudo virsh net-start default
```

**Join token expired:**
Tokens expire after 24 hours. Generate a new one on the control plane:

```bash
kubeadm token create --print-join-command
```
