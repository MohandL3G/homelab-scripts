---
name: PVE Operations
description: Procedures for Proxmox VE host and LXC container work - ssh pve access rules, pct command recipes, the CT drift-check procedure, and CT ID safety. Use for any task involving the PVE host, containers, cluster storage, or backups.
---

# PVE Operations

Environment facts (per-CT details, IPs, storage layout, migration state) live in Supermemory, not in this skill. Before assuming any homelab fact, search Supermemory (`supermemory_recall` / supermemory search). If a search returns nothing relevant, say so rather than guessing.

## Access rules

- `ssh pve` (alias for `root@192.168.0.51`) is the ONLY channel to Proxmox. Key-based, plain ssh.
- The Proxmox MCP server was removed Oct 6 2026. Never reference `http://192.168.0.110:8000/mcp` (token dead) and never try to restore it.
- No web-UI automation against the PVE host unless the user explicitly asks.

## Drift procedure (mandatory)

If anything looks mismatched or odd versus expected state:

1. Run `ssh pve 'pct list'` (and `pct config <id>`) FIRST to see whether a CT was added or changed.
2. On finding a new/changed guest, update Supermemory yourself: forget the stale memory, add the corrected one. No near-duplicates.
3. Ask the user whether the change needs further updates (NPM proxy, DNS) before acting.

## CT ID safety

- Before ANY destructive operation, reconcile the requested CT ID against live `pct list` - user-provided IDs may be off-by-one or typos. Treat the confirmation as referring to the pending or only candidate, and report the corrected ID.
- Never `pct destroy`, stop, or restart a CT without explicit user confirmation for that specific action.
- Backups: PBS is a separate CT (see Supermemory for current state). `vzdump` only when the user asks.

## Common recipes

- Enter a CT: `ssh pve 'pct exec <id> -- <command>'`
- Status / config: `ssh pve 'pct status <id>'` / `ssh pve 'pct config <id>'`
- Service inside a CT: `ssh pve 'pct exec <id> -- systemctl status <svc>'`
- List storages: `ssh pve 'pvesm status'` (layout details in Supermemory)
- Start/stop only with user confirmation: `pct start <id>` / `pct stop <id>`

### CT 103 (`antigravity`) Daemon Management

- The CLI remote-control daemon is managed under systemd user manager as `antigravity-cli-daemon.service`.
- `agy remote-control` subcommands are strictly `start`, `stop`, and `status`. **There is no `restart` subcommand**.
- **To restart from inside CT 103:**
  - `agy remote-control stop && agy remote-control start`
  - Or: `systemctl --user restart antigravity-cli-daemon`
- **To check status from inside CT 103:**
  - `agy remote-control status`
  - Or: `systemctl --user status antigravity-cli-daemon`
- **To restart/check from the PVE host via `pct exec`:**
  - `ssh pve 'pct exec 103 -- systemctl --user -M root@ restart antigravity-cli-daemon'`
  - `ssh pve 'pct exec 103 -- systemctl --user -M root@ status antigravity-cli-daemon'`

After any environment change, update Supermemory yourself - do not ask the user to maintain it.
