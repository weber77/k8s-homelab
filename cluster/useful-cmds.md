start vms in cluster:

- with prefix e.g. k8s

```bash
for vm in $(virsh list --all --name | grep '^k8s-'); do
  virsh start "$vm"
done
```

- all 'shut off'

```bash
for vm in $(virsh list --all --name); do
  if [[ "$(virsh domstate "$vm")" == "shut off" ]]; then
    virsh start "$vm"
  fi
done
```

## reset vm

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet /etc/cni/net.d /var/lib/cni "$HOME/.kube"
sudo systemctl restart containerd
sudo systemctl restart kubelet
```
