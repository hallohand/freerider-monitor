# Freerider Map — Design Spec

## Overview

Interaktive Karte als einzelne HTML-Datei die alle verfügbaren Mietwagenrückführungen von Hertz Freerider, DriveBack und Movacar auf einer Leaflet/OpenStreetMap-Karte anzeigt. Kein Server nötig — die Datei holt sich die Daten direkt von den APIs.

## Datenquellen

### Hertz Freerider
- **URL:** `https://www.hertzfreerider.se/api/transport-routes/?country=SWEDEN`
- **Format:** JSON Array von Routengruppen, jede mit `.routes[]`
- **Felder:** `pickupLocation.{city,name,geoLat,geoLon}`, `returnLocation.{city,name,geoLat,geoLon}`, `carModel`, `availableAt`, `latestReturn`, `distance`, `travelTime`
- **CORS:** Direkt aufrufbar

### DriveBack
- **URL:** `https://www.driveback.se/resor`
- **Format:** JSON Array
- **Felder:** `from_station.{area,location.{city,latitude,longitude}}`, `to_stations[0].{area,location.{city,latitude,longitude}}`, `vehicle.{car_model,car_size}`, `first_pickup`, `last_deliver`
- **CORS:** Direkt aufrufbar

### Movacar
- **Locations:** `https://crowd-api-production-615013621295.europe-west1.run.app/v1/locations?name={city}&language=en`
- **Offers:** `https://crowd-api-production-615013621295.europe-west1.run.app/v1/offers?locale=en&destination={ref}`
- **Format:** JSON:API (`data[]`, `included[]` mit Stationen)
- **Header:** `Accept: application/vnd.api+json`
- **Felder:** `attributes.{make,model,start_date,end_date,free_km}`, Stationen in `included[]` mit `attributes.{city,latitude,longitude}`
- **Strategie:** Destinations Stockholm, Göteborg, Malmö abfragen. Zusätzlich alle Offers die von schwedischen Standorten starten (origin-basierte Suche mit schwedischen Location-Refs).
- **CORS:** Muss getestet werden. Fallback: Daten per Shell-Script als JSON exportieren und einbetten.

## Layout

### Sidebar (links, 360px)

1. **Header:** Titel "Freerider Map" + Source-Badges mit Anzahl pro Quelle (farbig: Hertz=gelb, DriveBack=grün, Movacar=blau)
2. **Filter-Zeile:** Buttons "Alle | Hertz | DriveBack | Movacar" — togglen welche Quellen auf der Karte sichtbar sind
3. **Abfahrten/Ankünfte Toggle:** Zwei Buttons die umschalten ob Routen AB oder NACH dem ausgewählten Ort angezeigt werden. Abfahrten = rot, Ankünfte = grün.
4. **Ausgewählter Ort:** Name + Stats (X Abfahrten, Y Ankünfte)
5. **Route-Liste:** Scrollbare Liste von Route-Karten mit:
   - Start → Ziel
   - Source-Badge
   - Fahrzeug, Datum, Distanz

### Karte (rechts, restliche Breite)

- **Leaflet + OpenStreetMap Tiles** via CDN
- **Initiale Ansicht:** Schweden zentriert (~62°N, 16°E, Zoom 5), mit Europa sichtbar für Movacar-Routen
- **Marker:** Ein Punkt pro einzigartigem Ort (nach Koordinaten-Nähe gruppiert, ~10km Radius). Marker-Größe skaliert mit Anzahl der Routen.
- **Klick auf Marker:** Wählt den Ort aus → Sidebar aktualisiert sich, Luftlinien werden gezeichnet
- **Luftlinien:** Vom ausgewählten Ort zu allen Zielen (Abfahrtsmodus) bzw. von allen Startorten zum ausgewählten Ort (Ankunftsmodus). Farbe: rot für Abfahrten, grün für Ankünfte.
- **Hover auf Route-Karte in Sidebar:** Entsprechende Luftlinie auf der Karte wird hervorgehoben.
- **Legende:** Rechts unten, erklärt Farben.

## Datenfluss

1. **Beim Laden:** Parallel alle drei APIs fetchen
2. **Normalisierung:** Alle Routen in einheitliches Format bringen:
   ```
   {
     source: "hertz" | "driveback" | "movacar",
     id: string,
     from: { name: string, lat: number, lon: number },
     to: { name: string, lat: number, lon: number },
     vehicle: string,
     availableFrom: ISO date string,
     availableUntil: ISO date string,
     distance: number | null,
     freeKm: number | null
   }
   ```
3. **Ort-Gruppierung:** Alle einzigartigen Orte extrahieren (from + to). Orte innerhalb ~10km Radius zusammenfassen.
4. **Marker erstellen:** Ein Marker pro Ort. Marker-Größe = `Math.min(8 + routeCount, 20)`.
5. **Interaktion:** Klick auf Marker → `selectedLocation` setzen → Sidebar + Linien aktualisieren.

## Technologie

- **Eine HTML-Datei**, keine Build-Tools
- **Leaflet 1.9** via CDN (`unpkg.com`)
- **OpenStreetMap** Tiles (keine API-Keys)
- **Vanilla JS** — kein Framework
- **CSS** inline im `<style>` Tag
- **Dark Theme** passend zum Mockup

## Movacar CORS-Fallback

Falls die Movacar-API CORS blockiert:
- Ein kleines Shell-Script `update-movacar.sh` das die Daten fetcht und als `movacar-data.json` ablegt
- Die HTML liest diese JSON-Datei als Fallback wenn der direkte Fetch fehlschlägt
- Das Script kann optional vom `freerider-monitor.sh` mit aufgerufen werden

## Nicht im Scope

- Imoova-Integration (spätere Erweiterung)
- Server/Backend
- Buchungsfunktion
- Echtzeit-Updates (manuelle Seite neu laden)
- Mobile-optimiertes Layout (Desktop-first)
