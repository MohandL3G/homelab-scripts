# Zerobyte Operational Guides

Distilled operational notes from `https://zerobyte.app/docs` for volume mounts, restores, retention, and repository maintenance.

---

## 1. Volumes & Mount Backends
Zerobyte mounts remote or local sources inside the container (`/var/lib/zerobyte/volumes/<shortId>/_data`) before Restic snapshots them:
- **Supported Volume Backends (`system info`):** `directory`, `nfs`, `smb`, `webdav`, `sftp` (plus `rclone` when enabled).
- **WebDAV (`mount.davfs`):** On CT 100, Zerobyte binds `/root/compose/zerobyte/mount.davfs-wrapper.sh` to `/usr/local/bin/mount.davfs` to clean stale `/var/run/mount.davfs/*.pid` locks before mounting.
- **Dotfiles & Permissions on FileBrowser Quantum WebDAV:** Ensure `userDefaults.listing.showHidden: true` is set on the remote FileBrowser Quantum instance so dotfiles (`.env`, `.ssh`, `.gemini`, `.config`) are readable over `/dav/folder`.
- **Read-Only vs. Writable Volumes:** Read-only mounts can be backed up cleanly, but cannot accept in-place restores back to the original location.

---

## 2. Backups, Retention & Pruning (`forget`)
Each backup schedule binds:
- **Volume** (`volumeId`) → **Repository** (`repositoryId`)
- **Cron Schedule** (`cronExpression`, container `TZ=Africa/Tripoli`)
- **Path Filters:**
  - `includePaths`: specific root-relative paths inside the volume (e.g. `/.env`, `/.gemini`, `/home/AGENTS.md`)
  - `excludePatterns`: glob exclusions (e.g. `**/node_modules/**`, `.gemini/antigravity-cli/brain/**`)
  - `excludeIfPresent`: skip directories containing marker files (e.g. `.nobackup`, `CACHEDIR.TAG`)
- **Retention Policy (`retentionPolicy`):**
  - Homelab standard: `keepLast: 1`, `keepDaily: 7`, `keepWeekly: 4`, `keepMonthly: 6`, `keepYearly: 1`.
  - Applying retention (`POST /api/v1/backups/{shortId}/forget`) removes expired snapshots and triggers Restic pruning asynchronously (`202` with `taskId`).

---

## 3. Restoring Data (`guides/restoring`)
- **Before Restoring:** Verify the repository is `healthy` and unlocked, the target path exists and is writable, and there is sufficient free space.
- **Staging vs. In-Place:** Prefer restoring to a temporary/custom staging `--target-path` (e.g., `/tmp/restore-check`) before overwriting live files.
- **Overwrite Modes:**
  - `always`: replace all target files
  - `if-changed`: overwrite only if content/metadata differs
  - `if-newer`: overwrite only if snapshot file is newer
  - `never`: skip existing files
- **Single-File / Snapshot Dump:** Use `GET /api/v1/repositories/{shortId}/snapshots/{snapshotId}/dump?path=...&kind=file|dir` when downloading directly without writing to a server path.
- **Snapshot Path Prefix:** Inside Restic snapshots, WebDAV/remote volumes are stored under `/var/lib/zerobyte/volumes/<volumeShortId>/_data/...` (e.g., `/var/lib/zerobyte/volumes/Sa9lHyXW/_data/.env`), while `Citadel` is stored under `/mnt/citadel/...`. Check `snapshots get` `paths` before passing `--path` or `--include`.

---

## 4. Repository Maintenance (`guides/repository-maintenance`)
- **Status Values:**
  - `healthy`: last health/doctor check completed cleanly.
  - `error`: last check failed; inspect `lastError` and doctor output before running backups.
  - `unknown`: settings changed or no recent verdict; verify access and run `doctor`.
  - `doctor`: integrity check currently running; wait before launching conflicting operations.
- **Tools:**
  - `repos refresh-stats`: refreshes repository size and deduplication metrics.
  - `repos doctor`: runs Restic repository consistency checks.
  - `repos unlock`: clears stale Restic lock files **only** after confirming no active backup/prune/restore task is running in `tasks list`.
