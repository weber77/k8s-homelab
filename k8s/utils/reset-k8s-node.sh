#!/bin/bash
set -e

echo "Stopping kubelet..."
sudo systemctl stop kubelet || true

echo "Running kubeadm reset..."
sudo kubeadm reset -f || true

echo "Stopping containerd..."
sudo systemctl stop containerd || true

echo "Removing Kubernetes directories..."
sudo rm -rf /etc/kubernetes
sudo rm -rf /var/lib/etcd
sudo rm -rf /var/lib/kubelet
sudo rm -rf $HOME/.kube

echo "Removing CNI configs..."
sudo rm -rf /etc/cni/net.d
sudo rm -rf /var/lib/cni

echo "Flushing iptables rules..."
sudo iptables -F
sudo iptables -t nat -F
sudo iptables -t mangle -F
sudo iptables -X

echo "Restarting containerd..."
sudo systemctl start containerd

echo "Restarting kubelet..."
sudo systemctl start kubelet

echo "Checking that Kubernetes ports are free..."
sudo ss -lntp | grep -E '6443|10250|10257|10259' || echo "Ports are free."

echo "Reset complete. Node is clean."
