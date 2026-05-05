# hertz — Mietwagen-Rückführungs-Monitor

Monitort drei Quellen für kostenlose/günstige Mietwagen-Rückführungen
(Freerider) und benachrichtigt bei neuen Routen.

## Quellen

| Quelle              | Endpoint                                                                                | Format     |
|---------------------|-----------------------------------------------------------------------------------------|------------|
| Hertz Freerider     | `https://www.hertzfreerider.se/api/transport-routes/?country=SWEDEN`                     | JSON-Array |
| DriveBack           | `https://www.driveback.se/resor`                                                         | JSON-Array |
| Movacar             | `https://crowd-api-production-615013621295.europe-west1.run.app/v1/{locations,offers}`   | JSON:API   |

## Skripte

- `freerider-monitor.sh [INTERVAL]` — lokaler Endlos-Loop mit Desktop-
  Notifications (notify-send + paplay). Default-Intervall 300 s.
- `freerider-monitor-telegram.sh` — One-shot-Variante für GitHub-Actions-
  Cron, sendet Treffer per Telegram (siehe `.github/workflows/`).
- `update-data.sh` / `update-movacar.sh` — manuelle Snapshot-Updates.
- `movacar-scrape.py` — Python-Scraper für tiefere Movacar-Daten.
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

- `TELEGRAM_BOT_TOKEN` — von `@BotFather`
- `TELEGRAM_CHAT_ID` — numerische Chat-ID, nach erstem Bot-Kontakt via
  `https://api.telegram.org/bot<TOKEN>/getUpdates` ablesen

## Bot-Token rotieren

`@BotFather` → `/revoke` → neuen Token in GitHub-Secrets eintragen
(`Settings → Secrets and variables → Actions`). Kein Code-Change nötig.
