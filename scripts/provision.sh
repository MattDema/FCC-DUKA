#!/bin/bash
# provision.sh
# Complete provisioning: network + templates + VMs
# Run on the OpenNebula host as duka (uses sudo -u oneadmin internally)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "╔══════════════════════════════════════╗"
echo "║  Fog Storage — Provisioning Cluster  ║"
echo "╚══════════════════════════════════════╝"

# ============================================
# 0. Pre-provisioning checks
# ============================================
echo ""
echo "=== [0/6] Checks ==="

# Check if the image is ready
IMAGE_STATUS=$(sudo -u oneadmin oneimage list --no-header -l STAT 2>/dev/null | head -1 | tr -d ' ')
if [ "$IMAGE_STATUS" != "rdy" ]; then
  echo "No ready image found! Run first: sudo bash scripts/prepare-image.sh"
  exit 1
fi
IMAGE_ID=$(sudo -u oneadmin oneimage list --no-header -l ID | head -1 | tr -d ' ')
echo "Image found (ID: $IMAGE_ID)"

# ============================================
# 1. Create network
# ============================================
echo ""
echo "=== [1/6] Network creation ==="
# Create network if it doesn't exist
if ! sudo -u oneadmin onevnet list | grep -q "fog-network"; then
  cp "$PROJECT_DIR/network/vnet.tmpl" /tmp/vnet.tmpl
  sudo -u oneadmin onevnet create /tmp/vnet.tmpl
fi
NETWORK_ID=$(sudo -u oneadmin onevnet list --no-header | grep "fog-network" | awk '{print $1}' | head -1)
echo "Network found (ID: $NETWORK_ID)"

# ============================================
# 2. Base64 encode cloud-init files
# ============================================
echo ""
echo "=== [2/6] Cloud-init preparation ==="
MASTER_B64=$(base64 -w 0 "$PROJECT_DIR/context/master-cloud-init.yaml")
WORKER_B64=$(base64 -w 0 "$PROJECT_DIR/context/worker-cloud-init.yaml")
echo "Cloud-init processed and base64 encoded"

# ============================================
# 3. Update and create templates
# ============================================
echo ""
echo "=== [3/6] Template creation ==="

# Clean up old templates
for t in $(sudo -u oneadmin onetemplate list --no-header -l ID 2>/dev/null | tr -d ' '); do
  sudo -u oneadmin onetemplate delete $t
done

# Create master template with correct IDs and base64 USER_DATA
sed "s/IMAGE_ID = \"0\"/IMAGE_ID = \"$IMAGE_ID\"/" "$PROJECT_DIR/templates/k8s-master.tmpl" | \
  sed "s/NETWORK_ID = \"0\"/NETWORK_ID = \"$NETWORK_ID\"/" | \
  sed "s|\$USER_DATA_B64|$MASTER_B64|" > /tmp/k8s-master-resolved.tmpl
sudo -u oneadmin onetemplate create /tmp/k8s-master-resolved.tmpl

# Create worker template with correct IDs and base64 USER_DATA
sed "s/IMAGE_ID = \"0\"/IMAGE_ID = \"$IMAGE_ID\"/" "$PROJECT_DIR/templates/k8s-worker.tmpl" | \
  sed "s/NETWORK_ID = \"0\"/NETWORK_ID = \"$NETWORK_ID\"/" | \
  sed "s|\$USER_DATA_B64|$WORKER_B64|" > /tmp/k8s-worker-resolved.tmpl
sudo -u oneadmin onetemplate create /tmp/k8s-worker-resolved.tmpl

echo "Templates created in OpenNebula"

# ============================================
# 4. Configure oneadmin SSH key
# ============================================
echo ""
echo "=== [4/6] SSH configuration ==="
if [ ! -f /var/lib/one/.ssh/id_rsa ]; then
  sudo -u oneadmin ssh-keygen -t rsa -N "" -f /var/lib/one/.ssh/id_rsa
fi
PUBKEY=$(sudo cat /var/lib/one/.ssh/id_rsa.pub)
sudo -u oneadmin oneuser update oneadmin --append <<< "SSH_PUBLIC_KEY=\"$PUBKEY\""
echo "SSH key configured"

# ============================================
# 5. Instantiate VMs
# ============================================
echo ""
echo "=== [5/6] VM instantiation ==="

# Clean up old VMs
for vm in $(sudo -u oneadmin onevm list --no-header -l ID 2>/dev/null | tr -d ' '); do
  sudo -u oneadmin onevm terminate --hard $vm
done
sleep 5 # Wait for them to disappear

echo "  → Creating control-plane-1..."
sudo -u oneadmin onetemplate instantiate "k8s-master" --name "control-plane-1"

echo "  → Waiting 10 seconds..."
sleep 10

echo "  → Creating edge-node-1..."
sudo -u oneadmin onetemplate instantiate "k8s-worker" --name "edge-node-1"
echo "  → Creating edge-node-2..."
sudo -u oneadmin onetemplate instantiate "k8s-worker" --name "edge-node-2"
echo "  → Creating edge-node-3..."
sudo -u oneadmin onetemplate instantiate "k8s-worker" --name "edge-node-3"

echo "VMs instantiated"

# ============================================
# 6. Show status
# ============================================
echo ""
echo "=== [6/6] VM Status ==="
sleep 5
sudo -u oneadmin onevm list

echo ""
echo "=== VM IPs ==="
for vm in $(sudo -u oneadmin onevm list --no-header -l ID | tr -d ' '); do
  NAME=$(sudo -u oneadmin onevm show $vm | grep "^NAME" | awk -F= '{print $2}' | tr -d ' "')
  IP=$(sudo -u oneadmin onevm show $vm | grep ETH0_IP= | head -1 | awk -F'"' '{print $2}')
  echo "  $NAME → $IP"
done

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  Provisioning complete!                      ║"
echo "║                                              ║"
echo "║  Wait ~10 mins for cloud-init, then:         ║"
echo "║  sudo -u oneadmin ssh root@<MASTER_IP>       ║"
echo "║  cloud-init status --wait                    ║"
echo "║  kubectl get nodes                           ║"
echo "╚══════════════════════════════════════════════╝"
