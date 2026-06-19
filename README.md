# BlueFors CS2 Monitor

Real-time monitoring and Slack alerting for a BlueFors dilution refrigerator (CS2 control system).

## Architecture

```
Windows PC (BlueFors CS2)                  Raspberry Pi
┌─────────────────────────────┐            ┌──────────────────────────────┐
│  CS2 Control Software       │            │  PostgreSQL 17 (port 5432)   │
│  PostgreSQL 14.9 (port 5434)│            │  /mnt/harddrive/cs2_database │
│                             │            │                              │
│  sync_push.ps1 ─────────────┼──SSH──────►│  cs2 database (mirror)       │
│  (Windows Task Scheduler,   │            │                              │
│   every 1 minute)           │            │  monitor.py ─────────────────┼──► Slack
└─────────────────────────────┘            │  (cron, every 1 minute)      │
                                           └──────────────────────────────┘
```

- **Windows PC** runs BlueFors CS2 and holds the live PostgreSQL database (port 5434).  
- **Raspberry Pi** holds a mirror copy stored on an external hard drive. A PowerShell script running on Windows pushes new rows every minute.  
- **monitor.py** on the Raspberry Pi checks the mirror for threshold violations and forwards CS2 system alerts to Slack.

### Why push from Windows instead of pull from Pi

The Raspberry Pi cannot initiate a connection to the Windows machine (no inbound access), but the Windows machine can reach the Pi. The PowerShell script runs as a Windows Scheduled Task and pushes data outward.

---

## Network

| Machine | IP | Role |
|---|---|---|
| Windows PC (BlueFors CS2) | 172.31.255.10 | Data source |
| Raspberry Pi | 172.31.255.62 | Monitor / alert hub |

---

## Prerequisites

### Raspberry Pi

- Raspberry Pi OS (64-bit)  
- PostgreSQL 17  
- Python 3.x with packages: `psycopg2-binary`, `requests`  
- External hard drive mounted at `/mnt/harddrive`  

### Windows PC

- PostgreSQL client tools (`psql.exe`) — installed with any PostgreSQL version  
- PowerShell 5.1 or later  
- Network access to the Raspberry Pi on port 5432  

---

## Setup: Raspberry Pi

### 1. Create the database

```bash
sudo -u postgres psql -c "CREATE DATABASE cs2;"
```

### 2. Configure PostgreSQL for remote connections

Edit `/etc/postgresql/17/main/postgresql.conf`:

```
listen_addresses = '*'
```

Edit `/etc/postgresql/17/main/pg_hba.conf` — add this line:

```
host    cs2    postgres    172.31.255.0/16    md5
```

Set the postgres user password:

```bash
sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'cs2monitor';"
```

Restart PostgreSQL:

```bash
sudo systemctl restart postgresql
```

### 3. Open the firewall

```bash
sudo ufw allow from 172.31.255.0/16 to any port 5432
```

### 4. Restore the database backup

The CS2 database was exported from Windows using `pg_dump` and restored on the Pi:

```bash
export PGPASSWORD=cs2monitor
pg_restore -h localhost -U postgres -d cs2 -v cs2_backup.dump
```

Data is stored under `/mnt/harddrive/cs2_database/main` (PostgreSQL data directory configured via `data_directory` in `postgresql.conf`).

### 5. Install Python dependencies

```bash
pip3 install psycopg2-binary requests
```

---

## Setup: Windows PC

### 1. Copy the sync script

Copy `sync_push.ps1` to `C:\bluefors_monitor\` on the Windows machine.

```powershell
# From Raspberry Pi
scp /home/cdms/bluefors_monitor/sync_push.ps1 cdms@172.31.255.62:/tmp/
# Then from Windows, pull from Pi (or copy via USB / shared drive)
```

Or use SCP from another machine to push it directly to `C:\bluefors_monitor\`.

### 2. Verify psql.exe is available

The script looks for `psql.exe` in the default PostgreSQL installation paths:

```
C:\Program Files\PostgreSQL\17\bin\psql.exe
C:\Program Files\PostgreSQL\16\bin\psql.exe
...
```

If none are found, the script exits with an error.

### 3. Run once to verify

Open PowerShell and run:

```powershell
powershell -ExecutionPolicy Bypass -File C:\bluefors_monitor\sync_push.ps1
```

Expected output on first run:

```
2026-06-18 19:33:49 === Sync started ===
2026-06-18 19:33:49 Connected to Raspberry Pi OK
2026-06-18 19:33:49 Local CS2 database OK - 4484137 rows in double_value_change_events
2026-06-18 19:33:49 First run - initialising sync position from Raspberry Pi...
2026-06-18 19:33:49   double_value_change_events : will sync from id > 3649339
...
2026-06-18 19:33:53 === Sync done: +27178 rows total ===
```

On first run the script queries the Raspberry Pi for the current maximum row ID in each table and stores that as the starting point (`win_sync_state.json`). Only rows with IDs greater than that value are synced going forward, so the backup data already on the Pi is never re-sent.

### 4. Install as a Scheduled Task

Run PowerShell **as Administrator**:

```powershell
powershell -ExecutionPolicy Bypass -File C:\bluefors_monitor\sync_push.ps1 -Install
```

This registers a Windows Scheduled Task named `BlueForsSync` that runs every minute indefinitely.

Verify it is active:

```powershell
Get-ScheduledTask -TaskName "BlueForsSync" | Select-Object TaskName, State
```

---

## How sync_push.ps1 works

```
┌─────────────────────────────────────────────┐
│  sync_push.ps1 (runs every minute)          │
│                                             │
│  1. Connect to CS2 PostgreSQL (port 5434)   │
│  2. Connect to Pi PostgreSQL  (port 5432)   │
│  3. Load win_sync_state.json                │
│     └─ first run? init from Pi max IDs      │
│  4. For each table:                         │
│     a. \copy rows WHERE id > last_id        │
│        LIMIT 5000  →  stdout (CSV)          │
│     b. Pipe CSV into Pi via \copy FROM stdin│
│     c. Update last_id in state              │
│  5. device_states: TRUNCATE + full refresh  │
│  6. Save win_sync_state.json                │
└─────────────────────────────────────────────┘
```

Tables synced:

| Table | Key column | Description |
|---|---|---|
| `double_value_change_events` | `id` | Temperature, pressure, flow readings |
| `int_value_change_events` | `id` | Integer sensor values |
| `boolean_value_change_events` | `id` | Boolean device states |
| `string_value_change_events` | `id` | String sensor values |
| `json_value_change_events` | `id` | JSON payloads |
| `device_events` | `id` | Device lifecycle events |
| `alerts` | `id` | CS2 system alerts |
| `automation_events` | `id` | Automation log |
| `user_log_entries` | `id` | User activity |
| `device_states` | — | Current state of all 50 devices (full refresh) |

State is persisted in `win_sync_state.json` so each run only fetches new rows.

---

## Database schema (key tables)

### double_value_change_events

Stores every numerical sensor reading.

```sql
id       BIGINT PRIMARY KEY
time     TIMESTAMPTZ
mapping  VARCHAR   -- sensor name, e.g. "MXC_TEMPERATURE"
value    DOUBLE PRECISION
value_id VARCHAR
```

### alerts

CS2 system alerts (errors and warnings generated by the control software).

```sql
id                  BIGINT PRIMARY KEY
code                INTEGER
datetime            TIMESTAMPTZ
description         VARCHAR
title               VARCHAR
severity            INTEGER   -- 1 = warning, 2 = error
originator          VARCHAR
resolution_datetime TIMESTAMPTZ
resolved_by         VARCHAR
```

### device_states

Current state snapshot of all connected devices.

```sql
datetime   TIMESTAMPTZ
device_id  VARCHAR PRIMARY KEY
values     JSONB
```

---

## Sensor mappings (double_value_change_events)

All sensors found in the CS2 database:

| Mapping | Unit | Description |
|---|---|---|
| `MXC_TEMPERATURE` | K | Mixing chamber temperature |
| `MXC_TEMPERATURE_FAR` | K | Mixing chamber far-end temperature |
| `STILL_TEMPERATURE` | K | Still temperature |
| `4K_TEMPERATURE` | K | 4K plate temperature |
| `50K_TEMPERATURE` | K | 50K plate temperature |
| `B1A_TEMPERATURE` | K | B1A stage temperature |
| `B2_TEMPERATURE` | K | B2 stage temperature |
| `P1_PRESSURE` | mbar | Return line pressure |
| `P2_PRESSURE` | mbar | Still pressure |
| `P3_PRESSURE` | mbar | Condenser pressure |
| `P4_PRESSURE` | mbar | Pumping line pressure |
| `P5_PRESSURE` | mbar | MXC pressure |
| `P6_PRESSURE` | mbar | Backing pressure |
| `P7_PRESSURE` | mbar | Foreline pressure |
| `FLOW_VALUE` | mmol/s | Helium flow rate |
| `HELIUM_TANK_VALUE` | — | Helium tank level |
| `MXC_HEATING_POWER` | W | MXC heater power |
| `STILL_HEATING_POWER` | W | Still heater power |
| `MXC_TARGET_TEMPERATURE` | K | MXC setpoint |
| `STILL_TARGET_TEMPERATURE` | K | Still setpoint |
| `COM_PUMP_POWER` | W | Compressor pump power |
| `R1A_PUMP_POWER` | W | R1A pump power |
| `R2_PUMP_POWER` | W | R2 pump power |

---

## Setup: monitor.py

### config.py

Edit `/home/cdms/bluefors_monitor/config.py` to set thresholds and Slack credentials:

```python
SLACK_BOT_TOKEN = "xoxb-..."      # Slack bot token
SLACK_CHANNEL   = "C0B42G4AU0N"   # Slack channel ID

THRESHOLDS = {
    # sensor mapping       : (max_value, min_value, description)
    "MXC_TEMPERATURE":     (0.030,  None,  "MXC temperature > 30 mK"),
    "STILL_TEMPERATURE":   (2.0,    None,  "Still temperature > 2 K"),
    "4K_TEMPERATURE":      (6.0,    None,  "4K plate > 6 K"),
    "50K_TEMPERATURE":     (65.0,   None,  "50K plate > 65 K"),
    "P2_PRESSURE":         (0.5,    None,  "P2 still pressure > 0.5 mbar"),
    "P5_PRESSURE":         (1e-3,   None,  "P5 MXC pressure > 1e-3 mbar"),
    "FLOW_VALUE":          (None,   0.01,  "He flow < 0.01 mmol/s"),
    # add / adjust to match your system's normal operating ranges
}

ALERT_COOLDOWN_MINUTES = 30   # minimum gap between repeated alerts for the same sensor
CS2_ALERT_MIN_SEVERITY = 2    # 1 = warning, 2 = error only
```

### First run (skip historical alerts)

Run this once before starting the cron job to record the current alert state and avoid flooding Slack with old alerts:

```bash
cd /home/cdms/bluefors_monitor
python3 monitor.py --init
```

### Install cron job

```bash
bash setup_cron.sh
```

This adds a crontab entry that runs `monitor.py` every minute:

```
* * * * * python3 /home/cdms/bluefors_monitor/monitor.py >> /home/cdms/bluefors_monitor/monitor.log 2>&1
```

Verify:

```bash
crontab -l
```

---

## How monitor.py works

Every minute, three checks run:

### 1. Data freshness

Checks `MAX(time)` in `double_value_change_events`. If the latest reading is more than 5 minutes old, a Slack alert is sent indicating the sync pipeline may have stopped.

### 2. Sensor threshold violations

For each sensor defined in `THRESHOLDS`, the latest value is fetched and compared against the configured limits. If a limit is exceeded and the cooldown period has passed, a Slack message is sent:

```
⚠️ MXC temperature > 30 mK
Current value: 0.0312 K | Sensor time: 2026-06-18 14:23:01
```

### 3. CS2 system alert forwarding

New rows in the `alerts` table with `severity >= CS2_ALERT_MIN_SEVERITY` are forwarded to Slack. Alerts are grouped by error code so repeated occurrences are batched into a single message.

State (last seen alert ID, last alert times per sensor) is stored in `monitor_state.json`.

---

## Troubleshooting

### Sync: "Cannot connect to Raspberry Pi"

- Check the Pi is reachable: `ping 172.31.255.62`  
- Check port 5432 is open: `Test-NetConnection -ComputerName 172.31.255.62 -Port 5432`  
- Check UFW on Pi: `sudo ufw status`  

### Sync: "duplicate key value violates unique constraint"

This happens if `win_sync_state.json` is lost or empty and the script tries to re-copy rows already in the Pi database. Fix:

```powershell
Remove-Item C:\bluefors_monitor\win_sync_state.json -ErrorAction SilentlyContinue
# Re-run once — the script will re-initialise from the Pi's current max IDs
powershell -ExecutionPolicy Bypass -File C:\bluefors_monitor\sync_push.ps1
```

### Sync: "syntax error at or near ON"

PostgreSQL's `COPY` command does not support `ON CONFLICT`. The current script avoids this by initialising from the Pi's max IDs so no duplicate rows are sent. If you see this error, delete `win_sync_state.json` and re-initialise as above.

### Scheduled task runs once then stops

Verify the task was registered with administrator privileges:

```powershell
Get-ScheduledTask -TaskName "BlueForsSync"
# State should be "Ready"
```

Re-install if needed (run PowerShell as Administrator):

```powershell
powershell -ExecutionPolicy Bypass -File C:\bluefors_monitor\sync_push.ps1 -Install
```

### Monitor: Slack messages not sending

Check `monitor.log`:

```bash
tail -50 /home/cdms/bluefors_monitor/monitor.log
```

Test the token manually:

```bash
curl -s https://slack.com/api/auth.test \
  -H "Authorization: Bearer xoxb-YOUR-TOKEN"
```

The bot must be invited to the target channel: in Slack, type `/invite @BlueFors-Alert` in the channel.

### Check how far behind the sync is

```bash
PGPASSWORD=cs2monitor psql -h localhost -U postgres -d cs2 \
  -c "SELECT MAX(time) FROM double_value_change_events;"
```

Compare with the current time. Each sync cycle pushes up to 5000 rows per table, so large gaps (e.g. after the initial setup) take time to catch up.

---

## File reference

| File | Location | Description |
|---|---|---|
| `sync_push.ps1` | Windows `C:\bluefors_monitor\` | Pushes CS2 data to Pi every minute |
| `win_sync_state.json` | Windows `C:\bluefors_monitor\` | Tracks last synced row ID per table |
| `win_sync.log` | Windows `C:\bluefors_monitor\` | Sync log |
| `config.py` | Pi `~/bluefors_monitor/` | Thresholds, credentials, settings |
| `monitor.py` | Pi `~/bluefors_monitor/` | Alert monitor (runs via cron) |
| `setup_cron.sh` | Pi `~/bluefors_monitor/` | Installs the cron job |
| `monitor_state.json` | Pi `~/bluefors_monitor/` | Tracks last seen alert IDs |
| `monitor.log` | Pi `~/bluefors_monitor/` | Monitor log |

---

## GitHub

Source code: [https://github.com/ZhihengLi0/column](https://github.com/ZhihengLi0/column)

> **Note:** `config.py` is excluded from the repository (contains the Slack bot token). Copy it manually to the Pi and fill in your credentials.
