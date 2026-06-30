#!/bin/bash
# =============================================================================
#  DUKA CLUSTER AUTO-HEAL SCRIPT
# =============================================================================
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${RESET}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
section() { echo -e "\n${BOLD}══════════════════════════════════════════${RESET}"; \
            echo -e "${BOLD}  $*${RESET}"; \
            echo -e "${BOLD}══════════════════════════════════════════${RESET}"; }
# ── Configuration ─────────────────────────────────────────────────────────────
MASTER_IP="172.16.100.2"
WORKER_IPS=("10.1.1.100" "10.1.2.100" "10.1.3.100")
ALL_NODE_IPS=("$MASTER_IP" "${WORKER_IPS[@]}")
# Calico IPAM /26 blocks (one per node — stable after first Calico init)
MASTER_POD_CIDR="10.244.83.128/26"
WORKER1_POD_CIDR="10.244.147.128/26"   # ip-172-16-100-3
WORKER2_POD_CIDR="10.244.223.192/26"   # ip-172-16-100-4
WORKER3_POD_CIDR="10.244.97.192/26"    # ip-172-16-100-5
# OpenNebula host DNS server (dnsmasq on minionebr)
DNS_SERVER="172.16.100.1"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes"
ssh_node()  { sudo -u oneadmin ssh $SSH_OPTS ubuntu@"$1" "${@:2}"; }
ssh_admin() { sudo -u oneadmin ssh $SSH_OPTS ubuntu@"$1" "${@:2}"; }
# =============================================================================
section "PHASE 0 — Wake Up Suspended / Powered-Off VMs"
# =============================================================================
OFF_VMS=$(sudo -u oneadmin onevm list 2>/dev/null | awk '/k8s-/ && ($5 == "poff" || $5 == "susp") {print $1}')
if [ -n "$OFF_VMS" ]; then
    info "Resuming VMs: $(echo $OFF_VMS | tr '\n' ' ')"
    for vm_id in $OFF_VMS; do
        sudo -u oneadmin onevm resume "$vm_id" >/dev/null 2>&1
    done
    info "Waiting 15s for VMs to power on..."
    sleep 15
else
    ok "All VMs already running."
fi
# =============================================================================
section "PHASE 1 — Recreate Edge Bridges"
# =============================================================================
for i in 1 2 3; do
    BR="br-edge-$i"
    IP="10.1.$i.1"
    sudo ip link add name "$BR" type bridge 2>/dev/null || true
    sudo ip addr add "$IP/24" dev "$BR" 2>/dev/null || true
    sudo ip link set "$BR" up 2>/dev/null || true
    ok "$BR → $IP/24"
done
# =============================================================================
section "PHASE 2 — Wait for Workers to Boot (QEMU Guest Agent)"
# =============================================================================
for vm_id in $(sudo -u oneadmin onevm list 2>/dev/null | awk '/k8s-worker/ {print $1}'); do
    domain="one-$vm_id"
    ip_addr=$(sudo -u oneadmin onevm show "$vm_id" 2>/dev/null | grep -i 'ETH1_IP=' | cut -d'"' -f2)
    if [ -n "$ip_addr" ]; then
        info "Waiting for worker VM $vm_id ($ip_addr) to boot..."
        while true; do
            agent_status=$(sudo virsh qemu-agent-command "$domain" '{"execute":"guest-ping"}' 2>&1 || true)
            if [[ "$agent_status" == *"return"* ]]; then
                ok "Worker VM $vm_id is ready."
                break
            fi
            sleep 5
            echo -n "."
        done
        info "Bringing up interface and injecting IP $ip_addr..."
        sudo ip link set "one-${vm_id}-1" up 2>/dev/null || true
        sudo virsh qemu-agent-command "$domain" \
            '{"execute":"guest-exec","arguments":{"path":"/bin/ip","arg":["link","set","enp3s0","up"]}}' \
            >/dev/null 2>&1 || true
        sudo virsh qemu-agent-command "$domain" \
            "{\"execute\":\"guest-exec\",\"arguments\":{\"path\":\"/bin/ip\",\"arg\":[\"addr\",\"add\",\"$ip_addr/24\",\"dev\",\"enp3s0\"]}}" \
            >/dev/null 2>&1 || true
    fi
done
info "Waiting 5s for IPs to propagate..."
sleep 5
# =============================================================================
section "PHASE 3 — Restore Worker Default Routes + DNS"
# =============================================================================
WORKER_GATEWAYS=("10.1.1.1" "10.1.2.1" "10.1.3.1")
for i in "${!WORKER_IPS[@]}"; do
    ip="${WORKER_IPS[$i]}"
    gw="${WORKER_GATEWAYS[$i]}"
    info "Configuring worker $ip (gateway: $gw, DNS: $DNS_SERVER)..."
    ssh_admin "$ip" "
        # Default route
        sudo ip route add default via $gw 2>/dev/null || true
        # DNS — use OpenNebula host (172.16.100.1) which runs dnsmasq
        sudo rm -f /etc/resolv.conf
        printf 'nameserver $DNS_SERVER\n' | sudo tee /etc/resolv.conf >/dev/null
        # Fix /etc/hosts so sudo doesn't complain about unresolvable hostname
        HOSTNAME=\$(hostname)
        grep -q \"\$HOSTNAME\" /etc/hosts || echo '127.0.1.1 '\$HOSTNAME | sudo tee -a /etc/hosts >/dev/null
    " 2>/dev/null && ok "$ip configured" || warn "$ip may have failed"
done
# =============================================================================
section "PHASE 4 — Calico Pod CIDR Routes on OpenNebula Host"
# =============================================================================
# Remove stale old Flannel /24 routes
for net in 10.244.1.0/24 10.244.2.0/24 10.244.3.0/24; do
    sudo ip route del "$net" 2>/dev/null || true
done
# Add correct Calico /26 routes
declare -A POD_ROUTES=(
    ["$MASTER_POD_CIDR"]="$MASTER_IP dev minionebr"
    ["$WORKER1_POD_CIDR"]="10.1.1.100 dev br-edge-1"
    ["$WORKER2_POD_CIDR"]="10.1.2.100 dev br-edge-2"
    ["$WORKER3_POD_CIDR"]="10.1.3.100 dev br-edge-3"
)
for cidr in "${!POD_ROUTES[@]}"; do
    read -r nexthop iface <<< "${POD_ROUTES[$cidr]}"
    sudo ip route add "$cidr" via "$nexthop" dev "$iface" 2>/dev/null || true
    ok "Route: $cidr → $nexthop ($iface)"
done
# =============================================================================
section "PHASE 5 — OpenNebula Host NAT (definitive ruleset)"
# =============================================================================

# Backup current rules
sudo iptables-save | sudo tee /tmp/iptables-backup-$(date +%F-%H%M).rules >/dev/null
# Flush only POSTROUTING to apply a clean, ordered ruleset
sudo iptables -t nat -F POSTROUTING
# 1. Exempt BGP (Calico peer traffic must not have its source IP rewritten)
sudo iptables -t nat -A POSTROUTING -p tcp --sport 179 -j RETURN
sudo iptables -t nat -A POSTROUTING -p tcp --dport 179 -j RETURN
# 2. Exempt pod-to-pod traffic
sudo iptables -t nat -A POSTROUTING -s 10.244.0.0/16 -d 10.244.0.0/16 -j RETURN
# 3. Exempt edge ↔ control-plane traffic
sudo iptables -t nat -A POSTROUTING -s 10.1.0.0/16 -d 172.16.100.0/24 -j RETURN
sudo iptables -t nat -A POSTROUTING -s 172.16.100.0/24 -d 10.1.0.0/16 -j RETURN
# 4. Exempt edge-to-edge traffic
sudo iptables -t nat -A POSTROUTING -s 10.1.0.0/16 -d 10.1.0.0/16 -j RETURN
# 5. Exempt pod CIDR ↔ node networks
sudo iptables -t nat -A POSTROUTING -s 10.1.0.0/16 -d 10.244.0.0/16 -j RETURN
sudo iptables -t nat -A POSTROUTING -s 172.16.100.0/24 -d 10.244.0.0/16 -j RETURN
sudo iptables -t nat -A POSTROUTING -s 10.244.0.0/16 -d 10.1.0.0/16 -j RETURN
sudo iptables -t nat -A POSTROUTING -s 10.244.0.0/16 -d 172.16.100.0/24 -j RETURN
# 6. MASQUERADE internet-bound traffic from pods, control plane, and workers
sudo iptables -t nat -A POSTROUTING -s 10.244.0.0/16 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -s 172.16.100.0/24 ! -d 172.16.100.0/24 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -s 10.1.0.0/16 ! -d 172.16.100.0/24 -j MASQUERADE
# Persist
sudo netfilter-persistent save
ok "NAT ruleset applied and saved."
# =============================================================================
section "PHASE 6 — Wait for SSH on All Nodes"
# =============================================================================
info "Waiting for all nodes to accept SSH..."
for node_ip in "${ALL_NODE_IPS[@]}"; do
    for attempt in $(seq 1 30); do
        if ssh_node "$node_ip" "true" 2>/dev/null; then
            ok "$node_ip is reachable."
            break
        fi
        if [ "$attempt" -eq 30 ]; then
            warn "$node_ip still unreachable after 30 attempts — continuing anyway."
        fi
        sleep 5
    done
done
# =============================================================================
section "PHASE 7 — All Nodes: Remove Flannel Ghost Rules + Calico Masquerade"
# =============================================================================
for node_ip in "${ALL_NODE_IPS[@]}"; do
    info "Cleaning $node_ip..."
    ssh_node "$node_ip" "
        # Remove Flannel ghost POSTROUTING chain
        sudo iptables -t nat -D POSTROUTING \
            -m comment --comment 'flanneld masq' -j FLANNEL-POSTRTG 2>/dev/null || true
        sudo iptables -t nat -F FLANNEL-POSTRTG 2>/dev/null || true
        sudo iptables -t nat -X FLANNEL-POSTRTG 2>/dev/null || true
        # Remove Flannel ghost FORWARD chain
        sudo iptables -D FORWARD \
            -m comment --comment 'flanneld forward' -j FLANNEL-FWD 2>/dev/null || true
        sudo iptables -F FLANNEL-FWD 2>/dev/null || true
        sudo iptables -X FLANNEL-FWD 2>/dev/null || true
        # Add safe internet masquerade for pods (don't masquerade internal cluster traffic)
        sudo iptables -t nat -A POSTROUTING -s 10.244.0.0/16 -d 10.0.0.0/8 -j RETURN 2>/dev/null || true
        sudo iptables -t nat -A POSTROUTING -s 10.244.0.0/16 -d 172.16.0.0/12 -j RETURN 2>/dev/null || true
        if ! sudo iptables -t nat -C POSTROUTING -s 10.244.0.0/16 -m comment --comment 'calico internet masquerade' -j MASQUERADE 2>/dev/null; then
          sudo iptables -t nat -A POSTROUTING -s 10.244.0.0/16 -m comment --comment 'calico internet masquerade' -j MASQUERADE
        fi
    " 2>/dev/null && ok "$node_ip cleaned" || warn "$node_ip cleanup may have failed"
done
# =============================================================================
section "PHASE 8 — Control Plane: Routes to Worker Pod CIDRs"
# =============================================================================
ssh_node "$MASTER_IP" "
    sudo ip route add $WORKER1_POD_CIDR via $DNS_SERVER dev enp3s0 2>/dev/null || true
    sudo ip route add $WORKER2_POD_CIDR via $DNS_SERVER dev enp3s0 2>/dev/null || true
    sudo ip route add $WORKER3_POD_CIDR via $DNS_SERVER dev enp3s0 2>/dev/null || true
    echo 'Control plane routes added.'
" 2>/dev/null && ok "Control plane routes configured." || warn "Control plane route setup may have failed."
# =============================================================================
section "PHASE 9 — Wait for Kubernetes to Be Ready"
# =============================================================================
info "Waiting for kube-apiserver..."
for attempt in $(seq 1 30); do
    if ssh_node "$MASTER_IP" "kubectl get nodes" >/dev/null 2>&1; then
        ok "kube-apiserver is responding."
        break
    fi
    sleep 5
    echo -n "."
done
info "Waiting for all nodes to be Ready..."
for attempt in $(seq 1 36); do
    NOT_READY=$(ssh_node "$MASTER_IP" "kubectl get nodes --no-headers 2>/dev/null | grep -v ' Ready' | wc -l" 2>/dev/null || echo "99")
    if [ "$NOT_READY" -eq 0 ]; then
        ok "All Kubernetes nodes are Ready."
        break
    fi
    sleep 5
    echo -n "."
done
# =============================================================================
section "PHASE 10 — Cluster Health Summary"
# =============================================================================
echo ""
ssh_node "$MASTER_IP" "
    echo '── Nodes ──────────────────────────────────────'
    kubectl get nodes -o wide
    echo ''
    echo '── Calico BGP Status ───────────────────────────'
    CALICO_POD=\$(kubectl get pods -n kube-system -l k8s-app=calico-node -o name 2>/dev/null | head -1)
    if [ -n \"\$CALICO_POD\" ]; then
        kubectl exec -n kube-system \$CALICO_POD -- birdcl show protocols 2>/dev/null | grep -E 'Mesh|kernel' || echo 'BGP status unavailable'
    fi
    echo ''
    echo '── DUKA Pods ───────────────────────────────────'
    kubectl get pods -n duka -o wide
    echo ''
    echo '── Falco Pods ──────────────────────────────────'
    kubectl get pods -n falco
" 2>/dev/null
echo ""
echo -e "${GREEN}${BOLD}══════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  DUKA cluster is operational! 🚀          ${RESET}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════${RESET}"
echo ""
echo -e "  Upload test:  ${CYAN}curl -X POST http://$MASTER_IP:30080/upload -F 'file=@/etc/hostname'${RESET}"
echo ""
