# DUKA Project: Kubernetes Secrets & Key Separation Report

This document summarizes the work done during Day 5 (Security Hardening). It serves as a reference for the final project report and presentation, highlighting the architectural improvement made to the key management system, the trade-offs involved, and the commands used to verify the implementation.

---

## 1. The Problem: Keys Living in Redis (Before)

In the original implementation, the Gateway stored the full file metadata — including the AES-256 encryption key and nonce — as a single JSON object in Redis:

```json
{
  "file_id": "abc-123",
  "filename": "confidential_report.pdf",
  "original_size": 524288,
  "key_hex": "a3f1c2d4e5f6...",
  "nonce_hex": "9b2e1a3c4d5e...",
  "shard_ids": ["abc-123-shard-0", "abc-123-shard-1", "abc-123-shard-2"],
  "daemon_urls": ["http://storage-daemon-0...", "..."]
}
```

**The vulnerability**: an attacker who compromises Redis gains everything simultaneously — the shard map, the daemon locations, the encryption key, and the nonce. With these four pieces of information, the attacker can reconstruct and decrypt any file in the system without ever touching the Storage Daemons.

This violates a core security principle from the course: **Limit Blast Radius**. A single compromised component should never cascade into a full system breach.

---

## 2. The Solution: Key Separation via Kubernetes Secrets

We implemented a clean architectural separation between two categories of data:

* **Redis** stores only routing metadata — where shards are, what the file is called, how big it is. This information is useless without the key.
* **Kubernetes Secrets** store only cryptographic material — the AES-256 key and GCM nonce. This information is useless without knowing which daemons hold the shards.

An attacker must now compromise **two independent systems** with **two separate access control mechanisms** to reconstruct a file. This is the definition of defense in depth.

### Updated Redis entry (after)

```json
{
  "file_id": "abc-123",
  "filename": "confidential_report.pdf",
  "original_size": 524288,
  "shard_ids": ["abc-123-shard-0", "abc-123-shard-1", "abc-123-shard-2"],
  "daemon_urls": ["http://storage-daemon-0...", "..."]
}
```

No `key_hex`. No `nonce_hex`. Redis is now entirely decoupled from the cryptographic layer.

---

## 3. RBAC: Controlling Access to the Keys

Kubernetes Secrets are only as secure as their access controls. We implemented a dedicated **ServiceAccount**, **Role**, and **RoleBinding** for the Gateway following the principle of least privilege.

### What was created

| Resource | Name | Purpose |
|---|---|---|
| `ServiceAccount` | `gateway-sa` | Identity assigned to the Gateway pod |
| `Role` | `gateway-secret-manager` | Defines allowed operations on Secrets |
| `RoleBinding` | `gateway-secret-manager-binding` | Links the Role to the ServiceAccount |

### Role permissions

The Role grants **only three verbs** on Secrets in the `duka` namespace:

```yaml
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create", "get", "delete"]
```

* `create` — store the key when a file is uploaded
* `get` — retrieve the key when a file is downloaded
* `delete` — optional cleanup when a file is removed

The Gateway ServiceAccount cannot list all Secrets, cannot modify other resources, and has no permissions outside the `duka` namespace. The Storage Daemons and Redis have no ServiceAccount permissions at all.

---

## 4. Implementation Details

### Gateway startup — K8s client initialization

The Kubernetes client is initialized once at module startup, not on every request. The `load_incluster_config()` call reads the ServiceAccount token automatically mounted by Kubernetes at `/var/run/secrets/kubernetes.io/serviceaccount/token`.

```python
try:
    config.load_incluster_config()   # runs inside K8s pod
except config.ConfigException:
    config.load_kube_config()        # fallback for local development

k8s_v1 = client.CoreV1Api()
```

### Key storage on upload

```python
def store_key_as_secret(file_id: str, key: bytes, nonce: bytes):
    secret = client.V1Secret(
        metadata=client.V1ObjectMeta(
            name=f"duka-key-{file_id}",
            namespace="duka"
        ),
        data={
            "key": base64.b64encode(key).decode(),
            "nonce": base64.b64encode(nonce).decode()
        }
    )
    k8s_v1.create_namespaced_secret(namespace="duka", body=secret)
```

### Key retrieval on download

```python
def retrieve_key_from_secret(file_id: str) -> tuple[bytes, bytes]:
    secret = k8s_v1.read_namespaced_secret(
        name=f"duka-key-{file_id}",
        namespace="duka"
    )
    key = base64.b64decode(secret.data["key"])
    nonce = base64.b64decode(secret.data["nonce"])
    return key, nonce
```

---

## 5. Architectural Trade-offs & Known Limitations

### What this improves

* **Blast radius reduction**: compromising Redis no longer yields decryptable data.
* **Access control**: RBAC enforces that only the Gateway ServiceAccount can touch key material.
* **Separation of concerns**: routing logic (Redis) and cryptographic material (Secrets) are cleanly decoupled.

### Known limitation: etcd stores Secrets as base64, not encrypted

Kubernetes Secrets are base64-encoded by default, which is encoding — not encryption. Anyone with direct etcd access can read them. This is a well-documented Kubernetes limitation.

**The production fix** is two-layered:

1. **Encryption at rest**: configure the K8s API server with a KMS provider (e.g. Azure Key Vault, AWS KMS) to encrypt Secret data before writing to etcd. At this point etcd holds only ciphertext.
2. **HashiCorp Vault**: replace K8s Secrets entirely with Vault, which adds encryption at rest, a full audit trail of every key access, automatic lease expiry, and dynamic secret generation. The Gateway authenticates to Vault using the same ServiceAccount token mechanism already in place — no passwords required.

The three levels of the same architectural idea:

| Level | Key storage | Weakness |
|---|---|---|
| Level 1 (original) | Redis alongside metadata | Compromise Redis = full breach |
| Level 2 (current) | K8s Secrets with RBAC | base64 in etcd, no audit trail |
| Level 3 (production) | HashiCorp Vault | No significant weakness at this scale |

---

## 6. Testing & Verification Cheatsheet

### Verify RBAC resources exist

```bash
kubectl get serviceaccount -n duka
kubectl get role -n duka
kubectl get rolebinding -n duka
```

### Verify the Gateway pod uses the correct ServiceAccount

```bash
kubectl get pod -n duka -l app=gateway \
  -o jsonpath='{.items[0].spec.serviceAccountName}'
# Expected output: gateway-sa
```

### Upload a file and verify key separation

```bash
# 1. Upload
echo "This is a confidential DUKA document." > testfile.txt
curl -X POST http://localhost:8080/upload -F "file=@testfile.txt"
# Copy the returned file_id

# 2. Verify Redis has NO key material
kubectl exec -it redis-0 -n duka -- redis-cli GET file:<FILE_ID>
# Expected: JSON with filename, shard_ids, daemon_urls — NO key_hex, NO nonce_hex

# 3. Verify the key IS in a K8s Secret
kubectl get secret -n duka | grep duka-key
kubectl get secret duka-key-<FILE_ID> -n duka -o jsonpath='{.data}'
# Expected: {"key":"<base64>","nonce":"<base64>"}
```

### Verify download still works (end-to-end integrity)

```bash
curl http://localhost:8080/download/<FILE_ID> -o result.txt
md5sum testfile.txt result.txt
# Expected: identical checksums
```

### Demonstrate RBAC enforcement (negative test)

Attempt to read a Secret from a Storage Daemon pod — it should be forbidden:

```bash
kubectl exec -it storage-daemon-0 -n duka -- \
  wget -qO- --header="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
  https://kubernetes.default.svc/api/v1/namespaces/duka/secrets/duka-key-<FILE_ID> \
  --no-check-certificate
# Expected: 403 Forbidden
# Reason: storage-daemon pods use the default ServiceAccount which has no Secret access
```
