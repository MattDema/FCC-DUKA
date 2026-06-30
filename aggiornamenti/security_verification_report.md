# DUKA Project: Security Verification & Integration Report

This document summarizes the work done during Day 3 (Integration) and Day 4 (Security Verification). It serves as a reference for the final project report and presentation, highlighting key technical discoveries, architectural trade-offs, and the commands used to verify the system.

---

## 1. System Integration (Day 3 Recap)

After successfully installing `runsc` (gVisor) on all worker nodes and resolving the Containerd configuration, the `storage-daemon` pods successfully came online. 

We verified the end-to-end integration by uploading a file to the Gateway, which successfully distributed the shards to the storage daemons and saved the metadata in Redis. We then successfully downloaded the file and verified its integrity using an MD5 checksum.

---

## 2. Security Discoveries & Architectural Trade-offs (Day 4)

During the Security Verification phase, we made two critical discoveries that demonstrate a deep understanding of Kubernetes security mechanisms. **These should be highlighted during the professor's evaluation.**

### Discovery A: Network Policies vs. Flannel
* **The Goal**: We defined NetworkPolicies (e.g., `default-deny-all`, `allow-gateway`) to restrict lateral movement. For example, `redis` should not be able to communicate with a `storage-daemon`.
* **The Test**: We executed a `wget` request from the `redis` pod to a `storage-daemon` pod.
* **The Finding**: The request **succeeded** (`HTTP 200 OK`), completely bypassing the NetworkPolicy.
* **The Explanation**: The cluster uses **Flannel** as its Container Network Interface (CNI). Flannel is a simple, lightweight networking overlay that **does not enforce NetworkPolicies natively**. While Kubernetes accepts the policy objects, there is no underlying controller to drop the packets.
* **Future Improvement**: In a true production environment, the cluster must be provisioned with a policy-enforcing CNI such as **Calico** or **Cilium**.

### Discovery B: The "gVisor vs. Falco" Observability Blindspot
* **The Goal**: Use Falco (eBPF) to detect anomalous behavior, such as a shell being spawned inside a container.
* **The Test**: We spawned an interactive shell (`sh`) inside both the `gateway` pod and the `storage-daemon` pod.
* **The Finding**: 
  * Falco **successfully detected** the shell inside the `gateway` pod and fired a `WARNING` alert.
  * Falco **completely missed** the shell inside the `storage-daemon` pod.
* **The Explanation**: This is a textbook example of a defense-in-depth trade-off. 
  * The `gateway` pod uses the standard `runc` runtime, meaning its system calls go directly to the host Linux kernel, where Falco's eBPF hooks can intercept and analyze them.
  * The `storage-daemon` pod uses the `gVisor` (`runsc`) runtime. gVisor is a user-space kernel that intercepts and handles system calls *inside* the sandbox. Because the `execve` syscall for the shell never reaches the host Linux kernel, Falco is entirely blind to it.
* **Conclusion**: gVisor provides incredibly strong isolation (preventing container breakouts), but at the cost of host-based observability.

---

## 3. Testing & Verification Cheatsheet

Use these commands to demonstrate the system's capabilities during the presentation.

### End-to-End File Upload/Download
```bash
# 1. Create a test file
echo "This is a highly confidential document stored securely in DUKA." > testfile.txt
md5sum testfile.txt

# 2. Upload the file via NodePort
curl -X POST http://localhost:30080/upload -F file=@testfile.txt

# 3. Download the file using the returned file_id
curl "http://localhost:30080/download/<YOUR_FILE_ID>" -o downloaded.txt

# 4. Verify integrity
md5sum downloaded.txt
```

### Demonstrating the Flannel NetworkPolicy Limitation
Show that a pod can reach another pod despite a deny policy:
```bash
kubectl exec redis-0 -n duka -- wget -qO- --timeout=5 http://storage-daemon-1.storage-daemon.duka.svc.cluster.local:8000/health
# Expected Output: {"status":"ok","daemon_id":"storage-daemon-1"}
```

### Demonstrating the Falco/gVisor Trade-off
Show Falco successfully catching an intrusion in the standard container, but missing it in the gVisor sandbox.

```bash
# 1. Trigger the Falco rule in the Gateway (runc)
kubectl exec deploy/gateway -n duka -- sh -c "echo I am an attacker"

# 2. Trigger the Falco rule in the Storage Daemon (gVisor)
kubectl exec storage-daemon-0 -n duka -- sh -c "echo I am an attacker"

# 3. Check the Falco alerts
kubectl logs -l app.kubernetes.io/name=falco -n falco -c falco --since=2m | grep -i "DUKA"

# Expected Output: Only ONE alert will be present, and it will specifically state container=gateway.
```
