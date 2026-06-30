#!/bin/bash
# 1. Create a 10MB dummy test file
dd if=/dev/urandom of=testfile.jpg bs=1M count=1 2>/dev/null

# TO DO: Insert the exact IP and port of your Gateway (or Ingress)
GATEWAY_IP="10.106.233.31:8080"

echo "Starting Load Test (30 concurrent 1MB requests)..."

for i in $(seq 1 30); do
  # Launch curl in background using the trailing "&" for true concurrency
  curl -s -X POST http://$GATEWAY_IP/upload -F file=@testfile.jpg > /dev/null &
done

echo "Waiting for uploads to finish (wait)..."
wait
echo "Load Test sent to the cluster!"