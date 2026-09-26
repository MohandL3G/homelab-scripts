#!/usr/bin/env bash
#
# clean-lxc-caches.sh — prune package-manager caches in every running LXC.
#
# Run on the PVE HOST as root, invoked straight from GitHub raw (no local copy
# needed), same pattern as update-lxcs.sh:
#
#   dry run:  bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/ProxmoxVE/clean-lxc-caches.sh)" _ --dry
#   real run: bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/ProxmoxVE/clean-lxc-caches.sh)"
#
# The leading "_" is a throwaway $0 so "--dry" lands in $1.
#
# Fully auto-discovering, no hardcoded CT IDs and no per-host branching:
#   - Targets EVERY currently-running CT on whatever Proxmox host this runs
#     on (via `pct list`). Add/remove/rename CTs freely — nothing here needs
#     updating for that.
#   - For each CT, checks what's actually installed inside it (pnpm / npm /
#     uv / apt-get) before doing anything, and prints what it found. A CT
#     without a given tool never has that tool's command run against it.
#
# What it can clean inside a CT, if present:
#   - pnpm store (via `pnpm store prune` — NEVER rm -rf; hardlinked into node_modules)
#   - pnpm cache dir, npm cacache, yarn v6 cache
#   - uv pip cache
#   - apt archive cache (apt-get clean only — no autoremove / dist-upgrade)
#
# It NEVER touches application/data directories (e.g. /opt/immich/cache/clip).
#
set -uo pipefail

DRY=0
[ "${1:-}" = "--dry" ] && DRY=1

mapfile -t CTLIST < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running"{print $1}')

if [ "${#CTLIST[@]}" -eq 0 ]; then
  echo "No running CTs found (or 'pct list' failed)."
  exit 0
fi

DETECT='
  is(){ command -v "$1" >/dev/null 2>&1; }
  found=()
  is pnpm && found+=("pnpm")
  is npm  && found+=("npm")
  is uv   && found+=("uv")
  [ -d /root/.cache/pnpm ]            && found+=("pnpm-dir")
  [ -d /root/.npm/_cacache ]          && found+=("npm-dir")
  [ -d /usr/local/share/.cache/yarn ] && found+=("yarn-dir")
  { is apt-get && [ -d /var/cache/apt/archives ]; } && found+=("apt")
  [ "${#found[@]}" -eq 0 ] && echo NONE || echo "${found[*]}"
'

for v in "${CTLIST[@]}"; do
  pct status "$v" >/dev/null 2>&1 || { echo "== CT $v skipped (stopped) =="; continue; }
  echo "== CT $v =="

  found=$(pct exec "$v" -- bash -c "$DETECT")

  if [ "$found" = "NONE" ]; then
    echo "   nothing to clean (no pnpm/npm/uv/apt-get found)"
    continue
  fi
  echo "   found: $found"

  if [ $DRY -eq 1 ]; then
    pct exec "$v" -- df -h / | awk 'NR==2{printf "   (dry) would prune; currently used: %s\n",$5}'
    continue
  fi

  used_before=$(pct exec "$v" -- df -h / | awk 'NR==2{print $5}')
  pct exec "$v" -- bash -s <<'REMOTE'
    is(){ command -v "$1" >/dev/null 2>&1; }
    is pnpm && pnpm store prune 2>/dev/null || true
    is npm  && npm cache clean --force 2>/dev/null || true
    is uv   && uv cache clean 2>/dev/null || true
    [ -d /root/.cache/pnpm ]            && rm -rf /root/.cache/pnpm
    [ -d /root/.npm/_cacache ]          && rm -rf /root/.npm/_cacache
    [ -d /usr/local/share/.cache/yarn ] && rm -rf /usr/local/share/.cache/yarn
    { command -v apt-get >/dev/null 2>&1 && [ -d /var/cache/apt/archives ]; } && apt-get clean 2>/dev/null
REMOTE
  used_after=$(pct exec "$v" -- df -h / | awk 'NR==2{print $5}')
  echo "   used: $used_before -> $used_after"
done

echo "Done."
