---
name: zerobyte
description: Manage, inspect, trigger, and troubleshoot Zerobyte backups, volumes, Restic repositories, snapshots, restores, tasks, and notifications via Zerobyte's HTTP API (`scripts/zerobyte.py`). Trigger whenever the user mentions Zerobyte, `zerobyte.mohandl3g.ly`, `Vault`, Restic snapshots, backup schedules, retention/forget pruning, restoring backed-up files, WebDAV/SMB/directory backup volumes, or `ZEROBYTE_API_KEY`—even if they ask generally "check my backups", "did CT 103 back up last night?", "browse the latest snapshot", or "restore this file from backup".
---

# Zerobyte Backup Orchestrator Skill

Interact safely and deterministically with your self-hosted **Zerobyte** instance on CT 100 (`master`) using its REST API (`/api/v1`) and the standalone CLI helper at `scripts/zerobyte.py`.

Using the HTTP API rather than inspecting `zerobyte.db` directly ensures Zerobyte's internal state, Restic locking, mount health, and task queue remain consistent.

---

## 1. Credentials & Endpoint Configuration

Credentials live in `/root/.env` (strictly mode `0600`):
- **`ZEROBYTE_API_KEY`**: API key sent via the `X-API-Key` header.
- **`ZEROBYTE_BASE_URL`** *(optional)*: Defaults to `http://192.168.0.100:4096` (direct LAN access avoids Cloudflare WAF/bot filtering and TLS overhead; override with `https://zerobyte.mohandl3g.ly` or `--base-url` if needed).

> [!CAUTION]
> **Credential & Secret Protection**
> Never print, echo, log, or commit `ZEROBYTE_API_KEY` or volume/repository passwords. `zerobyte.py` automatically masks sensitive keys (`password`, `secret`, `token`, `apiKey`, `resticPassword`, etc.) in output.

---

## 2. Safety Rules

- **API-only state changes:** Always query and mutate Zerobyte through `zerobyte.py` / `/api/v1`, never by editing `/root/appdata/zerobyte/data/zerobyte.db`.
- **Confirmation gate (`--confirmed`):** Destructive or mutating recovery operations—`volumes delete`, `repos delete`, `repos unlock`, `repos exec`, `snapshots delete`, `backups delete`, `backups forget`, `restore run`, and raw `api DELETE`—are blocked unless `--confirmed` is passed after explicit user approval.
- **No unrequested production backup triggers:** Do not trigger `backups run`, `backups forget`, `repos doctor`, or `restore run` merely to test code paths unless the user asks or you are verifying an approved deployment.
- **Safe restore practice:** When unsure of target permissions or live files, restore to a staging directory (`--target-path`) first rather than overwriting live paths in place.

---

## 3. CLI Quickstart (`scripts/zerobyte.py`)

`zerobyte.py` accepts names, `shortId`s, or numeric IDs for volumes, repositories, and backup schedules, and supports `--json` on every command.

```bash
ZB="python3 /root/home/.agents/skills/zerobyte/scripts/zerobyte.py"

# System & capabilities
$ZB system info
$ZB system updates

# Volumes (list, inspect, browse files, health check, mount/unmount)
$ZB volumes list
$ZB volumes get Antigravity
$ZB volumes files Antigravity --path "/"
$ZB volumes health-check Antigravity
$ZB volumes test-connection --config-json '{"backend":"webdav","server":"192.168.0.103","port":8083,"path":"/dav/folder","username":"zerobyte","password":"...","ssl":false}'

# Repositories & stats
$ZB repos list
$ZB repos stats Vault
$ZB repos refresh-stats Vault
$ZB repos doctor Vault                 # Runs integrity check (background task)

# Snapshots & file inspection (snapshots store full container mount paths, e.g. /var/lib/zerobyte/volumes/<volShortId>/_data/...)
$ZB snapshots list Vault
$ZB snapshots list Vault --backup Antigravity
$ZB snapshots files Vault <snapshot_id> --path "/var/lib/zerobyte/volumes/Sa9lHyXW/_data/.gemini/config" --limit 100
$ZB snapshots tag Vault <snapshot_id> --add manual

# Backup schedules & execution
$ZB backups list
$ZB backups get Antigravity
$ZB backups by-volume Antigravity
$ZB backups run Antigravity            # Starts async backup task; returns taskId
$ZB backups run Antigravity --wait     # Poll task until completion

# Tasks & history
$ZB tasks list
$ZB tasks history --page 1
$ZB tasks get <task_id>

# Restore (requires explicit user confirmation + --confirmed)
$ZB restore run Vault <snapshot_id> \
  --include "/.env" --kind file \
  --target-path "/tmp/restore-test" --overwrite never --confirmed

# Notifications
$ZB notifications list
$ZB notifications test <destination_id>

# Raw API escape hatch (for any of the 75 OpenAPI endpoints)
$ZB api GET /api/v1/agents
$ZB api GET /api/v1/repositories/KWcRXBV8/snapshots/43bf54a9.../files?limit=50
```

---

## 4. Homelab Reference Topology (Current Baseline)

| Volume / Job | CT | Transport | Source / Target | Schedule (`Africa/Tripoli`) |
| :--- | :--- | :--- | :--- | :--- |
| **`Citadel`** | CT 100 | Local directory (`/mnt/citadel`) | `/appdata`, `/appdata2`, `/compose` (excludes media/caches/`vault`) | `00 04 * * *` → `Vault` (`KWcRXBV8`) |
| **`Adguard`** | CT 101 | WebDAV (`192.168.0.101:8083/dav/folder`) | `/adguardhome`, `/filebrowserquantum` | `00 04 * * *` → `Vault` |
| **`NPM`** | CT 102 | WebDAV (`192.168.0.102:8083/dav/folder`) | `/filebrowserquantum`, `/npm` | `00 04 * * *` → `Vault` |
| **`Antigravity`** | CT 103 | WebDAV (`192.168.0.103:8083/dav/folder`) | `/.env`, `/.ssh`, `/.gitconfig`, `/.config`, `/.supermemory`, `/.gemini`, `/home/AGENTS.md`, `/home/.agents/skills` (excludes `brain/`, `conversations/`, caches, `node_modules`) | `00 04 * * *` → `Vault` |

Standard retention policy across schedules: `keepLast: 1`, `keepDaily: 7`, `keepWeekly: 4`, `keepMonthly: 6`, `keepYearly: 1`.

---

## 5. Additional References

Read these bundled reference files when constructing payloads, debugging volume backends, or performing maintenance/restores:
- **`references/api.md`**: Complete index of all 75 Zerobyte `/api/v1` endpoints, path/query parameters, and request body fields.
- **`references/guides.md`**: Operational guidance from `zerobyte.app/docs` covering volume backends, restore semantics, repository health states (`healthy`/`error`/`unknown`/`doctor`), `Unlock` vs `Doctor`, and troubleshooting.
