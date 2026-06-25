#!/bin/bash
# prepare-image.sh
# Scarica Ubuntu 22.04 cloud image e configura cloud-init nativamente
# Eseguire sull'host OpenNebula come root

set -e

echo "=== [1/4] Installazione tool ==="
apt-get update
apt-get install -y libguestfs-tools wget qemu-utils

echo "=== [2/4] Download Ubuntu 22.04 cloud image ==="
cd /tmp
if [ ! -f jammy-server-cloudimg-amd64.img ]; then
  wget -q --show-progress https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img
fi
cp jammy-server-cloudimg-amd64.img ubuntu-22.04-k8s.img

echo "=== [3/4] Configurazione cloud-init per OpenNebula ==="
# Usiamo virt-customize per:
# 1. Forzare il datasource OpenNebula per cloud-init
# 2. Installare qemu-guest-agent
# (NON installiamo one-context per evitare conflitti con cloud-init)
virt-customize -a ubuntu-22.04-k8s.img \
  --run-command "apt-get update" \
  --install "qemu-guest-agent" \
  --run-command "echo 'datasource_list: [ OpenNebula, None ]' > /etc/cloud/cloud.cfg.d/90_opennebula.cfg" \
  --run-command "cloud-init clean" \
  --run-command "systemctl enable serial-getty@ttyS0.service"

echo "=== [4/4] Registrazione immagine in OpenNebula ==="
# Spostiamo l'immagine in /var/tmp per evitare problemi di permessi
mv ubuntu-22.04-k8s.img /var/tmp/ubuntu-22.04-k8s.img
chown oneadmin:oneadmin /var/tmp/ubuntu-22.04-k8s.img

cat > /tmp/ubuntu-k8s-image.tmpl <<EOF
NAME = "Ubuntu-22.04-cloud-k8s"
PATH = "/var/tmp/ubuntu-22.04-k8s.img"
TYPE = "OS"
FORMAT = "qcow2"
EOF

# Cancella l'immagine vecchia se esiste già
sudo -u oneadmin oneimage delete "Ubuntu-22.04-cloud-k8s" 2>/dev/null || true

# Registra la nuova
sudo -u oneadmin oneimage create /tmp/ubuntu-k8s-image.tmpl --datastore default

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  ✅ Immagine preparata!                      ║"
echo "║  Attendi che lo STAT diventi 'rdy' (~1 min)  ║"
echo "║  Controlla con:                              ║"
echo "║  watch sudo -u oneadmin oneimage list        ║"
echo "╚══════════════════════════════════════════════╝"
