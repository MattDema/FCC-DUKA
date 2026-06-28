#!/bin/bash

# Test resilienza Gateway durante carico.
# Obiettivo:
#   1. Generare traffico verso il Gateway.
#   2. Eliminare un pod Gateway mentre il traffico e in corso.
#   3. Mostrare che Kubernetes/Deployment ricrea il pod.
#
# Uso sulla VM/master:
#   chmod +x gateway-resilience-kill-test.sh
#   ./gateway-resilience-kill-test.sh

# DA CAMBIARE se necessario.
GATEWAY_IP="10.106.233.31:8080"
NAMESPACE="duka"
GATEWAY_LABEL="app=gateway"

# Parametri del carico.
PAYLOAD_MB=1
WORKERS=4
REQUEST_DELAY_SECONDS=1
DELAY_BEFORE_KILL=8
LOAD_DURATION_SECONDS=60
WATCH_SECONDS=45

TEST_FILE="resilience-testfile.bin"
RESULTS_FILE="resilience-results.txt"
ERRORS_FILE="resilience-errors.txt"

echo "=================================================="
echo "🧪 Test resilienza Gateway durante carico"
echo "🌐 Gateway: http://$GATEWAY_IP/upload"
echo "📦 Payload: ${PAYLOAD_MB}MB"
echo "👥 Worker paralleli: $WORKERS"
echo "⏱️  Durata carico: ${LOAD_DURATION_SECONDS}s"
echo "🎯 Namespace: $NAMESPACE"
echo "🏷️  Label Gateway: $GATEWAY_LABEL"
echo "=================================================="

echo ""
echo "1. Verifico pod Gateway attuali..."
kubectl get pods -n "$NAMESPACE" -l "$GATEWAY_LABEL" -o wide

POD_TO_DELETE=$(kubectl get pods -n "$NAMESPACE" -l "$GATEWAY_LABEL" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$POD_TO_DELETE" ]; then
  echo "ERRORE: nessun pod Gateway Running trovato con label '$GATEWAY_LABEL' nel namespace '$NAMESPACE'."
  exit 1
fi

echo ""
echo "Pod scelto per il kill: $POD_TO_DELETE"

echo ""
echo "2. Creo file di test..."
dd if=/dev/urandom of="$TEST_FILE" bs=1M count="$PAYLOAD_MB" 2>/dev/null
: > "$RESULTS_FILE"
: > "$ERRORS_FILE"

echo ""
echo "3. Avvio carico continuo in background..."
END_LOAD_TIME=$((SECONDS + LOAD_DURATION_SECONDS))

for WORKER_ID in $(seq 1 "$WORKERS"); do
  (
    REQUEST_ID=0
    while [ "$SECONDS" -lt "$END_LOAD_TIME" ]; do
      REQUEST_ID=$((REQUEST_ID + 1))

      # L'header Expect viene disabilitato per evitare risposte intermedie HTTP 100
      # che rendono meno leggibile il risultato della demo.
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

echo "Carico continuo avviato. Attendo ${DELAY_BEFORE_KILL}s prima di eliminare il pod..."
sleep "$DELAY_BEFORE_KILL"

echo ""
echo "4. Elimino il pod Gateway durante il carico..."
kubectl delete pod "$POD_TO_DELETE" -n "$NAMESPACE"

echo ""
echo "5. Osservo la riconciliazione del Deployment per ${WATCH_SECONDS}s..."
echo "   Dovresti vedere il vecchio pod terminare e un nuovo pod apparire."
echo ""

END_TIME=$((SECONDS + WATCH_SECONDS))
while [ "$SECONDS" -lt "$END_TIME" ]; do