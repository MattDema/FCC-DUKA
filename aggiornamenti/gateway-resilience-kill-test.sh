#!/bin/bash

# DUKA Gateway resilience test during load.
# The script generates continuous upload traffic, deletes one Gateway pod,
# then reports how many requests succeeded while Kubernetes reconciled.

GATEWAY_IP="${GATEWAY_IP:-10.106.233.31:8080}"
NAMESPACE="${NAMESPACE:-duka}"
GATEWAY_LABEL="${GATEWAY_LABEL:-app=gateway}"

PAYLOAD_MB="${PAYLOAD_MB:-1}"
WORKERS="${WORKERS:-4}"
REQUEST_DELAY_SECONDS="${REQUEST_DELAY_SECONDS:-1}"
DELAY_BEFORE_KILL="${DELAY_BEFORE_KILL:-8}"
LOAD_DURATION_SECONDS="${LOAD_DURATION_SECONDS:-60}"
WATCH_SECONDS="${WATCH_SECONDS:-45}"

TEST_FILE="resilience-testfile.bin"
RESULTS_FILE="resilience-results.txt"
ERRORS_FILE="resilience-errors.txt"

echo "=================================================="
echo "DUKA Gateway resilience test during load"
echo "Gateway: http://$GATEWAY_IP/upload"
echo "Payload: ${PAYLOAD_MB}MB"
echo "Parallel workers: $WORKERS"
echo "Load duration: ${LOAD_DURATION_SECONDS}s"
echo "Namespace: $NAMESPACE"
echo "Gateway label: $GATEWAY_LABEL"
echo "=================================================="

echo ""
echo "1. Current Gateway pods:"
kubectl get pods -n "$NAMESPACE" -l "$GATEWAY_LABEL" -o wide

POD_TO_DELETE=$(kubectl get pods -n "$NAMESPACE" -l "$GATEWAY_LABEL" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$POD_TO_DELETE" ]; then
  echo "ERROR: no Running Gateway pod found with label '$GATEWAY_LABEL' in namespace '$NAMESPACE'."
  exit 1
fi

echo ""
echo "Pod selected for deletion: $POD_TO_DELETE"

echo ""
echo "2. Creating payload file..."
dd if=/dev/urandom of="$TEST_FILE" bs=1M count="$PAYLOAD_MB" 2>/dev/null
: > "$RESULTS_FILE"
: > "$ERRORS_FILE"

echo ""
echo "3. Starting continuous background load..."
END_LOAD_TIME=$((SECONDS + LOAD_DURATION_SECONDS))

for WORKER_ID in $(seq 1 "$WORKERS"); do
  (
    while [ "$SECONDS" -lt "$END_LOAD_TIME" ]; do
      HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" \
        --connect-timeout 5 \
        --max-time 30 \
        -H "Expect:" \
        -X POST "http://$GATEWAY_IP/upload" \
        -F file=@"$TEST_FILE" 2>>"$ERRORS_FILE")

      echo "$HTTP_CODE" >> "$RESULTS_FILE"
      sleep "$REQUEST_DELAY_SECONDS"
    done
  ) &
done

echo "Background load started. Waiting ${DELAY_BEFORE_KILL}s before deleting the pod..."
sleep "$DELAY_BEFORE_KILL"

echo ""
echo "4. Deleting Gateway pod during load..."
kubectl delete pod "$POD_TO_DELETE" -n "$NAMESPACE"

echo ""
echo "5. Watching Deployment reconciliation for ${WATCH_SECONDS}s..."
END_WATCH_TIME=$((SECONDS + WATCH_SECONDS))
while [ "$SECONDS" -lt "$END_WATCH_TIME" ]; do
  kubectl get pods -n "$NAMESPACE" -l "$GATEWAY_LABEL" -o wide
  echo "--------------------------------------------------"
  sleep 5
done

echo ""
echo "6. Waiting for background requests to finish..."
wait

TOTAL=$(wc -l < "$RESULTS_FILE" | tr -d ' ')
SUCCESS=$(grep -E '^[23][0-9][0-9]$' "$RESULTS_FILE" | wc -l | tr -d ' ')
FAILED=$((TOTAL - SUCCESS))
CODE_000=$(grep -c '^000$' "$RESULTS_FILE" || true)
CODE_100=$(grep -c '^100$' "$RESULTS_FILE" || true)

echo ""
echo "=================================================="
echo "Test result"
echo "=================================================="
echo "Total completed requests: $TOTAL"
echo "HTTP 2xx/3xx successes: $SUCCESS"
echo "Failed or non-2xx/3xx: $FAILED"
echo "HTTP 000, no complete HTTP response: $CODE_000"
echo "HTTP 100 Continue responses: $CODE_100"

echo ""
echo "HTTP code distribution:"
sort "$RESULTS_FILE" | uniq -c

if [ -s "$ERRORS_FILE" ]; then
  echo ""
  echo "Last curl errors:"
  tail -n 10 "$ERRORS_FILE"
fi

echo ""
echo "Final Gateway pod state:"
kubectl get pods -n "$NAMESPACE" -l "$GATEWAY_LABEL" -o wide

echo ""
echo "Interpretation:"
echo "- Some HTTP 000 responses during the kill are normal if no ready backend is available."
echo "- The important result is that the Deployment recreates the Gateway pod."
echo "- With multiple Gateway replicas, remaining pods should absorb the failure window."
