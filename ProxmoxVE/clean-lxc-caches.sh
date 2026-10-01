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
# Options (in any order, both optional):
#   --dry       report only, change nothing
#   --verbose   also stream the per-CT detail as each CT is processed
#
# The leading "_" is a throwaway $0 so the options land in $1.
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
# then prints a "=== LXC cache cleanup — <timestamp> ===" run header, then a
# "Summary" table (CTID / Name / Found / Before / After / Freed / Status) plus a
# "Total reclaimed: ... across N CTs   Elapsed: Nm Ns" footer closes the run.
# By default that is ALL you get — the per-CT detail (what was found, before ->
# after usage) is behind --verbose. On a TTY the run is not silent: a single
# transient line shows which CT is being cleaned and is erased before the table.
# Free sizes come from `df -Pk /` inside each CT, POSIX so Alpine busybox is OK.
#
set -uo pipefail

DRY=0
VERBOSE=0
for arg in "$@"; do
  case "$arg" in
    --dry)     DRY=1 ;;
    --verbose) VERBOSE=1 ;;
    -h|--help)
      echo "usage: clean-lxc-caches.sh [--dry] [--verbose]"
      echo "  --dry       report only, change nothing"
      echo "  --verbose   also stream per-CT detail while running"
      exit 0
      ;;
    *)
      echo "clean-lxc-caches.sh: unknown option: $arg" >&2
      echo "usage: clean-lxc-caches.sh [--dry] [--verbose]" >&2
      exit 2
      ;;
  esac
done

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

# Per-CT detail: printed only in --verbose mode, dropped otherwise. Everything
# still gets measured and recorded either way, so the table is identical.
# Named `say` because the per-CT loop below uses `v` as its loop variable.
say() { [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$*"; return 0; }

# Transient progress line, TTY and non-verbose only. Rewritten in place with
# \r + erase-to-EOL, and cleared before the table so it leaves no trace.
PROGRESS=0
[ -t 1 ] && [ "$VERBOSE" -eq 0 ] && PROGRESS=1
progress() { [ "$PROGRESS" -eq 1 ] && printf '\r\033[KCleaning CT %s (%d/%d)...' "$1" "$2" "$3"; return 0; }
progress_clear() { [ "$PROGRESS" -eq 1 ] && printf '\r\033[K'; return 0; }

# Run the in-CT cleanup. Output is swallowed by the caller unless --verbose; the
# body already silences each command, so this only stops unexpected chatter.
cleanup_ct() {
  pct exec "$1" -- bash -s <<'REMOTE'
    is(){ command -v "$1" >/dev/null 2>&1; }
    is pnpm && pnpm store prune 2>/dev/null || true
    is npm  && npm cache clean --force 2>/dev/null || true
    is uv   && uv cache clean 2>/dev/null || true
    [ -d /root/.cache/pnpm ]            && rm -rf /root/.cache/pnpm
    [ -d /root/.npm/_cacache ]          && rm -rf /root/.npm/_cacache
    [ -d /usr/local/share/.cache/yarn ] && rm -rf /usr/local/share/.cache/yarn
    { command -v apt-get >/dev/null 2>&1 && [ -d /var/cache/apt/archives ]; } && apt-get clean 2>/dev/null
REMOTE
}

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
NCT=${#CTLIST[@]}
IDX=0

for v in "${CTLIST[@]}"; do
  IDX=$(( IDX + 1 ))
  progress "$v" "$IDX" "$NCT"

  # hostname is readable on a stopped CT too, so skipped rows still get a name
  cname=$(pct config "$v" 2>/dev/null | awk -F': ' '/^hostname/{print $2; exit}')
  [ -n "$cname" ] || cname='-'

  if ! pct status "$v" >/dev/null 2>&1; then
    say "== CT $v skipped (stopped) =="
    sum_row "$v" "$cname" '-' '-' '-' '-' 'skipped (stopped)'
    continue
  fi
  say "== CT $v =="

  found=$(pct exec "$v" -- bash -c "$DETECT")

  if [ -z "$found" ]; then
    say "   error: pct exec returned nothing (CT unreachable?)"
    sum_row "$v" "$cname" '-' '-' '-' '-' 'error'
    continue
  fi

  if [ "$found" = "NONE" ]; then
    say "   nothing to clean (no pnpm/npm/uv/apt-get found)"
    sum_row "$v" "$cname" 'none' '-' '-' '-' 'nothing to clean'
    continue
  fi
  say "   found: $found"

  usage=$(df_used "$v")
  if [ -z "$usage" ]; then
    say "   error: could not read df -Pk /"
    sum_row "$v" "$cname" "$found" '-' '-' '-' 'error'
    continue
  fi
  b_pct=${usage%% *}
  b_kb=${usage##* }

  if [ $DRY -eq 1 ]; then
    say "   (dry) would prune; currently used: $b_pct"
    sum_row "$v" "$cname" "$found" "$b_pct" '-' '-' 'dry-run'
    continue
  fi

  # Swallow whatever the cleanup prints by default, but the status is only ever
  # logged, never acted on: a package manager returning non-zero for its own
  # reasons must not turn an otherwise-fine CT into an `error` row. The row's
  # health comes from the df read either side, as before.
  cleanup_rc=0
  if [ "$VERBOSE" -eq 1 ]; then
    cleanup_ct "$v" || cleanup_rc=$?
  else
    cleanup_ct "$v" >/dev/null 2>&1 || cleanup_rc=$?
  fi
  [ "$cleanup_rc" -eq 0 ] || say "   (pct exec exited $cleanup_rc; ignoring)"

  usage=$(df_used "$v")
  if [ -z "$usage" ]; then
    say "   used: $b_pct -> ?"
    sum_row "$v" "$cname" "$found" "$b_pct" '-' '-' 'error'
    continue
  fi
  a_pct=${usage%% *}
  a_kb=${usage##* }
  say "   used: $b_pct -> $a_pct"

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

# Column widths, measured from the header AND every cell, so a long CT name or a
# long tool list can never run into its neighbour and every rule ends up the same
# length. Seeded at the header lengths so an empty table still renders.
ctid_w=4; name_w=4; found_w=5; before_w=6; after_w=5; freed_w=5; status_w=6
for i in "${!SUM_CTID[@]}"; do
  [ "${#SUM_CTID[i]}"   -gt "$ctid_w" ]   && ctid_w="${#SUM_CTID[i]}"
  [ "${#SUM_NAME[i]}"   -gt "$name_w" ]   && name_w="${#SUM_NAME[i]}"
  [ "${#SUM_FOUND[i]}"  -gt "$found_w" ]  && found_w="${#SUM_FOUND[i]}"
  [ "${#SUM_BEFORE[i]}" -gt "$before_w" ] && before_w="${#SUM_BEFORE[i]}"
  [ "${#SUM_AFTER[i]}"  -gt "$after_w" ]  && after_w="${#SUM_AFTER[i]}"
  [ "${#SUM_FREED[i]}"  -gt "$freed_w" ]  && freed_w="${#SUM_FREED[i]}"
  [ "${#SUM_STATUS[i]}" -gt "$status_w" ] && status_w="${#SUM_STATUS[i]}"
done

# One space of padding either side of every cell. The label-ish columns read
# left-aligned, the numeric ones right-aligned so magnitudes line up.
pad() {
  case "$2" in
    r) printf '%*s'   "$1" "$3" ;;
    *) printf '%-*s'  "$1" "$3" ;;
  esac
}

row() {
  printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
    "$(pad "$ctid_w"   l "$1")" "$(pad "$name_w"   l "$2")" \
    "$(pad "$found_w"  l "$3")" "$(pad "$before_w" r "$4")" \
    "$(pad "$after_w"  r "$5")" "$(pad "$freed_w"  r "$6")" \
    "$(pad "$status_w" l "$7")"
}

# Horizontal rule with '+' at every column junction: '=' for the heavy rules
# framing the header and the table, '-' for the light ones between data rows.
# Each segment is the column width plus its one space of padding either side,
# which is what keeps a rule exactly as wide as the rows it separates.
rule() {
  local fill='-' seg line='+' w
  [ "$1" = heavy ] && fill='='
  for w in "$ctid_w" "$name_w" "$found_w" "$before_w" "$after_w" "$freed_w" "$status_w"; do
    seg=$(printf "%$(( w + 2 ))s" '')
    line="$line${seg// /$fill}+"
  done
  printf '%s\n' "$line"
}

# Wipe the progress line before the table, so the final screen is clean.
progress_clear

echo
if [ $DRY -eq 1 ]; then
  echo "Summary (dry run — no changes made)"
else
  echo "Summary"
fi
rule heavy
row CTID Name Found Before After Freed Status
rule heavy
n=${#SUM_CTID[@]}
i=0
while [ "$i" -lt "$n" ]; do
  row "${SUM_CTID[i]}" "${SUM_NAME[i]}" "${SUM_FOUND[i]}" "${SUM_BEFORE[i]}" \
      "${SUM_AFTER[i]}" "${SUM_FREED[i]}" "${SUM_STATUS[i]}"
  i=$(( i + 1 ))
  [ "$i" -lt "$n" ] && rule light
done
rule heavy

elapsed=$(( SECONDS - T0 ))
if [ $DRY -eq 1 ]; then
  printf 'Elapsed: %dm %ds\n' "$(( elapsed / 60 ))" "$(( elapsed % 60 ))"
else
  printf 'Total reclaimed: %s across %d CTs   Elapsed: %dm %ds\n' \
    "$(human_kb "$TOTAL_FREED_KB")" "${#SUM_CTID[@]}" \
    "$(( elapsed / 60 ))" "$(( elapsed % 60 ))"
fi

