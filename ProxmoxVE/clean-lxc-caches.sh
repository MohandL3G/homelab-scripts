#!/usr/bin/env bash
#
# clean-lxc-caches.sh — prune package-manager caches in community-scripts LXCs.
#
# Run on the PVE HOST as root, invoked straight from GitHub raw (no local copy
# needed), same pattern as update-lxcs.sh:
#
#   dry run:  bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/ProxmoxVE/clean-lxc-caches.sh)" _ --dry
#   real run: bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/ProxmoxVE/clean-lxc-caches.sh)"
#
# The leading "_" is a throwaway $0 so "--dry" lands in $1.
#
# What it cleans inside each target CT:
#   - pnpm store (via `pnpm store prune` — NEVER rm -rf; hardlinked into node_modules)
#   - pnpm cache dir, npm cacache, yarn v6 cache
#   - uv pip cache
#   - apt archive cache (apt-get clean only — no autoremove / dist-upgrade)
#
# It NEVER touches application/data directories (e.g. /opt/immich/cache/clip).
# Non-running CTs are skipped via `pct status`.
#
# Design segment — CT target list (CTID == running check only):
#   100 Immich, 104 NPM, 106 MeTube, 115 Homarr, 117 Papra, 119 Nametag,
#   120 Mealie, 121 achivements-passport, 122 Invoice Ninja, 123 Budget-Board.
#   CT 116 excluded (stopped, n8n). CT 123 treated like any other CT — it is
#   covered solely by the `pct status` running check, no special-casing.
#
set -uo pipefail

DRY=0
[ "${1:-}" = "--dry" ] && DRY=1

CTLIST=(100 104 106 115 117 119 120 121 122 123)

for v in "${CTLIST[@]}"; do
  pct status "$v" >/dev/null 2>&1 || { echo "== CT $v skipped (not running) =="; continue; }
  echo "== CT $v =="

  [ $DRY -eq 1 ] && { pct exec "$v" -- df -h / | awk 'NR==2{printf "   (dry) would prune cache; currently used: %s\n",$5}'; continue; }

  used_before=$(pct exec "$v" -- df -h / | awk 'NR==2{print $5}')
  pct exec "$v" -- bash -s <<'REMOTE'
    is(){ command -v "$1" >/dev/null 2>&1; }
    if is pnpm; then pnpm store prune 2>/dev/null || true; fi
    if is npm;  then npm cache clean --force 2>/dev/null   || true; fi
    if is uv;   then uv cache clean 2>/dev/null            || true; fi
    [ -d /root/.cache/pnpm ]            && rm -rf /root/.cache/pnpm
    [ -d /root/.npm/_cacache ]          && rm -rf /root/.npm/_cacache
    [ -d /usr/local/share/.cache/yarn ] && rm -rf /usr/local/share/.cache/yarn
    [ -d /var/cache/apt/archives ]      && apt-get clean 2>/dev/null
REMOTE
  used_after=$(pct exec "$v" -- df -h / | awk 'NR==2{print $5}')
  echo "   used: $used_before -> $used_after"
done

echo "Done."