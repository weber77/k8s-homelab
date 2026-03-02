# KVM Kubernetes Lab Automation

This repository provides simple automation for building a local virtualization environment and provisioning multiple Ubuntu virtual machines for Kubernetes labs.

It includes:

## 1️⃣ KVM Setup Script
Installs and configures KVM, libvirt, and networking with safe defaults.  
Handles common host conflicts (such as container runtimes modifying bridges or iptables) to ensure virtualization networking works out of the box.

## 2️⃣ VM Provisioning Script
Creates any number of Ubuntu cloud-init virtual machines automatically.

Features:
- Batch VM creation from a single command
- Cloud-init based provisioning
- Automatic SSH access
- Per-VM configuration
- Works with existing KVM setup script
- Designed for Kubernetes node simulation (control plane, workers, load balancer, etc.)

## Use Cases
- Kubernetes learning labs
- Local cluster testing
- Networking experiments
- Infrastructure automation practice
- Reproducible dev environments

## Goal
Make it fast and repeatable to spin up a multi-node virtual infrastructure on a single machine with minimal manual setup.

## 🚀 How to Use

This project provides two scripts:

1. **KVM setup script** – installs and configures virtualization
2. **VM creation script** – creates multiple Ubuntu cloud-init virtual machines

---

## 📦 Requirements

- Ubuntu host (recommended)
- Internet connection
- sudo privileges
- CPU virtualization enabled (Intel VT-x / AMD-V)

---

## 1️⃣ Install and Configure KVM

Run the setup script to install and configure KVM, libvirt, and networking.

```bash
chmod +x kvm-setup.sh
./kvm-setup.sh
