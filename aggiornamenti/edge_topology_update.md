# DUKA Network Update: New Fog/Edge Topology

This is an important update about the new OpenNebula network topology.
Please read this carefully before running commands against the cluster, because worker access and routing have changed.

---

## 1. Why We Changed the Topology

Originally, all Kubernetes VMs were attached to the same flat OpenNebula network:

```text
vnet / minionebr
172.16.100.0/24
```

That was enough to run Kubernetes, but it was not a realistic Fog simulation.
In a real Fog deployment, edge nodes are usually in different network segments or locations, not all on the same LAN.

We added one dedicated edge network per worker:

```text
net-edge-1 -> worker 1
net-edge-2 -> worker 2
net-edge-3 -> worker 3
```

The OpenNebula host now acts as the router between the control-plane network and the edge networks.

---

## 2. Current High-Level Topology

```text
                           OpenNebula Host
                         routing enabled
       172.16.100.1 / 10.1.1.1 / 10.1.2.1 / 10.1.3.1
                                  |
        -------------------------------------------------------
        |                         |             |              |
        |                         |             |              |
   vnet / minionebr          net-edge-1    net-edge-2     net-edge-3
   172.16.100.0/24           10.1.1.0/24   10.1.2.0/24    10.1.3.0/24
        |                         |             |              |
        |                         |             |              |
   k8s-master              k8s-worker-8   k8s-worker-9   k8s-worker-10
   172.16.100.2            10.1.1.100     10.1.2.100     10.1.3.100
```

Important:

- The master remains on the control-plane network `vnet`.
- Each worker has an edge IP in its own network.
- Kubernetes now advertises the workers using the `10.1.x.100` edge IPs.
- The OpenNebula host is currently used as the router because the Azure VM has only 4 vCPUs, already allocated to master + 3 workers.

---

## 3. Node/IP Mapping

| Role | OpenNebula VM | Kubernetes Node Name | Old IP | New Edge IP |
|---|---|---|---|---|
| Master | `k8s-master` | `ip-172-16-100-2` | `172.16.100.2` | N/A |
| Worker 1 | `k8s-worker-8` | `ip-172-16-100-3` | `172.16.100.3` | `10.1.1.100` |
| Worker 2 | `k8s-worker-9` | `ip-172-16-100-4` | `172.16.100.4` | `10.1.2.100` |
| Worker 3 | `k8s-worker-10` | `ip-172-16-100-5` | `172.16.100.5` | `10.1.3.100` |

Note:

The Kubernetes node names still contain the old IPs.
This is expected.
Renaming Kubernetes nodes would require removing/rejoining the workers, so we should not do it now.

The important value is `INTERNAL-IP`.

Expected output:

```bash
kubectl get nodes -o wide
```

```text
ip-172-16-100-2   Ready   control-plane   ...   172.16.100.2
ip-172-16-100-3   Ready   <none>          ...   10.1.1.100
ip-172-16-100-4   Ready   <none>          ...   10.1.2.100
ip-172-16-100-5   Ready   <none>          ...   10.1.3.100
```

---

## 4. Network Segments

| Network | OpenNebula Bridge | Subnet | Gateway |
|---|---|---|---|
| `vnet` | `minionebr` | `172.16.100.0/24` | `172.16.100.1` |
| `net-edge-1` | `br-edge-1` | `10.1.1.0/24` | `10.1.1.1` |
| `net-edge-2` | `br-edge-2` | `10.1.2.0/24` | `10.1.2.1` |
| `net-edge-3` | `br-edge-3` | `10.1.3.0/24` | `10.1.3.1` |

The gateways are configured on the OpenNebula host.

Check on the OpenNebula host:

```bash
for iface in minionebr br-edge-1 br-edge-2 br-edge-3; do
  ip -br addr show "$iface"
done
```

Expected:

```text
minionebr  UP  172.16.100.1/24
br-edge-1  UP  10.1.1.1/24
br-edge-2  UP  10.1.2.1/24
br-edge-3  UP  10.1.3.1/24
```

Also verify IP forwarding:

```bash
sysctl net.ipv4.ip_forward
```

Expected:

```text
net.ipv4.ip_forward = 1
```

---

## 5. SSH Access Has Changed

Workers should now be accessed through their edge IPs.

Use:

```bash
sudo -u oneadmin ssh ubuntu@10.1.1.100
sudo -u oneadmin ssh ubuntu@10.1.2.100
sudo -u oneadmin ssh ubuntu@10.1.3.100
```

Avoid relying on:

```bash
172.16.100.3
172.16.100.4
172.16.100.5
```

Those are the old flat-network addresses.
They may stop working after the final detach.

---

## 6. Routing Behavior

### Worker to Master

Worker 1 reaches the master like this:

```text
10.1.1.100 -> 10.1.1.1 -> 172.16.100.1 -> 172.16.100.2
```

Verify:

```bash
sudo -u oneadmin ssh ubuntu@10.1.1.100 "ip route get 172.16.100.2"
sudo -u oneadmin ssh ubuntu@10.1.2.100 "ip route get 172.16.100.2"
sudo -u oneadmin ssh ubuntu@10.1.3.100 "ip route get 172.16.100.2"
```

Expected:

```text
172.16.100.2 via 10.1.1.1 dev enp9s0 src 10.1.1.100
172.16.100.2 via 10.1.2.1 dev enp9s0 src 10.1.2.100
172.16.100.2 via 10.1.3.1 dev enp9s0 src 10.1.3.100
```

### Master to Workers

The master reaches the workers via the OpenNebula host router:

```text
172.16.100.2 -> 172.16.100.1 -> 10.1.x.100
```

Verify:

```bash
sudo -u oneadmin ssh ubuntu@172.16.100.2 "ping -c 3 10.1.1.100"
sudo -u oneadmin ssh ubuntu@172.16.100.2 "ping -c 3 10.1.2.100"
sudo -u oneadmin ssh ubuntu@172.16.100.2 "ping -c 3 10.1.3.100"
```

### Worker to Worker Across Edge Segments

Workers are in different subnets, so cross-worker traffic must go through the router.

Routes may need to be explicitly configured:

```bash
sudo -u oneadmin ssh ubuntu@10.1.1.100 "sudo ip route replace 10.1.2.0/24 via 10.1.1.1"
sudo -u oneadmin ssh ubuntu@10.1.1.100 "sudo ip route replace 10.1.3.0/24 via 10.1.1.1"

sudo -u oneadmin ssh ubuntu@10.1.2.100 "sudo ip route replace 10.1.1.0/24 via 10.1.2.1"
sudo -u oneadmin ssh ubuntu@10.1.2.100 "sudo ip route replace 10.1.3.0/24 via 10.1.2.1"

sudo -u oneadmin ssh ubuntu@10.1.3.100 "sudo ip route replace 10.1.1.0/24 via 10.1.3.1"
sudo -u oneadmin ssh ubuntu@10.1.3.100 "sudo ip route replace 10.1.2.0/24 via 10.1.3.1"
```

Then test:

```bash
sudo -u oneadmin ssh ubuntu@10.1.1.100 "ip route get 10.1.2.100; ping -c 3 10.1.2.100"
sudo -u oneadmin ssh ubuntu@10.1.1.100 "ip route get 10.1.3.100; ping -c 3 10.1.3.100"
sudo -u oneadmin ssh ubuntu@10.1.2.100 "ip route get 10.1.3.100; ping -c 3 10.1.3.100"
```

Expected route examples:

```text
10.1.2.100 via 10.1.1.1 dev enp9s0 src 10.1.1.100
10.1.3.100 via 10.1.1.1 dev enp9s0 src 10.1.1.100
10.1.3.100 via 10.1.2.1 dev enp9s0 src 10.1.2.100
```

---

## 7. Kubernetes / Flannel Status

Kubernetes has already accepted the new worker Internal IPs.

Check:

```bash
sudo -u oneadmin ssh ubuntu@172.16.100.2 "kubectl get nodes -o wide"
sudo -u oneadmin ssh ubuntu@172.16.100.2 "kubectl get pods -n duka -o wide"
sudo -u oneadmin ssh ubuntu@172.16.100.2 "kubectl get pods -n kube-flannel -o wide"
```

Expected:

- all nodes should be `Ready`;
- DUKA pods should be `Running`;
- Flannel pods on workers should show IPs `10.1.1.100`, `10.1.2.100`, `10.1.3.100`.

Example:

```text
kube-flannel on worker 1 -> 10.1.1.100
kube-flannel on worker 2 -> 10.1.2.100
kube-flannel on worker 3 -> 10.1.3.100
```

---

## 8. Current State vs Final State

### Current State

Workers have edge IPs and Kubernetes uses them, but the old NIC may still exist.

```text
k8s-master    -> vnet
k8s-worker-8  -> vnet + net-edge-1
k8s-worker-9  -> vnet + net-edge-2
k8s-worker-10 -> vnet + net-edge-3
```

### Final Target State

After detach, workers should only remain on their edge networks:

```text
k8s-master    -> vnet
k8s-worker-8  -> net-edge-1 only
k8s-worker-9  -> net-edge-2 only
k8s-worker-10 -> net-edge-3 only
```

This removes the old flat-network shortcut and forces worker traffic through the routed Fog topology.

---

## 9. Important Warning Before Detach

Do **not** detach all old NICs at once.

Detach one worker at a time and verify after each step:

```bash
kubectl get nodes -o wide
kubectl get pods -n duka -o wide
kubectl get pods -n kube-flannel -o wide
```

If one worker breaks, stop immediately and rollback that worker before touching the others.

---

## 10. How to Explain This in the Presentation

Short version:

> We moved from a flat OpenNebula network to a routed Fog-like topology. The master remains on the control-plane network, while each worker is attached to a separate edge network. The OpenNebula host routes between the control plane and the edge segments.

More technical version:

> The old setup placed all VMs in the same L2 segment. Now each worker has its own edge subnet: `10.1.1.0/24`, `10.1.2.0/24`, and `10.1.3.0/24`. Kubernetes advertises the workers using the edge IPs, and Flannel is running on those addresses. This better simulates geographically separated Fog nodes connected through routed infrastructure.

Honest note:

> We initially tried to instantiate a dedicated router VM, but the Azure host only has 4 vCPUs, already allocated to the master and three workers. To avoid disrupting the running cluster, we implemented the routing function directly on the OpenNebula host.

