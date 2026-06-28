import os
from fastapi import FastAPI, UploadFile, HTTPException
from fastapi.responses import Response

app = FastAPI()
SHARD_DIR = "/data/shards"
os.makedirs(SHARD_DIR, exist_ok=True)

DAEMON_ID = os.environ.get("DAEMON_ID", "daemon-unknown")

@app.get("/health")
def health():
    return {"status": "ok", "daemon_id": DAEMON_ID}

@app.post("/shard/{shard_id}")
async def store_shard(shard_id: str, file: UploadFile):
    shard_path = os.path.join(SHARD_DIR, shard_id)
    content = await file.read()
    with open(shard_path, "wb") as f:
        f.write(content)
    return {"stored": shard_id, "size": len(content)}

@app.get("/shard/{shard_id}")
def retrieve_shard(shard_id: str):
    shard_path = os.path.join(SHARD_DIR, shard_id)
    if not os.path.exists(shard_path):
        raise HTTPException(status_code=404, detail="Shard not found")
    with open(shard_path, "rb") as f:
        data = f.read()
    return Response(content=data, media_type="application/octet-stream")

@app.delete("/shard/{shard_id}")
def delete_shard(shard_id: str):
    shard_path = os.path.join(SHARD_DIR, shard_id)
    if os.path.exists(shard_path):
        os.remove(shard_path)
    return {"deleted": shard_id}