# 💾 DUKA Project: VM Lifecycle & State Persistence Report

This document details the strategies applied to ensure the DUKA Fog cluster survives Azure VM deallocations and reboots. It serves as a reference for the final project report, detailing the challenge of volatile network state in custom L3 topologies and the precise recovery mechanisms implemented.

---

## 📌 1. Context: The Persistence Challenge

The DUKA cluster utilizes a highly customized, non-standard **L3 routed edge topology** inside an OpenNebula hypervisor. To achieve this Fog-like isolation, the OpenNebula host acts as a router between the control plane and three separate worker edge networks (`10.1.1.0/24`, `10.1.2.0/24`, `10.1.3.0/24`).

To make this architecture functional with Calico and external networks, we manually introduced several network modifications:
1. **NAT/Masquerade Rules:** `iptables` rules on the OpenNebula host to grant the edge workers internet access.
2. **BGP Exemptions:** `iptables` RETURN rules on the OpenNebula host to exempt Calico's BGP TCP Port 179 from NAT masquerading.
3. **Static Routing:** `ip route` entries injected into the Master and Worker nodes to allow pod-to-pod routing across the edge subnets.

### The Problem
When the Azure VM is stopped to save billing credits, the inner KVM VMs shut down, and the Linux kernel clears **all ephemeral routing and iptables rules**. 
When the VM boots back up, the cluster enters a broken state: Calico BGP peering fails, and pods cannot communicate.

---

## 🐛 2. The Solution: A Two-Part Persistence Strategy

To permanently solve the reboot amnesia without breaking the underlying OS network managers, we implemented a split persistence strategy.

### Strategy A: `iptables-persistent` (OpenNebula Host)
We installed the `iptables-persistent` package on the OpenNebula host. 
This package captures the active, correctly-configured IPv4 iptables rules (including our crucial BGP NAT exemptions and internet MASQUERADE) and saves them to `/etc/iptables/rules.v4`. 

**Why this works:** During the Linux boot sequence, the `netfilter-persistent` daemon automatically restores these rules before OpenNebula even starts the KVM workers. The routing foundation is guaranteed to be ready.

### Strategy B: The `start_duka.sh` Recovery Script (Workers & Master)
We initially considered hardcoding the static routes into Ubuntu's `netplan` on the edge workers. However, modifying `netplan` carries a severe risk: a single syntax error can permanently drop SSH connectivity to the VMs, destroying the cluster.

Instead, we opted for a safe, on-demand recovery script located on the OpenNebula host (`/home/duka/start_duka.sh`). The script uses the `oneadmin` SSH keys to surgically re-inject the exact routes needed by Calico's `bird` daemon.

**Script Contents:**
```bash
#!/bin/bash
echo "Restoring Edge Network Routes..."

# 1. Restore Master Routes to the Edge Subnets
sudo ip route add 10.244.1.0/24 via 172.16.100.1 2>/dev/null
sudo ip route add 10.244.2.0/24 via 172.16.100.1 2>/dev/null
sudo ip route add 10.244.3.0/24 via 172.16.100.1 2>/dev/null

# 2. Restore Worker Default Routes back to the OpenNebula Router
sudo -u oneadmin ssh -o StrictHostKeyChecking=no ubuntu@10.1.1.100 "sudo ip route add default via 10.1.1.1 2>/dev/null"
sudo -u oneadmin ssh -o StrictHostKeyChecking=no ubuntu@10.1.2.100 "sudo ip route add default via 10.1.2.1 2>/dev/null"
sudo -u oneadmin ssh -o StrictHostKeyChecking=no ubuntu@10.1.3.100 "sudo ip route add default via 10.1.3.1 2>/dev/null"

echo "Done! Calico BGP should now connect."
```

*(Note: The DNS fix for `systemd-resolved` we applied earlier writes directly to a configuration file, so it survives reboots natively and does not need to be in the script).*

---

## 📋 3. Operations Guide: How & When to Recover the Cluster

### When to run the script:
You **MUST** run this script every time the Azure VM is turned on after being Stopped/Deallocated. 
*(If the Azure VM has been running continuously, do not run the script).*

### Recovery Procedure:
1. Turn on the Azure VM from the portal.
2. Connect to the Azure VM via SSH as the `duka` user.
3. Execute the recovery script:
   ```bash
   ./start_duka.sh
   ```
4. **Wait 30 to 60 seconds.**
   Calico's internal BGP daemon will automatically detect the restored routes and establish the BGP mesh. The cluster will transition from a broken state back to `1/1 Running`, and the DUKA platform will be fully operational.

---

## 🏗️ 4. Architectural Lessons Learned

1. **State is Volatile at the Edge:** In a Fog environment where nodes might lose power or be frequently restarted, relying on manual terminal commands for networking is unsustainable.
2. **Infrastructure as Code (IaC):** While our bash script is an effective ad-hoc solution for this project, a true production Fog cluster would use tools like Ansible or Terraform to declaratively enforce the network state on boot.
3. **The Importance of Safe Fallbacks:** By choosing a boot script over modifying `netplan`, we prioritized system recoverability. A failed boot script simply leaves the cluster offline until re-run; a failed `netplan` renders the VM completely inaccessible.
