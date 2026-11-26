# homelab-scripts

Personal admin/automation scripts for my homelab and workstation - configurable
over time across **Bash, PowerShell, Python, and AutoHotkey v2** as the need
arises.

## Folder convention

One top-level folder per **target system / category** - nothing flat at root:

| Folder              | Target                     |
|---------------------|----------------------------|
| `ProxmoxVE/`        | PVE hosts & LXC containers |
| `Antigravity/`      | Antigravity agent & skills (CT 103) |

Future systems get their own sibling folders (e.g. `Windows/`, `Cloudflare/`,
`GitHub/`) with the same per-folder README/script-doc approach.

## Secrets

**`.env` files are never committed** (gitignored root-wide, `.env` + `.env.*`).
If a script needs credentials, read them from a `.env`.`*local` file next to the
script or a dedicated credential store - never hardcode secrets here.

## Scripts

Each script documents its usage in its header. Scripts that target the PVE host
are designed to run **straight from the raw GitHub URL** (no scp/local copy),
same pattern as community-scripts' `update-lxcs.sh`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/<FOLDER>/<script>.sh)" [--dry]
```

### `ProxmoxVE/clean-lxc-caches.sh`

Prunes **package-manager caches** from community-scripts LXC containers that
accumulate on each nightly source rebuild (pnpm store/cache, npm cacache, yarn
v6 cache, uv cache, apt archives). Run on the PVE host as root.

```
# dry run - prints current usage, deletes nothing
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/ProxmoxVE/clean-lxc-caches.sh)" _ --dry

# real run
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/ProxmoxVE/clean-lxc-caches.sh)"

# real run, streaming the per-CT detail too
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/ProxmoxVE/clean-lxc-caches.sh)" _ --verbose
```

The leading `_` is a throwaway `$0` so the options land in `$1`. `--dry` and
`--verbose` may be given in either order; an unknown option exits 2.

Before reporting anything it clears the terminal - but only when stdout is a
real TTY, so `| tee` / `> run.log` stays free of escape codes - and prints a
`=== LXC cache cleanup - <timestamp> ===` run header (a `DRY RUN` variant with
`--dry`) so a saved log can never be mistaken for a live run.

Output is summary-only by default - the header, the table below, and the footer.
The per-CT detail (what each CT had installed, `before -> after` usage) is behind
`--verbose`, which restores it as a live stream while the run is in progress:

```
Cleaning CT 101 (1/6)...   <- only on a TTY, rewritten in place and erased
                            before the table, never when piped/redirected
```

Without `--verbose` a non-TTY run prints nothing but the header, table and
footer, and the `pct exec` cleanup chatter is discarded (its exit status is
ignored either way, so a chatty package manager cannot turn a healthy CT into an
`error` row).

The **summary table** closes the run out:

```
Summary
+======+=====================+=========+========+=======+===============+===================+
| CTID | Name                | Found   | Before | After |         Freed | Status            |
+======+=====================+=========+========+=======+===============+===================+
| 100  | immich              | npm apt |    14% |   14% | 117.2 MB (0%) | OK                |
+------+---------------------+---------+--------+-------+---------------+-------------------+
| 102  | a-very-long-ct-name | apt     |    14% |   14% |      0 B (0%) | no change         |
+------+---------------------+---------+--------+-------+---------------+-------------------+
| 105  | metube              | -       |      - |     - |             - | skipped (stopped) |
+======+=====================+=========+========+=======+===============+===================+

Total reclaimed: 3.2 GB across 6 CTs   Elapsed: 0m 3s
```

Columns are sized from the header and every cell, so a long CT name or a long
tool list widens just its own column and every rule stays exactly as wide as the
rows above and below it. `CTID`, `Name`, `Found` and `Status` are left-aligned;
`Before`, `After` and `Freed` are right-aligned so the magnitudes line up.

`Status` is `OK`, `no change`, `nothing to clean`, `skipped (stopped)`, `error`,
or `dry-run` under `--dry` - a failed `pct exec`/`df` always shows as `error`,
never as a clean row. Sizes come from `df -Pk /` inside each CT (POSIX, so
Alpine busybox works too); a CT that grew during the run is clamped to `0 B`.
`Before`/`After`/`Freed` are `-` for skipped CTs and `After`/`Freed` are `-` on
a dry run, which reports no total reclaimed.

**Safety rules baked in:**
- Never `rm -rf` the pnpm store (hardlinked into live `node_modules`) - only `pnpm store prune`.
- Never touches app/data dirs (e.g. `/opt/immich/cache/clip`) - caches only.
- `apt-get clean` only - no autoremove / dist-upgrade.
- Non-running CTs are skipped; no implicit assumptions about locked CTs.

**Tradeoff - NOT scheduled (deliberately):** caches exist to make the next
community-scripts rebuild fast; pruning them is a release of disk, not a fix -
they regrow on the next 03:00 update. A scheduled prune would burn ~constant
CPU/IO every night for a one-time size win. Leave it manual: run when a CT
approaches its rootfs waterline. If you later want automation, prefer a weekly
low-priority pass over a hook inside the (read-only) update pipeline.

### `ProxmoxVE/update-hawser.sh`

Auto-discovers and updates Docker-based **Hawser** agents (`ghcr.io/finsys/hawser`)
across running Proxmox VE LXC containers. Run on the PVE host as root, straight
from the raw GitHub URL:

```bash
# dry run - discovers CTs and compares installed vs upstream version without modifying anything
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/ProxmoxVE/update-hawser.sh)" _ --dry

# real run - scans all running CTs and updates any outdated :latest Hawser agents
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/ProxmoxVE/update-hawser.sh)"

# targeted verbose run on specific CTs
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/ProxmoxVE/update-hawser.sh)" _ --ct=101,102 --verbose
```

The leading `_` is a throwaway `$0` so options land in `$1`.

**Options:**
- `--dry`, `-n`: Report installed vs upstream release without pulling or recreating containers
- `--verbose`, `-v`: Stream per-CT inspection, pull, recreate, and health-check output
- `--force`, `-f`: Re-pull and recreate even when installed version already matches upstream
- `--ct=ID[,ID...]`: Restrict scan to specific comma-separated CT IDs (repeatable)
- `--no-prune`: Keep the temporary `hawser-rollback:<old_ver>` image tag after verification
- `-h`, `--help`: Show help message

The **summary table** reports every scanned CT:

```text
Summary (upstream latest: 0.2.54)
+======+===================+=========+========+=======+=========+===================+
| CTID | Name              | Mode    | Before | After | Health  | Status            |
+======+===================+=========+========+=======+=========+===================+
| 100  | master            | -       |      - |     - | -       | no hawser         |
+------+-------------------+---------+--------+-------+---------+-------------------+
| 101  | adguard           | direct  | 0.2.53 | 0.2.54| healthy | updated           |
+------+-------------------+---------+--------+-------+---------+-------------------+
| 102  | nginxproxymanager | compose | 0.2.53 | 0.2.54| healthy | updated           |
+------+-------------------+---------+--------+-------+---------+-------------------+
| 116  | opencode          | -       |      - |     - | -       | skipped (stopped) |
+======+===================+=========+========+=======+=========+===================+

Updated: 2   Up-to-date: 0   Skipped: 2   Errors: 0   Elapsed: 0m 28s
```

**Safety rules baked in:**
- Skips stopped CTs, CTs without Docker/Hawser, and containers pinned to non-`:latest` tags (e.g. `:0.2.53` or `@sha256:...`).
- Handles both Compose-managed deployments (when a `docker-compose.yml` exists on disk) and standalone/direct containers (reconstructed from `docker inspect` using a temporary `0600` `--env-file` so `TOKEN` is never exposed in CLI arguments or output).
- Tags the previous image as `hawser-rollback:<old_ver>` before recreating, verifies both Docker healthcheck and `/_hawser/health` (`"connected":true`), automatically rolls back on failure, and prunes the rollback tag once healthy (unless `--no-prune`).

### `Antigravity/update-skills.sh`

Checks for updates across git-cloned agent skill repositories on CT 103, fast-forwards
to latest releases, syncs all skills into Antigravity (`~/.gemini/config/skills`), and
updates homelab knowledge in Supermemory. Run inside CT 103 as root.

```bash
# dry run - checks upstream and reports status, changes nothing
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/Antigravity/update-skills.sh)" _ --dry

# real run
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/Antigravity/update-skills.sh)"

# real run with verbose git output
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/Antigravity/update-skills.sh)" _ --verbose

# force resync of all skills even if git is already up to date
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/Antigravity/update-skills.sh)" _ --force
```

Or execute directly from a local clone:

```bash
./Antigravity/update-skills.sh [--dry] [--verbose] [--force]
```

The leading `_` is a throwaway `$0` so options land in `$1` when invoked via `bash -c`.

**Options:**
- `--dry`, `-n`: Check and report updates only; make no changes
- `--verbose`, `-v`: Stream git fetch/pull commands and detailed output
- `--force`, `-f`: Force reinstall/resync all skills even if git is up to date
- `--no-anchor`, `--no-memory`: Skip updating Anchor memory after sync (`--no-supermemory` supported as legacy alias)
- `--repos-dir=PATH`: Directory containing skill repos (default: `/root/antigravity`)
- `--dest-dir=PATH`: Target skills directory (default: `~/.gemini/config/skills`)

The **summary table** reports the status of each discovered skill repository:

```
Summary
+=================+=========+==========+========+========+============+
| Repository      | Current | Upstream | Behind | Skills | Status     |
+=================+=========+==========+========+========+============+
| artcraft-skills | v1.2.0  | v1.3.0   |      3 |  17/17 | updated    |
+-----------------+---------+----------+--------+--------+------------+
| rust-skills     | 5c40d3a | 5c40d3a  |      0 |  38/38 | up-to-date |
+-----------------+---------+----------+--------+--------+------------+

Result: Skills successfully updated: artcraft-skills (v1.3.0, 17 skills)
Anchor: updated (Note: [Memory] Installed Agent Skills & External Repositories)
Elapsed: 30s
```

**Features and safety:**
- Auto-discovers any git repo under `/root/antigravity` containing skills.
- Pulls only via `git pull --ff-only` to ensure clean upstream fast-forwards.
- Re-scans skill directories after pull so brand-new skills added in an upstream release (e.g. `materialcraft`, `texturecraft`, `solidcraft`) are automatically detected and synced.
- Syncs to both Antigravity's active skills directory (`~/.gemini/config/skills`) and `~/.agents/skills` when present.
- Updates Supermemory's homelab namespace (`repo_root__de0b3628254df1e4`) automatically by forgetting previous skill-version memories and indexing the updated state.

### `Antigravity/update-agy.sh`

Automates updating the Antigravity CLI (`agy`) inside CT 103 by retrieving the release archive from the Gaming PC (`MOHANDL3G-PC`) over local Gigabit LAN, verifying SHA-512 integrity against Google's official release manifest, atomically installing the binary into `/root/.local/bin/agy`, and cleaning up temporary files on both hosts.

```bash
# dry run — checks upstream manifest and inspects Gaming PC without installing
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/Antigravity/update-agy.sh)" _ --dry

# real run — auto-discovers archive on Desktop (or ABDM Downloads) and installs
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/Antigravity/update-agy.sh)"

# real run with detailed transfer and verification logs
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/Antigravity/update-agy.sh)" _ --verbose

# update using a specific archive file path on Gaming PC
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/Antigravity/update-agy.sh)" _ --file='C:\Users\MohandL3G\Desktop\agy_cli_linux_x64.tar.gz'
```

Or execute directly from a local clone:

```bash
./Antigravity/update-agy.sh [--dry] [--verbose] [--force]
```

The leading `_` is a throwaway `$0` so options land in `$1` when invoked via `bash -c`.

**Options:**
- `--dry`, `-n`: Check upstream manifest and inspect remote Gaming PC files; make no changes
- `--verbose`, `-v`: Stream scp transfer progress and detailed verification output
- `--force`, `-f`: Force reinstall even if installed version matches upstream
- `--file=PATH`: Specify explicit remote path on Gaming PC (skips auto-scan)
- `--no-backup`: Skip creating rollback backup (by default only the immediate previous backup is kept; older backups are automatically pruned)
- `--no-cleanup`: Retain temporary extraction staging and remote archive
- `--no-anchor`: Skip recording the update in Anchor persistent memory
- `--no-restart`: Skip restarting the remote-control daemon
- `--restart`: Force daemon restart even if executed inside an active agent session

The **summary table** reports the update result:

```
Summary
+=======================+==========+===========+=========+
| Component             | Previous | Installed | Status  |
+=======================+==========+===========+=========+
| Antigravity CLI (agy) | 1.5.7    | 1.5.10    | updated |
+=======================+==========+===========+=========+

Result: Antigravity CLI successfully updated to 1.5.10.
Daemon: deferred (active session)
Anchor: updated (Note: [Changelog] Homelab Events Archive)

Note: To reload the remote-control daemon into the new version:
  systemctl --user restart antigravity-cli-daemon.service
  # or: agy remote-control stop && agy remote-control start

Elapsed: 15s
```

### `Antigravity/skills/gmail/scripts/gmail.py`

CLI and client library for interacting with Mohand's Gmail account via encrypted IMAP SSL (`imap.gmail.com:993`) and SMTP STARTTLS (`smtp.gmail.com:587`). Runs inside CT 103 and exposes subcommands for folder inspection, message searches, full email reading, drafting, and guarded sending.

```bash
# List all mailbox folders
python3 Antigravity/skills/gmail/scripts/gmail.py folders

# Search emails (latest 5 in INBOX)
python3 Antigravity/skills/gmail/scripts/gmail.py search --limit 5

# Search unread emails
python3 Antigravity/skills/gmail/scripts/gmail.py search --query "UNSEEN"

# Read email by UID with header and decoded body breakdown
python3 Antigravity/skills/gmail/scripts/gmail.py read <UID>

# Create a draft in [Gmail]/Drafts
python3 Antigravity/skills/gmail/scripts/gmail.py draft --to "user@example.com" --subject "Meeting" --body "Draft notes"

# Send email immediately (requires explicit --confirmed flag)
python3 Antigravity/skills/gmail/scripts/gmail.py send --to "user@example.com" --subject "Meeting" --body "Hello" --confirmed
```

Credentials are read automatically from `/root/.env` (`GMAIL_ADDRESS` and `GMAIL_APP_PASSWORD`).


