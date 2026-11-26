#!/usr/bin/env bash
#
# update-hawser.sh — Auto-discover and update Docker-based Hawser agents across
# all running Proxmox VE LXC containers.
#
# Run on the PVE HOST as root, or invoked straight from GitHub raw:
#
#   dry run:   bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/ProxmoxVE/update-hawser.sh)" _ --dry
#   real run:  bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/ProxmoxVE/update-hawser.sh)"
#   targeted:  bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/ProxmoxVE/update-hawser.sh)" _ --ct=101,102 --verbose
#
# Options (in any order, all optional):
#   --dry, -n          Check upstream release and per-CT versions only; make no changes
#   --verbose, -v      Stream per-CT inspection, pull, recreate, and health-check logs
#   --force, -f        Recreate and re-pull even if installed version matches upstream
#   --ct=ID[,ID...]    Limit scan to specific comma-separated CT IDs (repeatable)
#   --no-prune         Keep the hawser-rollback:<old_ver> image tag after success
#   -h, --help         Show this help message
#
# The leading "_" is a throwaway $0 so the options land in $1 when invoked via bash -c.
#
# Behavior & Safety:
#   - Scans every CT from `pct list` (unless --ct is given); stopped CTs and CTs
#     without Docker or Hawser are reported cleanly and skipped.
#   - Skips containers pinned to non-:latest image tags (e.g. :0.2.53 or @sha256:...)
#     so intentional version pins are never silently overwritten.
#   - Supports both Compose-managed deployments (when a compose file exists on disk)
#     and standalone/direct Docker containers (reconstructing network, binds, ports,
#     restart policy, and env via a temporary chmod 600 --env-file; secrets like
#     TOKEN are never echoed or passed on command lines).
#   - Tags the previous image as hawser-rollback:<old_ver> before recreating, waits
#     for Docker healthcheck + /_hawser/health (connected=true), automatically rolls
#     back on failure, and prunes the rollback tag once healthy (unless --no-prune).
#
set -uo pipefail

DRY=0
VERBOSE=0
FORCE=0
PRUNE=1
CT_FILTER_RAW=""

usage() {
  cat <<'EOF'
usage: update-hawser.sh [--dry] [--verbose] [--force] [--ct=ID[,ID...]] [--no-prune]
  --dry, -n          report only, change nothing
  --verbose, -v      stream per-CT detail while running
  --force, -f        recreate even when installed version matches upstream
  --ct=ID[,ID...]    limit scan to specific comma-separated CT IDs (repeatable)
  --no-prune         keep hawser-rollback:<old_ver> image after verification
  -h, --help         show this help message
EOF
}

if [ $# -gt 0 ] && [ "$1" = "_" ]; then
  shift
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --dry|-n)      DRY=1; shift ;;
    --verbose|-v)  VERBOSE=1; shift ;;
    --force|-f)    FORCE=1; shift ;;
    --no-prune)    PRUNE=0; shift ;;
    --ct=*)
      val="${1#--ct=}"
      [ -n "$val" ] || { echo "update-hawser.sh: --ct requires an ID list" >&2; exit 2; }
      CT_FILTER_RAW="${CT_FILTER_RAW:+$CT_FILTER_RAW,}$val"
      shift
      ;;
    --ct)
      if [ $# -lt 2 ] || [ -z "${2:-}" ]; then
        echo "update-hawser.sh: --ct requires an ID list" >&2
        exit 2
      fi
      CT_FILTER_RAW="${CT_FILTER_RAW:+$CT_FILTER_RAW,}$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "update-hawser.sh: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v pct >/dev/null 2>&1; then
  echo "update-hawser.sh: 'pct' not found — run this script on the Proxmox VE host as root." >&2
  exit 1
fi

declare -A CT_FILTER_MAP=()
declare -a CT_FILTER_ORDER=()
if [ -n "$CT_FILTER_RAW" ]; then
  IFS=',' read -ra _ct_parts <<< "$CT_FILTER_RAW"
  for _id in "${_ct_parts[@]}"; do
    _id="${_id//[[:space:]]/}"
    if ! printf '%s' "$_id" | grep -Eq '^[0-9]+$'; then
      echo "update-hawser.sh: invalid CT ID in --ct: '$_id'" >&2
      exit 2
    fi
    if [ -z "${CT_FILTER_MAP[$_id]+x}" ]; then
      CT_FILTER_MAP["$_id"]=1
      CT_FILTER_ORDER+=("$_id")
    fi
  done
fi

if [ -t 1 ]; then
  tput clear 2>/dev/null || clear 2>/dev/null || printf '\033[H\033[2J'
  printf '\033[3J'
fi

NOW=$(date '+%Y-%m-%d %H:%M:%S')
FLAGS=''
[ "$FORCE" -eq 1 ] && FLAGS="$FLAGS --force"
[ "$PRUNE" -eq 0 ] && FLAGS="$FLAGS --no-prune"
[ -n "$CT_FILTER_RAW" ] && FLAGS="$FLAGS --ct=$CT_FILTER_RAW"
[ "$VERBOSE" -eq 1 ] && FLAGS="$FLAGS --verbose"

if [ "$DRY" -eq 1 ]; then
  printf '=== Hawser agent update (DRY RUN — nothing will be changed)%s — %s ===\n\n' "$FLAGS" "$NOW"
else
  printf '=== Hawser agent update%s — %s ===\n\n' "$FLAGS" "$NOW"
fi

say() { [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$*"; return 0; }

PROGRESS=0
[ -t 1 ] && [ "$VERBOSE" -eq 0 ] && PROGRESS=1
progress() { [ "$PROGRESS" -eq 1 ] && printf '\r\033[KChecking CT %s (%d/%d)...' "$1" "$2" "$3"; return 0; }
progress_clear() { [ "$PROGRESS" -eq 1 ] && printf '\r\033[K'; return 0; }

# ---- Query upstream latest release once on PVE host ----
get_upstream_version() {
  local tag="" api_json="" eff_url=""
  if command -v curl >/dev/null 2>&1; then
    api_json=$(curl -fsSL --max-time 15 "https://api.github.com/repos/Finsys/hawser/releases/latest" 2>/dev/null || true)
    if [ -n "$api_json" ]; then
      if command -v jq >/dev/null 2>&1; then
        tag=$(printf '%s' "$api_json" | jq -r '.tag_name // empty' 2>/dev/null || true)
      else
        tag=$(printf '%s' "$api_json" | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | sed -E 's/.*"([^"]+)"$/\1/' || true)
      fi
    fi
    if [ -z "$tag" ]; then
      eff_url=$(curl -fsSLI --max-time 15 -o /dev/null -w '%{url_effective}' "https://github.com/Finsys/hawser/releases/latest" 2>/dev/null || true)
      case "$eff_url" in
        */tag/*) tag="${eff_url##*/tag/}" ;;
      esac
    fi
  fi
  tag="${tag#v}"
  printf '%s' "$tag"
}

UPSTREAM_VER=$(get_upstream_version)
if [ -z "$UPSTREAM_VER" ]; then
  echo "update-hawser.sh: failed to resolve latest Finsys/hawser release from GitHub." >&2
  exit 1
fi
say "Upstream latest release: $UPSTREAM_VER"

# ---- Build CT list from pct list ----
declare -A PCT_STATUS_MAP=()
declare -a ALL_CTIDS=()
while read -r vid vstatus _rest; do
  [ -n "$vid" ] || continue
  PCT_STATUS_MAP["$vid"]="$vstatus"
  ALL_CTIDS+=("$vid")
done < <(pct list 2>/dev/null | awk 'NR>1{print $1, $2}')

declare -a TARGET_CTS=()
if [ "${#CT_FILTER_ORDER[@]}" -gt 0 ]; then
  TARGET_CTS=("${CT_FILTER_ORDER[@]}")
else
  TARGET_CTS=("${ALL_CTIDS[@]}")
fi

if [ "${#TARGET_CTS[@]}" -eq 0 ]; then
  echo "No CTs found (or 'pct list' failed)."
  exit 0
fi

# ---- Remote in-CT probe (read-only) ----
probe_ct_hawser() {
  pct exec "$1" -- sh -s <<'REMOTE'
set -u
if ! command -v docker >/dev/null 2>&1; then
  echo "STATE=no_docker"
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  echo "STATE=docker_unhealthy"
  exit 0
fi

# Find Hawser container(s): exact name "hawser" or image matching "(^|/)hawser(:|@|$)"
match=$(docker ps -a --format '{{.Names}}|{{.Image}}|{{.State}}' | awk -F'|' '
  $1 == "hawser" || $2 ~ /(^|\/)hawser(:|@|$)/ { print; exit }
')

if [ -z "$match" ]; then
  echo "STATE=no_hawser"
  exit 0
fi

cname="${match%%|*}"
rest="${match#*|}"
cimage="${rest%%|*}"
cstate="${rest#*|}"

# Check image pin state
pinned=0
pin_tag=""
case "$cimage" in
  *@*)
    pinned=1
    pin_tag="digest"
    ;;
  *)
    last_part="${cimage##*/}"
    case "$last_part" in
      *:*)
        tag="${last_part#*:}"
        if [ "$tag" != "latest" ]; then
          pinned=1
          pin_tag="$tag"
        fi
        ;;
    esac
    ;;
esac

# Detect compose file on disk
mode="direct"
compose_file=""
lbl_files=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$cname" 2>/dev/null || true)
if [ -n "$lbl_files" ]; then
  OLD_IFS="$IFS"
  IFS=','
  for f in $lbl_files; do
    if [ -f "$f" ]; then
      compose_file="$f"
      mode="compose"
      break
    fi
  done
  IFS="$OLD_IFS"
fi

if [ -z "$compose_file" ]; then
  for cand in \
    /root/compose/hawser/docker-compose.yml \
    /root/compose/hawser/docker-compose.yaml \
    /root/compose/hawser/compose.yml \
    /root/compose/hawser/compose.yaml; do
    if [ -f "$cand" ]; then
      compose_file="$cand"
      mode="compose"
      break
    fi
  done
fi

# Detect installed version
ver=""
if [ "$cstate" = "running" ]; then
  ver=$(docker exec "$cname" /usr/local/bin/hawser --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?' | head -n1 || true)
fi
if [ -z "$ver" ]; then
  ver=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$cname" 2>/dev/null || true)
fi
[ -n "$ver" ] || ver="unknown"

# Detect current health
health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cname" 2>/dev/null || true)
[ -n "$health" ] || health="unknown"

echo "STATE=found"
echo "CNAME=$cname"
echo "CIMAGE=$cimage"
echo "CSTATE=$cstate"
echo "MODE=$mode"
echo "COMPOSE_FILE=$compose_file"
echo "PINNED=$pinned"
echo "PIN_TAG=$pin_tag"
echo "VERSION=$ver"
echo "HEALTH=$health"
REMOTE
}

# ---- Remote in-CT update + health check + automatic rollback ----
update_ct_hawser() {
  local vmid="$1" cname="$2" cimage="$3" mode="$4" compose_file="$5" old_ver="$6" target_ver="$7" prune="$8" force="$9"
  pct exec "$vmid" -- sh -s -- "$cname" "$cimage" "$mode" "$compose_file" "$old_ver" "$target_ver" "$prune" "$force" <<'REMOTE'
set -u

CNAME="$1"
CIMAGE="$2"
MODE="$3"
COMPOSE_FILE="$4"
OLD_VER="$5"
TARGET_VER="$6"
PRUNE="$7"
FORCE="$8"

TMP_ENV=""
cleanup_tmp() {
  [ -n "$TMP_ENV" ] && rm -f "$TMP_ENV"
}
trap cleanup_tmp EXIT

OLD_IMAGE_ID=$(docker inspect -f '{{.Image}}' "$CNAME" 2>/dev/null || true)
if [ -z "$OLD_IMAGE_ID" ]; then
  echo "RESULT=error"
  echo "DETAIL=could not inspect current image ID"
  exit 1
fi

SAFE_VER=$(printf '%s' "${OLD_VER:-prev}" | tr -cd 'A-Za-z0-9._-')
[ -n "$SAFE_VER" ] || SAFE_VER="prev"
ROLLBACK_TAG="hawser-rollback:${SAFE_VER}"

# Capture runtime parameters before touching the container (needed for direct recreate and fallback rollback)
NET_MODE=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$CNAME" 2>/dev/null || true)
RESTART_NAME=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$CNAME" 2>/dev/null || true)
RESTART_MAX=$(docker inspect -f '{{.HostConfig.RestartPolicy.MaximumRetryCount}}' "$CNAME" 2>/dev/null || true)
PRIVILEGED=$(docker inspect -f '{{.HostConfig.Privileged}}' "$CNAME" 2>/dev/null || true)
HAS_COMPOSE_LBL=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$CNAME" 2>/dev/null || true)
BINDS_LIST=$(docker inspect -f '{{range .HostConfig.Binds}}{{println .}}{{end}}' "$CNAME" 2>/dev/null || true)
HOSTS_LIST=$(docker inspect -f '{{range .HostConfig.ExtraHosts}}{{println .}}{{end}}' "$CNAME" 2>/dev/null || true)
PORTS_LIST=$(docker inspect -f '{{range $p, $conf := .HostConfig.PortBindings}}{{range $conf}}{{if .HostIp}}{{.HostIp}}:{{end}}{{if .HostPort}}{{.HostPort}}:{{end}}{{$p}}{{println ""}}{{end}}{{end}}' "$CNAME" 2>/dev/null || true)

TMP_ENV=$(mktemp /tmp/hawser-env.XXXXXX)
chmod 600 "$TMP_ENV"
docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$CNAME" 2>/dev/null | grep -v '^PATH=' > "$TMP_ENV" || true

if ! docker tag "$OLD_IMAGE_ID" "$ROLLBACK_TAG" >/dev/null 2>&1; then
  echo "RESULT=error"
  echo "DETAIL=failed to tag rollback image"
  exit 1
fi

# Helper: start container directly from captured inspect metadata
run_direct_container() {
  local img_ref="$1"
  set -- -d --name "$CNAME"

  if [ -n "$RESTART_NAME" ] && [ "$RESTART_NAME" != "no" ]; then
    if [ "$RESTART_NAME" = "on-failure" ] && [ "${RESTART_MAX:-0}" -gt 0 ] 2>/dev/null; then
      set -- "$@" --restart "on-failure:${RESTART_MAX}"
    else
      set -- "$@" --restart "$RESTART_NAME"
    fi
  fi

  if [ -n "$NET_MODE" ] && [ "$NET_MODE" != "default" ]; then
    set -- "$@" --network "$NET_MODE"
  fi

  if [ "$PRIVILEGED" = "true" ]; then
    set -- "$@" --privileged
  fi

  while IFS= read -r b; do
    [ -n "$b" ] && set -- "$@" -v "$b"
  done <<EOF_BINDS
$BINDS_LIST
EOF_BINDS

  while IFS= read -r h; do
    [ -n "$h" ] && set -- "$@" --add-host "$h"
  done <<EOF_HOSTS
$HOSTS_LIST
EOF_HOSTS

  while IFS= read -r p; do
    [ -n "$p" ] && set -- "$@" -p "$p"
  done <<EOF_PORTS
$PORTS_LIST
EOF_PORTS

  if [ -s "$TMP_ENV" ]; then
    set -- "$@" --env-file "$TMP_ENV"
  fi

  docker run "$@" "$img_ref" >/dev/null
}

# Step 1: Validate compose config (if compose) and pull new image
if [ "$MODE" = "compose" ]; then
  if ! docker compose -f "$COMPOSE_FILE" config --quiet 2>&1; then
    docker rmi "$ROLLBACK_TAG" >/dev/null 2>&1 || true
    echo "RESULT=error"
    echo "DETAIL=compose config validation failed"
    exit 1
  fi
  if ! docker compose -f "$COMPOSE_FILE" pull 2>&1; then
    docker rmi "$ROLLBACK_TAG" >/dev/null 2>&1 || true
    echo "RESULT=error"
    echo "DETAIL=docker compose pull failed"
    exit 1
  fi
else
  if ! docker pull "$CIMAGE" 2>&1; then
    docker rmi "$ROLLBACK_TAG" >/dev/null 2>&1 || true
    echo "RESULT=error"
    echo "DETAIL=docker pull failed"
    exit 1
  fi
fi

NEW_IMAGE_ID=$(docker image inspect -f '{{.Id}}' "$CIMAGE" 2>/dev/null || true)
if [ -n "$NEW_IMAGE_ID" ] && [ "$NEW_IMAGE_ID" = "$OLD_IMAGE_ID" ] && [ "$FORCE" -eq 0 ]; then
  docker rmi "$ROLLBACK_TAG" >/dev/null 2>&1 || true
  echo "RESULT=unchanged"
  echo "VERSION=$OLD_VER"
  echo "HEALTH=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CNAME" 2>/dev/null || echo unknown)"
  exit 0
fi

# Rollback helper (only invoked after old container was stopped/removed)
do_rollback() {
  local reason="$1"
  docker stop "$CNAME" >/dev/null 2>&1 || true
  docker rm "$CNAME" >/dev/null 2>&1 || true
  docker tag "$ROLLBACK_TAG" "$CIMAGE" >/dev/null 2>&1 || true
  if [ "$MODE" = "compose" ]; then
    docker compose -f "$COMPOSE_FILE" up -d >/dev/null 2>&1 || run_direct_container "$CIMAGE" >/dev/null 2>&1 || true
  else
    run_direct_container "$CIMAGE" >/dev/null 2>&1 || true
  fi
  docker rmi "$ROLLBACK_TAG" >/dev/null 2>&1 || true
  echo "RESULT=rolled-back"
  echo "DETAIL=$reason"
  exit 1
}

# Step 2: Recreate container
if [ "$MODE" = "compose" ]; then
  if [ -n "$HAS_COMPOSE_LBL" ]; then
    if ! docker compose -f "$COMPOSE_FILE" up -d --force-recreate 2>&1; then
      do_rollback "docker compose up failed"
    fi
  else
    docker stop "$CNAME" >/dev/null 2>&1 || true
    docker rm "$CNAME" >/dev/null 2>&1 || true
    if ! docker compose -f "$COMPOSE_FILE" up -d 2>&1; then
      do_rollback "docker compose up failed"
    fi
  fi
else
  docker stop "$CNAME" >/dev/null 2>&1 || true
  docker rm "$CNAME" >/dev/null 2>&1 || true
  if ! run_direct_container "$CIMAGE" 2>&1; then
    do_rollback "docker run failed"
  fi
fi

# Step 3: Wait for container healthcheck + Hawser connected=true
health=""
i=0
while [ "$i" -lt 25 ]; do
  cstatus=$(docker inspect -f '{{.State.Status}}' "$CNAME" 2>/dev/null || echo "missing")
  if [ "$cstatus" != "running" ]; then
    do_rollback "container exited with status: $cstatus"
  fi
  has_hc=$(docker inspect -f '{{if .State.Health}}yes{{end}}' "$CNAME" 2>/dev/null || true)
  if [ "$has_hc" = "yes" ]; then
    health=$(docker inspect -f '{{.State.Health.Status}}' "$CNAME" 2>/dev/null || echo "starting")
    if [ "$health" = "healthy" ]; then
      break
    fi
    if [ "$health" = "unhealthy" ]; then
      do_rollback "container became unhealthy"
    fi
  else
    health="running"
    break
  fi
  sleep 2
  i=$(( i + 1 ))
done

if [ "$health" != "healthy" ] && [ "$health" != "running" ]; then
  do_rollback "healthcheck timed out (last=$health)"
fi

# Verify /_hawser/health connected=true (try edge health endpoint)
hc_json=$(docker exec "$CNAME" sh -c '
  p="${PORT:-2376}"
  if [ -n "${TLS_CERT:-}" ]; then
    wget -qO- --no-check-certificate "https://localhost:${p}/_hawser/health" 2>/dev/null
  else
    wget -qO- "http://localhost:${p}/_hawser/health" 2>/dev/null
  fi
' 2>/dev/null || true)

if [ -n "$hc_json" ] && ! printf '%s' "$hc_json" | grep -q '"connected":true'; then
  do_rollback "hawser health endpoint did not report connected:true"
fi

after_ver=$(docker exec "$CNAME" /usr/local/bin/hawser --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?' | head -n1 || true)
[ -n "$after_ver" ] || after_ver=$(docker inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$CNAME" 2>/dev/null || echo "unknown")

if [ "$TARGET_VER" != "unknown" ] && [ "$after_ver" != "$TARGET_VER" ] && [ "$FORCE" -eq 0 ]; then
  do_rollback "post-update version mismatch (got=$after_ver expected=$TARGET_VER)"
fi

# Step 4: Prune rollback tag (and unreferenced previous image layers) if requested
if [ "$PRUNE" -eq 1 ]; then
  docker rmi "$ROLLBACK_TAG" >/dev/null 2>&1 || true
fi

echo "RESULT=updated"
echo "VERSION=$after_ver"
echo "HEALTH=$health"
REMOTE
}

# ---- Summary table helpers ----
SUM_CTID=(); SUM_NAME=(); SUM_MODE=(); SUM_BEFORE=(); SUM_AFTER=(); SUM_HEALTH=(); SUM_STATUS=()
sum_row() {
  SUM_CTID+=("$1"); SUM_NAME+=("$2"); SUM_MODE+=("$3"); SUM_BEFORE+=("$4")
  SUM_AFTER+=("$5"); SUM_HEALTH+=("$6"); SUM_STATUS+=("$7")
}

CNT_UPDATED=0
CNT_UPTODATE=0
CNT_SKIPPED=0
CNT_ERRORS=0
T0=$SECONDS
NCT=${#TARGET_CTS[@]}
IDX=0

for v in "${TARGET_CTS[@]}"; do
  IDX=$(( IDX + 1 ))
  progress "$v" "$IDX" "$NCT"

  if [ -z "${PCT_STATUS_MAP[$v]+x}" ]; then
    say "== CT $v not found =="
    sum_row "$v" '-' '-' '-' '-' '-' 'not found'
    CNT_ERRORS=$(( CNT_ERRORS + 1 ))
    continue
  fi

  cname=$(pct config "$v" 2>/dev/null | awk -F': ' '/^hostname/{print $2; exit}')
  [ -n "$cname" ] || cname='-'

  if [ "${PCT_STATUS_MAP[$v]}" != "running" ]; then
    say "== CT $v ($cname) skipped (${PCT_STATUS_MAP[$v]}) =="
    sum_row "$v" "$cname" '-' '-' '-' '-' "skipped (${PCT_STATUS_MAP[$v]})"
    CNT_SKIPPED=$(( CNT_SKIPPED + 1 ))
    continue
  fi

  say "== CT $v ($cname) =="
  probe_out=$(probe_ct_hawser "$v" 2>/dev/null)
  probe_rc=$?
  if [ "$probe_rc" -ne 0 ] || [ -z "$probe_out" ]; then
    say "   error: pct exec probe failed"
    sum_row "$v" "$cname" '-' '-' '-' '-' 'error'
    CNT_ERRORS=$(( CNT_ERRORS + 1 ))
    continue
  fi

  p_state=""; p_cname=""; p_cimage=""; p_cstate=""; p_mode=""; p_compose=""
  p_pinned=0; p_pin_tag=""; p_ver="-"; p_health="-"
  while IFS='=' read -r k val; do
    case "$k" in
      STATE)        p_state="$val" ;;
      CNAME)        p_cname="$val" ;;
      CIMAGE)       p_cimage="$val" ;;
      CSTATE)       p_cstate="$val" ;;
      MODE)         p_mode="$val" ;;
      COMPOSE_FILE) p_compose="$val" ;;
      PINNED)       p_pinned="$val" ;;
      PIN_TAG)      p_pin_tag="$val" ;;
      VERSION)      p_ver="$val" ;;
      HEALTH)       p_health="$val" ;;
    esac
  done <<< "$probe_out"

  case "$p_state" in
    no_docker)
      say "   no docker installed"
      sum_row "$v" "$cname" '-' '-' '-' '-' 'no docker'
      CNT_SKIPPED=$(( CNT_SKIPPED + 1 ))
      continue
      ;;
    docker_unhealthy)
      say "   error: docker daemon unreachable"
      sum_row "$v" "$cname" '-' '-' '-' '-' 'error (docker)'
      CNT_ERRORS=$(( CNT_ERRORS + 1 ))
      continue
      ;;
    no_hawser)
      say "   no hawser container found"
      sum_row "$v" "$cname" '-' '-' '-' '-' 'no hawser'
      CNT_SKIPPED=$(( CNT_SKIPPED + 1 ))
      continue
      ;;
    found) ;;
    *)
      say "   error: unexpected probe output"
      sum_row "$v" "$cname" '-' '-' '-' '-' 'error'
      CNT_ERRORS=$(( CNT_ERRORS + 1 ))
      continue
      ;;
  esac

  say "   container=$p_cname image=$p_cimage mode=$p_mode${p_compose:+ ($p_compose)} version=$p_ver health=$p_health"

  if [ "$p_pinned" -eq 1 ]; then
    say "   skipped: pinned to $p_pin_tag"
    sum_row "$v" "$cname" "$p_mode" "$p_ver" '-' "$p_health" "skipped (pinned:$p_pin_tag)"
    CNT_SKIPPED=$(( CNT_SKIPPED + 1 ))
    continue
  fi

  if [ "$p_ver" = "$UPSTREAM_VER" ] && [ "$FORCE" -eq 0 ]; then
    say "   up-to-date ($p_ver)"
    sum_row "$v" "$cname" "$p_mode" "$p_ver" "$p_ver" "$p_health" 'up-to-date'
    CNT_UPTODATE=$(( CNT_UPTODATE + 1 ))
    continue
  fi

  if [ "$DRY" -eq 1 ]; then
    if [ "$p_ver" = "$UPSTREAM_VER" ]; then
      say "   (dry) would force-recreate ($p_ver)"
      sum_row "$v" "$cname" "$p_mode" "$p_ver" "$UPSTREAM_VER" "$p_health" 'would-recreate'
    else
      say "   (dry) needs update: $p_ver -> $UPSTREAM_VER"
      sum_row "$v" "$cname" "$p_mode" "$p_ver" "$UPSTREAM_VER" "$p_health" 'needs-update'
    fi
    continue
  fi

  # Real update
  [ "$PROGRESS" -eq 1 ] && printf '\r\033[KUpdating CT %s (%d/%d)...' "$v" "$IDX" "$NCT"
  upd_out=""
  upd_rc=0
  upd_out=$(update_ct_hawser "$v" "$p_cname" "$p_cimage" "$p_mode" "$p_compose" "$p_ver" "$UPSTREAM_VER" "$PRUNE" "$FORCE" 2>&1) || upd_rc=$?
  [ "$VERBOSE" -eq 1 ] && printf '%s\n' "$upd_out" | sed 's/^/   /'

  u_result=""; u_ver=""; u_health=""; u_detail=""
  while IFS='=' read -r k val; do
    case "$k" in
      RESULT)  u_result="$val" ;;
      VERSION) u_ver="$val" ;;
      HEALTH)  u_health="$val" ;;
      DETAIL)  u_detail="$val" ;;
    esac
  done <<< "$upd_out"

  if [ "$upd_rc" -eq 0 ] && [ "$u_result" = "updated" ]; then
    if [ "$p_ver" = "$u_ver" ] && [ "$FORCE" -eq 1 ]; then
      st="recreated"
    else
      st="updated"
    fi
    say "   $st: $p_ver -> $u_ver (health=$u_health)"
    sum_row "$v" "$cname" "$p_mode" "$p_ver" "$u_ver" "$u_health" "$st"
    CNT_UPDATED=$(( CNT_UPDATED + 1 ))
  elif [ "$upd_rc" -eq 0 ] && [ "$u_result" = "unchanged" ]; then
    say "   image digest unchanged ($u_ver)"
    sum_row "$v" "$cname" "$p_mode" "$p_ver" "$u_ver" "$u_health" 'image unchanged'
    CNT_UPTODATE=$(( CNT_UPTODATE + 1 ))
  elif [ "$u_result" = "rolled-back" ]; then
    say "   error: rolled back ($u_detail)"
    sum_row "$v" "$cname" "$p_mode" "$p_ver" "$p_ver" 'rolled-back' "error (rolled back)"
    CNT_ERRORS=$(( CNT_ERRORS + 1 ))
  else
    say "   error: ${u_detail:-update failed}"
    sum_row "$v" "$cname" "$p_mode" "$p_ver" '-' '-' 'error'
    CNT_ERRORS=$(( CNT_ERRORS + 1 ))
  fi
done

# ---- Render summary table ----
progress_clear

ctid_w=4; name_w=4; mode_w=4; before_w=6; after_w=5; health_w=6; status_w=6
for i in "${!SUM_CTID[@]}"; do
  [ "${#SUM_CTID[i]}"   -gt "$ctid_w" ]   && ctid_w="${#SUM_CTID[i]}"
  [ "${#SUM_NAME[i]}"   -gt "$name_w" ]   && name_w="${#SUM_NAME[i]}"
  [ "${#SUM_MODE[i]}"   -gt "$mode_w" ]   && mode_w="${#SUM_MODE[i]}"
  [ "${#SUM_BEFORE[i]}" -gt "$before_w" ] && before_w="${#SUM_BEFORE[i]}"
  [ "${#SUM_AFTER[i]}"  -gt "$after_w" ]  && after_w="${#SUM_AFTER[i]}"
  [ "${#SUM_HEALTH[i]}" -gt "$health_w" ] && health_w="${#SUM_HEALTH[i]}"
  [ "${#SUM_STATUS[i]}" -gt "$status_w" ] && status_w="${#SUM_STATUS[i]}"
done

pad() {
  case "$2" in
    r) printf '%*s'  "$1" "$3" ;;
    *) printf '%-*s' "$1" "$3" ;;
  esac
}

row() {
  printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
    "$(pad "$ctid_w"   l "$1")" "$(pad "$name_w"   l "$2")" \
    "$(pad "$mode_w"   l "$3")" "$(pad "$before_w" r "$4")" \
    "$(pad "$after_w"  r "$5")" "$(pad "$health_w" l "$6")" \
    "$(pad "$status_w" l "$7")"
}

rule() {
  local fill='-' seg line='+' w
  [ "$1" = heavy ] && fill='='
  for w in "$ctid_w" "$name_w" "$mode_w" "$before_w" "$after_w" "$health_w" "$status_w"; do
    seg=$(printf "%$(( w + 2 ))s" '')
    line="$line${seg// /$fill}+"
  done
  printf '%s\n' "$line"
}

echo
if [ "$DRY" -eq 1 ]; then
  echo "Summary (dry run — upstream latest: $UPSTREAM_VER, no changes made)"
else
  echo "Summary (upstream latest: $UPSTREAM_VER)"
fi
rule heavy
row CTID Name Mode Before After Health Status
rule heavy
n=${#SUM_CTID[@]}
i=0
while [ "$i" -lt "$n" ]; do
  row "${SUM_CTID[i]}" "${SUM_NAME[i]}" "${SUM_MODE[i]}" "${SUM_BEFORE[i]}" \
      "${SUM_AFTER[i]}" "${SUM_HEALTH[i]}" "${SUM_STATUS[i]}"
  i=$(( i + 1 ))
  [ "$i" -lt "$n" ] && rule light
done
rule heavy

elapsed=$(( SECONDS - T0 ))
printf 'Updated: %d   Up-to-date: %d   Skipped: %d   Errors: %d   Elapsed: %dm %ds\n' \
  "$CNT_UPDATED" "$CNT_UPTODATE" "$CNT_SKIPPED" "$CNT_ERRORS" \
  "$(( elapsed / 60 ))" "$(( elapsed % 60 ))"

[ "$CNT_ERRORS" -eq 0 ] || exit 1
