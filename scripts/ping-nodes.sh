#!/bin/bash
# ping-nodes.sh
# Esegue un ping rapido su tutte le VM OpenNebula attive
# Eseguire sull'host OpenNebula

echo "=========================================="
echo "    VERIFICA CONNETTIVITÀ NODI CLUSTER    "
echo "=========================================="
echo ""

for vm in $(sudo -u oneadmin onevm list --no-header -l ID | tr -d ' '); do
  NAME=$(sudo -u oneadmin onevm show $vm | grep "^NAME" | awk -F= '{print $2}' | tr -d ' "')
  IP=$(sudo -u oneadmin onevm show $vm | grep ETH0_IP= | head -1 | awk -F'"' '{print $2}')
  
  # Salta se la VM non ha un IP (es. ancora in fase di boot)
  if [ -z "$IP" ]; then
    echo "⏳ $NAME non ha ancora un IP."
    continue
  fi

  echo -n "Testando $NAME ($IP) ... "
  if ping -c 2 -W 2 $IP > /dev/null 2>&1; then
    echo "✅ CONNESSO"
  else
    echo "❌ NON RAGGIUNGIBILE"
  fi
done
echo ""
echo "=========================================="
