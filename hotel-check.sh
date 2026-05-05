#!/usr/bin/env bash
#
# Hotel-Preisvergleich via Xotelo API (Booking.com, Agoda, Trip.com etc.)
# Zeigt die günstigsten Übernachtungen für eine Stadt + Datum.
#
# Nutzung: ./hotel-check.sh <stadt> <check-in> [check-out]
#   ./hotel-check.sh gavle 2026-04-08
#   ./hotel-check.sh uppsala 2026-04-08 2026-04-09
#
# Check-out ist standardmäßig der Tag nach Check-in.

set -euo pipefail

XOTELO_API="https://data.xotelo.com/api"

# TripAdvisor Location Keys für schwedische Städte
declare -A LOCATIONS=(
    [gavle]="g189825"
    [gävle]="g189825"
    [uppsala]="g189871"
    [stockholm]="g189852"
    [göteborg]="g189894"
    [goteborg]="g189894"
    [malmö]="g189838"
    [malmo]="g189838"
    [sundsvall]="g189861"
    [umeå]="g189868"
    [umea]="g189868"
    [lund]="g189836"
    [linköping]="g189834"
    [linkoping]="g189834"
    [örebro]="g189844"
    [orebro]="g189844"
    [västerås]="g189872"
    [vasteras]="g189872"
    [karlstad]="g189831"
    [norrköping]="g189843"
    [norrkoping]="g189843"
    [jönköping]="g189829"
    [jonkoping]="g189829"
    [halmstad]="g189889"
    [kalmar]="g189830"
    [kristianstad]="g189832"
    [luleå]="g189837"
    [lulea]="g189837"
)

city_input="${1:-}"
checkin="${2:-}"
checkout="${3:-}"

if [ -z "$city_input" ] || [ -z "$checkin" ]; then
    echo "Nutzung: $0 <stadt> <check-in> [check-out]"
    echo "Beispiel: $0 gavle 2026-04-08"
    echo ""
    echo "Verfügbare Städte: ${!LOCATIONS[*]}"
    exit 1
fi

city=$(echo "$city_input" | tr '[:upper:]' '[:lower:]')
location_key="${LOCATIONS[$city]:-}"

if [ -z "$location_key" ]; then
    echo "Stadt '$city_input' nicht gefunden."
    echo "Verfügbare Städte: ${!LOCATIONS[*]}"
    exit 1
fi

# Check-out = Check-in + 1 Tag falls nicht angegeben
if [ -z "$checkout" ]; then
    checkout=$(date -d "$checkin + 1 day" '+%Y-%m-%d')
fi

echo "Suche Unterkünfte in $city_input ($checkin → $checkout)..."
echo ""

# Hotels für die Stadt laden
hotels_json=$(curl -s -f --max-time 15 "$XOTELO_API/list?location_key=$location_key&sort=best_value&limit=15")

# Hotel-Keys + Namen extrahieren
mapfile -t hotel_entries < <(echo "$hotels_json" | jq -r '.result.list[] | "\(.key)|\(.name)|\(.accommodation_type)"')

if [ ${#hotel_entries[@]} -eq 0 ]; then
    echo "Keine Hotels gefunden."
    exit 1
fi

echo "Preise werden abgefragt (${#hotel_entries[@]} Unterkünfte)..."
echo ""

# Temporäre Datei für Ergebnisse
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

# Preise parallel abrufen
for entry in "${hotel_entries[@]}"; do
    IFS='|' read -r key name type <<< "$entry"
    (
        rates_json=$(curl -s -f --max-time 15 "$XOTELO_API/rates?hotel_key=$key&chk_in=$checkin&chk_out=$checkout&currency=EUR" 2>/dev/null || echo '{}')
        echo "$rates_json" | jq -r --arg name "$name" --arg type "$type" '
            if .result.rates and (.result.rates | length) > 0 then
                .result.rates | sort_by(.rate) | .[0] |
                "\(.rate)|\($name)|\($type)|\(.name)|\(.rate + .tax)"
            else empty end
        ' 2>/dev/null
    ) >> "$tmpfile" &
done
wait

if [ ! -s "$tmpfile" ]; then
    echo "Keine Preise für dieses Datum verfügbar."
    exit 1
fi

# Sortiert nach Preis ausgeben
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-35s %6s  %-12s %s\n" "Hotel" "Preis" "inkl. Tax" "Anbieter"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

sort -t'|' -k1 -n "$tmpfile" | while IFS='|' read -r rate name type vendor total; do
    printf "%-35s %4s €  %4s €       %s\n" "$name" "$rate" "$total" "$vendor"
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Preise in EUR (ca. 1 EUR ≈ 11.5 SEK). Quelle: Xotelo/TripAdvisor"
