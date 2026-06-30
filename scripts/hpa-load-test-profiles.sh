#!/bin/bash

# Load test for the DUKA Gateway.
# To be executed on the VM/master where you have access to the Gateway Service.
#
# Usage:
#   chmod +x load-test-profiles.sh
#   ./load-test-profiles.sh light
#   ./load-test-profiles.sh medium
#   ./load-test-profiles.sh medium50
#   ./load-test-profiles.sh aggressive
#   ./load-test-profiles.sh all

# TO DO: insert exact IP and port of your Gateway or Ingress.
GATEWAY_IP="10.106.233.31:8080"

# Default profile if no arguments are passed.
PROFILO="${1:-medium}"

run_test() {
  DIMENSIONE_MB="$1"
  RICHIESTE="$2"
  NOME_TEST="$3"

  echo ""
  echo "=================================================="
  echo "Starting Load Test: $NOME_TEST"
  echo "Payload: ${DIMENSIONE_MB}MB"
  echo "Concurrent requests: $RICHIESTE"
  echo "Gateway: http://$GATEWAY_IP/upload"
  echo "=================================================="

  # Create a dummy test file of the requested size.
  dd if=/dev/urandom of=testfile.jpg bs=1M count="$DIMENSIONE_MB" 2>/dev/null

  START_TIME=$(date +%s)

  for i in $(seq 1 "$RICHIESTE"); do
    echo "Sending request $i/$RICHIESTE..."
    curl -s -X POST "http://$GATEWAY_IP/upload" -F file=@testfile.jpg > /dev/null &
  done

  echo "Waiting for uploads to finish (wait)..."
  wait

  END_TIME=$(date +%s)
  ELAPSED=$((END_TIME - START_TIME))

  echo "Load Test '$NOME_TEST' completed in ${ELAPSED}s!"
  echo ""
  echo "Check HPA and pods with:"
  echo "kubectl get hpa -n duka"
  echo "kubectl get pods -n duka"
  echo "kubectl top pods -n duka"
}

case "$PROFILO" in
  light)
    # 1MB x 10 requests
    run_test 1 10 "light - 1MB x 10 requests"
    ;;

  medium)
    # 1MB x 30 requests
    run_test 1 30 "medium - 1MB x 30 requests"
    ;;

  medium50)
    # 1MB x 50 requests
    run_test 1 50 "medium50 - 1MB x 50 requests"
    ;;

  aggressive)
    # 10MB x 50 requests
    run_test 10 50 "aggressive - 10MB x 50 requests"
    ;;

  all)
    run_test 1 10 "light - 1MB x 10 requests"
    echo "20 seconds pause before medium test..."
    sleep 20

    run_test 1 30 "medium - 1MB x 30 requests"
    echo "20 seconds pause before medium50 test..."
    sleep 20

    run_test 1 50 "medium50 - 1MB x 50 requests"
    echo "20 seconds pause before aggressive test..."
    sleep 20

    run_test 10 50 "aggressive - 10MB x 50 requests"
    ;;

  *)
    echo "Invalid profile: $PROFILO"
    echo ""
    echo "Available profiles:"
    echo "  light       -> 1MB x 10 requests"
    echo "  medium      -> 1MB x 30 requests"
    echo "  medium50    -> 1MB x 50 requests"
    echo "  aggressive  -> 10MB x 50 requests"
    echo "  all         -> runs all tests sequentially"
    exit 1
    ;;
esac
