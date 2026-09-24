# homelab-scripts

Personal admin/automation scripts for my homelab and workstation — configurable
over time across **Bash, PowerShell, Python, and AutoHotkey v2** as the need
arises.

## Folder convention

One top-level folder per **target system / category** — nothing flat at root:

| Folder              | Target                     |
|---------------------|----------------------------|
| `ProxmoxVE/`        | PVE hosts & LXC containers |

Future systems get their own sibling folders (e.g. `Windows/`, `Cloudflare/`,
`GitHub/`) with the same per-folder README/script-doc approach.

## Secrets

**`.env` files are never committed** (gitignored root-wide, `.env` + `.env.*`).
If a script needs credentials, read them from a `.env`.`*local` file next to the
script or a dedicated credential store — never hardcode secrets here.

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
# dry run — prints current usage, deletes nothing
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/ProxmoxVE/clean-lxc-caches.sh)" _ --dry

# real run
bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/ProxmoxVE/clean-lxc-caches.sh)"
```

The leading `_` is a throwaway `$0` so `--dry` lands in `$1`.

**Safety rules baked in:**
- Never `rm -rf` the pnpm store (hardlinked into live `node_modules`) — only `pnpm store prune`.
- Never touches app/data dirs (e.g. `/opt/immich/cache/clip`) — caches only.
- `apt-get clean` only — no autoremove / dist-upgrade.
- Non-running CTs are skipped; no implicit assumptions about locked CTs.

**Tradeoff — NOT scheduled (deliberately):** caches exist to make the next
community-scripts rebuild fast; pruning them is a release of disk, not a fix —
they regrow on the next 03:00 update. A scheduled prune would burn ~constant
CPU/IO every night for a one-time size win. Leave it manual: run when a CT
approaches its rootfs waterline. If you later want automation, prefer a weekly
low-priority pass over a hook inside the (read-only) update pipeline.