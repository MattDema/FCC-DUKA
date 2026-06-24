#!/bin/bash
set -e

GATEWAY="http://localhost:8080"
TEST_FILE="test_input.pdf"

# Create a test file if none exists
if [ ! -f "$TEST_FILE" ]; then
    dd if=/dev/urandom bs=1024 count=512 of="$TEST_FILE" 2>/dev/null
    echo "Created random test file: $TEST_FILE (512 KB)"
fi

echo "--- Uploading ---"
RESPONSE=$(curl -s -X POST "$GATEWAY/upload" -F "file=@$TEST_FILE")
echo "$RESPONSE"
FILE_ID=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['file_id'])")

echo ""
echo "--- Downloading file_id: $FILE_ID ---"
curl -s "$GATEWAY/download/$FILE_ID" -o "test_output.pdf"

echo ""
echo "--- Checksum verification ---"
HASH_IN=$(md5sum "$TEST_FILE" | awk '{print $1}')
HASH_OUT=$(md5sum "test_output.pdf" | awk '{print $1}')
echo "Input:  $HASH_IN"
echo "Output: $HASH_OUT"

if [ "$HASH_IN" == "$HASH_OUT" ]; then
    echo "✅ PASS — checksums match"
else
    echo "❌ FAIL — checksums differ"
    exit 1
fi