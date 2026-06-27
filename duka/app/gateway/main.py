import os
import uuid
import httpx
import redis
import json
from fastapi import FastAPI, UploadFile, HTTPException
from fastapi.responses import Response
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from kubernetes import client, config
import base64  

app = FastAPI()

# --- Config ---
REDIS_HOST = os.environ.get("REDIS_HOST", "localhost")
DAEMON_URLS = os.environ.get(
    "DAEMON_URLS",
    "http://localhost:8001,http://localhost:8002,http://localhost:8003"
).split(",")

# Redis client
r = redis.Redis(host=REDIS_HOST, port=6379, decode_responses=True)

# --- Crypto helpers ---
def generate_key() -> bytes:
    return AESGCM.generate_key(bit_length=256)

def encrypt(data: bytes, key: bytes) -> tuple[bytes, bytes]:
    """Returns (nonce, ciphertext). AESGCM handles authentication."""
    aesgcm = AESGCM(key)
    nonce = os.urandom(12)  # 96-bit nonce, standard for GCM
    ciphertext = aesgcm.encrypt(nonce, data, None)
    return nonce, ciphertext

def decrypt(nonce: bytes, ciphertext: bytes, key: bytes) -> bytes:
    aesgcm = AESGCM(key)
    return aesgcm.decrypt(nonce, ciphertext, None)

# --- Sharding helpers ---
def split_into_shards(data: bytes, n: int) -> list[bytes]:
    """Split data into n equal-ish chunks."""
    size = len(data)
    chunk_size = (size + n - 1) // n  # ceiling division
    return [data[i:i + chunk_size] for i in range(0, size, chunk_size)]

def reassemble_shards(shards: list[bytes]) -> bytes:
    return b"".join(shards)

try:
    config.load_incluster_config()
except config.ConfigException:
    config.load_kube_config()

k8s_v1 = client.CoreV1Api()


def store_key_as_secret(file_id: str, key: bytes, nonce: bytes):
    secret = client.V1Secret(
        metadata=client.V1ObjectMeta(name=f"duka-key-{file_id}", namespace="duka"),
        data={
            "key": base64.b64encode(key).decode(),
            "nonce": base64.b64encode(nonce).decode()
        }
    )
    k8s_v1.create_namespaced_secret(namespace="duka", body=secret)


def retrieve_key_from_secret(file_id: str) -> tuple[bytes, bytes]:
    secret = k8s_v1.read_namespaced_secret(name=f"duka-key-{file_id}", namespace="duka")
    key = base64.b64decode(secret.data["key"])
    nonce = base64.b64decode(secret.data["nonce"])
    return key, nonce


# --- Routes ---
@app.get("/health")
def health():
    return {"status": "ok", "daemons": DAEMON_URLS}



@app.post("/upload")
async def upload(file: UploadFile):
    file_id = str(uuid.uuid4())
    raw_data = await file.read()
    original_size = len(raw_data)
    original_filename = file.filename

    # 1. Encrypt
    key = generate_key()
    nonce, ciphertext = encrypt(raw_data, key)

    # 2. Store key in K8s Secret — NOT in Redis
    store_key_as_secret(file_id, key, nonce)

    # 3. Split into shards
    n = len(DAEMON_URLS)
    shards = split_into_shards(ciphertext, n)

    # 4. Distribute shards
    shard_ids = []
    async with httpx.AsyncClient() as client_http:
        for i, (shard_data, daemon_url) in enumerate(zip(shards, DAEMON_URLS)):
            shard_id = f"{file_id}-shard-{i}"
            response = await client_http.post(
                f"{daemon_url}/shard/{shard_id}",
                files={"file": (shard_id, shard_data, "application/octet-stream")}
            )
            if response.status_code != 200:
                raise HTTPException(status_code=500, detail=f"Failed to store shard {i}")
            shard_ids.append(shard_id)

    # 5. Store metadata in Redis — no key material here anymore
    metadata = {
        "file_id": file_id,
        "filename": original_filename,
        "original_size": original_size,
        "shard_ids": shard_ids,
        "daemon_urls": DAEMON_URLS,
    }
    r.set(f"file:{file_id}", json.dumps(metadata))

    return {
        "file_id": file_id,
        "filename": original_filename,
        "shards": len(shard_ids),
        "size_bytes": original_size,
    }

@app.get("/download/{file_id}")
async def download(file_id: str):
    # 1. Fetch metadata from Redis
    raw = r.get(f"file:{file_id}")
    if not raw:
        raise HTTPException(status_code=404, detail="File not found")
    metadata = json.loads(raw)

    # 2. Fetch key from K8s Secret
    key, nonce = retrieve_key_from_secret(file_id)

    # 3. Retrieve shards
    shards = []
    async with httpx.AsyncClient() as client_http:
        for shard_id, daemon_url in zip(metadata["shard_ids"], metadata["daemon_urls"]):
            response = await client_http.get(f"{daemon_url}/shard/{shard_id}")
            if response.status_code != 200:
                raise HTTPException(status_code=500, detail=f"Failed to retrieve shard {shard_id}")
            shards.append(response.content)

    # 4. Reassemble and decrypt
    ciphertext = reassemble_shards(shards)
    plaintext = decrypt(nonce, ciphertext, key)

    return Response(
        content=plaintext,
        media_type="application/octet-stream",
        headers={"Content-Disposition": f'attachment; filename="{metadata["filename"]}"'}
    )
@app.get("/files")
def list_files():
    keys = r.keys("file:*")
    files = []
    for key in keys:
        meta = json.loads(r.get(key))
        files.append({
            "file_id": meta["file_id"],
            "filename": meta["filename"],
            "size_bytes": meta["original_size"],
            "shards": len(meta["shard_ids"]),
        })
    return files