#!/bin/bash

##################################################
# Capture d'écran multiple sur macOS et les diffuser via FFmpeg
# Ce script détecte tous les écrans disponibles, les capture,
# les combine horizontalement, et les diffuse vers un serveur RTMP.
##################################################

# Fonction de nettoyage pour Control-C
cleanup() {
    echo -e "\n\nArrêt du stream..."
    kill $FFMPEG_PID 2>/dev/null || true
    kill $READER_PID 2>/dev/null || true
    rm -f "$FIFO"
    exit 0
}

# Capturer Control-C (SIGINT) et SIGTERM
trap cleanup SIGINT SIGTERM

SCALE="1920:-2" # Redimensionner à une largeur de 1920px, en ajustant la hauteur pour conserver les proportions
# Récupérer l'URL du stream depuis une variable d'environnement STREAM_URL (ou RTMP_URL)
STREAM_URL="${STREAM_URL}"
if [ -z "$STREAM_URL" ]; then
    echo "Erreur: veuillez définir la variable d'environnement STREAM_URL (ex: rtmp://server/app/cle)"
    exit 1
fi

# 1. Detecter les index des écrans
# Nous capturons la sortie, cherchons "Capture screen", et extrayons les numéros d'index.
# Exemple de ligne: [AVFoundation input device @ 0x7fae5bc0c600] [1] Capture screen 0
DEVICES=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep "Capture screen" | awk -F'[][]' '{print $4}')

if [ -z "$DEVICES" ]; then
    echo "Aucun périphérique de capture d'écran trouvé."
    exit 1
fi

echo "Indices des écrans trouvés : $DEVICES"

# 2. Construire dynamiquement la commande FFmpeg
# Nous devons construire les arguments d'entrée (-i ...) et les arguments de filtre (hstack) 
# en fonction du nombre d'écrans.

INPUTS_ARGS=()
FILTER_SCALES=""
FILTER_STACK=""
COUNT=0

for INDEX in $DEVICES; do
    # Ajouter l'entrée pour cet écran
    INPUTS_ARGS+=("-f" "avfoundation" "-framerate" "30" "-i" "${INDEX}:none")
    
    # Créer une chaîne de filtres pour redimensionner cette entrée spécifique à une hauteur commune (720px) 
    # afin de garantir qu'elles peuvent être empilées, puis lui attribuer une étiquette [v0], [v1], etc.
    FILTER_SCALES="${FILTER_SCALES}[${COUNT}:v]scale=-2:720[v${COUNT}];"
    
    # Construire la liste des étiquettes à empiler plus tard : [v0][v1]...
    FILTER_STACK="${FILTER_STACK}[v${COUNT}]"
    
    ((COUNT++))
done

# 3. Finaliser la chaîne de filtres
if [ "$COUNT" -gt 1 ]; then
    # Si plusieurs écrans : les empiler horizontalement, puis redimensionner le résultat FINAL selon la demande de l'utilisateur
    FULL_FILTER="${FILTER_SCALES}${FILTER_STACK}hstack=inputs=${COUNT}[stacked];[stacked]scale=${SCALE},format=yuv420p[out]"
    MAP_ARG="-map [out]"
else
    # Si seulement un écran : le redimensionner directement
    FULL_FILTER="scale=${SCALE},format=yuv420p"
    MAP_ARG="" 
fi

echo "Démarrage du flux combiné avec $COUNT écrans..."

# 4. Exécuter FFmpeg

# Créer un FIFO pour la progression de ffmpeg et démarrer un lecteur avant de lancer ffmpeg
FIFO="$(mktemp -u)"
mkfifo "$FIFO"

# Lecteur : analyser les lignes de progression et afficher le nombre de frames envoyées
(
    while IFS='=' read -r key val; do
        case "$key" in
            frame) printf "\rFrames envoyées : %s" "$val" ;;
            progress) [ "$val" = "end" ] && { echo; break; } ;;
        esac
    done <"$FIFO"
) &
READER_PID=$!

# Rouler ffmpeg caché, en envoyant la progression au FIFO
ffmpeg \
    "${INPUTS_ARGS[@]}" \
    -filter_complex "$FULL_FILTER" $MAP_ARG \
    -c:v libx264 \
    -preset ultrafast \
    -tune zerolatency \
    -crf 35 \
    -g 10 \
    -an \
    -f flv "$STREAM_URL" \
    -progress "$FIFO" -nostats -hide_banner -loglevel error 2>/dev/null &
FFMPEG_PID=$!

# Attendre que ffmpeg se termine, puis nettoyer le lecteur et le FIFO
wait $FFMPEG_PID
EXIT_CODE=$?
kill $READER_PID 2>/dev/null || true
rm -f "$FIFO"
exit $EXIT_CODE