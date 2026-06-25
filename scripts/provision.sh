#!/bin/bash
# provision.sh
# Provisioning completo: rete + template + VM
# Eseguire sull'host OpenNebula come duka (usa sudo -u oneadmin internamente)

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "╔══════════════════════════════════════╗"
echo "║  Fog Storage — Provisioning Cluster  ║"
echo "╚══════════════════════════════════════╝"

# ============================================
# 0. Verifiche pre-provisioning
# ============================================
echo ""
echo "=== [0/6] Verifiche ==="

# Verificare che l'immagine sia pronta
IMAGE_STATUS=$(sudo -u oneadmin oneimage list --no-header -l STAT 2>/dev/null | head -1 | tr -d ' ')
if [ "$IMAGE_STATUS" != "rdy" ]; then
  echo "❌ Nessuna immagine pronta! Esegui prima: sudo bash scripts/prepare-image.sh"
  exit 1
fi
IMAGE_ID=$(sudo -u oneadmin oneimage list --no-header -l ID | head -1 | tr -d ' ')
echo "✅ Immagine trovata (ID: $IMAGE_ID)"

# ============================================
# 1. Creare la rete
# ============================================
echo ""
echo "=== [1/6] Creazione rete ==="
# Creare rete se non esiste
if ! sudo -u oneadmin onevnet list | grep -q "fog-network"; then
  cp "$PROJECT_DIR/network/vnet.tmpl" /tmp/vnet.tmpl
  sudo -u oneadmin onevnet create /tmp/vnet.tmpl
fi
NETWORK_ID=$(sudo -u oneadmin onevnet list --no-header | grep "fog-network" | awk '{print $1}' | head -1)
echo "✅ Rete trovata (ID: $NETWORK_ID)"

# ============================================
# 2. Base64 encode dei cloud-init
# ============================================
echo ""
echo "=== [2/6] Preparazione cloud-init ==="
MASTER_B64=$(base64 -w 0 "$PROJECT_DIR/context/master-cloud-init.yaml")
WORKER_B64=$(base64 -w 0 "$PROJECT_DIR/context/worker-cloud-init.yaml")
echo "✅ Cloud-init processati e codificati in base64"

# ============================================
# 3. Aggiornare e creare i template
# ============================================
echo ""
echo "=== [3/6] Creazione template ==="

# Pulizia vecchi template
for t in $(sudo -u oneadmin onetemplate list --no-header -l ID 2>/dev/null | tr -d ' '); do
  sudo -u oneadmin onetemplate delete $t
done

# Creare template master con gli ID corretti e USER_DATA base64
sed "s/IMAGE_ID = \"0\"/IMAGE_ID = \"$IMAGE_ID\"/" "$PROJECT_DIR/templates/k8s-master.tmpl" | \
  sed "s/NETWORK_ID = \"0\"/NETWORK_ID = \"$NETWORK_ID\"/" | \
  sed "s|\$USER_DATA_B64|$MASTER_B64|" > /tmp/k8s-master-resolved.tmpl
sudo -u oneadmin onetemplate create /tmp/k8s-master-resolved.tmpl

# Creare template worker con gli ID corretti e USER_DATA base64
sed "s/IMAGE_ID = \"0\"/IMAGE_ID = \"$IMAGE_ID\"/" "$PROJECT_DIR/templates/k8s-worker.tmpl" | \
  sed "s/NETWORK_ID = \"0\"/NETWORK_ID = \"$NETWORK_ID\"/" | \
  sed "s|\$USER_DATA_B64|$WORKER_B64|" > /tmp/k8s-worker-resolved.tmpl
sudo -u oneadmin onetemplate create /tmp/k8s-worker-resolved.tmpl

echo "✅ Template creati in OpenNebula"

# ============================================
# 4. Configurare SSH key di oneadmin
# ============================================
echo ""
echo "=== [4/6] Configurazione SSH ==="
if [ ! -f /var/lib/one/.ssh/id_rsa ]; then
  sudo -u oneadmin ssh-keygen -t rsa -N "" -f /var/lib/one/.ssh/id_rsa
fi
PUBKEY=$(sudo cat /var/lib/one/.ssh/id_rsa.pub)
sudo -u oneadmin oneuser update oneadmin --append <<< "SSH_PUBLIC_KEY=\"$PUBKEY\""
echo "✅ SSH key configurata"

# ============================================
# 5. Istanziare le VM
# ============================================
echo ""
echo "=== [5/6] Istanziazione VM ==="

# Pulizia vecchie VM
for vm in $(sudo -u oneadmin onevm list --no-header -l ID 2>/dev/null | tr -d ' '); do
  sudo -u oneadmin onevm terminate --hard $vm
done
sleep 5 # Attendi che spariscano

echo "  → Creazione control-plane-1..."
sudo -u oneadmin onetemplate instantiate "k8s-master" --name "control-plane-1"

echo "  → Attesa 10 secondi..."
sleep 10

echo "  → Creazione edge-node-1..."
sudo -u oneadmin onetemplate instantiate "k8s-worker" --name "edge-node-1"
echo "  → Creazione edge-node-2..."
sudo -u oneadmin onetemplate instantiate "k8s-worker" --name "edge-node-2"
echo "  → Creazione edge-node-3..."
sudo -u oneadmin onetemplate instantiate "k8s-worker" --name "edge-node-3"

echo "✅ VM istanziate"

# ============================================
# 6. Mostra stato
# ============================================
echo ""
echo "=== [6/6] Stato VM ==="
sleep 5
sudo -u oneadmin onevm list

echo ""
echo "=== IP delle VM ==="
for vm in $(sudo -u oneadmin onevm list --no-header -l ID | tr -d ' '); do
  NAME=$(sudo -u oneadmin onevm show $vm | grep "^NAME" | awk -F= '{print $2}' | tr -d ' "')
  IP=$(sudo -u oneadmin onevm show $vm | grep ETH0_IP= | head -1 | awk -F'"' '{print $2}')
  echo "  $NAME → $IP"
done

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  ✅ Provisioning completato!                 ║"
echo "║                                              ║"
echo "║  Attendi ~10 min per cloud-init, poi:        ║"
echo "║  sudo -u oneadmin ssh root@<IP_MASTER>       ║"
echo "║  cloud-init status --wait                    ║"
echo "║  kubectl get nodes                           ║"
echo "╚══════════════════════════════════════════════╝"
