# freerider-monitor

Telegram-Bot für Hertz Freerider + DriveBack Routen-Tracking.
Push für neue Mietwagen-Rückführungen, persistente Filter,
On-Demand-Suche.

## Quellen

| Quelle              | Endpoint                                                                                | Status        |
|---------------------|------------------------------------------------------------------------------------------|---------------|
| Hertz Freerider     | `https://www.hertzfreerider.se/api/transport-routes/?country=SWEDEN`                     | aktiv         |
| DriveBack           | `https://www.driveback.se/resor`                                                         | aktiv         |
| Movacar             | `crowd-api-production-…run.app/v1/{locations,offers}`                                    | deaktiviert   |

`movacar-scrape.py` und Snapshots bleiben im Repo, laufen aber
nicht im Service.

## Bot-Commands

```
/start         Begrüßung
/help          Command-Übersicht
/filters       aktive Filter zeigen
/addfilter     Filter anlegen oder überschreiben
/removefilter  Filter mit Namen löschen
/clear         alle Filter löschen
/search        Live-Suche, gleiche Syntax wie /addfilter ohne name
```

Filter-Syntax (alle Felder außer `name` optional, Reihenfolge egal):

```
/addfilter <name> from=A,B to=C,D pickup_after=YYYY-MM-DD pickup_before=YYYY-MM-DD deliver_before=YYYY-MM-DD
```

Stadtnamen sind case-insensitive und Diakritika-tolerant
(`Skellefteå` ≡ `skelleftea`). Match: AND innerhalb Filter, OR über
Filter. Ohne Filter werden alle neuen Routen gepusht (Backstop).

## Setup (auf einem VPS)

```bash
adduser --system --no-create-home --group --shell /usr/sbin/nologin freerider
mkdir -p /opt/freerider /var/lib/freerider/state /etc/freerider
chown -R freerider:freerider /var/lib/freerider
git clone https://github.com/hallohand/freerider-monitor.git /opt/freerider/freerider-monitor

cat >/etc/freerider/env <<EOF
TELEGRAM_KEY=<bot-token>
CHAT_ID=<numeric-user-id>
EOF
chmod 640 /etc/freerider/env && chown root:freerider /etc/freerider/env
```

Drei systemd-Units:
- `freerider-bot.service` — Long-Polling-Daemon, `--bot-loop`,
  Type=simple, permanent.
- `freerider.timer` → `freerider.service` mit `--scrape-only`,
  oneshot, alle 5 min.
- `freerider-backup.timer` → tägliches lokales Backup von
  `/var/lib/freerider/state/`, 30-Tage-Retention.

Logs: `journalctl -u freerider-bot -f`.

Chat-ID herausfinden: Bot in Telegram suchen → `/start` →
`https://api.telegram.org/bot<TOKEN>/getUpdates` → `result[0].message.chat.id`.

## Bot-Token rotieren

```
@BotFather → /revoke → @<deinbot> → neuer Token
sudo sed -i 's/^TELEGRAM_KEY=.*/TELEGRAM_KEY=<neu>/' /etc/freerider/env
sudo systemctl restart freerider-bot.service
```

## Lokal testen

```bash
STATE_FILE=./state/known-ids.txt \
LAST_UPDATE_FILE=./state/last-update-id.txt \
FILTERS_FILE=./state/filters.json \
TELEGRAM_KEY=... CHAT_ID=... \
./freerider-monitor-telegram.sh
```
