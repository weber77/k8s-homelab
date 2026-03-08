# k8s utils

## reset-k8s-node.sh

**Where:** Run **inside a VM** (e.g. over SSH or `virsh console`).  
**What:** Resets the node’s Kubernetes state: stops kubelet and containerd, runs `kubeadm reset`, removes Kubernetes/etcd/CNI configs and data, flushes iptables, then restarts containerd and kubelet. Use before re-joining a node or when rebuilding a cluster from scratch.

**Usage (inside the VM):**

```bash
chmod +x reset-k8s-node.sh
./reset-k8s-node.sh
```

If you copy the script into the VM, make it executable and run as user `ubuntu`. The script uses **sudo** for system and Kubernetes commands.
