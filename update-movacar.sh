#!/usr/bin/env bash
# Fetches Movacar offers destined for Sweden and saves as movacar-data.json
# Run this if the HTML can't fetch Movacar directly (CORS).
set -euo pipefail

API="https://crowd-api-production-615013621295.europe-west1.run.app/v1"
HEADER="Accept: application/vnd.api+json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTFILE="$SCRIPT_DIR/movacar-data.json"

echo "[]" > "$OUTFILE.tmp"

for city in Stockholm Göteborg Malmö; do
  encoded=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$city'))")
  ref=$(curl -s -H "$HEADER" "$API/locations?name=$encoded&language=en" \
    | jq -r '.data[0].attributes.reference // empty')
  [ -z "$ref" ] && { echo "Skipping $city (no ref found)"; continue; }

  echo "Fetching offers for $city (ref: $ref)..."
  curl -s -H "$HEADER" "$API/offers?locale=en&destination=$ref" \
    | jq '
      ([.included[] | select(.type=="station")] | map({(.id): {name:.attributes.city, lat:.attributes.latitude, lon:.attributes.longitude}}) | add // {}) as $st |
      [.data[] |
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
      ]' >> "$OUTFILE.tmp"
done

# Merge all arrays into one
jq -s 'add | unique_by(.id)' "$OUTFILE.tmp" > "$OUTFILE"
rm -f "$OUTFILE.tmp"
echo "Wrote $(jq length "$OUTFILE") Movacar routes to $OUTFILE"
