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
#   FILTERS_FILE         — Default state/filters.json
#   WHITELIST_CHAT_IDS   — kommagetrennte Liste, Default = CHAT_ID
#
# Modi (per Argument):
#   (default)       — One-Shot: erst Bot-Commands abarbeiten, dann scrapen
#   --bot-loop      — Daemon: Long-Polling getUpdates (30s timeout), reagiert
#                     binnen <1s auf neue Commands. Kein Scrape.
#   --scrape-only   — Nur Source-Scrape + Push, keine Bot-Commands
#
# State-Files werden im aufrufenden Verzeichnis bzw. relativ zu
# STATE_FILE/LAST_UPDATE_FILE erwartet.

set -euo pipefail

HERTZ_API="https://www.hertzfreerider.se/api/transport-routes/?country=SWEDEN"
DRIVEBACK_URL="https://www.driveback.se/resor"
STATE_FILE="${STATE_FILE:-state/known-ids.txt}"
LAST_UPDATE_FILE="${LAST_UPDATE_FILE:-state/last-update-id.txt}"
FILTERS_FILE="${FILTERS_FILE:-state/filters.json}"

# Lokal: .env.local laden falls vorhanden. CI: Vars sind schon im Env.
if [ -f .env.local ] && [ -z "${TELEGRAM_KEY:-}" ]; then
    set -a; . ./.env.local; set +a
fi

: "${TELEGRAM_KEY:?TELEGRAM_KEY ist nicht gesetzt}"
: "${CHAT_ID:?CHAT_ID ist nicht gesetzt}"

WHITELIST_CHAT_IDS="${WHITELIST_CHAT_IDS:-${CHAT_ID}}"

mkdir -p "$(dirname "$STATE_FILE")" "$(dirname "$LAST_UPDATE_FILE")" "$(dirname "$FILTERS_FILE")"

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
    local response
    response=$(curl -s --max-time 15 \
        --data-urlencode "chat_id=${target_chat_id}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "disable_web_page_preview=true" \
        "https://api.telegram.org/bot${TELEGRAM_KEY}/sendMessage" 2>&1) || {
        echo "[send] curl-Fehler an chat=${target_chat_id}: $response" >&2
        return 0
    }
    local ok
    ok=$(echo "$response" | jq -r '.ok // false' 2>/dev/null || echo "parse-fail")
    if [ "$ok" != "true" ]; then
        local desc
        desc=$(echo "$response" | jq -r '.description // "unbekannt"' 2>/dev/null || echo "$response")
        echo "[send] FAIL chat=${target_chat_id}: ${desc}" >&2
    else
        local mid
        mid=$(echo "$response" | jq -r '.result.message_id // "?"')
        echo "[send] OK chat=${target_chat_id} message_id=${mid} chars=${#text}" >&2
    fi
}

notify_telegram() {
    send_message "$CHAT_ID" "$1"
}

is_whitelisted() {
    local cid="$1"
    [[ ",${WHITELIST_CHAT_IDS}," == *",${cid},"* ]]
}

# ---------------------------------------------------------------------------
# Stadt-Normalisierung (case-insensitive + Diakritika weg)
# ---------------------------------------------------------------------------

normalize_city() {
    echo "$1" | \
      sed -e 's/[åÅ]/a/g' -e 's/[äÄãÃáÁàÀâÂ]/a/g' -e 's/[æÆ]/ae/g' \
          -e 's/[öÖóÓòÒôÔ]/o/g' -e 's/[øØ]/o/g' \
          -e 's/[éÉèÈêÊë]/e/g' \
          -e 's/[üÜúÚûÛ]/u/g' \
          -e 's/[íÍì]/i/g' \
          -e 's/[çÇ]/c/g' -e 's/[ñÑ]/n/g' \
          -e 's/[ßẞ]/ss/g' | \
      tr '[:upper:]' '[:lower:]' | \
      sed "s/[\"'\` ]//g"
}

normalize_city_list() {
    local input="$1"
    local out=""
    IFS=',' read -ra parts <<< "$input"
    for p in "${parts[@]}"; do
        local n
        n=$(normalize_city "$p")
        [ -z "$n" ] && continue
        out+="${n},"
    done
    echo "${out%,}"
}

ensure_filters_file() {
    if [ ! -f "$FILTERS_FILE" ]; then
        echo '[]' > "$FILTERS_FILE"
    fi
}

# ---------------------------------------------------------------------------
# Bot-Commands
# ---------------------------------------------------------------------------

cmd_help() {
    local cid="$1"
    send_message "$cid" "🚗 Freerider-Monitor — Commands

/start         Begrüßung
/help          diese Übersicht
/filters       aktive Filter zeigen
/addfilter     Filter anlegen oder überschreiben
/removefilter  Filter mit Namen löschen
/clear         alle Filter löschen
/search        Live-Suche ohne Filter zu speichern (folgt)

Filter-Syntax (alle Felder außer name optional, Reihenfolge egal):
/addfilter <name> from=A,B to=C,D pickup_after=YYYY-MM-DD pickup_before=YYYY-MM-DD deliver_before=YYYY-MM-DD

Stadtnamen sind case-insensitive und Diakritika-toleriert
(Skellefteå ≡ skelleftea). Mehrere Städte mit Komma trennen.

Ohne Filter werden alle neuen Routen gepusht. Mit Filtern: ein
Push nur wenn eine neue Route mindestens einem Filter komplett
entspricht (AND innerhalb, OR über Filter)."
}

cmd_start() {
    local cid="$1"
    send_message "$cid" "👋 Bot ist aktiv.

Du bekommst Pushes für neue Mietwagen-Rückführungen aus Hertz
Freerider und DriveBack (alle 5 min). Tippe /help für die
Command-Übersicht inklusive Filter-Syntax."
}

# ---------------------------------------------------------------------------
# Filter-CRUD
# ---------------------------------------------------------------------------

cmd_addfilter() {
    local cid="$1"; shift
    local name="${1:-}"
    if [ -z "$name" ]; then
        send_message "$cid" "Nutzung: /addfilter <name> [from=A,B] [to=C,D] [pickup_after=YYYY-MM-DD] [pickup_before=YYYY-MM-DD] [deliver_before=YYYY-MM-DD]"
        return
    fi
    shift

    local from="" to="" pa="" pb="" db=""
    while [ -n "${1:-}" ]; do
        case "$1" in
            from=*)           from="${1#from=}" ;;
            to=*)             to="${1#to=}" ;;
            pickup_after=*)   pa="${1#pickup_after=}" ;;
            pickup_before=*)  pb="${1#pickup_before=}" ;;
            deliver_before=*) db="${1#deliver_before=}" ;;
        esac
        shift
    done

    local from_norm to_norm
    from_norm=$(normalize_city_list "$from")
    to_norm=$(normalize_city_list "$to")

    ensure_filters_file
    local tmp; tmp=$(mktemp)
    jq --arg name "$name" \
       --arg from "$from_norm" \
       --arg to "$to_norm" \
       --arg pa "$pa" \
       --arg pb "$pb" \
       --arg db "$db" \
       'map(select(.name != $name)) + [{
            name: $name,
            from_cities: ($from | if . == "" then [] else split(",") end),
            to_cities:   ($to   | if . == "" then [] else split(",") end),
            pickup_after:    ($pa | if . == "" then null else . end),
            pickup_before:   ($pb | if . == "" then null else . end),
            deliver_before:  ($db | if . == "" then null else . end)
        }]' "$FILTERS_FILE" > "$tmp" && mv "$tmp" "$FILTERS_FILE"

    local count; count=$(jq 'length' "$FILTERS_FILE")
    send_message "$cid" "✓ Filter '${name}' gespeichert (gesamt: ${count}).

from: ${from_norm:-(beliebig)}
to: ${to_norm:-(beliebig)}
pickup_after: ${pa:-(egal)}
pickup_before: ${pb:-(egal)}
deliver_before: ${db:-(egal)}"
}

cmd_filters() {
    local cid="$1"
    ensure_filters_file
    local count; count=$(jq 'length' "$FILTERS_FILE")
    if [ "$count" -eq 0 ]; then
        send_message "$cid" "Keine aktiven Filter.
Backstop: alle neuen Routen werden gepusht."
        return
    fi
    local list
    list=$(jq -r '.[] |
        "• \(.name)\n  from: \(.from_cities | if length == 0 then "(beliebig)" else join(",") end)\n  to: \(.to_cities | if length == 0 then "(beliebig)" else join(",") end)\n  pickup: \(.pickup_after // "*") .. \(.pickup_before // "*")\n  deliver_before: \(.deliver_before // "(egal)")"' "$FILTERS_FILE")
    send_message "$cid" "Aktive Filter (${count}):

${list}"
}

cmd_removefilter() {
    local cid="$1"; shift
    local name="${1:-}"
    if [ -z "$name" ]; then
        send_message "$cid" "Nutzung: /removefilter <name>"
        return
    fi
    ensure_filters_file
    local before; before=$(jq 'length' "$FILTERS_FILE")
    local tmp; tmp=$(mktemp)
    jq --arg name "$name" 'map(select(.name != $name))' "$FILTERS_FILE" > "$tmp" && mv "$tmp" "$FILTERS_FILE"
    local after; after=$(jq 'length' "$FILTERS_FILE")
    if [ "$before" = "$after" ]; then
        send_message "$cid" "Kein Filter mit Name '${name}' gefunden. Aktive: ${after}."
    else
        send_message "$cid" "✓ Filter '${name}' gelöscht. Verbleibend: ${after}."
    fi
}

cmd_clear() {
    local cid="$1"
    ensure_filters_file
    local before; before=$(jq 'length' "$FILTERS_FILE")
    echo '[]' > "$FILTERS_FILE"
    send_message "$cid" "✓ Alle Filter gelöscht (${before} entfernt).
Backstop aktiv: alle neuen Routen werden gepusht."
}

# ---------------------------------------------------------------------------
# Filter-Match-Logik (jq-basiert, OR über Filter, AND innerhalb)
# ---------------------------------------------------------------------------

# Returns 0 (match → push) oder 1 (kein match → still).
# Args: from_city_raw, to_city_raw, pickup_iso, deliver_iso
match_filters() {
    local from to pickup deliver
    from=$(normalize_city "$1")
    to=$(normalize_city "$2")
    pickup="${3:0:10}"   # YYYY-MM-DD aus ISO-String
    deliver="${4:0:10}"

    ensure_filters_file

    local result
    result=$(jq --arg from "$from" --arg to "$to" \
                --arg pickup "$pickup" --arg deliver "$deliver" '
        if length == 0 then true
        else
            any(.[];
                (.from_cities | length == 0 or any(.[]; . == $from)) and
                (.to_cities   | length == 0 or any(.[]; . == $to)) and
                (.pickup_after   == null or $pickup  >= .pickup_after)  and
                (.pickup_before  == null or $pickup  <= .pickup_before) and
                (.deliver_before == null or $deliver <= .deliver_before)
            )
        end
    ' "$FILTERS_FILE")

    [ "$result" = "true" ]
}

# ---------------------------------------------------------------------------
# Update-Verarbeitung
# ---------------------------------------------------------------------------

process_updates() {
    local poll_timeout="${1:-0}"
    local offset=0
    if [ -f "$LAST_UPDATE_FILE" ] && [ -s "$LAST_UPDATE_FILE" ]; then
        offset=$(($(cat "$LAST_UPDATE_FILE") + 1))
    fi

    # curl-max-time = poll_timeout + 5s Buffer
    local curl_timeout=$((poll_timeout + 5))
    local response
    response=$(curl -s --max-time "$curl_timeout" \
        "https://api.telegram.org/bot${TELEGRAM_KEY}/getUpdates?offset=${offset}&timeout=${poll_timeout}") || {
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

        # Strip @bot-suffix, isolate command + args
        local cmd="${text%% *}"
        cmd="${cmd%@*}"
        local args="${text#"${text%% *}"}"
        args="${args# }"

        # shellcheck disable=SC2086 — args wird absichtlich word-gesplittet
        case "$cmd" in
            /start)        cmd_start        "$chat_id" ;;
            /help)         cmd_help         "$chat_id" ;;
            /filters)      cmd_filters      "$chat_id" ;;
            /clear)        cmd_clear        "$chat_id" ;;
            /addfilter)    cmd_addfilter    "$chat_id" $args ;;
            /removefilter) cmd_removefilter "$chat_id" $args ;;
            "")            ;;
            *)             ;;
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

    local new_in_state=0
    local matched=0

    while IFS='|' read -r id pickup_city return_city car_model available_at latest_return; do
        [ -z "$id" ] && continue
        local state_id="hertz-$id"
        if ! grep -qxF "$state_id" "$STATE_FILE"; then
            echo "$state_id" >> "$STATE_FILE"
            new_in_state=$((new_in_state + 1))
            if match_filters "$pickup_city" "$return_city" "$available_at" "$latest_return"; then
                matched=$((matched + 1))
                new_lines+="• ${pickup_city} → ${return_city}"$'\n'"  ${car_model} | ab ${available_at:0:10} | bis ${latest_return:0:10}"$'\n\n'
            fi
        fi
    done < <(echo "$response" | jq -r '
        .[].routes[] |
        "\(.id)|\(.pickupLocation.city // .pickupLocation.name)|\(.returnLocation.city // .returnLocation.name)|\(.carModel)|\(.availableAt)|\(.latestReturn // "")"
    ')

    local total
    total=$(echo "$response" | jq '[.[].routes | length] | add // 0')

    if [ "$matched" -gt 0 ] && [ "$SILENT_INIT" = false ]; then
        notify_telegram "🚗 Hertz Freerider — ${matched} neue Route(n)"$'\n\n'"${new_lines}"
    fi
    echo "[Hertz] ${total} aktiv, ${new_in_state} neu, ${matched} match"
}

check_driveback() {
    local response
    response=$(curl -s -f --max-time 30 "$DRIVEBACK_URL") || {
        echo "[DriveBack] API-Fehler"
        return 1
    }

    local new_lines=""
    local new_count=0

    local new_in_state=0
    local matched=0

    while IFS='|' read -r id from_area from_city to_area to_city car_model first_pickup last_deliver; do
        [ -z "$id" ] && continue
        local state_id="driveback-$id"
        if ! grep -qxF "$state_id" "$STATE_FILE"; then
            echo "$state_id" >> "$STATE_FILE"
            new_in_state=$((new_in_state + 1))
            if match_filters "$from_city" "$to_city" "$first_pickup" "$last_deliver"; then
                matched=$((matched + 1))
                local pickup_date="${first_pickup%%T*}"
                local deliver_date="${last_deliver%%T*}"
                new_lines+="• ${from_area} (${from_city}) → ${to_area} (${to_city})"$'\n'"  ${car_model} | ab ${pickup_date} | bis ${deliver_date}"$'\n\n'
            fi
        fi
    done < <(echo "$response" | jq -r '
        .[] |
        "\(.id)|\(.from_station.area)|\(.from_station.location.city)|\(.to_stations[0].area)|\(.to_stations[0].location.city)|\(.vehicle.car_model)|\(.first_pickup)|\(.last_deliver // "")"
    ')

    local total
    total=$(echo "$response" | jq 'length')

    if [ "$matched" -gt 0 ] && [ "$SILENT_INIT" = false ]; then
        notify_telegram "🚗 DriveBack — ${matched} neue Rückführung(en)"$'\n\n'"${new_lines}"
    fi
    echo "[DriveBack] ${total} aktiv, ${new_in_state} neu, ${matched} match"
}

# ---------------------------------------------------------------------------
# Hauptablauf
# ---------------------------------------------------------------------------

case "${1:-}" in
    --bot-loop)
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Bot-Loop gestartet (Long-Polling, 30s timeout)."
        while true; do
            process_updates 30 || echo "[Bot] iter-fail, weiter in 5s"
            sleep 1
        done
        ;;
    --scrape-only)
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Scrape-Lauf. Silent-Init=${SILENT_INIT}."
        check_hertz || true
        check_driveback || true
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Fertig."
        ;;
    *)
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] One-Shot-Lauf. Silent-Init=${SILENT_INIT}."
        process_updates 0 || true
        check_hertz || true
        check_driveback || true
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Fertig."
        ;;
esac
