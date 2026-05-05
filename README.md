# hertz — Mietwagen-Rückführungs-Monitor

Monitort drei Quellen für kostenlose/günstige Mietwagen-Rückführungen
(Freerider) und benachrichtigt bei neuen Routen.

## Quellen

| Quelle              | Endpoint                                                                                | Format     | Status        |
|---------------------|-----------------------------------------------------------------------------------------|------------|---------------|
| Hertz Freerider     | `https://www.hertzfreerider.se/api/transport-routes/?country=SWEDEN`                     | JSON-Array | aktiv         |
| DriveBack           | `https://www.driveback.se/resor`                                                         | JSON-Array | aktiv         |
| Movacar             | `https://crowd-api-production-615013621295.europe-west1.run.app/v1/{locations,offers}`   | JSON:API   | **deaktiviert (Stand 2026-05-05)** |

**Movacar deaktiviert:** Eigentümer-Entscheidung 2026-05-05. Skript
`movacar-scrape.py` und Daten-Snapshots bleiben im Repo (sunk cost,
reaktivierbar), werden aber nicht mehr im 24/7-Workflow ausgeführt.

## Skripte

- `freerider-monitor.sh [INTERVAL]` — lokaler Endlos-Loop mit Desktop-
  Notifications (notify-send + paplay), prüft Hertz Freerider +
  DriveBack. Default-Intervall 300 s.
- `freerider-monitor-telegram.sh` — One-shot-Variante für GitHub-Actions-
  Cron, sendet Treffer per Telegram (siehe `.github/workflows/`).
- `update-data.sh` — manuelle Snapshot-Updates der aktiven Quellen.
- `movacar-scrape.py` / `update-movacar.sh` — *deaktiviert.* Bleibt im
  Repo, läuft aber nicht im 24/7-Workflow.
- `start-map.sh` + `map.html` — visualisiert Snapshots auf Karte.

## Lauf-Anleitung

Lokal:
```bash
./freerider-monitor.sh           # Loop mit 5-Min-Intervall
./freerider-monitor.sh 60        # Loop mit 1-Min-Intervall
```

GitHub Actions: Workflow läuft alle 10 min (`*/10 * * * *`),
State-File liegt in `state/known-ids.txt` und wird vom Workflow zurück-
committed. Logs: GitHub-Actions-Tab.

## Secrets (nur in GitHub Actions / `.env.local`)

- `TELEGRAM_KEY` — Bot-Token von `@BotFather`
- `CHAT_ID` — numerische Chat-ID, nach erstem Bot-Kontakt via
  `https://api.telegram.org/bot<TOKEN>/getUpdates` ablesen
  (Feld `result[].message.chat.id` — User-IDs sind 9–10-stellig
  positiv, nicht mit der Bot-User-ID verwechseln)

`.env.local` ist gitignored. Format:

```
TELEGRAM_KEY=<bot-token-from-botfather>
CHAT_ID=<numeric-user-id>
```

## Bot-Token rotieren

`@BotFather` → `/revoke` → neuen Token in GitHub-Secrets eintragen
(`Settings → Secrets and variables → Actions`). Kein Code-Change nötig.
