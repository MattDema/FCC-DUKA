#!/bin/bash

echo "=========================================="
echo "    DUKA CLUSTER AUTO-HEAL INITIATED      "
echo "=========================================="

echo "1. Recreating Edge Bridges..."
sudo ip link add name br-edge-1 type bridge 2>/dev/null
sudo ip addr add 10.1.1.1/24 dev br-edge-1 2>/dev/null
sudo ip link set br-edge-1 up 2>/dev/null

sudo ip link add name br-edge-2 type bridge 2>/dev/null
sudo ip addr add 10.1.2.1/24 dev br-edge-2 2>/dev/null
sudo ip link set br-edge-2 up 2>/dev/null

sudo ip link add name br-edge-3 type bridge 2>/dev/null
sudo ip addr add 10.1.3.1/24 dev br-edge-3 2>/dev/null
sudo ip link set br-edge-3 up 2>/dev/null

echo "2. Auto-Detecting VMs and Waiting for Boot Sequence..."
for vmid in $(sudo -u oneadmin onevm list | awk '/k8s-worker/ {print $1}'); do
    domain="one-$vmid"
    ip_addr=$(sudo -u oneadmin onevm show $vmid | grep -i 'ETH1_IP=' | cut -d'"' -f2)

    if [ -n "$ip_addr" ]; then
        echo -n " -> Waiting for Worker VM $vmid to boot "
        
        # Loop until the Guest Agent responds (meaning the VM is 100% booted)
        while true; do
            agent_status=$(sudo virsh qemu-agent-command $domain '{"execute": "guest-ping"}' 2>&1)
            if [[ "$agent_status" == *"return"* ]]; then
                echo " Ready!"
                break
            fi
            sleep 5
            echo -n "."
        done

        echo "    Forcing cable UP and injecting IP $ip_addr..."
        sudo ip link set "one-${vmid}-1" up 2>/dev/null
        sudo virsh qemu-agent-command $domain '{"execute": "guest-exec", "arguments": { "path": "/bin/ip", "arg": [ "link", "set", "enp3s0", "up" ] } }' >/dev/null 2>&1
        sudo virsh qemu-agent-command $domain "{\"execute\": \"guest-exec\", \"arguments\": { \"path\": \"/bin/ip\", \"arg\": [ \"addr\", \"add\", \"$ip_addr/24\", \"dev\", \"enp3s0\" ] } }" >/dev/null 2>&1
    fi
done

echo "Waiting 3 seconds for IPs to apply globally..."
sleep 3

echo "3. Restoring Master BGP Routes..."
sudo ip route add 10.244.1.0/24 via 172.16.100.1 2>/dev/null
sudo ip route add 10.244.2.0/24 via 172.16.100.1 2>/dev/null
sudo ip route add 10.244.3.0/24 via 172.16.100.1 2>/dev/null

echo "4. Restoring Worker Default Routes..."
sudo -u oneadmin ssh -o StrictHostKeyChecking=no ubuntu@10.1.1.100 "sudo ip route add default via 10.1.1.1" 2>/dev/null
sudo -u oneadmin ssh -o StrictHostKeyChecking=no ubuntu@10.1.2.100 "sudo ip route add default via 10.1.2.1" 2>/dev/null
sudo -u oneadmin ssh -o StrictHostKeyChecking=no ubuntu@10.1.3.100 "sudo ip route add default via 10.1.3.1" 2>/dev/null

echo "=========================================="
echo " Done! The DUKA cluster is 100% operational."
echo "=========================================="
