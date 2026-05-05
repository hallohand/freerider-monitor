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

GitHub Actions: Workflow läuft alle 5 min (`*/5 * * * *`).
State-Files liegen im privaten Schwester-Repo
[hallohand/freerider-monitor-state](https://github.com/hallohand/freerider-monitor-state)
(Files: `state/known-ids.txt`, `state/last-update-id.txt`,
`state/filters.json`). Workflow checkout't beide Repos und
committet Änderungen ins State-Repo zurück.
Logs: GitHub-Actions-Tab dieses Repos.

## Secrets (nur in GitHub Actions / `.env.local`)

- `TELEGRAM_KEY` — Bot-Token von `@BotFather`
- `CHAT_ID` — numerische Chat-ID, nach erstem Bot-Kontakt via
  `https://api.telegram.org/bot<TOKEN>/getUpdates` ablesen
  (Feld `result[].message.chat.id` — User-IDs sind 9–10-stellig
  positiv, nicht mit der Bot-User-ID verwechseln)
- `STATE_REPO_TOKEN` (nur GitHub Actions) — fine-grained PAT mit
  Scope „nur `freerider-monitor-state`, Contents: read+write".
  Nicht in `.env.local` nötig (lokal wird kein State ins Schwester-
  Repo geschrieben).

`.env.local` ist gitignored. Format:

```
TELEGRAM_KEY=<bot-token-from-botfather>
CHAT_ID=<numeric-user-id>
```

## Setup für neuen User

1. Beide Repos forken/klonen: `freerider-monitor` (public, Code) und
   `freerider-monitor-state` (privat, Daten).
2. Telegram-Bot via `@BotFather` anlegen, Token notieren, einmal an
   den Bot schreiben, Chat-ID via `getUpdates` auslesen.
3. Fine-grained PAT auf `freerider-monitor-state` (Contents: write).
4. In GitHub-Actions des Eltern-Repos drei Secrets setzen:
   `TELEGRAM_KEY`, `CHAT_ID`, `STATE_REPO_TOKEN`.
5. Workflow läuft beim nächsten Cron-Tick automatisch.

## Bot-Token rotieren

`@BotFather` → `/revoke` → neuen Token in GitHub-Secrets eintragen
(`Settings → Secrets and variables → Actions`). Kein Code-Change nötig.

## PAT rotieren

`Settings → Personal access tokens → freerider-monitor-state-write`
→ Regenerate → neuen Wert in GitHub-Secrets eintragen
(`STATE_REPO_TOKEN`).
