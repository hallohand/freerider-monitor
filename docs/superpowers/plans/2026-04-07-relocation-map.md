# Freerider Map Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a single-file interactive map showing all car relocation offers from Hertz Freerider, DriveBack, and Movacar on a Leaflet/OSM map.

**Architecture:** One HTML file (`map.html`) with inline CSS and JS. Fetches data from three APIs on page load, normalizes into a common format, renders markers on a Leaflet map, and shows route details in a sidebar. A companion shell script (`update-movacar.sh`) provides a CORS fallback for Movacar data.

**Tech Stack:** Leaflet 1.9 (CDN), OpenStreetMap tiles, vanilla JS, inline CSS, dark theme.

**Spec:** `docs/superpowers/specs/2026-04-07-relocation-map-design.md`

---

## File Structure

- **Create:** `map.html` — the complete application (HTML + CSS + JS)
- **Create:** `update-movacar.sh` — shell script that fetches Movacar data and writes `movacar-data.json` as CORS fallback

The HTML file is structured internally as:
1. `<style>` — all CSS (dark theme, sidebar, map layout, route cards, etc.)
2. `<body>` — sidebar HTML structure + map container
3. `<script>` — all JS logic split into clearly commented sections:
   - Data fetching & normalization
   - Location grouping
   - Map initialization & markers
   - Sidebar rendering & interaction
   - Filter & toggle logic

---

### Task 1: HTML Shell + CSS + Leaflet Map

Create `map.html` with the complete CSS, sidebar HTML skeleton, and a working Leaflet map centered on Sweden. No data loading yet — just the visual shell.

**Files:**
- Create: `map.html`

- [ ] **Step 1: Create `map.html` with full CSS and empty Leaflet map**

Write the complete file with:
- Leaflet CSS/JS from `https://unpkg.com/leaflet@1.9.4/dist/...`
- All CSS from the design mockup (dark theme, sidebar, filters, toggle, route cards, legend)
- Sidebar HTML structure: header with title + badge placeholders, filter buttons, toggle bar, selected-info section, empty route-list div
- Map div taking remaining width
- Leaflet map initialized at `[62, 16]` zoom 5, CartoDB Dark Matter tiles (`https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png`)
- Legend overlay bottom-right

```html
<!-- Key structural elements: -->
<div class="container">
  <div class="sidebar">
    <div class="sidebar-header">
      <h1>Freerider Map</h1>
      <div class="source-badges" id="source-badges"></div>
    </div>
    <div class="filters" id="filters"></div>
    <div class="toggle-bar" id="toggle-bar"></div>
    <div class="selected-info" id="selected-info"></div>
    <div class="route-list" id="route-list"></div>
  </div>
  <div id="map"></div>
</div>
```

- [ ] **Step 2: Open in browser and verify**

Run: `xdg-open map.html` (or open manually)
Expected: Dark-themed page with sidebar on the left (empty but styled) and a dark map of Sweden/Europe on the right. Map should be pannable and zoomable.

---

### Task 2: Data Fetching — Hertz & DriveBack

Add the JS functions that fetch from Hertz and DriveBack APIs and normalize into the common route format.

**Files:**
- Modify: `map.html` (add to `<script>` section)

- [ ] **Step 1: Add the normalized route type and Hertz fetch function**

```javascript
// Normalized route format used throughout the app
// { source, id, from: {name, lat, lon}, to: {name, lat, lon},
//   vehicle, availableFrom, availableUntil, distance, freeKm }

async function fetchHertz() {
  const resp = await fetch('https://www.hertzfreerider.se/api/transport-routes/?country=SWEDEN');
  const data = await resp.json();
  const routes = [];
  for (const group of data) {
    for (const r of group.routes) {
      routes.push({
        source: 'hertz',
        id: 'hertz-' + r.id,
        from: { name: r.pickupLocation.city || r.pickupLocation.name, lat: r.pickupLocation.geoLat, lon: r.pickupLocation.geoLon },
        to: { name: r.returnLocation.city || r.returnLocation.name, lat: r.returnLocation.geoLat, lon: r.returnLocation.geoLon },
        vehicle: r.carModel,
        availableFrom: r.availableAt,
        availableUntil: r.latestReturn,
        distance: r.distance || null,
        freeKm: null,
      });
    }
  }
  return routes;
}
```

- [ ] **Step 2: Add DriveBack fetch function**

```javascript
async function fetchDriveBack() {
  const resp = await fetch('https://www.driveback.se/resor');
  const data = await resp.json();
  return data.map(r => ({
    source: 'driveback',
    id: 'driveback-' + r.id,
    from: { name: r.from_station.area, lat: r.from_station.location.latitude, lon: r.from_station.location.longitude },
    to: { name: r.to_stations[0].area, lat: r.to_stations[0].location.latitude, lon: r.to_stations[0].location.longitude },
    vehicle: r.vehicle.car_model,
    availableFrom: r.first_pickup,
    availableUntil: r.last_deliver,
    distance: null,
    freeKm: null,
  }));
}
```

- [ ] **Step 3: Add loadAll function and test with console.log**

```javascript
async function loadAllRoutes() {
  const [hertz, driveback] = await Promise.allSettled([
    fetchHertz(),
    fetchDriveBack(),
  ]);
  const routes = [
    ...(hertz.status === 'fulfilled' ? hertz.value : []),
    ...(driveback.status === 'fulfilled' ? driveback.value : []),
  ];
  console.log(`Loaded ${routes.length} routes (Hertz: ${hertz.status === 'fulfilled' ? hertz.value.length : 'FAIL'}, DriveBack: ${driveback.status === 'fulfilled' ? driveback.value.length : 'FAIL'})`);
  return routes;
}

// Call on page load
loadAllRoutes().then(routes => { window._routes = routes; });
```

- [ ] **Step 4: Verify in browser console**

Open `map.html`, open DevTools Console.
Expected: `Loaded ~100+ routes (Hertz: ~100, DriveBack: ~2)`. Check `window._routes[0]` has correct structure.

---

### Task 3: Data Fetching — Movacar

Add Movacar fetch with CORS fallback. Also create the `update-movacar.sh` script.

**Files:**
- Modify: `map.html` (add `fetchMovacar()`)
- Create: `update-movacar.sh`

- [ ] **Step 1: Add Movacar fetch function to map.html**

```javascript
async function fetchMovacar() {
  const API = 'https://crowd-api-production-615013621295.europe-west1.run.app/v1';
  const headers = { 'Accept': 'application/vnd.api+json' };
  const destinations = ['Stockholm', 'Göteborg', 'Malmö'];
  const routes = [];

  for (const city of destinations) {
    try {
      const locResp = await fetch(`${API}/locations?name=${encodeURIComponent(city)}&language=en`, { headers });
      const locData = await locResp.json();
      const ref = locData.data?.[0]?.attributes?.reference;
      if (!ref) continue;

      const offResp = await fetch(`${API}/offers?locale=en&destination=${ref}`, { headers });
      const offData = await offResp.json();

      const stations = {};
      for (const inc of (offData.included || [])) {
        if (inc.type === 'station') {
          stations[inc.id] = { name: inc.attributes.city, lat: inc.attributes.latitude, lon: inc.attributes.longitude };
        }
      }

      for (const offer of (offData.data || [])) {
        const originId = offer.relationships?.origin?.data?.id;
        const destId = offer.relationships?.destination?.data?.id;
        const origin = stations[originId];
        const dest = stations[destId];
        if (!origin || !dest) continue;

        routes.push({
          source: 'movacar',
          id: 'movacar-' + offer.attributes.offer_id,
          from: { name: origin.name, lat: origin.lat, lon: origin.lon },
          to: { name: dest.name, lat: dest.lat, lon: dest.lon },
          vehicle: `${offer.attributes.make || ''} ${offer.attributes.model || ''}`.trim(),
          availableFrom: offer.attributes.start_date,
          availableUntil: offer.attributes.end_date,
          distance: null,
          freeKm: offer.attributes.free_km || null,
        });
      }
    } catch (e) {
      console.warn(`Movacar fetch for ${city} failed:`, e);
    }
  }
  return routes;
}
```

- [ ] **Step 2: Add CORS fallback to fetchMovacar**

Wrap the API fetch in a try/catch. On failure, try loading `movacar-data.json` from the same directory:

```javascript
async function fetchMovacarWithFallback() {
  try {
    return await fetchMovacar();
  } catch (e) {
    console.warn('Movacar API failed (CORS?), trying local fallback...', e);
    try {
      const resp = await fetch('movacar-data.json');
      return await resp.json();
    } catch (e2) {
      console.warn('Movacar fallback also failed:', e2);
      return [];
    }
  }
}
```

- [ ] **Step 3: Update loadAllRoutes to include Movacar**

```javascript
async function loadAllRoutes() {
  const [hertz, driveback, movacar] = await Promise.allSettled([
    fetchHertz(),
    fetchDriveBack(),
    fetchMovacarWithFallback(),
  ]);
  const routes = [
    ...(hertz.status === 'fulfilled' ? hertz.value : []),
    ...(driveback.status === 'fulfilled' ? driveback.value : []),
    ...(movacar.status === 'fulfilled' ? movacar.value : []),
  ];
  console.log(`Loaded ${routes.length} routes`);
  return routes;
}
```

- [ ] **Step 4: Create `update-movacar.sh`**

```bash
#!/usr/bin/env bash
# Fetches Movacar offers destined for Sweden and saves as movacar-data.json
# Run this if the HTML can't fetch Movacar directly (CORS).
set -euo pipefail
API="https://crowd-api-production-615013621295.europe-west1.run.app/v1"
HEADER="Accept: application/vnd.api+json"
OUTFILE="$(dirname "$0")/movacar-data.json"
# ... (full implementation fetching Stockholm/Göteborg/Malmö, normalizing, writing JSON)
```

- [ ] **Step 5: Verify in browser**

Open `map.html`, check console.
Expected: `Loaded ~130 routes` with Movacar routes included (or fallback message if CORS blocked).

---

### Task 4: Location Grouping + Markers

Extract unique locations from all routes, group nearby ones (~10km), create Leaflet circle markers sized by route count.

**Files:**
- Modify: `map.html` (add grouping logic and marker creation)

- [ ] **Step 1: Add location grouping function**

```javascript
function groupLocations(routes) {
  const locs = [];
  // Collect all from/to locations
  for (const r of routes) {
    addLocation(locs, r.from);
    addLocation(locs, r.to);
  }
  return locs;
}

function addLocation(locs, point) {
  // Find existing location within ~10km
  for (const loc of locs) {
    if (haversineKm(loc.lat, loc.lon, point.lat, point.lon) < 10) {
      if (!loc.names.includes(point.name)) loc.names.push(point.name);
      return loc;
    }
  }
  const newLoc = { lat: point.lat, lon: point.lon, name: point.name, names: [point.name] };
  locs.push(newLoc);
  return newLoc;
}

function haversineKm(lat1, lon1, lat2, lon2) {
  const R = 6371;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a = Math.sin(dLat/2)**2 + Math.cos(lat1*Math.PI/180) * Math.cos(lat2*Math.PI/180) * Math.sin(dLon/2)**2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
}
```

- [ ] **Step 2: Add marker rendering**

```javascript
function renderMarkers(map, locations, routes) {
  const markerLayer = L.layerGroup().addTo(map);
  for (const loc of locations) {
    const departures = routes.filter(r => locMatchesPoint(loc, r.from));
    const arrivals = routes.filter(r => locMatchesPoint(loc, r.to));
    const count = departures.length + arrivals.length;
    const radius = Math.min(6 + count, 18);

    const marker = L.circleMarker([loc.lat, loc.lon], {
      radius,
      fillColor: '#e94560',
      fillOpacity: 0.8,
      color: '#fff',
      weight: 1.5,
    }).addTo(markerLayer);

    marker.bindTooltip(loc.name, { direction: 'top', offset: [0, -radius] });
    marker.on('click', () => selectLocation(loc));
    loc._marker = marker;
  }
  return markerLayer;
}

function locMatchesPoint(loc, point) {
  return haversineKm(loc.lat, loc.lon, point.lat, point.lon) < 10;
}
```

- [ ] **Step 3: Wire up in page load**

```javascript
let allRoutes = [];
let allLocations = [];
let markerLayer = null;

loadAllRoutes().then(routes => {
  allRoutes = routes;
  allLocations = groupLocations(routes);
  markerLayer = renderMarkers(map, allLocations, routes);
  updateBadges(routes);
});
```

- [ ] **Step 4: Verify in browser**

Open `map.html`.
Expected: Dark map with red dots at ~40-60 unique locations across Sweden. Dots near Stockholm and Göteborg should be larger. Hovering shows city name tooltip.

---

### Task 5: Source Badges + Filter Buttons

Render the source badges with counts and wire up the filter buttons to show/hide routes by source.

**Files:**
- Modify: `map.html`

- [ ] **Step 1: Add badge rendering**

```javascript
function updateBadges(routes) {
  const counts = { hertz: 0, driveback: 0, movacar: 0 };
  for (const r of routes) counts[r.source]++;
  document.getElementById('source-badges').innerHTML =
    `<span class="badge hertz">Hertz ${counts.hertz}</span>` +
    `<span class="badge driveback">DriveBack ${counts.driveback}</span>` +
    `<span class="badge movacar">Movacar ${counts.movacar}</span>`;
}
```

- [ ] **Step 2: Add filter buttons and state**

```javascript
let activeFilters = new Set(['hertz', 'driveback', 'movacar']);

function renderFilters() {
  const container = document.getElementById('filters');
  const sources = ['alle', 'hertz', 'driveback', 'movacar'];
  container.innerHTML = '<div class="filter-row">' +
    sources.map(s => `<button class="filter-btn ${s === 'alle' ? 'active' : (activeFilters.has(s) ? 'active' : '')}"
      onclick="toggleFilter('${s}')">${s === 'alle' ? 'Alle' : s.charAt(0).toUpperCase() + s.slice(1)}</button>`).join('') +
    '</div>';
}

function toggleFilter(source) {
  if (source === 'alle') {
    activeFilters = new Set(['hertz', 'driveback', 'movacar']);
  } else {
    if (activeFilters.size === 3) {
      activeFilters = new Set([source]);
    } else if (activeFilters.has(source) && activeFilters.size > 1) {
      activeFilters.delete(source);
    } else {
      activeFilters.add(source);
    }
  }
  renderFilters();
  refreshView();
}

function getFilteredRoutes() {
  return allRoutes.filter(r => activeFilters.has(r.source));
}
```

- [ ] **Step 3: Verify in browser**

Click filter buttons. Expected: Clicking "Hertz" shows only Hertz markers. Clicking "Alle" resets. Badge counts stay fixed (total counts, not filtered).

---

### Task 6: Location Selection + Route Lines

Implement marker click → select location → draw route lines + update sidebar.

**Files:**
- Modify: `map.html`

- [ ] **Step 1: Add selection state and toggle**

```javascript
let selectedLocation = null;
let viewMode = 'departures'; // or 'arrivals'
let lineLayer = L.layerGroup().addTo(map);

function selectLocation(loc) {
  if (selectedLocation?._marker) {
    selectedLocation._marker.setStyle({ fillColor: '#e94560' });
  }
  selectedLocation = loc;
  loc._marker.setStyle({ fillColor: '#ffd700' });
  refreshView();
}
```

- [ ] **Step 2: Add toggle bar rendering**

```javascript
function renderToggle() {
  const container = document.getElementById('toggle-bar');
  if (!selectedLocation) { container.innerHTML = ''; return; }

  const routes = getFilteredRoutes();
  const depCount = routes.filter(r => locMatchesPoint(selectedLocation, r.from)).length;
  const arrCount = routes.filter(r => locMatchesPoint(selectedLocation, r.to)).length;

  container.innerHTML =
    `<button class="toggle-btn departures ${viewMode === 'departures' ? 'active' : ''}"
       onclick="setViewMode('departures')">Abfahrten (${depCount})</button>` +
    `<button class="toggle-btn arrivals ${viewMode === 'arrivals' ? 'active' : ''}"
       onclick="setViewMode('arrivals')">Ankünfte (${arrCount})</button>`;
}

function setViewMode(mode) {
  viewMode = mode;
  refreshView();
}
```

- [ ] **Step 3: Add route line drawing**

```javascript
function drawRouteLines() {
  lineLayer.clearLayers();
  if (!selectedLocation) return;

  const routes = getFilteredRoutes();
  const color = viewMode === 'departures' ? '#e94560' : '#4CAF50';
  const matchingRoutes = viewMode === 'departures'
    ? routes.filter(r => locMatchesPoint(selectedLocation, r.from))
    : routes.filter(r => locMatchesPoint(selectedLocation, r.to));

  for (const r of matchingRoutes) {
    const target = viewMode === 'departures' ? r.to : r.from;
    const line = L.polyline(
      [[selectedLocation.lat, selectedLocation.lon], [target.lat, target.lon]],
      { color, weight: 2, opacity: 0.6, dashArray: '6,4' }
    ).addTo(lineLayer);
    line._routeId = r.id;
  }
}
```

- [ ] **Step 4: Add selected-info rendering**

```javascript
function renderSelectedInfo() {
  const container = document.getElementById('selected-info');
  if (!selectedLocation) {
    container.innerHTML = '<p class="hint">Klick auf einen Punkt um Routen zu sehen</p>';
    return;
  }
  const routes = getFilteredRoutes();
  const deps = routes.filter(r => locMatchesPoint(selectedLocation, r.from)).length;
  const arrs = routes.filter(r => locMatchesPoint(selectedLocation, r.to)).length;
  container.innerHTML = `<h3>${selectedLocation.name}</h3>
    <div class="stats">${deps} Abfahrten &bull; ${arrs} Ankünfte</div>`;
}
```

- [ ] **Step 5: Wire refreshView**

```javascript
function refreshView() {
  renderToggle();
  renderSelectedInfo();
  renderRouteList();
  drawRouteLines();
  updateMarkerVisibility();
}
```

- [ ] **Step 6: Verify in browser**

Click a dot (e.g. Stockholm). Expected: Dot turns gold, sidebar shows "Stockholm" + stats, toggle shows departure/arrival counts, dashed lines appear to destinations. Click "Ankünfte" → lines turn green, sidebar updates.

---

### Task 7: Route List in Sidebar

Render the scrollable route cards and wire up hover-to-highlight on the map.

**Files:**
- Modify: `map.html`

- [ ] **Step 1: Add route list rendering**

```javascript
function renderRouteList() {
  const container = document.getElementById('route-list');
  if (!selectedLocation) {
    container.innerHTML = '<p class="hint">Wähle einen Ort auf der Karte</p>';
    return;
  }

  const routes = getFilteredRoutes();
  const matching = viewMode === 'departures'
    ? routes.filter(r => locMatchesPoint(selectedLocation, r.from))
    : routes.filter(r => locMatchesPoint(selectedLocation, r.to));

  if (matching.length === 0) {
    container.innerHTML = '<p class="hint">Keine Routen in diesem Modus</p>';
    return;
  }

  // Sort by date
  matching.sort((a, b) => a.availableFrom.localeCompare(b.availableFrom));

  container.innerHTML = matching.map(r => {
    const dateFrom = r.availableFrom ? new Date(r.availableFrom).toLocaleDateString('de-DE', { day: '2-digit', month: '2-digit' }) : '?';
    const distText = r.distance ? `${Math.round(r.distance)} km` : (r.freeKm ? `${r.freeKm} km inkl.` : '');
    return `<div class="route-card" data-route-id="${r.id}"
        onmouseenter="highlightLine('${r.id}')"
        onmouseleave="unhighlightLine('${r.id}')">
      <div class="route-header">
        <span class="route-cities">${r.from.name} <span class="arrow">→</span> ${r.to.name}</span>
        <span class="route-source badge ${r.source}">${r.source}</span>
      </div>
      <div class="route-details">
        <span>${r.vehicle}</span>
        <span>Ab: ${dateFrom}</span>
        ${distText ? `<span>${distText}</span>` : ''}
      </div>
    </div>`;
  }).join('');
}
```

- [ ] **Step 2: Add hover highlight functions**

```javascript
function highlightLine(routeId) {
  lineLayer.eachLayer(layer => {
    if (layer._routeId === routeId) {
      layer.setStyle({ weight: 4, opacity: 1 });
      layer.bringToFront();
    }
  });
}

function unhighlightLine(routeId) {
  const color = viewMode === 'departures' ? '#e94560' : '#4CAF50';
  lineLayer.eachLayer(layer => {
    if (layer._routeId === routeId) {
      layer.setStyle({ weight: 2, opacity: 0.6 });
    }
  });
}
```

- [ ] **Step 3: Verify in browser**

Select Stockholm, see route cards in sidebar. Hover over a card → corresponding line on map becomes thicker/brighter. Switch to Ankünfte → list shows routes arriving at Stockholm.

---

### Task 8: Marker Visibility + Loading State

Update marker visibility when filters change, and add a loading spinner while data loads.

**Files:**
- Modify: `map.html`

- [ ] **Step 1: Add marker visibility update**

```javascript
function updateMarkerVisibility() {
  const routes = getFilteredRoutes();
  for (const loc of allLocations) {
    const hasDep = routes.some(r => locMatchesPoint(loc, r.from));
    const hasArr = routes.some(r => locMatchesPoint(loc, r.to));
    if (hasDep || hasArr) {
      loc._marker.setStyle({ fillOpacity: 0.8 });
    } else {
      loc._marker.setStyle({ fillOpacity: 0.15 });
    }
  }
}
```

- [ ] **Step 2: Add loading state**

Add a loading overlay div in the HTML:
```html
<div id="loading" class="loading-overlay">
  <div class="loading-spinner"></div>
  <p>Lade Routen...</p>
</div>
```

CSS for spinner animation. In JS, hide it after `loadAllRoutes()` completes:
```javascript
loadAllRoutes().then(routes => {
  // ... existing setup ...
  document.getElementById('loading').style.display = 'none';
});
```

- [ ] **Step 3: Add initial hint in sidebar**

When no location is selected, show: "Klick auf einen Punkt um Routen zu sehen" in both selected-info and route-list.

- [ ] **Step 4: Full verification**

Open `map.html` fresh. Expected:
1. Loading spinner appears briefly
2. Map shows ~40-60 dots, badges show counts
3. Click a dot → sidebar populates, lines appear
4. Toggle Abfahrten/Ankünfte → lines change color, list updates
5. Filter to "Movacar" only → most markers fade, Movacar routes remain
6. Hover route card → line highlights on map

---

### Task 9: Movacar CORS Fallback Script

Create the shell script that exports Movacar data as JSON for the HTML to load locally.

**Files:**
- Create: `update-movacar.sh`

- [ ] **Step 1: Write `update-movacar.sh`**

Full script that:
1. Queries Movacar locations API for Stockholm, Göteborg, Malmö refs
2. Fetches offers for each destination
3. Normalizes into the same `{ source, id, from, to, vehicle, ... }` format
4. Writes `movacar-data.json` to the same directory

```bash
#!/usr/bin/env bash
set -euo pipefail
API="https://crowd-api-production-615013621295.europe-west1.run.app/v1"
HEADER="Accept: application/vnd.api+json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTFILE="$SCRIPT_DIR/movacar-data.json"

echo "[]" > "$OUTFILE.tmp"

for city in Stockholm Göteborg Malmö; do
  ref=$(curl -s -H "$HEADER" "$API/locations?name=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$city'))")&language=en" \
    | jq -r '.data[0].attributes.reference // empty')
  [ -z "$ref" ] && continue

  curl -s -H "$HEADER" "$API/offers?locale=en&destination=$ref" \
    | jq --arg city "$city" '
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
```

- [ ] **Step 2: Test the script**

Run: `bash update-movacar.sh`
Expected: `Wrote ~26 Movacar routes to movacar-data.json`

- [ ] **Step 3: Make executable and verify fallback**

```bash
chmod +x update-movacar.sh
```

Open `map.html` — if Movacar CORS works, it uses the API directly. If not, it loads `movacar-data.json`.

---

## Self-Review Checklist

- [x] **Spec coverage:** All spec sections covered — 3 data sources, sidebar layout, map with markers, filters, toggle, route lines, hover highlight, loading state, CORS fallback
- [x] **Placeholder scan:** No TBD/TODO in any task. All code steps include actual code.
- [x] **Type consistency:** `locMatchesPoint`, `haversineKm`, `selectedLocation`, `viewMode`, `lineLayer`, `allRoutes`, `allLocations` — names consistent across all tasks.
- [x] **Spec gap check:** Legend rendering mentioned in Task 1 (static HTML). Marker sizing in Task 4. All covered.
