# DUKA Project: Flannel Topology Migration Report

This document summarizes the network incident that occurred during Day 5 (Security Hardening), after the OpenNebula topology was upgraded from a flat network to a routed Fog/Edge topology. It serves as a reference for the final project report and presentation, highlighting the root cause, the fix applied, and the architectural insights gained.

---

## 1. Background: The Topology Change

Originally, all Kubernetes VMs shared a single flat OpenNebula network:

```
vnet / minionebr — 172.16.100.0/24
├── k8s-master    172.16.100.2
├── k8s-worker-1  172.16.100.3
├── k8s-worker-2  172.16.100.4
└── k8s-worker-3  172.16.100.5
```

To better simulate a realistic Fog deployment, Person A migrated each worker to its own dedicated edge network segment, with the OpenNebula host acting as a router between the control plane and the edge networks:

```
vnet / minionebr — 172.16.100.0/24
└── k8s-master    172.16.100.2

net-edge-1 — 10.1.1.0/24
└── k8s-worker-1  10.1.1.100

net-edge-2 — 10.1.2.0/24
└── k8s-worker-2  10.1.2.100

net-edge-3 — 10.1.3.0/24
└── k8s-worker-3  10.1.3.100
```

This change broke Flannel's VXLAN overlay, causing all DUKA pods to lose pod-to-pod connectivity.

---

## 2. The Incident: What Broke and Why

### Symptom

After the topology migration, all upload attempts to the Gateway returned `Internal Server Error`. The Gateway logs showed:

```
httpx.ConnectError: All connection attempts failed
```

Python TCP connectivity tests confirmed the issue:

```bash
kubectl exec -n duka deployment/gateway -- python3 -c "..."
# TCP FAILED: [Errno 101] Network is unreachable
```

DNS resolution was working correctly — the Storage Daemon hostnames resolved to valid pod IPs (`10.244.x.x`). The problem was at the **routing layer**, not DNS.

### Root Cause Chain

The incident had four compounding causes, each discovered in sequence:

#### Cause 1 — Flannel VXLAN tunnels pointed to old worker IPs

Flannel uses node annotations to know each worker's public IP for VXLAN encapsulation. After the topology change, these annotations still contained the old flat-network addresses:

```
flannel.alpha.coreos.com/public-ip: 172.16.100.3  ← old, wrong
flannel.alpha.coreos.com/public-ip: 172.16.100.4  ← old, wrong
flannel.alpha.coreos.com/public-ip: 172.16.100.5  ← old, wrong
```

Flannel was encapsulating VXLAN packets and sending them to `172.16.100.x` addresses that no longer existed on the network.

#### Cause 2 — No pod CIDR routes on the control plane

The control plane had no routes for the worker pod subnets (`10.244.1-3.0/24`) via the new topology. Broken Flannel routes were present but pointing to `flannel.1` with invalid VXLAN endpoints:

```
10.244.1.0/24 via 10.244.1.0 dev flannel.1 onlink  ← broken
10.244.2.0/24 via 10.244.2.0 dev flannel.1 onlink  ← broken
10.244.3.0/24 via 10.244.3.0 dev flannel.1 onlink  ← broken
```

#### Cause 3 — Workers could not reach the Kubernetes API server

When Flannel pods on workers were restarted, they immediately crashed with:

```
Failed to create SubnetManager: dial tcp 10.96.0.1:443: connect: network is unreachable
```

The Kubernetes API server is exposed via ClusterIP `10.96.0.1` (service CIDR `10.96.0.0/12`). Workers had no route to this subnet after the topology change, so Flannel could not authenticate to start.

#### Cause 4 — Workers had no default route

After the topology change, workers only had specific static routes — no default gateway. Flannel requires a default route to determine which interface to use for VXLAN:

```
E main.go:325] Failed to find any valid interface to use: 
  failed to get default interface: unable to find default route
```

---

## 3. The Fix: Step-by-Step

### Step 1 — Add pod CIDR routes on the control plane

```bash
# On the control plane (172.16.100.2)
sudo ip route add 10.244.1.0/24 via 172.16.100.1
sudo ip route add 10.244.2.0/24 via 172.16.100.1
sudo ip route add 10.244.3.0/24 via 172.16.100.1
```

The control plane reaches edge networks via `172.16.100.1` (the OpenNebula host/router).

### Step 2 — Add pod CIDR routes on the OpenNebula host

```bash
# On the OpenNebula host (Azure VM)
sudo ip route add 10.244.1.0/24 via 10.1.1.100
sudo ip route add 10.244.2.0/24 via 10.1.2.100
sudo ip route add 10.244.3.0/24 via 10.1.3.100
```

The OpenNebula host is the router — it needs to know which worker holds which pod subnet.

### Step 3 — Add service CIDR routes on each worker

```bash
# On the OpenNebula host, via oneadmin SSH
sudo -u oneadmin ssh ubuntu@10.1.1.100 "sudo ip route add 10.96.0.0/12 via 10.1.1.1"
sudo -u oneadmin ssh ubuntu@10.1.2.100 "sudo ip route add 10.96.0.0/12 via 10.1.2.1"
sudo -u oneadmin ssh ubuntu@10.1.3.100 "sudo ip route add 10.96.0.0/12 via 10.1.3.1"
```

This allows workers to reach the Kubernetes API server at `10.96.0.1`.

### Step 4 — Add return routes for the master pod CIDR on each worker

```bash
sudo -u oneadmin ssh ubuntu@10.1.1.100 "sudo ip route add 10.244.0.0/24 via 10.1.1.1"
sudo -u oneadmin ssh ubuntu@10.1.2.100 "sudo ip route add 10.244.0.0/24 via 10.1.2.1"
sudo -u oneadmin ssh ubuntu@10.1.3.100 "sudo ip route add 10.244.0.0/24 via 10.1.3.1"
```

Without these, response packets from daemon pods could not reach the Gateway pod on the master.

### Step 5 — Add default routes on each worker

```bash
sudo -u oneadmin ssh ubuntu@10.1.1.100 "sudo ip route add default via 10.1.1.1"
sudo -u oneadmin ssh ubuntu@10.1.2.100 "sudo ip route add default via 10.1.2.1"
sudo -u oneadmin ssh ubuntu@10.1.3.100 "sudo ip route add default via 10.1.3.1"
```

Required for Flannel to identify which interface to use for VXLAN encapsulation.

### Step 6 — Restart Flannel and update node annotations

```bash
# Restart Flannel to pick up the new routing
kubectl delete pod -n kube-flannel --all
kubectl get pods -n kube-flannel -w
# Wait for all 4 pods to be 1/1 Running

# Update node annotations with correct edge IPs
kubectl annotate node ip-172-16-100-3 \
  flannel.alpha.coreos.com/public-ip="10.1.1.100" --overwrite
kubectl annotate node ip-172-16-100-4 \
  flannel.alpha.coreos.com/public-ip="10.1.2.100" --overwrite
kubectl annotate node ip-172-16-100-5 \
  flannel.alpha.coreos.com/public-ip="10.1.3.100" --overwrite

# Restart Flannel again to pick up the new annotations
kubectl delete pod -n kube-flannel --all
kubectl get pods -n kube-flannel -w
```

### Step 7 — Verify

```bash
# TCP connectivity test from Gateway to Storage Daemon
kubectl exec -n duka deployment/gateway -- python3 -c "
import socket
s = socket.socket()
s.settimeout(5)
try:
    s.connect(('storage-daemon-0.storage-daemon.duka.svc.cluster.local', 8000))
    print('TCP OK')
except Exception as e:
    print('TCP FAILED:', e)
finally:
    s.close()
"
# Expected: TCP OK
```

---

## 4. Architectural Insights

### Why Flannel struggled with the topology change

Flannel's VXLAN backend assumes that node public IPs are stable and reachable from all other nodes. When node IPs change (as they did during the topology migration), Flannel has no automatic mechanism to detect and update its VXLAN peer table. The stale annotations must be updated manually, and Flannel must be restarted to rebuild its FDB (Forwarding Database) entries.

This is a known operational limitation of Flannel compared to more advanced CNIs like Calico or Cilium, which use BGP or eBPF-based routing that adapts more gracefully to topology changes.

### Why this strengthens the demo

This incident reinforces Discovery A from the Security Verification Report: Flannel's simplicity, while easy to deploy, creates operational fragility in dynamic or non-trivial topologies. A CNI like Calico would have handled the topology change more gracefully and would also have enforced the NetworkPolicies that Flannel silently ignores.

### Important warning: routes are not persistent

All routes added during this fix are **ephemeral** — they will be lost if the VMs are rebooted. Before the demo, verify all routes are present:

```bash
# On control plane
ip route | grep 10.244

# On OpenNebula host
ip route | grep 10.244

# On each worker
sudo -u oneadmin ssh ubuntu@10.1.1.100 "ip route | grep -E 'default|10.96|10.244'"
sudo -u oneadmin ssh ubuntu@10.1.2.100 "ip route | grep -E 'default|10.96|10.244'"
sudo -u oneadmin ssh ubuntu@10.1.3.100 "ip route | grep -E 'default|10.96|10.244'"
```

If any routes are missing after a reboot, reapply Steps 1–5 before restarting Flannel.

---

## 5. How to Explain This in the Presentation

Short version:

> After migrating workers to isolated edge network segments, Flannel's VXLAN overlay broke because it still advertised the old flat-network IPs. We fixed it by adding the correct routing table entries at every layer of the topology — control plane, OpenNebula host router, and each worker — then updated the Flannel node annotations to advertise the new edge IPs and restarted the DaemonSet.

More technical version:

> Flannel uses node annotations to build its VXLAN peer table. After the topology change, these annotations still contained the old `172.16.100.x` addresses, causing VXLAN encapsulation to target unreachable endpoints. Additionally, workers lacked routes to the Kubernetes service CIDR (`10.96.0.0/12`) and had no default route, preventing Flannel from authenticating to the API server or identifying its VXLAN interface. The fix required adding static routes at three layers — control plane, router, and workers — updating the node annotations, and restarting Flannel to rebuild its FDB entries with the correct `10.1.x.100` peer addresses.
