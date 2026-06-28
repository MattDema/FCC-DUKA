# FCC-DUKA

Distributed, untrusted-node, key-separated object storage for a Fog Computing scenario.

DUKA is a course project for Fog and Cloud Computing. It demonstrates how to run a secure object storage service on Kubernetes workers that simulate geographically separated edge nodes. Files are encrypted, split into shards, distributed across isolated edge workers, and reconstructed only through the Gateway.

The project is intentionally more than a happy-path demo: it includes a routed OpenNebula edge topology, Calico-enforced NetworkPolicies, gVisor sandboxing, Kubernetes Secret based key separation, HPA/load testing, resilience testing, and Falco runtime monitoring experiments.

## Current Live Snapshot

This section reflects the latest audit captured on `2026-06-28 14:07 UTC` from the Azure/OpenNebula VM.

| Area | Current State |
|---|---|
| Cloud host | Azure VM `opennebula-host`, 4 vCPU, 32 GB RAM |
| OpenNebula | 4 running VMs: 1 master, 3 workers |
| CPU allocation | 400/400 percent allocated; no room for an extra router VM |
| Kubernetes | v1.29.15, all 4 nodes `Ready` |
| CNI | Calico active and running on all nodes |
| Gateway | 1/1 Running, NodePort `30080`, Service IP `10.106.233.31` |
| Redis | 1/1 Running, persistent PVC |
| Storage Daemons | 3/3 Running, one per worker, persistent PVCs |
| gVisor | `RuntimeClass/gvisor` installed; all Storage Daemons use it |
| NetworkPolicies | Enforced by Calico; verified with positive and negative tests |
| HPA | Configured 1-4 replicas, but current metrics are `<unknown>/70%` because metrics-server is in CrashLoopBackOff |
| Falco | Installed with custom rules; master pod is healthy, worker Falco pods are unstable/partially ready |

## Why This Project Is Interesting

DUKA addresses a realistic Fog problem: edge nodes cannot be fully trusted, but they are useful storage/compute locations. The design reduces trust in each individual component.

- A compromised Storage Daemon only sees encrypted shards.
- A compromised Redis instance only sees routing metadata, not encryption keys.
- A compromised pod is limited by Kubernetes security contexts and NetworkPolicies.
- Storage Daemons run inside gVisor, reducing host-kernel exposure.
- Gateway traffic can scale through HPA when metrics-server is healthy.
- Failure and recovery are explicitly tested by deleting Gateway pods during traffic.

## Architectural Insights and Lessons Learned

This project is valuable not only because the final system works, but because the implementation exposed several real cloud-native trade-offs. These are the main theoretical insights behind the design and the debugging work.

### 1. Fog Simulation Requires Real Failure Domains

Running several VMs on the same flat subnet is still mostly a local cluster. By moving each worker into its own OpenNebula Virtual Network (`10.1.1.0/24`, `10.1.2.0/24`, `10.1.3.0/24`), the project moved from a simple Kubernetes lab to a routed Fog topology. Each worker now behaves more like a separate edge site behind a network boundary.

The OpenNebula host is therefore not just a hypervisor. It is also part of the network architecture: it routes traffic between the control plane and the edge segments, applies NAT, and must preserve routing state across VM restarts.

### 2. Networking Is Part of the Threat Model

The network is not only "plumbing". It is one of the security controls. DUKA combines two kinds of segmentation:

- Infrastructure segmentation: each edge worker lives in a different L3 subnet.
- Kubernetes segmentation: Calico NetworkPolicies define which pods may communicate.

This matters because a compromised Storage Daemon should not be able to scan Redis, reach other daemons, or laterally move across the namespace. The network model is therefore a direct expression of the threat model.

### 3. NetworkPolicies Are Only Real If the CNI Enforces Them

Kubernetes accepts `NetworkPolicy` objects independently of the CNI plugin. With Flannel, policies were accepted by the API server but not enforced in the dataplane. Redis could still reach a Storage Daemon even under a default-deny policy.

The Calico migration turned the same YAML objects into real packet filtering rules. This is a key lesson:

```text
NetworkPolicy intent lives in Kubernetes.
NetworkPolicy enforcement lives in the CNI.
```

### 4. Default-Deny Breaking DNS Was a Good Sign

When Calico started enforcing `default-deny-all`, it also blocked DNS egress to CoreDNS. That initially broke service discovery, but it proved that the policy engine was actually active.

In Kubernetes, DNS is part of the runtime dependency graph. A service that talks to `redis.duka.svc.cluster.local` or `storage-daemon-0.storage-daemon.duka.svc.cluster.local` depends on UDP/TCP 53 egress to CoreDNS. A true zero-trust policy must explicitly allow that traffic.

### 5. CNI Migration Leaves Kernel State Behind

Deleting Flannel from Kubernetes does not automatically remove every iptables chain it installed on the nodes. During the Calico migration, old `FLANNEL-POSTRTG` masquerade rules kept rewriting pod source IPs to node IPs.

This caused Calico to drop traffic because packets no longer appeared to come from an `app=gateway` pod. The control plane looked clean, but the Linux dataplane still contained stale state.

The lesson is that CNI migration must include both:

- Kubernetes resource cleanup.
- Kernel dataplane cleanup: routes, iptables chains, tunnels and NAT rules.

### 6. Same-Node Success and Cross-Node Failure Is a Diagnostic Pattern

During debugging, traffic from the Gateway to same-node pods worked, while traffic to pods on other workers failed. That pattern is extremely useful: it usually points to routing, encapsulation, NAT or POSTROUTING issues rather than application code or DNS.

In this project, `tcpdump` on both the pod-side `cali*` interface and the node-side `enp9s0` interface revealed the source IP rewrite. Observing a packet before and after POSTROUTING was the fastest way to find the bug.

### 7. BGP and NAT Need Careful Boundaries

Calico uses BGP for route distribution. BGP peering is identity-sensitive: peers expect connections from known node IPs. If a router applies MASQUERADE to TCP port 179, the source IP can change from a node IP to a bridge gateway IP, and BIRD rejects the session as an unexpected peer.

This is why the OpenNebula host needs NAT exemptions for BGP traffic:

```bash
sudo iptables -t nat -I POSTROUTING 1 -p tcp --dport 179 -j RETURN
sudo iptables -t nat -I POSTROUTING 1 -p tcp --sport 179 -j RETURN
```

### 8. Overlay Encapsulation Is Not Always Better

Calico's `ipipMode: Always` is useful in some environments, but it conflicted with this routed edge topology. DUKA already had an underlay route between subnets through the OpenNebula host, so IPIP encapsulation added complexity instead of solving a problem.

For this topology, plain L3 routing with Calico policy enforcement is the cleaner model.

### 9. StatefulSet Provides Identity, Not Only Persistence

The Storage Daemons are implemented as a StatefulSet because the Gateway stores exact daemon URLs in Redis:

```text
storage-daemon-0.storage-daemon.duka.svc.cluster.local
storage-daemon-1.storage-daemon.duka.svc.cluster.local
storage-daemon-2.storage-daemon.duka.svc.cluster.local
```

A Deployment would give interchangeable pods. That is useful for stateless services, but harmful here: Redis metadata must continue to point to the same logical shard holders. StatefulSet gives both persistent storage and stable identity.

### 10. Key Separation Reduces Blast Radius

The original design stored metadata and cryptographic material together. The improved design splits reconstruction knowledge:

- Redis stores file metadata, shard IDs and daemon URLs.
- Kubernetes Secrets store AES keys and GCM nonces.

Compromising Redis alone is not enough to decrypt files. Compromising a Storage Daemon alone exposes only encrypted shards. This is defense in depth through separation of concerns.

Kubernetes Secrets are still not a full production-grade KMS. They improve RBAC boundaries, but production would require etcd encryption at rest, a KMS provider, or Vault.

### 11. gVisor Improves Isolation but Changes Observability

Storage Daemons run with `runtimeClassName: gvisor`. gVisor places a userspace kernel between the container and the host kernel, reducing the risk that untrusted shard-handling code can exploit host syscalls.

The trade-off is observability. Falco watches host-kernel syscalls through eBPF. If gVisor handles some syscall activity inside its own userspace kernel, Falco may not see the same events it sees from standard `runc` containers.

This is an important security insight:

```text
Stronger isolation can reduce host-level visibility.
```

### 12. Prevention, Isolation and Detection Are Different Layers

DUKA intentionally combines three different security layers:

- Prevention: Calico NetworkPolicies block unauthorized traffic.
- Isolation: gVisor sandboxes untrusted Storage Daemons.
- Detection: Falco reports suspicious runtime behavior.

No single layer is enough. NetworkPolicies do not sandbox syscalls. gVisor does not express service-to-service authorization. Falco detects behavior but does not prevent all attacks by itself.

### 13. HPA Is Reactive, Not Protective

The HPA test exposed a classic race condition: very aggressive upload traffic can trigger an `OOMKilled` event before HPA has time to observe CPU metrics and scale the Deployment.

HPA is a feedback controller. It samples metrics, compares them to a target, and changes replica count. It cannot protect a pod from instantaneous memory spikes. This is why resource limits, payload size, concurrency and autoscaling policy must be designed together.

Also, CPU-based HPA requires `resources.requests.cpu`. Without CPU requests, Kubernetes cannot compute utilization and the HPA target becomes `<unknown>`.

### 14. Resilience and High Availability Are Different

The Gateway pod kill test demonstrates two different properties:

- With one replica, Kubernetes shows recovery: the Deployment recreates the deleted pod, but some requests can fail during the gap.
- With multiple replicas, Kubernetes shows availability: surviving pods can keep serving traffic while the failed pod is replaced.

Recovery means the system returns to the desired state. High availability means users may not observe the failure.

### 15. Edge State Persistence Is Part of Fog Reliability

In a Fog environment, nodes may reboot, disconnect or lose power. Runtime network state such as `ip route` entries and iptables rules is volatile. If the Azure VM is deallocated, routes, NAT and BGP-related rules may disappear unless they are persisted or restored.

This is why the project includes a lifecycle strategy: persist iptables where possible and use a recovery script/runbook to restore static routes safely after VM startup. This is not just an operational trick; it is part of making a Fog topology recoverable.

### 16. Test With Real Pods, Not Dummy Pods

NetworkPolicies depend on pod labels, namespaces and selectors. A dummy curl pod can produce misleading results because it may not match the same labels as the real Gateway or Redis pods.

The project therefore tests policies from the actual Gateway and Redis containers. That makes the result representative of the production architecture.

### 17. Git Manifests, Live Cluster State and Runbooks Can Drift

A Kubernetes project has multiple sources of truth:

- Git manifests describe the intended system.
- The live cluster contains the actual system.
- Operational scripts and runbooks describe how to recover or mutate the system.

The DUKA debugging process showed that keeping these three aligned is itself a cloud engineering problem. The README should therefore be read together with the current audit output before a final live demo.

## Architecture

```text
Client
  |
  | HTTP upload/download
  v
Gateway Deployment
  - FastAPI API server
  - AES-256-GCM encryption/decryption
  - ciphertext sharding and reassembly
  - writes metadata to Redis
  - writes key material to Kubernetes Secrets
  |
  | shard writes/reads
  v
Storage Daemon StatefulSet
  - 3 replicas
  - stable DNS names through a headless Service
  - one daemon per worker via pod anti-affinity
  - gVisor sandbox through RuntimeClass
  - persistent shard storage through PVCs

Redis StatefulSet
  - stores file_id, filename, size, shard IDs and daemon URLs
  - does not store AES keys or nonces

Kubernetes Secrets
  - one Secret per uploaded file
  - stores AES key and GCM nonce
  - accessible only by the Gateway ServiceAccount
```

## Repository Layout

```text
.
+-- context/                      # cloud-init for Kubernetes master/workers
+-- duka/app/
|   +-- gateway/                  # FastAPI Gateway
|   +-- storage-daemon/           # FastAPI shard store
|   `-- test/                     # local test helper
+-- k8s/manifests/
|   +-- gateway-*.yaml            # Gateway Deployment, Service, RBAC
|   +-- storage-daemon-*.yaml     # Storage StatefulSet + headless Service
|   +-- redis-*.yaml              # Redis StatefulSet + headless Service
|   +-- network-policy-*.yaml     # Zero-trust NetworkPolicies
|   +-- gvisor-runtimeclass.yaml  # RuntimeClass used by Storage Daemons
|   `-- falco/falco-values.yaml   # Falco Helm values and custom DUKA rules
+-- network/                      # OpenNebula base network template
+-- scripts/                      # provisioning, gVisor, load and resilience tests
+-- templates/                    # OpenNebula VM templates
+-- CHEAT_SHEET.md                # operational notes
`-- snapshot.txt                  # infrastructure snapshot
```

## Live Fog/Edge Topology

The current topology is no longer flat. The old worker NICs were detached; each worker is now attached only to its dedicated edge network. The OpenNebula host acts as the router because the Azure VM has no free vCPU for a separate OpenNebula Virtual Router.

```text
Azure VM: opennebula-host
  - eth0:        10.0.0.4/24       Azure-side interface
  - minionebr:   172.16.100.1/24   control-plane bridge
  - br-edge-1:   10.1.1.1/24       edge segment 1 gateway
  - br-edge-2:   10.1.2.1/24       edge segment 2 gateway
  - br-edge-3:   10.1.3.1/24       edge segment 3 gateway

Control-plane network: vnet / minionebr / 172.16.100.0/24
  `-- k8s-master      172.16.100.2

Edge network 1: net-edge-1 / br-edge-1 / 10.1.1.0/24
  `-- k8s-worker-8    10.1.1.100

Edge network 2: net-edge-2 / br-edge-2 / 10.1.2.0/24
  `-- k8s-worker-9    10.1.2.100

Edge network 3: net-edge-3 / br-edge-3 / 10.1.3.0/24
  `-- k8s-worker-10   10.1.3.100
```

Kubernetes still has old-looking node names, but the `INTERNAL-IP` column is correct:

```text
NAME              STATUS   ROLES           INTERNAL-IP
ip-172-16-100-2   Ready    control-plane   172.16.100.2
ip-172-16-100-3   Ready    <none>          10.1.1.100
ip-172-16-100-4   Ready    <none>          10.1.2.100
ip-172-16-100-5   Ready    <none>          10.1.3.100
```

Useful topology checks:

```bash
sudo -u oneadmin onevm list
sudo -u oneadmin onevnet list
ip -br addr
ip route
sysctl net.ipv4.ip_forward
sudo iptables -t nat -S
sudo -u oneadmin ssh ubuntu@172.16.100.2 "kubectl get nodes -o wide"
```

## Deployed Kubernetes Workloads

Latest audit:

```text
duka/gateway            1/1 Running   10.244.223.195   node ip-172-16-100-4
duka/redis-0            1/1 Running   10.244.147.129   node ip-172-16-100-3
duka/storage-daemon-0   1/1 Running   10.244.147.130   node ip-172-16-100-3
duka/storage-daemon-1   1/1 Running   10.244.97.195    node ip-172-16-100-5
duka/storage-daemon-2   1/1 Running   10.244.223.193   node ip-172-16-100-4
```

Services:

```text
gateway          NodePort    10.106.233.31   8080:30080/TCP
redis            Headless    None            6379/TCP
storage-daemon   Headless    None            8000/TCP
```

Persistent volumes:

- Redis PVC: `1Gi`, `local-path`
- Storage Daemon PVCs: `3 x 2Gi`, `local-path`

## Deploying the Application

From the Kubernetes master, apply the manifests:

```bash
kubectl apply -f k8s/manifests/namespace.yaml
kubectl apply -f k8s/manifests/gateway-rbac.yaml
kubectl apply -f k8s/manifests/gvisor-runtimeclass.yaml
kubectl apply -f k8s/manifests/redis-service.yaml
kubectl apply -f k8s/manifests/redis-statefulset.yaml
kubectl apply -f k8s/manifests/storage-daemon-service.yaml
kubectl apply -f k8s/manifests/storage-daemon-statefulset.yaml
kubectl apply -f k8s/manifests/gateway-service.yaml
kubectl apply -f k8s/manifests/gateway-deployment.yaml
kubectl apply -f k8s/manifests/network-policy-default-deny.yaml
kubectl apply -f k8s/manifests/network-policy-allow-gateway.yaml
kubectl apply -f k8s/manifests/network-policy-allow-storage-redis.yaml
```

Verify:

```bash
kubectl get pods -n duka -o wide
kubectl get svc -n duka
kubectl get pvc -n duka
kubectl get networkpolicy -n duka
```

## Core Demo 1: End-to-End Integrity

This proves that upload, encryption, sharding, metadata storage, key retrieval, download, reassembly and decryption all work.

Run on the master:

```bash
GATEWAY="http://localhost:30080"
dd if=/dev/urandom of=/tmp/duka-original.bin bs=1M count=1 2>/dev/null
ORIG=$(md5sum /tmp/duka-original.bin | awk '{print $1}')
RESP=$(curl -s -X POST "$GATEWAY/upload" -F file=@/tmp/duka-original.bin)
echo "$RESP"
FILE_ID=$(echo "$RESP" | sed -n 's/.*"file_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
curl -s "$GATEWAY/download/$FILE_ID" -o /tmp/duka-downloaded.bin
DOWN=$(md5sum /tmp/duka-downloaded.bin | awk '{print $1}')
echo "ORIGINAL_MD5=$ORIG"
echo "DOWNLOADED_MD5=$DOWN"
[ "$ORIG" = "$DOWN" ] && echo "RESULT=INTEGRITY_OK" || echo "RESULT=INTEGRITY_FAILED"
```

Observed result from the audit:

```text
UPLOAD_RESPONSE={"file_id":"e8642546-96dd-4190-a2c4-1a809b25df6b","filename":"duka-original.bin","shards":3,"size_bytes":1048576}
ORIGINAL_MD5=93fb73e58d344da06c499e37c25bf27c
DOWNLOADED_MD5=93fb73e58d344da06c499e37c25bf27c
RESULT=INTEGRITY_OK
```

## Core Demo 2: Key Separation

Redis stores metadata, while Kubernetes Secrets store cryptographic material.

```bash
kubectl exec -n duka redis-0 -- redis-cli GET file:<FILE_ID>
kubectl get secrets -n duka | grep duka-key
kubectl get pod -n duka -l app=gateway -o jsonpath='{.items[0].spec.serviceAccountName}'
kubectl get role,rolebinding -n duka
```

Expected:

- Redis metadata contains shard IDs and daemon URLs.
- Redis metadata does not contain `key_hex` or `nonce_hex`.
- The Gateway uses `gateway-sa`.
- `gateway-sa` can `create`, `get`, and `delete` Secrets in namespace `duka`.

## Core Demo 3: Calico Zero-Trust NetworkPolicies

The project originally exposed a key limitation of Flannel: Kubernetes accepted NetworkPolicy objects, but Flannel did not enforce them. The live cluster now runs Calico, which actively enforces policies.

Verify Calico:

```bash
kubectl get pods -A -o wide | grep -Ei 'calico|coredns'
kubectl get ds -n kube-system calico-node
kubectl get crd | grep -i calico
kubectl get networkpolicy -n duka
```

Observed CNI state:

```text
kube-system/calico-node                 4/4 available
kube-system/calico-kube-controllers     1/1 Running
kube-system/coredns                     2/2 Running
```

Authorized traffic, Gateway to Storage Daemon:

```bash
kubectl exec -n duka deployment/gateway -- python3 -c "
import socket
s = socket.socket()
s.settimeout(5)
try:
    s.connect(('storage-daemon-1.storage-daemon.duka.svc.cluster.local', 8000))
    print('RESULT=GATEWAY_TO_STORAGE_ALLOWED')
except Exception as e:
    print('RESULT=GATEWAY_TO_STORAGE_FAILED', e)
finally:
    s.close()
"
```

Observed result:

```text
RESULT=GATEWAY_TO_STORAGE_ALLOWED
```

Unauthorized traffic, Redis to Storage Daemon:

```bash
kubectl exec -n duka statefulset/redis -- \
  wget -qO- --timeout=5 http://storage-daemon-1.storage-daemon.duka.svc.cluster.local:8000/health
echo $?
```

Observed result:

```text
wget: download timed out
command terminated with exit code 1
```

This is the desired result: DNS resolution works, but Calico drops unauthorized TCP traffic.

## Core Demo 4: gVisor Isolation

The Storage Daemons run under gVisor:

```bash
kubectl get runtimeclass -o yaml
kubectl get pod -n duka -l app=storage-daemon \
  -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.runtimeClassName}{"\n"}{end}'
```

Observed result:

```text
storage-daemon-0 -> gvisor
storage-daemon-1 -> gvisor
storage-daemon-2 -> gvisor
```

Verify `runsc` on workers:

```bash
sudo -u oneadmin ssh ubuntu@10.1.1.100 "runsc --version"
sudo -u oneadmin ssh ubuntu@10.1.2.100 "runsc --version"
sudo -u oneadmin ssh ubuntu@10.1.3.100 "runsc --version"
```

Observed version:

```text
runsc version release-20260622.0
spec: 1.2.1
```

## Core Demo 5: HPA and Load Testing

The Gateway has CPU requests, so it can be targeted by the HPA:

```yaml
resources:
  requests:
    cpu: 100m
```

HPA is configured:

```bash
kubectl get hpa -n duka
```

Current audit result:

```text
gateway   Deployment/gateway   <unknown>/70%   min 1   max 4   replicas 1
```

This means HPA exists, but the current metrics pipeline is unhealthy. The audit shows `metrics-server` in `CrashLoopBackOff`, so CPU usage is currently `<unknown>`.

Fix/check metrics-server before demoing live autoscaling:

```bash
kubectl get pods -n kube-system | grep metrics-server
kubectl logs -n kube-system deploy/metrics-server --tail=80
kubectl patch deployment metrics-server -n kube-system --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl rollout restart deployment metrics-server -n kube-system
kubectl top nodes
kubectl top pods -n duka
```

Load scripts:

```bash
chmod +x scripts/*.sh

./scripts/autoscaling-test.sh
./scripts/hpa-load-test-profiles.sh leggero
./scripts/hpa-load-test-profiles.sh medio
./scripts/hpa-load-test-profiles.sh medio50
./scripts/hpa-load-test-profiles.sh aggressivo
./scripts/integrity-under-load-test.sh
./scripts/gateway-resilience-kill-test.sh
```

Useful monitor:

```bash
watch -n 1 "kubectl get hpa -n duka; echo '---'; kubectl get pods -n duka -o wide"
```

Important interpretation:

- `1MB x 30` is a realistic load profile.
- `10MB x 50` is intentionally aggressive and can cause OOM before HPA reacts.
- HPA reacts to metrics; it cannot prevent every memory spike.

## Core Demo 6: Gateway Resilience

The resilience test deletes one Gateway pod during continuous upload traffic:

```bash
./scripts/gateway-resilience-kill-test.sh
```

Expected story:

- With one Gateway replica, deleting the pod creates a short visible failure window.
- With multiple Gateway replicas, the remaining pods can keep serving traffic while Kubernetes recreates the deleted pod.
- Kubernetes guarantees desired-state reconciliation, not preservation of every in-flight request.

## Falco Runtime Detection

Falco is installed with DUKA custom rules:

```bash
helm upgrade --install falco falcosecurity/falco \
  --namespace falco \
  --create-namespace \
  -f k8s/manifests/falco/falco-values.yaml
```

Verify:

```bash
kubectl get pods -n falco -o wide
kubectl logs -n falco -l app.kubernetes.io/name=falco -c falco --since=10m --tail=80
```

Current audit state:

```text
falco-f5sct   2/2 Running            master
falco-dvrbf   1/2 CrashLoopBackOff   worker
falco-l75hz   1/2 Running/restarting worker
falco-x2sgl   1/2 Running/restarting worker
```

This should be presented honestly: Falco is integrated and its rules load, but the worker pods are unstable in the current VM. The likely causes are the constrained one-vCPU worker setup and health probe timeouts. This is a useful operational finding, not a hidden failure.

Security trade-off discovered during the project:

- Falco sees standard `runc` containers well.
- gVisor can hide some syscall-level activity from host eBPF visibility.
- This demonstrates a real defense-in-depth trade-off: stronger sandboxing can reduce host-level observability.

## Current Known Issues

These are real findings from the latest audit.

| Issue | Evidence | Impact | Recommended Action |
|---|---|---|---|
| Router persistence missing | `duka-edge-router-restore.service` not found | Edge routing may disappear after Azure deallocation/reboot | Create systemd restore service before deallocating |
| Sysctl persistence missing | `/etc/sysctl.d/99-duka-router.conf` missing | `ip_forward=1` may not survive reboot | Persist `net.ipv4.ip_forward=1` |
| Duplicate NAT rule | two `MASQUERADE -s 10.1.0.0/16` rules | Not fatal, but messy | Deduplicate iptables restore logic |
| metrics-server unhealthy | `CrashLoopBackOff`; HPA target `<unknown>/70%` | Live HPA demo will not work until fixed | Restart/fix metrics-server and verify `kubectl top` |
| Falco unstable on workers | worker pods `1/2`, restarts/CrashLoop | Falco demo should be scoped carefully | Present as operational limitation or tune probes/resources |
| Test pods left behind | `test-daemon` Pending, `test-gateway` Completed | Cosmetic noise | Delete old test pods before final demo |
| VM repo is not the final GitHub repo | `~/fog-project` is not a git repo and lacks app/manifests | Could confuse teammates | Use the final GitHub repo as source of truth |

Cleanup before final demo:

```bash
kubectl delete pod -n duka test-daemon test-gateway --ignore-not-found
kubectl delete pod -n default falco-tester --ignore-not-found
```

## Before Deallocating the Azure VM

Do not deallocate the Azure VM until the runtime network state is persisted. The audit shows the current topology works, but key routing components are only in runtime state.

### 1. Persist IP forwarding

On the OpenNebula host:

```bash
echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-duka-router.conf
sudo sysctl --system
```

### 2. Create a router restore script

```bash
sudo tee /usr/local/sbin/duka-edge-router-restore.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -e

ip addr replace 172.16.100.1/24 dev minionebr || true
ip addr replace 10.1.1.1/24 dev br-edge-1 || true
ip addr replace 10.1.2.1/24 dev br-edge-2 || true
ip addr replace 10.1.3.1/24 dev br-edge-3 || true

sysctl -w net.ipv4.ip_forward=1

iptables -t nat -C POSTROUTING -s 10.1.0.0/16 -j MASQUERADE 2>/dev/null || \
  iptables -t nat -A POSTROUTING -s 10.1.0.0/16 -j MASQUERADE

ip route replace 10.96.0.0/12 via 172.16.100.2 dev minionebr || true
ip route replace 10.244.97.192/26 via 10.1.3.100 dev br-edge-3 || true
ip route replace 10.244.147.128/26 via 10.1.1.100 dev br-edge-1 || true
ip route replace 10.244.223.192/26 via 10.1.2.100 dev br-edge-2 || true
EOF

sudo chmod +x /usr/local/sbin/duka-edge-router-restore.sh
```

### 3. Enable the restore service

```bash
sudo tee /etc/systemd/system/duka-edge-router-restore.service >/dev/null <<'EOF'
[Unit]
Description=Restore DUKA OpenNebula edge router IPs, NAT and routes
After=network-online.target opennebula.service libvirtd.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/duka-edge-router-restore.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable duka-edge-router-restore.service
sudo systemctl start duka-edge-router-restore.service
sudo systemctl status duka-edge-router-restore.service --no-pager
```

### 4. Final pre-deallocation checks

```bash
ip -br addr show minionebr
ip -br addr show br-edge-1
ip -br addr show br-edge-2
ip -br addr show br-edge-3
sysctl net.ipv4.ip_forward
sudo iptables -t nat -S | grep 10.1.0.0
systemctl status duka-edge-router-restore.service --no-pager

sudo -u oneadmin onevm list
sudo -u oneadmin onevnet list
sudo -u oneadmin ssh ubuntu@172.16.100.2 "kubectl get nodes -o wide"
sudo -u oneadmin ssh ubuntu@172.16.100.2 "kubectl get pods -A -o wide"
```

## Restart Checklist After Azure Deallocation

After starting the Azure VM again:

```bash
sudo systemctl start duka-edge-router-restore.service
sudo -u oneadmin onevm list

for iface in minionebr br-edge-1 br-edge-2 br-edge-3; do
  ip -br addr show "$iface"
done

sudo -u oneadmin ssh ubuntu@172.16.100.2 "kubectl get nodes -o wide"
sudo -u oneadmin ssh ubuntu@172.16.100.2 "kubectl get pods -A -o wide"
sudo -u oneadmin ssh ubuntu@172.16.100.2 "kubectl get hpa -n duka"
```

If the Azure public IP is dynamic, it may change after deallocation. Use a static public IP before the final demo if external access matters.

## Presentation Summary

The strongest story for the professor is:

1. DUKA stores files across untrusted edge nodes without trusting the nodes with plaintext.
2. The Fog topology is not just claimed; workers are isolated into separate OpenNebula edge networks.
3. Calico proves zero-trust enforcement: Gateway is allowed to reach Storage, Redis is denied.
4. gVisor sandboxes the untrusted Storage Daemons.
5. Key material is separated from Redis and protected by Kubernetes RBAC.
6. Integrity testing proves the system still returns the exact original file after encryption, sharding, distribution, retrieval and decryption.
7. HPA and resilience tests show elasticity and Kubernetes reconciliation, while the metrics-server issue is a real operational caveat discovered through testing.
