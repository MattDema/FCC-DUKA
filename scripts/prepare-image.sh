#!/bin/bash
# prepare-image.sh
# Download Ubuntu 22.04 cloud image and configure cloud-init natively
# Run on the OpenNebula host as root

set -e

echo "=== [1/4] Install tools ==="
apt-get update
apt-get install -y libguestfs-tools wget qemu-utils

echo "=== [2/4] Download Ubuntu 22.04 cloud image ==="
cd /tmp
if [ ! -f jammy-server-cloudimg-amd64.img ]; then
  wget -q --show-progress https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
fi
cp jammy-server-cloudimg-amd64.img ubuntu-22.04-k8s.img

echo "=== [3/4] Configure cloud-init for OpenNebula ==="
# We use virt-customize to:
# 1. Force the OpenNebula datasource for cloud-init
# 2. Install qemu-guest-agent
# (We DO NOT install one-context to avoid conflicts with cloud-init)
virt-customize -a ubuntu-22.04-k8s.img \
  --run-command "apt-get update" \
  --install "qemu-guest-agent" \
  --run-command "echo 'datasource_list: [ OpenNebula, None ]' > /etc/cloud/cloud.cfg.d/90_opennebula.cfg" \
  --run-command "cloud-init clean" \
  --run-command "systemctl enable serial-getty@ttyS0.service"

echo "=== [4/4] Register image in OpenNebula ==="
# Move the image to /var/tmp to avoid permission issues
mv ubuntu-22.04-k8s.img /var/tmp/ubuntu-22.04-k8s.img
chown oneadmin:oneadmin /var/tmp/ubuntu-22.04-k8s.img

cat > /tmp/ubuntu-k8s-image.tmpl <<EOF
NAME = "Ubuntu-22.04-cloud-k8s"
PATH = "/var/tmp/ubuntu-22.04-k8s.img"
TYPE = "OS"
FORMAT = "qcow2"
EOF

# Delete the old image if it already exists
sudo -u oneadmin oneimage delete "Ubuntu-22.04-cloud-k8s" 2>/dev/null || true

# Register the new one
sudo -u oneadmin oneimage create /tmp/ubuntu-k8s-image.tmpl --datastore default

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  Image prepared!                             ║"
echo "║  Wait for STAT to become 'rdy' (~1 min)      ║"
echo "║  Check with:                                 ║"
echo "║  watch sudo -u oneadmin oneimage list        ║"
echo "╚══════════════════════════════════════════════╝"
