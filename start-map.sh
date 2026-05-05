#!/usr/bin/env bash
# Startet die Freerider Map: aktualisiert Daten und öffnet einen lokalen Server.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT=8042

# Daten aktualisieren
echo "Aktualisiere Daten..."
bash "$SCRIPT_DIR/update-data.sh"

echo ""
echo "Starte Server auf http://localhost:$PORT"
echo "Strg+C zum Beenden"

# Auto-Update im Hintergrund alle 5 Minuten
(while true; do sleep 300; bash "$SCRIPT_DIR/update-data.sh" 2>/dev/null; done) &
UPDATE_PID=$!
trap "kill $UPDATE_PID 2>/dev/null" EXIT

# Server starten und Browser öffnen
xdg-open "http://localhost:$PORT/map.html" 2>/dev/null &
cd "$SCRIPT_DIR"
python3 -m http.server "$PORT"
