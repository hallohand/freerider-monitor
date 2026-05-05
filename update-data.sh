#!/usr/bin/env bash
# Fetches Hertz Freerider + Movacar data and saves as JSON fallback files.
# Run this before opening map.html (Hertz has no CORS headers).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Hertz Freerider ==="
curl -s -f --max-time 15 "https://www.hertzfreerider.se/api/transport-routes/?country=SWEDEN" > "$SCRIPT_DIR/hertz-data.json"
count=$(jq '[.[].routes | length] | add // 0' "$SCRIPT_DIR/hertz-data.json")
echo "Wrote $count Hertz routes to hertz-data.json"

echo ""
echo "=== Movacar ==="
API="https://crowd-api-production-615013621295.europe-west1.run.app/v1"
HEADER="Accept: application/vnd.api+json"
: > "$SCRIPT_DIR/movacar-data.json.tmp"

for city in Stockholm Göteborg Malmö Berlin Hamburg München Frankfurt Köln Wien Zürich Amsterdam Kopenhagen Oslo Paris Prag Brüssel Hannover Stuttgart Düsseldorf Leipzig Dresden Nürnberg Freiburg; do
  encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$city'))")
  ref=$(curl -s -H "$HEADER" "$API/locations?name=$encoded&language=en" 2>/dev/null \
    | jq -r '.data[0].attributes.reference // empty')
  [ -z "$ref" ] && continue

  echo -n "  $city..."
  curl -s -H "$HEADER" "$API/offers?locale=en&destination=$ref" 2>/dev/null \
    | jq '
      ([(.included // [])[] | select(.type=="station")] | map({(.id): {name:.attributes.city, lat:.attributes.latitude, lon:.attributes.longitude}}) | add // {}) as $st |
      [(.data // [])[] |
        ($st[.relationships.origin.data.id] // null) as $o |
        ($st[.relationships.destination.data.id] // null) as $d |
        select($o != null and $d != null) |
        {
          source: "movacar",
          id: ("movacar-" + .attributes.offer_id),
          from: {name: $o.name, lat: $o.lat, lon: $o.lon},
          to: {name: $d.name, lat: $d.lat, lon: $d.lon},
          vehicle: ((.attributes.make // "") + " " + (.attributes.model // "") | ltrimstr(" ") | rtrimstr(" ")),
          availableFrom: .attributes.start_date,
          availableUntil: .attributes.end_date,
          distance: null,
          freeKm: (.attributes.free_km // null)
        }
      ]' >> "$SCRIPT_DIR/movacar-data.json.tmp"
  echo " ok"
done

# Merge and deduplicate
jq -s 'add | unique_by(.id)' "$SCRIPT_DIR/movacar-data.json.tmp" > "$SCRIPT_DIR/movacar-data.json"
rm -f "$SCRIPT_DIR/movacar-data.json.tmp"
movacar_count=$(jq length "$SCRIPT_DIR/movacar-data.json")
echo "Wrote $movacar_count Movacar routes to movacar-data.json"

echo ""
echo "Fertig! Öffne map.html im Browser."
