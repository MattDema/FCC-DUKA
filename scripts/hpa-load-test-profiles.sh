#!/bin/bash

# Load test per il Gateway DUKA.
# Da eseguire sulla VM/master dove hai accesso al Service del Gateway.
#
# Uso:
#   chmod +x load-test-profiles.sh
#   ./load-test-profiles.sh leggero
#   ./load-test-profiles.sh medio
#   ./load-test-profiles.sh medio50
#   ./load-test-profiles.sh aggressivo
#   ./load-test-profiles.sh all

# DA CAMBIARE: inserisci IP e porta esatta del tuo Gateway o Ingress.
GATEWAY_IP="10.106.233.31:8080"

# Profilo di default se non passi argomenti.
PROFILO="${1:-medio}"

run_test() {
  DIMENSIONE_MB="$1"
  RICHIESTE="$2"
  NOME_TEST="$3"

  echo ""
  echo "=================================================="
  echo "🚀 Inizio Load Test: $NOME_TEST"
  echo "📦 Payload: ${DIMENSIONE_MB}MB"
  echo "👥 Richieste simultanee: $RICHIESTE"
  echo "🌐 Gateway: http://$GATEWAY_IP/upload"
  echo "=================================================="

  # Crea un file di test finto della dimensione richiesta.
  dd if=/dev/urandom of=testfile.jpg bs=1M count="$DIMENSIONE_MB" 2>/dev/null

  START_TIME=$(date +%s)

  for i in $(seq 1 "$RICHIESTE"); do
    echo "Invio richiesta $i/$RICHIESTE..."
    curl -s -X POST "http://$GATEWAY_IP/upload" -F file=@testfile.jpg > /dev/null &
  done

  echo "Attendo la fine dei caricamenti (wait)..."
  wait

  END_TIME=$(date +%s)
  ELAPSED=$((END_TIME - START_TIME))

  echo "✅ Load Test '$NOME_TEST' completato in ${ELAPSED}s!"
  echo ""
  echo "Controlla HPA e pod con:"
  echo "kubectl get hpa -n duka"
  echo "kubectl get pods -n duka"
  echo "kubectl top pods -n duka"
}

case "$PROFILO" in
  leggero)
    # 1MB x 10 richieste
    run_test 1 10 "leggero - 1MB x 10 richieste"
    ;;

  medio)
    # 1MB x 30 richieste
    run_test 1 30 "medio - 1MB x 30 richieste"
    ;;

  medio50)
    # 1MB x 50 richieste
    run_test 1 50 "medio50 - 1MB x 50 richieste"
    ;;

  aggressivo)
    # 10MB x 50 richieste
    run_test 10 50 "aggressivo - 10MB x 50 richieste"
    ;;

  all)
    run_test 1 10 "leggero - 1MB x 10 richieste"
    echo "Pausa di 20 secondi prima del test medio..."
    sleep 20

    run_test 1 30 "medio - 1MB x 30 richieste"
    echo "Pausa di 20 secondi prima del test medio50..."
    sleep 20

    run_test 1 50 "medio50 - 1MB x 50 richieste"
    echo "Pausa di 20 secondi prima del test aggressivo..."
    sleep 20

    run_test 10 50 "aggressivo - 10MB x 50 richieste"
    ;;

  *)
    echo "Profilo non valido: $PROFILO"
    echo ""
    echo "Profili disponibili:"
    echo "  leggero     -> 1MB x 10 richieste"
    echo "  medio       -> 1MB x 30 richieste"
    echo "  medio50     -> 1MB x 50 richieste"
    echo "  aggressivo  -> 10MB x 50 richieste"
    echo "  all         -> esegue tutti i test in sequenza"
    exit 1
    ;;
esac
