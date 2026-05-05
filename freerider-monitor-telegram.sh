#!/usr/bin/env bash
#
# Freerider Monitor — One-Shot mit Telegram-Push und Command-Receive.
# Designed für GitHub Actions Cron (kein Loop, kein Desktop-Notify).
# Quellen: Hertz Freerider + DriveBack. Movacar deaktiviert.
#
# Env (Pflicht):
#   TELEGRAM_KEY         — Bot-Token von @BotFather
#   CHAT_ID              — Default-Chat-ID für Push-Notifications
#
# Env (optional):
#   STATE_FILE           — Default state/known-ids.txt
#   LAST_UPDATE_FILE     — Default state/last-update-id.txt
#   WHITELIST_CHAT_IDS   — kommagetrennte Liste, Default = CHAT_ID
#
# Ablauf:
#   1. process_updates  — getUpdates pollen, Whitelist filtern,
#                         Commands (/start, /help) abarbeiten
#   2. check_hertz      — Hertz-Routen-Diff + Push bei neuen IDs
#   3. check_driveback  — DriveBack-Diff + Push bei neuen IDs
#
# State-Files werden im aufrufenden Verzeichnis bzw. relativ zu
# STATE_FILE/LAST_UPDATE_FILE erwartet. Im CI liegen sie im
# parallel ausgechecktem state-repo.

set -euo pipefail

HERTZ_API="https://www.hertzfreerider.se/api/transport-routes/?country=SWEDEN"
DRIVEBACK_URL="https://www.driveback.se/resor"
STATE_FILE="${STATE_FILE:-state/known-ids.txt}"
LAST_UPDATE_FILE="${LAST_UPDATE_FILE:-state/last-update-id.txt}"

# Lokal: .env.local laden falls vorhanden. CI: Vars sind schon im Env.
if [ -f .env.local ] && [ -z "${TELEGRAM_KEY:-}" ]; then
    set -a; . ./.env.local; set +a
fi

: "${TELEGRAM_KEY:?TELEGRAM_KEY ist nicht gesetzt}"
: "${CHAT_ID:?CHAT_ID ist nicht gesetzt}"

WHITELIST_CHAT_IDS="${WHITELIST_CHAT_IDS:-${CHAT_ID}}"

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LAST_UPDATE_FILE")"

SILENT_INIT=false
if [ ! -f "$STATE_FILE" ]; then
    SILENT_INIT=true
    touch "$STATE_FILE"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Kein State-File — Silent-Init-Lauf."
fi

# ---------------------------------------------------------------------------
# Telegram-Helpers
# ---------------------------------------------------------------------------

send_message() {
    local target_chat_id="$1"
    local text="$2"
    curl -s --max-time 15 \
        --data-urlencode "chat_id=${target_chat_id}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "disable_web_page_preview=true" \
        "https://api.telegram.org/bot${TELEGRAM_KEY}/sendMessage" \
        > /dev/null
}

notify_telegram() {
    send_message "$CHAT_ID" "$1"
}

is_whitelisted() {
    local cid="$1"
    [[ ",${WHITELIST_CHAT_IDS}," == *",${cid},"* ]]
}

# ---------------------------------------------------------------------------
# Bot-Commands
# ---------------------------------------------------------------------------

cmd_help() {
    local cid="$1"
    send_message "$cid" "🚗 Freerider-Monitor — Commands

/start  — Begrüßung
/help   — diese Übersicht

Du bekommst automatisch Pushes für neue Mietwagen-Rückführungen
aus Hertz Freerider und DriveBack (alle 5 min).

Filter und /search folgen in nächsten Updates."
}

cmd_start() {
    local cid="$1"
    send_message "$cid" "👋 Bot ist aktiv.

Du bekommst Pushes für neue Mietwagen-Rückführungen aus Hertz
Freerider und DriveBack. Tippe /help für eine Command-Übersicht."
}

# ---------------------------------------------------------------------------
# Update-Verarbeitung
# ---------------------------------------------------------------------------

process_updates() {
    local offset=0
    if [ -f "$LAST_UPDATE_FILE" ] && [ -s "$LAST_UPDATE_FILE" ]; then
        offset=$(($(cat "$LAST_UPDATE_FILE") + 1))
    fi

    local response
    response=$(curl -s --max-time 15 \
        "https://api.telegram.org/bot${TELEGRAM_KEY}/getUpdates?offset=${offset}&timeout=0") || {
        echo "[Bot] getUpdates-Fehler"
        return 0
    }

    local ok
    ok=$(echo "$response" | jq -r '.ok // false')
    if [ "$ok" != "true" ]; then
        echo "[Bot] getUpdates ok=false: $(echo "$response" | jq -r '.description // "unbekannt"')"
        return 0
    fi

    local n_updates
    n_updates=$(echo "$response" | jq '.result | length')
    if [ "$n_updates" -eq 0 ]; then
        echo "[Bot] keine neuen Updates"
        return 0
    fi

    local highest=0
    local processed=0
    local rejected=0

    while IFS=$'\t' read -r update_id chat_id text; do
        [ -z "$update_id" ] && continue
        if [ "$update_id" -gt "$highest" ]; then
            highest="$update_id"
        fi

        if ! is_whitelisted "$chat_id"; then
            rejected=$((rejected + 1))
            continue
        fi

        # Strip @bot-suffix, normalize
        local cmd="${text%% *}"
        cmd="${cmd%@*}"

        case "$cmd" in
            /start) cmd_start "$chat_id" ;;
            /help)  cmd_help  "$chat_id" ;;
            "")     ;;  # leere/Non-Text-Updates ignorieren
            *)      ;;  # unbekannte Commands silent ignorieren
        esac
        processed=$((processed + 1))
    done < <(echo "$response" | jq -r '.result[] | [.update_id, (.message.chat.id // ""), (.message.text // "")] | @tsv')

    if [ "$highest" -gt 0 ]; then
        echo "$highest" > "$LAST_UPDATE_FILE"
    fi

    echo "[Bot] ${n_updates} Update(s), ${processed} verarbeitet, ${rejected} abgelehnt (Whitelist), last_update_id=${highest}"
}

# ---------------------------------------------------------------------------
# Source-Checks
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Hauptablauf
# ---------------------------------------------------------------------------

echo "[$(date '+%Y-%m-%d %H:%M:%S')] One-Shot-Lauf. Silent-Init=${SILENT_INIT}."
process_updates || true
check_hertz || true
check_driveback || true
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Fertig."
