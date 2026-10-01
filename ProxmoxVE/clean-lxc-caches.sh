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
# Output: clears the terminal when stdout is a TTY (never when piped/redirected),
# then prints a "=== LXC cache cleanup — <timestamp> ===" run header, then the
# per-CT report streaming live as each CT is processed, then a "Summary" table
# (CTID / Name / Found / Before / After / Freed / Status) plus a
# "Total reclaimed: ... across N CTs   Elapsed: Nm Ns" footer closes the run.
# Free sizes come from `df -Pk /` inside each CT, POSIX so Alpine busybox is OK.
#
set -uo pipefail

DRY=0
[ "${1:-}" = "--dry" ] && DRY=1

# Clear the screen first, but ONLY on a real TTY so piped/redirected logs stay
# escape-free. Let terminfo pick the sequence (`tput`, then `clear`), and fall
# back to raw ANSI when neither can work -- e.g. TERM unset or `dumb`, which is
# exactly what a non-interactive ssh session gives us. Every probe is silenced so
# a failing lookup can never write to stderr. Straight to stdout rather than
# captured in $(...), because command substitution makes bash complain about
# the newlines some terminfo entries emit.
if [ -t 1 ]; then
  tput clear 2>/dev/null || clear 2>/dev/null || printf '\033[H\033[2J'
  printf '\033[3J'    # also wipe scrollback, where the terminal supports it
fi

# Run header, so a saved log is never mistaken for a live run.
NOW=$(date '+%Y-%m-%d %H:%M:%S')
if [ $DRY -eq 1 ]; then
  printf '=== LXC cache cleanup (DRY RUN — nothing will be changed) — %s ===\n\n' "$NOW"
else
  printf '=== LXC cache cleanup — %s ===\n\n' "$NOW"
fi

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

# host-side helpers for the summary table

# Append one summary row. "-" in a numeric field means "not measured".
sum_row() {
  SUM_CTID+=("$1"); SUM_NAME+=("$2"); SUM_FOUND+=("$3"); SUM_BEFORE+=("$4")
  SUM_AFTER+=("$5"); SUM_FREED+=("$6"); SUM_STATUS+=("$7")
}

# df -Pk / inside a CT -> "<capacity> <used_kb>"; empty on failure.
# Both numbers come from ONE pct exec. -P/-k are POSIX, so Alpine busybox is fine.
df_used() {
  pct exec "$1" -- df -Pk / 2>/dev/null | awk 'NR==2{print $5, $3}'
}

# KB -> B/KB/MB/GB, one decimal where useful. Negative (CT grew) reads as 0 B.
human_kb() {
  awk -v k="${1:-0}" 'BEGIN{
    if      (k <= 0)         { printf "0 B\n" }
    else if (k < 1024)       { printf "%.0f KB\n", k }
    else if (k < 1048576)    { printf "%.1f MB\n", k/1024 }
    else                     { printf "%.1f GB\n", k/1048576 }
  }'
}

SUM_CTID=(); SUM_NAME=(); SUM_FOUND=(); SUM_BEFORE=(); SUM_AFTER=()
SUM_FREED=(); SUM_STATUS=()
TOTAL_FREED_KB=0
T0=$SECONDS

for v in "${CTLIST[@]}"; do
  # hostname is readable on a stopped CT too, so skipped rows still get a name
  cname=$(pct config "$v" 2>/dev/null | awk -F': ' '/^hostname/{print $2; exit}')
  [ -n "$cname" ] || cname='-'

  if ! pct status "$v" >/dev/null 2>&1; then
    echo "== CT $v skipped (stopped) =="
    sum_row "$v" "$cname" '-' '-' '-' '-' 'skipped (stopped)'
    continue
  fi
  echo "== CT $v =="

  found=$(pct exec "$v" -- bash -c "$DETECT")

  if [ -z "$found" ]; then
    echo "   error: pct exec returned nothing (CT unreachable?)"
    sum_row "$v" "$cname" '-' '-' '-' '-' 'error'
    continue
  fi

  if [ "$found" = "NONE" ]; then
    echo "   nothing to clean (no pnpm/npm/uv/apt-get found)"
    sum_row "$v" "$cname" 'none' '-' '-' '-' 'nothing to clean'
    continue
  fi
  echo "   found: $found"

  usage=$(df_used "$v")
  if [ -z "$usage" ]; then
    echo "   error: could not read df -Pk /"
    sum_row "$v" "$cname" "$found" '-' '-' '-' 'error'
    continue
  fi
  b_pct=${usage%% *}
  b_kb=${usage##* }

  if [ $DRY -eq 1 ]; then
    printf '   (dry) would prune; currently used: %s\n' "$b_pct"
    sum_row "$v" "$cname" "$found" "$b_pct" '-' '-' 'dry-run'
    continue
  fi

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

  usage=$(df_used "$v")
  if [ -z "$usage" ]; then
    echo "   used: $b_pct -> ?"
    sum_row "$v" "$cname" "$found" "$b_pct" '-' '-' 'error'
    continue
  fi
  a_pct=${usage%% *}
  a_kb=${usage##* }
  echo "   used: $b_pct -> $a_pct"

  # clamp: a CT that grew during the run must never report negative gains
  freed=$(( b_kb - a_kb ))
  pts=$(( ${b_pct%\%} - ${a_pct%\%} ))
  [ "$freed" -lt 0 ] && freed=0
  [ "$pts" -lt 0 ] && pts=0

  if [ "$freed" -gt 0 ]; then
    status='OK'
    TOTAL_FREED_KB=$(( TOTAL_FREED_KB + freed ))
  else
    status='no change'
  fi
  sum_row "$v" "$cname" "$found" "$b_pct" "$a_pct" "$(human_kb "$freed") ($pts%)" "$status"
done

# ---- summary table (one row per CT, skipped ones included) ----

if [ "${#SUM_CTID[@]}" -eq 0 ]; then
  echo "Done."
  exit 0
fi

# widen the two variable columns to the data, never below their header
name_w=4
found_w=5
for i in "${!SUM_CTID[@]}"; do
  [ "${#SUM_NAME[i]}"  -gt "$name_w" ]  && name_w="${#SUM_NAME[i]}"
  [ "${#SUM_FOUND[i]}" -gt "$found_w" ] && found_w="${#SUM_FOUND[i]}"
done

row() { printf '%-4s  %-*s  %-*s  %-6s  %-5s  %-17s  %s\n' \
        "$1" "$name_w" "$2" "$found_w" "$3" "$4" "$5" "$6" "$7"; }

echo
if [ $DRY -eq 1 ]; then
  echo "Summary (dry run — no changes made)"
else
  echo "Summary"
fi
row CTID Name Found Before After Freed Status
for i in "${!SUM_CTID[@]}"; do
  row "${SUM_CTID[i]}" "${SUM_NAME[i]}" "${SUM_FOUND[i]}" "${SUM_BEFORE[i]}" \
      "${SUM_AFTER[i]}" "${SUM_FREED[i]}" "${SUM_STATUS[i]}"
done

echo
elapsed=$(( SECONDS - T0 ))
if [ $DRY -eq 1 ]; then
  printf 'Elapsed: %dm %ds\n' "$(( elapsed / 60 ))" "$(( elapsed % 60 ))"
else
  printf 'Total reclaimed: %s across %d CTs   Elapsed: %dm %ds\n' \
    "$(human_kb "$TOTAL_FREED_KB")" "${#SUM_CTID[@]}" \
    "$(( elapsed / 60 ))" "$(( elapsed % 60 ))"
fi

