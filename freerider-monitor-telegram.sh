#!/usr/bin/env bash
#
# Freerider Monitor — One-Shot-Variante mit Telegram-Notify.
# Designed für GitHub Actions Cron (kein Loop, kein Desktop-Notify).
# Quellen: Hertz Freerider + DriveBack. Movacar ist deaktiviert
# (Stand 2026-05-05).
#
# Erwartet die Env-Vars TELEGRAM_KEY und CHAT_ID (lokal über
# .env.local, in CI über GitHub Secrets).
#
# State-File: $STATE_FILE (Default state/known-ids.txt im Repo).
# Initial-Lauf (kein State-File): SILENT_INIT=true → Baseline befüllen,
# nichts senden.

set -euo pipefail

HERTZ_API="https://www.hertzfreerider.se/api/transport-routes/?country=SWEDEN"
DRIVEBACK_URL="https://www.driveback.se/resor"
STATE_FILE="${STATE_FILE:-state/known-ids.txt}"

# Lokal: .env.local laden falls vorhanden. CI: Vars sind schon im Env.
if [ -f .env.local ] && [ -z "${TELEGRAM_KEY:-}" ]; then
    set -a; . ./.env.local; set +a
fi

: "${TELEGRAM_KEY:?TELEGRAM_KEY ist nicht gesetzt}"
: "${CHAT_ID:?CHAT_ID ist nicht gesetzt}"

mkdir -p "$(dirname "$STATE_FILE")"
SILENT_INIT=false
if [ ! -f "$STATE_FILE" ]; then
    SILENT_INIT=true
    touch "$STATE_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Kein State-File — Silent-Init-Lauf."
fi

notify_telegram() {
    local text="$1"
    curl -s --max-time 15 \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "disable_web_page_preview=true" \
        "https://api.telegram.org/bot${TELEGRAM_KEY}/sendMessage" \
        > /dev/null
}

check_hertz() {
    local response
    response=$(curl -s -f --max-time 30 "$HERTZ_API") || {
        echo "[Hertz] API-Fehler"
        return 1
    }

    local new_lines=""
    local new_count=0

    while IFS='|' read -r id pickup_city return_city car_model available_at; do
        [ -z "$id" ] && continue
        local state_id="hertz-$id"
        if ! grep -qxF "$state_id" "$STATE_FILE"; then
            echo "$state_id" >> "$STATE_FILE"
            new_count=$((new_count + 1))
            new_lines+="• ${pickup_city} → ${return_city}"$'\n'"  ${car_model} | ab ${available_at}"$'\n\n'
        fi
    done < <(echo "$response" | jq -r '
        .[].routes[] |
        "\(.id)|\(.pickupLocation.city // .pickupLocation.name)|\(.returnLocation.city // .returnLocation.name)|\(.carModel)|\(.availableAt)"
    ')

    local total
    total=$(echo "$response" | jq '[.[].routes | length] | add // 0')

    if [ "$new_count" -gt 0 ] && [ "$SILENT_INIT" = false ]; then
        notify_telegram "🚗 Hertz Freerider — ${new_count} neue Route(n)"$'\n\n'"${new_lines}"
    fi
    echo "[Hertz] ${total} aktiv, ${new_count} neu"
}

check_driveback() {
    local response
    response=$(curl -s -f --max-time 30 "$DRIVEBACK_URL") || {
        echo "[DriveBack] API-Fehler"
        return 1
    }

    local new_lines=""
    local new_count=0

    while IFS='|' read -r id from_area from_city to_area to_city car_model first_pickup; do
        [ -z "$id" ] && continue
        local state_id="driveback-$id"
        if ! grep -qxF "$state_id" "$STATE_FILE"; then
            echo "$state_id" >> "$STATE_FILE"
            new_count=$((new_count + 1))
            local pickup_date="${first_pickup%%T*}"
            new_lines+="• ${from_area} (${from_city}) → ${to_area} (${to_city})"$'\n'"  ${car_model} | ab ${pickup_date}"$'\n\n'
        fi
    done < <(echo "$response" | jq -r '
        .[] |
        "\(.id)|\(.from_station.area)|\(.from_station.location.city)|\(.to_stations[0].area)|\(.to_stations[0].location.city)|\(.vehicle.car_model)|\(.first_pickup)"
    ')

    local total
    total=$(echo "$response" | jq 'length')

    if [ "$new_count" -gt 0 ] && [ "$SILENT_INIT" = false ]; then
        notify_telegram "🚗 DriveBack — ${new_count} neue Rückführung(en)"$'\n\n'"${new_lines}"
    fi
    echo "[DriveBack] ${total} aktiv, ${new_count} neu"
}

echo "[$(date '+%Y-%m-%d %H:%M:%S')] One-Shot-Lauf. Silent-Init=${SILENT_INIT}."
check_hertz || true
check_driveback || true
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Fertig."
