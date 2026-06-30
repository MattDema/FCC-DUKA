# 🎤 DUKA Project: Extended Presentation & Live Demo Masterclass (15-20 Mins)

This extended script is designed to fill a 15-20 minute presentation comfortably. It includes deep architectural insights, the specific troubleshooting steps your team took, and structured talking points for each live demo.

---

## ⏱️ Part 1: Architecture & Fog Topology (3-4 mins)

**What to do:**
Display the OpenNebula/Kubernetes Architecture Diagram (showing the nested VMs and Edge Subnets).

**What to say:**
* "Welcome to the presentation of DUKA, a distributed, secure file storage platform designed specifically for Fog Computing environments."
* "Most cloud deployments use a flat L2 network overlay. We wanted to simulate a true Edge/Fog topology, so we used OpenNebula nested virtualization to create **isolated L3 network segments** (`10.1.1.0/24`, etc.) for our worker nodes."
* "The OpenNebula host acts as a router. Because of this, we couldn't rely on basic Kubernetes installations. We had to manually engineer the BGP routing and iptables NAT traversal to allow the control plane to communicate with the edge."
* "To ensure our edge architecture survived reboots, we implemented a custom persistence strategy using `iptables-persistent` to preserve NAT rules and a safe SSH boot-script to surgically re-inject static IP routes, avoiding the risk of locking ourselves out via `netplan`."

---

## ⏱️ Part 2: Core Functionality & Cryptography (4-5 mins)

**What to do:**
Run the Upload/Download test live.
```bash
echo "DUKA Fog Storage Test" > demo.txt
md5sum demo.txt
curl -X POST http://localhost:30080/upload -F "file=@demo.txt"

# Copy the FILE_ID and check Redis:
kubectl exec -it redis-0 -n duka -- redis-cli GET file:<FILE_ID>

# Check K8s Secrets:
kubectl get secret duka-key-<FILE_ID> -n duka
```

**Key Insights to Discuss:**
* "When we upload a file, the Gateway encrypts it with AES-256, splits it into shards, and distributes those shards across the edge storage daemons."
* "For maximum security, we implemented **strict cryptographic key separation**. Look at the Redis output: it stores the file metadata and the shard mapping, but it *does not* hold the decryption key. If a hacker breaches our Redis database, they still cannot read any files."
* "The AES encryption keys are stored natively in Kubernetes Secrets as Base64 encoded strings, leveraging Kubernetes' own RBAC security."

---

## ⏱️ Part 3: Zero-Trust Networking & The Calico Migration (4-5 mins)

**What to do:**
Explain the CNI migration and run the Network Policy tests.
```bash
# 1. Gateway -> Storage (Allowed)
kubectl exec -n duka deployment/gateway -- python3 -c "import socket; s=socket.socket(); s.settimeout(5); s.connect(('storage-daemon-1.storage-daemon.duka.svc.cluster.local', 8000)); print('✅ TCP OK')"

# 2. Redis -> Storage (Blocked)
kubectl exec -n duka statefulset/redis -- wget -qO- --timeout=5 http://storage-daemon-1.storage-daemon.duka.svc.cluster.local:8000/health
```

**Key Insights to Discuss:**
* "Initially, we used Flannel as our Container Network Interface (CNI). However, Flannel relies purely on VXLAN routing and **does not enforce Kubernetes Network Policies**. Our zero-trust rules were purely decorative."
* "To achieve true Zero-Trust, we migrated to **Calico**, which uses Linux iptables and eBPF to drop unauthorized packets."
* **The Debugging Story:** "This migration was complex. When we enabled Calico's `default-deny-all` policy, it immediately broke the cluster because it actively blocked the Gateway from reaching `kube-dns` on UDP Port 53. We had to write a specific NetworkPolicy explicitly allowing DNS egress."
* **The SNAT Discovery:** "We also discovered through `tcpdump` that Flannel had left behind 'ghost' MASQUERADE rules in the host's iptables. These old rules were changing the Source IPs of our packets, causing Calico to drop them at the destination node. We had to manually purge the old `FLANNEL-POSTRTG` chains to restore cross-node traffic."
* "As you can see in the live test, the Gateway connects (`TCP OK`), but if Redis is compromised and tries to ping a Storage Daemon, Calico drops the packets at the network layer."

---

## ⏱️ Part 4: Container Sandboxing (gVisor vs Runc) (3 mins)

**What to do:**
Run the Falco attack detection test.
```bash
# Trigger an attack in the Gateway (standard runc)
kubectl exec deploy/gateway -n duka -- sh -c "echo ATTACK_GATEWAY"

# Trigger an attack in the Storage Daemon (gVisor)
kubectl exec storage-daemon-0 -n duka -- sh -c "echo ATTACK_DAEMON"

# Check Falco logs (Wait 5 seconds to flush to stdout)
sleep 5
kubectl logs -l app.kubernetes.io/name=falco -n falco -c falco --since=2m | grep -i "DUKA"
```

**Key Insights to Discuss:**
* "Standard containers use `runc` and share the underlying host kernel. If a container is compromised, the host is at risk. To protect our edge workers, we isolated the Storage Daemons inside **gVisor**, a userspace kernel sandbox built by Google."
* "To prove this sandboxing works, we installed Falco, an eBPF threat detection tool that monitors host kernel syscalls."
* "When we execute a shell in the Gateway (which uses standard `runc`), Falco instantly detects the `execve` syscall and throws an alert."
* "But when we execute the exact same attack in the Storage Daemon, Falco sees nothing. gVisor intercepts and handles the syscalls inside the container's userspace, completely blinding Falco and keeping the underlying host kernel 100% safe from the attacker."

---

## ⏱️ Part 5: Elasticity & Resilience (2-3 mins)

**What to do:**
Run Jago's `gateway-resilience-kill-test.sh` script or discuss the HPA load test.
```bash
./gateway-resilience-kill-test.sh
```

**Key Insights to Discuss:**
* "Finally, we want to prove that our Fog architecture is elastic and highly available."
* "We configured a Horizontal Pod Autoscaler (HPA) to monitor CPU load on the Gateway and scale replicas dynamically."
* "To test fault tolerance, we developed a Resilience script. This script generates continuous, parallel upload traffic. Right in the middle of the heavy load, it assassinates the active Gateway pod."
* "Because we are using Kubernetes Deployments, the control plane instantly spins up a replacement pod to heal the cluster, while the Service load-balancer reroutes traffic to surviving replicas."
* "The output of the script shows that despite a catastrophic pod failure, the service remained available with an extremely high percentage of HTTP 200 Success responses."
* "This concludes our presentation. Thank you for your attention."
