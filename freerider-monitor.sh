#!/usr/bin/env bash
#
# Freerider Monitor (Hertz Freerider + DriveBack + Movacar)
# Prüft regelmäßig auf neue Mietwagenrückführungen und benachrichtigt
# per Desktop-Notification + Sound.
#
# Nutzung: ./freerider-monitor.sh [INTERVALL_SEKUNDEN]
#   Standard-Intervall: 300 (5 Minuten)

set -euo pipefail

HERTZ_API="https://www.hertzfreerider.se/api/transport-routes/?country=SWEDEN"
DRIVEBACK_URL="https://www.driveback.se/resor"
MOVACAR_API="https://crowd-api-production-615013621295.europe-west1.run.app/v1"
STATE_FILE="$HOME/.cache/freerider-known-ids.txt"
CHECK_INTERVAL="${1:-300}"

mkdir -p "$(dirname "$STATE_FILE")"
touch "$STATE_FILE"

notify() {
    local title="$1"
    local body="$2"

    # Desktop-Notification
    if command -v notify-send &>/dev/null; then
        notify-send -u critical -i car "$title" "$body"
    fi

    # Sound
    if command -v paplay &>/dev/null; then
        paplay /usr/share/sounds/freedesktop/stereo/complete.oga 2>/dev/null || true
    elif command -v aplay &>/dev/null; then
        aplay /usr/share/sounds/sound-icons/glass-water-1.wav 2>/dev/null || true
    fi

    # Terminal-Ausgabe
    echo ""
    echo "========================================"
    echo "  🚗 $title"
    echo "  $body"
    echo "========================================"
    echo ""
}

check_hertz() {
    local response
    response=$(curl -s -f --max-time 30 "$HERTZ_API") || {
        echo "[$(date '+%H:%M:%S')] [Hertz] Fehler beim Abrufen der API"
        return 1
    }

    local new_count=0
    local details=""

    while IFS='|' read -r id pickup_city return_city car_model available_at; do
        [ -z "$id" ] && continue
        local state_id="hertz-$id"

        if ! grep -qxF "$state_id" "$STATE_FILE"; then
            echo "$state_id" >> "$STATE_FILE"
            new_count=$((new_count + 1))
            details+="  • [Hertz] $pickup_city → $return_city | $car_model | Ab: $available_at"$'\n'
        fi
    done < <(echo "$response" | jq -r '
        .[].routes[] |
        "\(.id)|\(.pickupLocation.city // .pickupLocation.name)|\(.returnLocation.city // .returnLocation.name)|\(.carModel)|\(.availableAt)"
    ')

    local total
    total=$(echo "$response" | jq '[.[].routes | length] | add // 0')

    if [ "$new_count" -gt 0 ] && [ "$SILENT_INIT" = false ]; then
        notify "Neue Hertz Freerider-Routen!" "$new_count neue Route(n)"
        echo "$details"
    fi
    echo "[$(date '+%H:%M:%S')] [Hertz] $total aktive Routen, $new_count neu"
}

check_driveback() {
    local response
    response=$(curl -s -f --max-time 30 "$DRIVEBACK_URL") || {
        echo "[$(date '+%H:%M:%S')] [DriveBack] Fehler beim Abrufen"
        return 1
    }

    local new_count=0
    local details=""

    while IFS='|' read -r id from_area from_city to_area to_city car_model first_pickup; do
        [ -z "$id" ] && continue
        local state_id="driveback-$id"

        if ! grep -qxF "$state_id" "$STATE_FILE"; then
            echo "$state_id" >> "$STATE_FILE"
            new_count=$((new_count + 1))
            local pickup_date="${first_pickup%%T*}"
            details+="  • [DriveBack] $from_area ($from_city) → $to_area ($to_city) | $car_model | Ab: $pickup_date"$'\n'
        fi
    done < <(echo "$response" | jq -r '
        .[] |
        "\(.id)|\(.from_station.area)|\(.from_station.location.city)|\(.to_stations[0].area)|\(.to_stations[0].location.city)|\(.vehicle.car_model)|\(.first_pickup)"
    ')

    local total
    total=$(echo "$response" | jq 'length')

    if [ "$new_count" -gt 0 ] && [ "$SILENT_INIT" = false ]; then
        notify "Neue DriveBack-Rückführungen!" "$new_count neue Route(n)"
        echo "$details"
    fi
    echo "[$(date '+%H:%M:%S')] [DriveBack] $total aktive Routen, $new_count neu"
}

check_movacar() {
    # Movacar bietet Routen in ganz Europa an (hauptsächlich Deutschland + Skandinavien)
    # Wir suchen nach Angeboten mit Ziel Schweden (Stockholm, Göteborg, Malmö)
    local new_count=0
    local details=""
    local total=0

    for dest_name in Stockholm Göteborg Malmö; do
        local loc_response
        loc_response=$(curl -s -f --max-time 15 -H "Accept: application/vnd.api+json" \
            "$MOVACAR_API/locations?name=$dest_name&language=en" 2>/dev/null) || continue

        local dest_ref
        dest_ref=$(echo "$loc_response" | jq -r '.data[0].attributes.reference // empty' 2>/dev/null)
        [ -z "$dest_ref" ] && continue

        local offers_response
        offers_response=$(curl -s -f --max-time 15 -H "Accept: application/vnd.api+json" \
            "$MOVACAR_API/offers?locale=en&destination=$dest_ref" 2>/dev/null) || continue

        while IFS='|' read -r offer_id origin destination vehicle pickup deliver km; do
            [ -z "$offer_id" ] && continue
            total=$((total + 1))
            local state_id="movacar-$offer_id"

            if ! grep -qxF "$state_id" "$STATE_FILE"; then
                echo "$state_id" >> "$STATE_FILE"
                new_count=$((new_count + 1))
                details+="  • [Movacar] $origin → $destination | $vehicle | Ab: $pickup | Bis: $deliver | ${km}km inkl."$'\n'
            fi
        done < <(echo "$offers_response" | jq -r '
            ([.included[] | select(.type == "station")] | map({(.id): .attributes.city}) | add) as $stations |
            [.data[] |
                "\(.attributes.offer_id)|\($stations[.relationships.origin.data.id])|\($stations[.relationships.destination.data.id])|\(.attributes.make // "") \(.attributes.model // "")|\(.attributes.start_date | split("T")[0])|\(.attributes.end_date | split("T")[0])|\(.attributes.free_km)"
            ] | .[]
        ' 2>/dev/null)
    done

    if [ "$new_count" -gt 0 ] && [ "$SILENT_INIT" = false ]; then
        notify "Neue Movacar-Rückführungen!" "$new_count neue Route(n)"
        echo "$details"
    fi
    echo "[$(date '+%H:%M:%S')] [Movacar] $total aktive Routen (SE), $new_count neu"
}

SILENT_INIT=false

check_all() {
    check_hertz
    check_driveback
    check_movacar
}

echo "Freerider Monitor gestartet (Hertz + DriveBack + Movacar)"
echo "Prüfe alle $CHECK_INTERVAL Sekunden..."
echo "Strg+C zum Beenden"
echo ""

# Initialer Scan: IDs speichern, aber keine Notifications/Details
echo "[$(date '+%H:%M:%S')] Initialer Scan..."
SILENT_INIT=true
check_all
SILENT_INIT=false
echo ""
echo "Baseline erfasst. Ab jetzt wird bei neuen Routen benachrichtigt."
echo ""

# Monitoring-Loop
while true; do
    sleep "$CHECK_INTERVAL"
    echo "--- Check $(date '+%H:%M:%S') ---"
    check_all
done
