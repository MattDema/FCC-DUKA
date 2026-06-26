#!/bin/bash
# 1. Crea un file di test finto da 10MB
dd if=/dev/urandom of=testfile.jpg bs=1M count=10 2>/dev/null

# DA CAMBIARE: Inserisci l'IP e la porta esatta del tuo Gateway (o Ingress)
GATEWAY_IP="127.0.0.1:8000"

echo "🚀 Inizio Load Test (50 richieste simultanee da 10MB)..."

for i in $(seq 1 50); do
  # Lancia la curl in background usando la "&" finale per fare concorrenza vera
  curl -s -X POST http://$GATEWAY_IP/upload -F file=@testfile.jpg > /dev/null &
done

echo "Attendo la fine dei caricamenti (wait)..."
wait
echo "✅ Load Test inviato al cluster!"