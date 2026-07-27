<a id="top"></a>

# D.U.K.A. - Distributed Untrusted-node Key-separated Architecture

<p align="center">
  <img src="https://img.shields.io/badge/version-1.0.0-2563EB?style=for-the-badge" alt="Version 1.0.0" />
  <a href="https://github.com/MattDema/FCC-DUKA/stargazers"><img src="https://img.shields.io/github/stars/MattDema/FCC-DUKA?style=for-the-badge&logo=github&label=Stars" alt="GitHub stars" /></a>
  <a href="https://github.com/MattDema/FCC-DUKA/graphs/contributors"><img src="https://img.shields.io/github/contributors/MattDema/FCC-DUKA?style=for-the-badge" alt="Contributors" /></a>
  <a href="https://github.com/MattDema/FCC-DUKA/forks"><img src="https://img.shields.io/github/forks/MattDema/FCC-DUKA?style=for-the-badge" alt="Forks" /></a>
  <a href="https://github.com/MattDema/FCC-DUKA/issues"><img src="https://img.shields.io/github/issues/MattDema/FCC-DUKA?style=for-the-badge" alt="Open issues" /></a>
  <img src="https://img.shields.io/github/repo-size/MattDema/FCC-DUKA?style=for-the-badge" alt="Repository size" />
  <img src="https://img.shields.io/github/last-commit/MattDema/FCC-DUKA?style=for-the-badge" alt="Last commit" />
  <img src="https://img.shields.io/github/license/MattDema/FCC-DUKA?style=for-the-badge" alt="License status" />
</p>

<p align="center">
  <img src="https://img.shields.io/badge/course-Fog%20and%20Cloud%20Computing-0F766E?style=for-the-badge" alt="Fog and Cloud Computing" />
  <img src="https://img.shields.io/badge/security-Zero%20Trust%20%7C%20AES--256--GCM-7C3AED?style=for-the-badge" alt="Zero Trust and AES-256-GCM" />
</p>

> A distributed object-storage prototype for partially trusted fog nodes. DUKA encrypts and shards objects across edge workers while separating metadata, cryptographic keys, network policy, and runtime isolation responsibilities.

**Course:** Fog and Cloud Computing 2025/26 - University of Trento

<details>
<summary><h2>Table of Contents 📖</h2></summary>

- [Motivation and scope](#1-motivation-and-scope)
- [Architecture](#2-revised-architecture)
- [Security design](#3-security-design)
- [Elasticity and failure handling](#4-elasticity--failure-handling)
- [Repository layout](#repository-layout)
- [Deploying the application](#deploying-the-application)
- [Core demos](#core-demos)
- [Security policy](#security-policy)
- [Acknowledgments](#acknowledgments)
- [Team](#team)

</details>

## 1. Motivation and Scope

Fog computing is useful when data has to be processed or stored close to where it is produced, but it leaves behind the safety net of a centralized cloud. Edge nodes may be smaller, administered by different parties, connected through non-uniform networks, and more exposed to faults or compromise. For this reason, our project treats storage nodes as useful but not fully trusted infrastructure, following the same general direction as zero-trust system design: trust is not assumed only because a component is inside the perimeter.

The goal of DUKA is to provide a shared object storage service where clients interact with a single gateway, while the actual storage work is distributed across several edge workers. Files are encrypted before being split into fragments. The fragments are placed on storage daemons running on different Kubernetes workers, while metadata and key material are kept outside the storage daemons. This gives us a compact system where we can demonstrate orchestration, elasticity, network isolation, runtime hardening, and observability.

## 2. Revised Architecture

### 2.1 OpenNebula IaaS Layer and Fog Topology

The project runs inside an Azure virtual machine that hosts OpenNebula. OpenNebula provisions four virtual machines: one Kubernetes control-plane node and three worker nodes. 

The topology separates the workers into three edge segments. The control plane remains on the original OpenNebula network, while each worker has an edge-facing interface on a different virtual network:

| Network | Bridge | Subnet | Role |
| :--- | :--- | :--- | :--- |
| Control-plane network | `minionebr` | `172.16.100.0/24` | Hosts the Kubernetes master and provides the administrative entry point. |
| `net-edge-1` | `br-edge-1` | `10.1.1.0/24` | Dedicated edge segment for worker 1. |
| `net-edge-2` | `br-edge-2` | `10.1.2.0/24` | Dedicated edge segment for worker 2. |
| `net-edge-3` | `br-edge-3` | `10.1.3.0/24` | Dedicated edge segment for worker 3. |

The Azure VM has limited CPU resources, so the OpenNebula host acts as a lightweight layer-3 router between the control-plane network and the three edge networks. This keeps the deployment reproducible while forcing the Kubernetes workers to communicate through routed paths instead of sharing one flat Ethernet segment. The host configures IP forwarding, bridge addresses, static routes, and NAT rules.

### 2.2 Kubernetes Layer

Kubernetes is responsible for the application lifecycle: deployments, stateful components, services, pod placement, health checks, and autoscaling. The cluster uses **Calico** as the CNI because the project needs actual `NetworkPolicy` enforcement (Flannel did not enforce the security policies required by the threat model).

The Kubernetes layer contains the following main components:
*   A **Gateway** deployment exposed through a NodePort service.
*   A **Redis** StatefulSet used only for object metadata.
*   A **Storage Daemon** StatefulSet with three replicas, one per worker, backed by persistent volumes.
*   A **RuntimeClass** for gVisor, used to run storage daemons with a stronger userspace isolation boundary.
*   **Calico NetworkPolicy** rules restricting lateral movement within the `duka` namespace: external ingress is permitted only to the Gateway, which is the only pod authorised to initiate connections to Redis and the Storage Daemon; DNS egress is explicitly allowed for all pods. All other traffic is denied by default.
*   `metrics-server` and a **Horizontal Pod Autoscaler** for the Gateway.

### 2.3 Application Layer

The application exposes a simple object-storage interface. 
- **Upload**: The Gateway receives the file, encrypts it with AES-256-GCM, splits the encrypted payload into fragments, and sends those fragments to the storage daemons. Redis stores the metadata needed to reconstruct the object, while the encryption key and nonce are stored as Kubernetes Secrets under a restricted service account.
- **Download**: The Gateway retrieves the metadata, asks the storage daemons for the fragments, reads the key material from the Kubernetes API, reconstructs the ciphertext, and decrypts the object before returning it to the client. 

The storage daemons never need the plaintext key. Compromising a storage node does not directly expose the original object.

## 3. Security Design

### 3.1 Threat Model
The project assumes that storage daemons and edge workers may be less trusted than the control-plane components. A compromised storage daemon should not be able to recover plaintext data by itself. A compromised pod should also have limited freedom to scan or contact unrelated services in the namespace.

### 3.2 Network Isolation with Calico
Calico enforces a deny-by-default behaviour at the pod level: once a `NetworkPolicy` selects a pod, all traffic not explicitly permitted is silently dropped. 

### 3.3 Key Separation and Kubernetes RBAC
Encryption keys are represented as Kubernetes Secrets to enforce separation of responsibilities. The Gateway service account receives the permissions needed to create, read, and delete object-specific secrets. Storage daemons do not receive those permissions.

### 3.4 Runtime Isolation and Falco
Storage daemons run with **gVisor** through a Kubernetes RuntimeClass, adding a userspace kernel boundary between the daemon and the host kernel.
**Falco** is used as the runtime security monitor to turn security into something observable, allowing us to trigger a controlled suspicious action and show a corresponding alert.

## 4. Elasticity & Failure Handling

### 4.1 Horizontal Pod Autoscaling
The Gateway is selected for autoscaling because it performs CPU-heavy work during encryption. The Gateway declares a CPU request of `100m`, and the HPA scales it between 1 and 4 replicas when average CPU usage exceeds 70%.

Load tests are split into profiles (e.g., 1 MB x 30 requests vs 10 MB x 50 requests) to demonstrate that HPA is reactive to sustained CPU load, distinguishing elasticity from unlimited capacity.

### 4.2 Gateway Resilience
Deleting a Gateway pod while background traffic is running demonstrates recovery vs high availability. With multiple Gateway replicas, traffic can continue through the remaining pods without client-visible failures.

---

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
+-- start_duka.sh                 # environment-specific OpenNebula/Kubernetes bootstrap script
```

## Deploying the Application

From the Kubernetes master, apply the manifests:

> [!IMPORTANT]
> Run DUKA only in an isolated, disposable environment. Do not commit OpenNebula host keys, Kubernetes `admin.conf`, join commands, cloud credentials, or real customer data. See [SECURITY.md](./SECURITY.md) before deployment.

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

## Core Demos

### Demo 1: End-to-End Integrity
Proves that upload, encryption, sharding, metadata storage, key retrieval, download, reassembly and decryption all work.

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

### Demo 2: Key Separation
Redis stores metadata, while Kubernetes Secrets store cryptographic material.

```bash
kubectl exec -n duka redis-0 -- redis-cli GET file:<FILE_ID>
kubectl get secrets -n duka | grep duka-key
kubectl get pod -n duka -l app=gateway -o jsonpath='{.items[0].spec.serviceAccountName}'
kubectl get role,rolebinding -n duka
```

### Demo 3: Calico Zero-Trust NetworkPolicies

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

Unauthorized traffic, Redis to Storage Daemon:
```bash
kubectl exec -n duka statefulset/redis -- \
  wget -qO- --timeout=5 http://storage-daemon-1.storage-daemon.duka.svc.cluster.local:8000/health
```
Expected result: `wget: download timed out`

### Demo 4: gVisor Isolation
Verify `runsc` on workers and RuntimeClass on Storage Daemons:

```bash
kubectl get runtimeclass -o yaml
kubectl get pod -n duka -l app=storage-daemon \
  -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.runtimeClassName}{"\n"}{end}'
```

### Demo 5: HPA and Load Testing
Check `metrics-server` and HPA:
```bash
kubectl top nodes
kubectl top pods -n duka
kubectl get hpa -n duka
```

Run load scripts:
```bash
chmod +x scripts/*.sh
./scripts/hpa-load-test-profiles.sh leggero
./scripts/hpa-load-test-profiles.sh aggressivo
```

Monitor in a separate terminal:
```bash
watch -n 1 "kubectl get hpa -n duka; echo '---'; kubectl get pods -n duka -l app=gateway"
```

### Demo 6: Gateway Resilience
Delete a Gateway pod during continuous upload traffic to observe Kubernetes reconciliation:

```bash
./scripts/gateway-resilience-kill-test.sh
```

### Demo 7: Falco Runtime Security & gVisor Trade-off

This live attack demo requires strict coordination between two terminals to show the trade-off between host-level observability (Falco) and userspace isolation (gVisor).

In Terminal B (Monitor):
```bash
# Tail the logs in the background terminal
kubectl logs -f -l app.kubernetes.io/name=falco -n falco -c falco
```

In Terminal A (Attacker):
```bash
# Attack 1: Spawn a shell in the Gateway (No gVisor)
kubectl exec deploy/gateway -n duka -- sh -c "echo 'I am an attacker spawning a shell in the Gateway'"

# Wait 2 seconds, then:
# Attack 2: Spawn a shell in the Storage Daemon (With gVisor)
kubectl exec storage-daemon-0 -n duka -- sh -c "echo 'I am an attacker spawning a shell in the Storage Daemon'"
```

**Expected Result:** You will see an alert triggered for the Gateway in Terminal B, but nothing for the Storage Daemon. This demonstrates a fundamental architectural trade-off: gVisor intercepts and handles system calls in userspace before they ever reach the host kernel. Because Falco lives on the host kernel, it is effectively blind to internal system calls happening inside the gVisor sandbox.

> [!WARNING]
> The Falco demonstration deliberately simulates suspicious activity. Run it only in an isolated test cluster that you control.

## Security policy

The current branch removes long-lived cluster-bootstrap behaviour, restricts the locally generated join command to its administrator, avoids accepting changed SSH host keys silently, and ignores local credentials and generated deployment files. Read [SECURITY.md](./SECURITY.md) for the operational checklist and production limitations.

## Acknowledgments

DUKA was developed for the **Fog and Cloud Computing** course at the University of Trento under the guidance of [**Prof. Domenico Siracusa**](https://iris.unitn.it/cris/rp/rp28498). We thank him for the course foundations, architectural guidance, and feedback that supported the development and evaluation of the project.

OpenNebula, Kubernetes, Calico, gVisor, Falco, Redis, and the other named platforms are technologies used by the prototype; no formal collaboration with their maintainers or vendors is claimed.

No infrastructure credentials, internal endpoints, host keys, join tokens, private configuration, or real deployment data are included in this repository documentation.

## Team

| Member | GitHub | LinkedIn | Email |
| --- | --- | --- | --- |
| Andrea Lo Iacono | [ADreLOI](https://github.com/ADreLOI) | [andreloi](https://www.linkedin.com/in/adreloi) | [andrea.loiacono@studenti.unitn.it](mailto:andrea.loiacono@studenti.unitn.it) |
| Matthew De Marco | [MattDema](https://github.com/MattDema) | [Matthew De Marco](https://www.linkedin.com/in/matt-de-marco/) | [matthew.demarco@studenti.unitn.it](mailto:matthew.demarco@studenti.unitn.it) |
| Jago Revrenna | [jagorev](https://github.com/jagorev) | [jagorevrenna](https://www.linkedin.com/in/jagorevrenna) | [jago.revrenna@studenti.unitn.it](mailto:jago.revrenna@studenti.unitn.it) |

<p align="center">
  <a href="#top" style="text-decoration: none;">
    <img src="https://img.icons8.com/ios-filled/50/000000/up.png" alt="Back to Top" width="40" height="40"/>
    <br>
    <strong>Back to Top</strong>
  </a>
</p>

