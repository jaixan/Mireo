#!/bin/bash

# Couleurs pour l'affichage
RESET="\033[0m"
BOLD="\033[1m"
CYAN="\033[36m"
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
BLUE="\033[34m"

# Fonction splash screen
show_splash() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "  ███╗   ███╗██╗██████╗ ███████╗ ██████╗ "
    echo "  ████╗ ████║██║██╔══██╗██╔════╝██╔═══██╗"
    echo "  ██╔████╔██║██║██████╔╝█████╗  ██║   ██║"
    echo "  ██║╚██╔╝██║██║██╔══██╗██╔══╝  ██║   ██║"
    echo "  ██║ ╚═╝ ██║██║██║  ██║███████╗╚██████╔╝"
    echo "  ╚═╝     ╚═╝╚═╝╚═╝  ╚═╝╚══════╝ ╚═════╝ "
    echo -e "${RESET}"
    echo -e "${BLUE}  Système de surveillance multi-écrans${RESET}"
    echo -e "${BLUE}  ────────────────────────────────────${RESET}"
    echo ""
}

# Fonction de nettoyage pour Control-C
cleanup() {
    echo -e "\n${YELLOW}┌─────────────────────────────────┐${RESET}"
    echo -e "${YELLOW}│${RESET}  Arrêt du stream en cours...    ${YELLOW}│${RESET}"
    echo -e "${YELLOW}└─────────────────────────────────┘${RESET}"
    kill $FFMPEG_PID 2>/dev/null || true
    kill $READER_PID 2>/dev/null || true
    kill $MONITOR_PID 2>/dev/null || true
    rm -f "$FIFO"
    echo -e "${GREEN}✓ Stream arrêté avec succès${RESET}"
    exit 0
}

# Capturer Control-C (SIGINT) et SIGTERM
trap cleanup SIGINT SIGTERM

# Afficher le splash screen
show_splash

# Configuration
SCALE="1920:-2"
STREAM_URL="${STREAM_URL}"

if [ -z "$STREAM_URL" ]; then
    echo -e "${RED}✗ Erreur:${RESET} Variable d'environnement STREAM_URL non définie"
    echo -e "${YELLOW}  Exemple:${RESET} export STREAM_URL='rtmp://server/app/cle'"
    exit 1
fi

echo -e "${GREEN}✓ Configuration chargée${RESET}"
echo -e "  ${CYAN}URL:${RESET} $STREAM_URL"

# Détection des écrans
echo -e "\n${CYAN}┌─────────────────────────────────┐${RESET}"
echo -e "${CYAN}│${RESET}  Détection des écrans...        ${CYAN}│${RESET}"
echo -e "${CYAN}└─────────────────────────────────┘${RESET}"

DEVICES=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep "Capture screen" | awk -F'[][]' '{print $4}')

if [ -z "$DEVICES" ]; then
    echo -e "${RED}✗ Aucun périphérique de capture d'écran trouvé${RESET}"
    exit 1
fi

SCREEN_COUNT=$(echo "$DEVICES" | wc -w | xargs)
echo -e "${GREEN}✓ ${SCREEN_COUNT} écran(s) détecté(s)${RESET}"
for DEVICE in $DEVICES; do
    echo -e "  ${BLUE}•${RESET} Écran $DEVICE"
done

INITIAL_DEVICES="$DEVICES"

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

# Démarrage du stream
echo -e "\n${CYAN}┌─────────────────────────────────┐${RESET}"
echo -e "${CYAN}│${RESET}  Démarrage du stream...         ${CYAN}│${RESET}"
echo -e "${CYAN}└─────────────────────────────────┘${RESET}"
echo -e "${GREEN}✓ Configuration:${RESET} $COUNT écran(s)"
echo -e "${GREEN}✓ Résolution:${RESET} $SCALE"
echo -e "${GREEN}✓ Codec:${RESET} H.264 (ultrafast)"
echo ""

# Créer un FIFO pour la progression de ffmpeg et démarrer un lecteur avant de lancer ffmpeg
FIFO="$(mktemp -u)"
mkfifo "$FIFO"

# Lecteur : analyser les lignes de progression et afficher le nombre de frames envoyées
(
    while IFS='=' read -r key val; do
        case "$key" in
            frame) 
                val=$(echo "$val" | xargs)
                printf "\r${BLUE}⬤${RESET} Streaming en cours... ${GREEN}%s${RESET} frames" "$val" 
                ;;
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

# Démarrer le monitoring des changements d'écrans
(
    while true; do
        sleep 3
        NEW_DEVICES=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep "Capture screen" | awk -F'[][]' '{print $4}')
        if [ "$NEW_DEVICES" != "$INITIAL_DEVICES" ]; then
            echo -e "\n\n${YELLOW}⚠ Changement d'écrans détecté${RESET}"
            echo -e "${CYAN}↻ Redémarrage du stream...${RESET}"
            # Tuer ffmpeg et le lecteur
            kill $FFMPEG_PID 2>/dev/null || true
            kill $READER_PID 2>/dev/null || true
            # Sortir de la boucle et terminer le subprocess
            exit 0
        fi
    done
) &
MONITOR_PID=$!

# Attendre que ffmpeg se termine, puis nettoyer le lecteur et le FIFO
wait $FFMPEG_PID
EXIT_CODE=$?
kill $READER_PID 2>/dev/null || true
kill $MONITOR_PID 2>/dev/null || true
rm -f "$FIFO"

# Si ffmpeg s'est terminé avec une erreur ou a été tué, et que les écrans ont changé, redémarrer
NEW_DEVICES=$(ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep "Capture screen" | awk -F'[][]' '{print $4}')
if [ "$NEW_DEVICES" != "$INITIAL_DEVICES" ]; then
    echo -e "\n${CYAN}↻ Redémarrage avec la nouvelle configuration...${RESET}\n"
    sleep 1
    exec "$0" "$@"
fi

echo -e "\n${GREEN}✓ Stream terminé${RESET}"
exit $EXIT_CODE