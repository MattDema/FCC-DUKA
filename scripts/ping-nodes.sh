#!/bin/bash
# ping-nodes.sh
# Performs a quick ping on all active OpenNebula VMs
# Run on the OpenNebula host

echo "=========================================="
echo "     VERIFY CLUSTER NODE CONNECTIVITY    "
echo "=========================================="
echo ""

for vm in $(sudo -u oneadmin onevm list --no-header -l ID | tr -d ' '); do
  NAME=$(sudo -u oneadmin onevm show $vm | grep "^NAME" | awk -F= '{print $2}' | tr -d ' "')
  IP=$(sudo -u oneadmin onevm show $vm | grep ETH0_IP= | head -1 | awk -F'"' '{print $2}')
  
  # Skip if VM has no IP (e.g. still booting)
  if [ -z "$IP" ]; then
    echo "WAITING $NAME does not have an IP yet."
    continue
  fi

  echo -n "Testing $NAME ($IP) ... "
  if ping -c 2 -W 2 $IP > /dev/null 2>&1; then
    echo "CONNECTED"
  else
    echo "UNREACHABLE"
  fi
done
echo ""
echo "=========================================="
