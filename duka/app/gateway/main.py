import os
import uuid
import httpx
import redis
import json
from fastapi import FastAPI, UploadFile, HTTPException
from fastapi.responses import Response
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

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

    # 2. Split into N shards (one per daemon)
    n = len(DAEMON_URLS)
    shards = split_into_shards(ciphertext, n)

    # 3. Distribute shards to daemons
    shard_ids = []
    async with httpx.AsyncClient() as client:
        for i, (shard_data, daemon_url) in enumerate(zip(shards, DAEMON_URLS)):
            shard_id = f"{file_id}-shard-{i}"
            response = await client.post(
                f"{daemon_url}/shard/{shard_id}",
                files={"file": (shard_id, shard_data, "application/octet-stream")}
            )
            if response.status_code != 200:
                raise HTTPException(
                    status_code=500,
                    detail=f"Failed to store shard {i} on {daemon_url}"
                )
            shard_ids.append(shard_id)

    # 4. Store metadata in Redis
    # Key and nonce stored as hex strings — in production these would go to a vault
    metadata = {
        "file_id": file_id,
        "filename": original_filename,
        "original_size": original_size,
        "key_hex": key.hex(),
        "nonce_hex": nonce.hex(),
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

    # 2. Retrieve shards from daemons in order
    shards = []
    async with httpx.AsyncClient() as client:
        for shard_id, daemon_url in zip(metadata["shard_ids"], metadata["daemon_urls"]):
            response = await client.get(f"{daemon_url}/shard/{shard_id}")
            if response.status_code != 200:
                raise HTTPException(
                    status_code=500,
                    detail=f"Failed to retrieve shard {shard_id} from {daemon_url}"
                )
            shards.append(response.content)

    # 3. Reassemble ciphertext
    ciphertext = reassemble_shards(shards)

    # 4. Decrypt
    key = bytes.fromhex(metadata["key_hex"])
    nonce = bytes.fromhex(metadata["nonce_hex"])
    plaintext = decrypt(nonce, ciphertext, key)

    return Response(
        content=plaintext,
        media_type="application/octet-stream",
        headers={
            "Content-Disposition": f'attachment; filename="{metadata["filename"]}"'
        }
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