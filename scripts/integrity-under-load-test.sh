#!/bin/bash

# Integrity test under load for DUKA.
# Objective:
#   1. Generate concurrent uploads to stimulate HPA.
#   2. Upload a sample file.
#   3. Download it via file_id.
#   4. Compare original and downloaded checksum.
#
# Usage:
#   chmod +x integrity-under-load-test.sh
#   ./integrity-under-load-test.sh

# TO DO: insert exact IP and port of your Gateway or Ingress.
GATEWAY_IP="localhost:30080"

# Background load parameters.
LOAD_FILE_MB=1
LOAD_REQUESTS=30

# Integrity file parameters.
ORIGINAL_FILE="original.bin"
DOWNLOADED_FILE="downloaded.bin"
LOAD_FILE="loadfile.bin"

UPLOAD_RESPONSE_FILE="upload-response.json"

checksum() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$1" | awk '{print $1}'
  elif command -v md5 >/dev/null 2>&1; then
    md5 -q "$1"
  else
    echo "ERROR: md5sum/md5 not found." >&2
    exit 1
  fi
}

extract_file_id() {
  RESPONSE_FILE="$1"

  if command -v jq >/dev/null 2>&1; then
    FILE_ID=$(jq -r '.file_id // .id // .fileId // empty' "$RESPONSE_FILE" 2>/dev/null)
    if [ -n "$FILE_ID" ] && [ "$FILE_ID" != "null" ]; then
      echo "$FILE_ID"
      return
    fi
  fi

  # Fallback without jq: try to read common JSON fields.
  FILE_ID=$(sed -n 's/.*"file_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$RESPONSE_FILE" | head -n 1)
  if [ -n "$FILE_ID" ]; then
    echo "$FILE_ID"
    return
  fi

  FILE_ID=$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$RESPONSE_FILE" | head -n 1)
  if [ -n "$FILE_ID" ]; then
    echo "$FILE_ID"
    return
  fi
}

echo "=================================================="
echo "Integrity test under load"
echo "Gateway: http://$GATEWAY_IP"
echo "Background load: ${LOAD_REQUESTS} uploads of ${LOAD_FILE_MB}MB"
echo "=================================================="

echo ""
echo "1. Creating load file and sample file..."
dd if=/dev/urandom of="$LOAD_FILE" bs=1M count="$LOAD_FILE_MB" 2>/dev/null
dd if=/dev/urandom of="$ORIGINAL_FILE" bs=1M count=1 2>/dev/null

ORIGINAL_MD5=$(checksum "$ORIGINAL_FILE")
echo "Original checksum: $ORIGINAL_MD5"

echo ""
echo "2. Starting background load..."
for i in $(seq 1 "$LOAD_REQUESTS"); do
  curl -s -X POST "http://$GATEWAY_IP/upload" -F file=@"$LOAD_FILE" > /dev/null &
done

echo "Load started. Now uploading/downloading the sample file while the Gateway is under stress."

echo ""
echo "3. Uploading sample file..."
curl -s -X POST "http://$GATEWAY_IP/upload" -F file=@"$ORIGINAL_FILE" -o "$UPLOAD_RESPONSE_FILE"

echo "Upload response:"
cat "$UPLOAD_RESPONSE_FILE"
echo ""

FILE_ID=$(extract_file_id "$UPLOAD_RESPONSE_FILE")

if [ -z "$FILE_ID" ]; then
  echo ""
  echo "Could not automatically extract file_id."
  echo "Look at the response above and paste the file_id here:"
  read -r FILE_ID
fi

if [ -z "$FILE_ID" ]; then
  echo "ERROR: file_id is empty. Cannot continue."
  exit 1
fi

echo "File ID: $FILE_ID"

echo ""
echo "4. Downloading sample file..."
curl -s "http://$GATEWAY_IP/download/$FILE_ID" -o "$DOWNLOADED_FILE"

if [ ! -s "$DOWNLOADED_FILE" ]; then
  echo "ERROR: download failed or downloaded file is empty."
  echo "Check endpoint: http://$GATEWAY_IP/download/$FILE_ID"
  exit 1
fi

DOWNLOADED_MD5=$(checksum "$DOWNLOADED_FILE")
echo "Downloaded checksum: $DOWNLOADED_MD5"

echo ""
echo "5. Waiting for background load to finish..."
wait

echo ""
echo "=================================================="
if [ "$ORIGINAL_MD5" = "$DOWNLOADED_MD5" ]; then
  echo "SUCCESS: checksums are identical."
  echo "The system maintains data integrity even under load."
else
  echo "FAILURE: checksums differ."
  echo "The downloaded file does not match the original."
  exit 1
fi
echo "=================================================="

echo ""
echo "Useful commands to show in another terminal during the test:"
echo "watch -n 1 \"kubectl get hpa -n duka; echo '---'; kubectl get pods -n duka\""
echo ""
echo "Post-test commands:"
echo "kubectl get hpa -n duka"
echo "kubectl get pods -n duka"
echo "kubectl top pods -n duka"
