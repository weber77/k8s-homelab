#!/usr/bin/env bash
set -e

echo "== Installing KVM + libvirt =="

sudo apt update
sudo apt install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  bridge-utils \
  virtinst \
  cloud-image-utils

echo "== Enabling libvirt =="
sudo systemctl enable --now libvirtd

echo "== Adding current user to libvirt group =="
sudo usermod -aG libvirt "$USER"

echo "== Fixing default network conflicts (docker / container runtimes) =="

# stop default if running
if sudo virsh net-info default &>/dev/null; then
  sudo virsh net-destroy default || true
  sudo virsh net-undefine default || true
fi

# create clean default network on safe subnet
cat <<EOF >/tmp/libvirt-default.xml
<network>
  <name>default</name>
  <forward mode='nat'/>
  <bridge name='virbr0' stp='on' delay='0'/>
  <ip address='192.168.130.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='192.168.130.2' end='192.168.130.254'/>
    </dhcp>
  </ip>
</network>
EOF

sudo virsh net-define /tmp/libvirt-default.xml
sudo virsh net-start default
sudo virsh net-autostart default

echo "== Verifying KVM =="
sudo virsh net-list --all

echo
echo "✅ KVM installed and network ready"
echo "⚠️  Reboot for group permissions"
