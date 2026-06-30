# DUKA Project: Calico CNI Migration & Network Policy Report

This document summarizes the network security upgrade performed on Day 5 (Security Hardening). We migrated the cluster's Container Network Interface (CNI) from Flannel to Calico. It serves as a reference for the final project report and presentation, detailing the rationale, the migration process, the DNS resolution incident, and the architectural insights gained.

---

## 1. Background: The Network Policy Limitation

During the Security Verification phase (Day 4), we made **Discovery A**: NetworkPolicies were completely ignored. A `wget` request from the Redis pod successfully connected to a Storage Daemon pod despite a strict `default-deny-all` NetworkPolicy being active.

The root cause was the choice of CNI. **Flannel** is a simple, lightweight networking overlay that focuses strictly on packet routing (via VXLAN) and does not natively enforce Kubernetes NetworkPolicies. 

To achieve a true Zero-Trust Fog architecture, we needed a policy-enforcing CNI. We chose to replace Flannel with **Calico**, which uses a highly scalable BGP routing engine and actively enforces NetworkPolicies using Linux iptables/eBPF.

---

## 2. The Migration: What Broke and Why

### Symptom: Workers Unable to Pull Images
After deleting Flannel and applying the Calico manifest, the `calico-node` pods on the three worker nodes (edge networks) became stuck in `Init:ImagePullBackOff` and `Init:ErrImagePull`.

### Root Cause 1: Lack of Internet NAT on Edge Networks
Because the OpenNebula topology was upgraded to a routed Fog/Edge topology, the workers resided on private `10.1.x.x` subnets. While static routes existed, the OpenNebula host router lacked NAT (`MASQUERADE`) rules. The workers' outbound traffic reached the internet, but the responses could not be routed back to the private subnets.

### Root Cause 2: Missing DNS Resolution
Even after NAT was applied, the workers could `ping 8.8.8.8` but failed to resolve `google.com` or `docker.io`. The edge networks lacked a DHCP-provided DNS server, leaving the workers without name resolution.

### Symptom: Internal Cluster DNS Blocked
Once Calico was running, the `gateway` pod attempted to resolve the `storage-daemon` service and threw a `Temporary failure in name resolution` error. Redis, however, timed out on the TCP layer.

### Root Cause 3: The True "Default Deny" Trap
When Calico became active, the existing `default-deny-all` NetworkPolicy instantly took effect. This policy blocked **all** egress traffic, including outbound UDP/TCP requests to port 53 (CoreDNS). The pods were literally blocked from asking the cluster DNS server for IP addresses.

---

## 3. The Fix: Step-by-Step

### Step 1 — Enable Edge NAT and DNS
To allow the edge workers to pull the Calico images from the internet, we applied NAT and forced the workers to use Google's DNS:
```bash
# On the OpenNebula host
sudo iptables -t nat -A POSTROUTING -s 10.1.0.0/16 -j MASQUERADE

# Update systemd-resolved on all workers
for ip in 10.1.1.100 10.1.2.100 10.1.3.100; do
  sudo -u oneadmin ssh ubuntu@$ip "sudo bash -c 'echo \"DNS=8.8.8.8\" >> /etc/systemd/resolved.conf && systemctl restart systemd-resolved'"
done
```

### Step 2 — Modify and Deploy Calico
Calico defaults to a Pod CIDR of `192.168.0.0/16`. Because our cluster was initialized with kubeadm using `10.244.0.0/16`, we had to manually patch the Calico manifest before applying it to prevent catastrophic IP conflicts:
```bash
sed -i -e 's/# - name: CALICO_IPV4POOL_CIDR/- name: CALICO_IPV4POOL_CIDR/g' calico.yaml
sed -i -e 's/#   value: "192.168.0.0\/16"/  value: "10.244.0.0\/16"/g' calico.yaml
kubectl apply -f calico.yaml
```

### Step 3 — Allow Internal DNS Egress
To fix the `default-deny-all` trap, we created a specific NetworkPolicy allowing all pods in the `duka` namespace to reach `kube-system` for DNS queries:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: duka
spec:
  podSelector: {} 
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - protocol: UDP
      port: 53
```

### Step 4 — Restart Workloads
All application pods and CoreDNS were deleted and recreated so Calico could assign them new IP addresses and inject them into the policy enforcement engine.

---

## 4. Architectural Insights

### Why we tested with Python, not Dummy Pods
Initially, we considered using dummy pods (`curlimages/curl` labeled as `app=gateway`) to test the policies. We discarded this idea because it introduces a high risk of false negatives. NetworkPolicies often match on specific labels (like `app.kubernetes.io/name=gateway`). Testing with a dummy pod might fail simply because it lacks the correct labels, misleading the security audit. 

Instead, we used the embedded Python interpreter inside the **actual** Gateway container, and the embedded `wget` binary inside the **actual** Redis container. This guarantees we are testing the true boundaries of the production architecture.

---

## 5. How to Explain This in the Presentation

**Short version:**
> "To enforce our Zero-Trust architecture, we migrated our CNI from Flannel to Calico. During the migration, we had to establish NAT and DNS routing for our isolated Edge workers. We also discovered that enforcing a strict default-deny policy actively blocks internal Kubernetes DNS requests, requiring us to explicitly punch a hole for CoreDNS. With Calico running, we successfully proved that our Gateway is allowed to reach the Storage Daemons, while Redis is completely blocked at the network layer."

**Live Verification Script:**
```bash
# Test Authorized Traffic (Gateway ➔ Storage Daemon)
# Expected: "✅ TCP OK: Connection Allowed"
kubectl exec -n duka deployment/gateway -- python3 -c "
import socket
s = socket.socket()
s.settimeout(5)
try:
    s.connect(('storage-daemon-1.storage-daemon.duka.svc.cluster.local', 8000))
    print('✅ TCP OK: Connection Allowed')
except Exception as e:
    print('❌ TCP FAILED:', e)
finally:
    s.close()
"

# Test Unauthorized Traffic (Redis ➔ Storage Daemon)
# Expected: "wget: download timed out"
kubectl exec -n duka statefulset/redis -- wget -qO- --timeout=5 http://storage-daemon-1.storage-daemon.duka.svc.cluster.local:8000/health
```
*(Point out to the professor that Redis returning "download timed out" instead of "bad address" proves that DNS resolution succeeded, but Calico actively dropped the TCP packets).*
