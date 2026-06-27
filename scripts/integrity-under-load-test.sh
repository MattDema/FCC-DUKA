#!/bin/bash

# Test integrita sotto carico per DUKA.
# Obiettivo:
#   1. Generare upload concorrenti per stimolare HPA.
#   2. Caricare un file campione.
#   3. Scaricarlo tramite file_id.
#   4. Confrontare checksum originale e scaricato.
#
# Uso:
#   chmod +x integrity-under-load-test.sh
#   ./integrity-under-load-test.sh

# DA CAMBIARE: inserisci IP e porta esatta del tuo Gateway o Ingress.
GATEWAY_IP="localhost:30080"

# Parametri del carico di background.
LOAD_FILE_MB=1
LOAD_REQUESTS=30

# Parametri del file di integrita.
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
    echo "ERRORE: md5sum/md5 non trovato." >&2
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

  # Fallback senza jq: prova a leggere campi JSON comuni.
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
echo "🧪 Test integrita sotto carico"
echo "🌐 Gateway: http://$GATEWAY_IP"
echo "📦 Carico background: ${LOAD_REQUESTS} upload da ${LOAD_FILE_MB}MB"
echo "=================================================="

echo ""
echo "1. Creo file di carico e file campione..."
dd if=/dev/urandom of="$LOAD_FILE" bs=1M count="$LOAD_FILE_MB" 2>/dev/null
dd if=/dev/urandom of="$ORIGINAL_FILE" bs=1M count=1 2>/dev/null

ORIGINAL_MD5=$(checksum "$ORIGINAL_FILE")
echo "Checksum originale: $ORIGINAL_MD5"

echo ""
echo "2. Avvio carico in background..."
for i in $(seq 1 "$LOAD_REQUESTS"); do
  curl -s -X POST "http://$GATEWAY_IP/upload" -F file=@"$LOAD_FILE" > /dev/null &
done

echo "Carico avviato. Ora faccio upload/download del file campione mentre il Gateway e sotto stress."

echo ""
echo "3. Upload file campione..."
curl -s -X POST "http://$GATEWAY_IP/upload" -F file=@"$ORIGINAL_FILE" -o "$UPLOAD_RESPONSE_FILE"

echo "Risposta upload:"
cat "$UPLOAD_RESPONSE_FILE"
echo ""

FILE_ID=$(extract_file_id "$UPLOAD_RESPONSE_FILE")

if [ -z "$FILE_ID" ]; then
  echo ""
  echo "Non sono riuscito a estrarre automaticamente il file_id."
  echo "Guarda la risposta sopra e incolla qui il file_id:"
  read -r FILE_ID
fi

if [ -z "$FILE_ID" ]; then
  echo "ERRORE: file_id vuoto. Impossibile continuare."
  exit 1
fi

echo "File ID: $FILE_ID"

echo ""
echo "4. Download file campione..."
curl -s "http://$GATEWAY_IP/download/$FILE_ID" -o "$DOWNLOADED_FILE"

if [ ! -s "$DOWNLOADED_FILE" ]; then
  echo "ERRORE: download fallito oppure file scaricato vuoto."
  echo "Controlla endpoint: http://$GATEWAY_IP/download/$FILE_ID"
  exit 1
fi

DOWNLOADED_MD5=$(checksum "$DOWNLOADED_FILE")
echo "Checksum scaricato: $DOWNLOADED_MD5"

echo ""
echo "5. Attendo fine carico background..."
wait

echo ""
echo "=================================================="
if [ "$ORIGINAL_MD5" = "$DOWNLOADED_MD5" ]; then
  echo "✅ SUCCESSO: checksum identici."
  echo "Il sistema mantiene integrita dei dati anche sotto carico."
else
  echo "❌ FALLIMENTO: checksum diversi."
  echo "Il file scaricato non coincide con quello originale."
  exit 1
fi
echo "=================================================="

echo ""
echo "Comandi utili da mostrare in un altro terminale durante il test:"
echo "watch -n 1 \"kubectl get hpa -n duka; echo '---'; kubectl get pods -n duka\""
echo ""
echo "Comandi post-test:"
echo "kubectl get hpa -n duka"
echo "kubectl get pods -n duka"
echo "kubectl top pods -n duka"
