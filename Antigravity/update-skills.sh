#!/usr/bin/env bash
#
# update-skills.sh — Check for updates to git-cloned agent skills, pull latest
# releases, sync skills into Antigravity, and update Supermemory.
#
# Run inside CT 103 (Antigravity guest) as root, or invoked straight from GitHub raw:
#
#   dry run:  bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/Antigravity/update-skills.sh)" _ --dry
#   real run: bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/Antigravity/update-skills.sh)"
#   force:    bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/Antigravity/update-skills.sh)" _ --force
#
# Options (in any order, all optional):
#   --dry, -n          Report available updates without pulling or copying files
#   --verbose, -v      Stream git fetch/pull commands and detailed output
#   --force, -f        Force reinstall/resync all skills even if git is up to date
#   --no-supermemory   Skip updating Supermemory memory after successful sync
#   --repos-dir=DIR    Override directory containing cloned repos (default: /root/antigravity)
#   --dest-dir=DIR     Override destination skills directory (default: ~/.gemini/config/skills)
#   --help, -h         Show this help message
#
# The leading "_" is a throwaway $0 so the options land in $1 when invoked via bash -c.
#
# Features:
#   - Auto-discovers git repositories in /root/antigravity (e.g. artcraft-skills, rust-skills)
#   - Detects remote updates via `git fetch origin`
#   - Fast-forwards tracking branch (`git pull --ff-only`)
#   - Auto-discovers all `SKILL.md` folders and safely syncs them into Antigravity
#   - Automatically updates Supermemory homelab namespace (repo_root__de0b3628254df1e4)
#     with new version tags and installed skill sets
#   - Renders a clean ASCII summary table with dynamic column sizing
#
set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults and Option Parsing
# -----------------------------------------------------------------------------
DRY_RUN=false
VERBOSE=false
FORCE=false
UPDATE_SUPERMEMORY=true
REPOS_DIR="/root/antigravity"
DEST_DIR="${HOME:-/root}/.gemini/config/skills"
SUPERMEMORY_NS="repo_root__de0b3628254df1e4"

usage() {
  cat <<'EOF'
Usage: update-skills.sh [OPTIONS]

Options:
  --dry, -n           Check and report updates only; make no changes
  --verbose, -v       Show detailed git output and sync actions
  --force, -f         Force resync skills into destination even if up to date
  --no-supermemory    Skip updating Supermemory even if skills are updated
  --repos-dir=PATH    Directory containing skill repos (default: /root/antigravity)
  --dest-dir=PATH     Target skills directory (default: ~/.gemini/config/skills)
  -h, --help          Show this help message
EOF
  exit 0
}

# Handle leading throwaway $0 if present
if [ $# -gt 0 ] && [ "$1" = "_" ]; then
  shift
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --dry|-n)
      DRY_RUN=true
      shift
      ;;
    --verbose|-v)
      VERBOSE=true
      shift
      ;;
    --force|-f)
      FORCE=true
      shift
      ;;
    --no-supermemory)
      UPDATE_SUPERMEMORY=false
      shift
      ;;
    --repos-dir=*)
      REPOS_DIR="${1#*=}"
      shift
      ;;
    --dest-dir=*)
      DEST_DIR="${1#*=}"
      shift
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Terminal Presentation
# -----------------------------------------------------------------------------
START_TIME=$(date +%s)
TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

if [ -t 1 ]; then
  clear 2>/dev/null || true
fi

if [ "$DRY_RUN" = true ]; then
  echo "=== Antigravity Skills Update (DRY RUN) — $TIMESTAMP ==="
else
  echo "=== Antigravity Skills Update — $TIMESTAMP ==="
fi
echo ""

# -----------------------------------------------------------------------------
# Repository Processing
# -----------------------------------------------------------------------------
if [ ! -d "$REPOS_DIR" ]; then
  echo "Error: Repositories directory not found: $REPOS_DIR" >&2
  exit 1
fi

mkdir -p "$DEST_DIR"

declare -a ROWS=()
ANY_UPDATED=false
UPDATED_DETAILS=()
UPDATED_REPOS=()

for repo_path in "$REPOS_DIR"/*; do
  [ -d "$repo_path/.git" ] || continue
  repo_name=$(basename "$repo_path")

  if [ -t 1 ] && [ "$VERBOSE" = false ]; then
    printf "\r\033[KChecking %s..." "$repo_name"
  elif [ "$VERBOSE" = true ]; then
    echo "Checking repository: $repo_name..."
  fi

  # Determine current branch
  branch=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
  
  # Fetch upstream quietly unless verbose
  if [ "$VERBOSE" = true ]; then
    git -C "$repo_path" fetch origin "$branch"
  else
    git -C "$repo_path" fetch origin "$branch" --quiet 2>/dev/null || true
  fi

  upstream="origin/$branch"
  if ! git -C "$repo_path" rev-parse --verify "$upstream" >/dev/null 2>&1; then
    upstream=$(git -C "$repo_path" rev-parse --abbrev-ref '@{u}' 2>/dev/null || echo "origin/main")
  fi

  # Versions before update
  ver_before=$(git -C "$repo_path" describe --tags --abbrev=0 HEAD 2>/dev/null || git -C "$repo_path" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  ver_remote=$(git -C "$repo_path" describe --tags --abbrev=0 "$upstream" 2>/dev/null || git -C "$repo_path" rev-parse --short "$upstream" 2>/dev/null || echo "$ver_before")

  behind_count=$(git -C "$repo_path" rev-list --count "HEAD..$upstream" 2>/dev/null || echo "0")

  # Discover all skill folders in repo
  skill_dirs=()
  for skill_file in "$repo_path"/*/SKILL.md "$repo_path"/skills/*/SKILL.md; do
    [ -f "$skill_file" ] || continue
    sdir=$(dirname "$skill_file")
    sname=$(basename "$sdir")
    [ "$sname" = "skills" ] && continue
    skill_dirs+=("$sdir")
  done

  total_repo_skills=${#skill_dirs[@]}

  # Count currently installed skills
  installed_count=0
  for sdir in "${skill_dirs[@]}"; do
    sname=$(basename "$sdir")
    if [ -d "$DEST_DIR/$sname" ] || [ -L "$DEST_DIR/$sname" ]; then
      installed_count=$((installed_count + 1))
    fi
  done

  skills_synced=0
  status="up-to-date"

  if [ "$behind_count" -gt 0 ] || [ "$FORCE" = true ]; then
    if [ "$DRY_RUN" = true ]; then
      status="needs-update"
      if [ "$FORCE" = true ] && [ "$behind_count" -eq 0 ]; then
        status="forced-dry"
      fi
      report_skills="$installed_count/$total_repo_skills"
    else
      # Perform git pull
      if [ "$behind_count" -gt 0 ]; then
        if [ "$VERBOSE" = true ]; then
          git -C "$repo_path" pull --ff-only origin "$branch"
        else
          git -C "$repo_path" pull --ff-only origin "$branch" --quiet
        fi
      fi

      ver_after=$(git -C "$repo_path" describe --tags --abbrev=0 HEAD 2>/dev/null || git -C "$repo_path" rev-parse --short HEAD 2>/dev/null || echo "unknown")

      # Re-discover in case new skills were added in this release
      skill_dirs=()
      for skill_file in "$repo_path"/*/SKILL.md "$repo_path"/skills/*/SKILL.md; do
        [ -f "$skill_file" ] || continue
        sdir=$(dirname "$skill_file")
        sname=$(basename "$sdir")
        [ "$sname" = "skills" ] && continue
        skill_dirs+=("$sdir")
      done
      total_repo_skills=${#skill_dirs[@]}

      # Sync skills
      for sdir in "${skill_dirs[@]}"; do
        sname=$(basename "$sdir")
        should_sync=false

        if [ "$repo_name" = "artcraft-skills" ]; then
          should_sync=true
        elif [ -e "$DEST_DIR/$sname" ] || [ -L "$DEST_DIR/$sname" ]; then
          should_sync=true
        fi

        if [ "$should_sync" = true ]; then
          if [ -L "$DEST_DIR/$sname" ]; then
            # Preserve symlink; refresh target link without overwriting with copied folder
            ln -sfn "$sdir" "$DEST_DIR/$sname"
          else
            rm -rf "$DEST_DIR/$sname"
            cp -R "$sdir" "$DEST_DIR/$sname"
          fi
          skills_synced=$((skills_synced + 1))
          
          # Also sync to ~/.agents/skills if the folder or symlink already exists there
          if [ -L "${HOME:-/root}/.agents/skills/$sname" ]; then
            ln -sfn "$sdir" "${HOME:-/root}/.agents/skills/$sname"
          elif [ -d "${HOME:-/root}/.agents/skills/$sname" ]; then
            rm -rf "${HOME:-/root}/.agents/skills/$sname"
            cp -R "$sdir" "${HOME:-/root}/.agents/skills/$sname"
          fi
        fi
      done

      status="updated"
      if [ "$FORCE" = true ] && [ "$behind_count" -eq 0 ]; then
        status="reinstalled"
      fi

      ANY_UPDATED=true
      report_skills="$skills_synced/$total_repo_skills"
      UPDATED_DETAILS+=("$repo_name ($ver_after, $skills_synced skills)")
      UPDATED_REPOS+=("$repo_name|$repo_path|$ver_after")
    fi
  else
    # Up to date
    ver_after="$ver_before"
    report_skills="$installed_count/$total_repo_skills"
  fi

  ver_after="${ver_after:-$ver_before}"
  ROWS+=("$repo_name|$ver_before|$ver_remote|$behind_count|$report_skills|$status")
done

if [ -t 1 ] && [ "$VERBOSE" = false ]; then
  printf "\r\033[K"
fi

# -----------------------------------------------------------------------------
# Supermemory Memory Update (if updates applied)
# -----------------------------------------------------------------------------
supermemory_status="skipped"
if [ "$ANY_UPDATED" = true ] && [ "$UPDATE_SUPERMEMORY" = true ] && [ "$DRY_RUN" = false ]; then
  if command -v supermemory >/dev/null 2>&1; then
    if [ "$VERBOSE" = true ]; then
      echo "Updating Supermemory memory for namespace: $SUPERMEMORY_NS..."
    fi

    for repo_entry in "${UPDATED_REPOS[@]}"; do
      IFS='|' read -r rname rpath rver <<< "$repo_entry"

      # Find and forget older skills memories for this repo
      old_ids=$(supermemory search "skills in $rpath updated" --namespace "$SUPERMEMORY_NS" --mode memories --limit 3 --json 2>/dev/null | grep -o '"id": *"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
      if [ -z "$old_ids" ] && [ "$rname" = "artcraft-skills" ]; then
        old_ids=$(supermemory search "ArtCraft skills in $rpath updated" --namespace "$SUPERMEMORY_NS" --mode memories --limit 3 --json 2>/dev/null | grep -o '"id": *"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
      fi
      if [ -n "$old_ids" ]; then
        for mid in $old_ids; do
          supermemory forget "$mid" --namespace "$SUPERMEMORY_NS" >/dev/null 2>&1 || true
        done
      fi

      # Discover active installed skills for this repo
      repo_active=()
      for sk in "$rpath"/*/SKILL.md "$rpath"/skills/*/SKILL.md; do
        [ -f "$sk" ] || continue
        sn=$(basename "$(dirname "$sk")")
        [ "$sn" = "skills" ] && continue
        if [ -e "$DEST_DIR/$sn" ] || [ -L "$DEST_DIR/$sn" ]; then
          repo_active+=("$sn")
        fi
      done
      active_count=${#repo_active[@]}
      active_list=$(IFS=', '; echo "${repo_active[*]}")

      mem_text="Skills from $rname ($rver) updated in $rpath. Active in $DEST_DIR ($active_count skills): $active_list. Auto-updated via update-skills.sh."
      supermemory add "$mem_text" --namespace "$SUPERMEMORY_NS" --dreaming instant >/dev/null 2>&1 || true
    done

    supermemory_status="updated"
  else
    supermemory_status="cli-not-found"
  fi
fi

# -----------------------------------------------------------------------------
# Summary Table Rendering
# -----------------------------------------------------------------------------
hdr_col0="Repository"
hdr_col1="Current"
hdr_col2="Upstream"
hdr_col3="Behind"
hdr_col4="Skills"
hdr_col5="Status"

w0=${#hdr_col0}
w1=${#hdr_col1}
w2=${#hdr_col2}
w3=${#hdr_col3}
w4=${#hdr_col4}
w5=${#hdr_col5}

for row in "${ROWS[@]}"; do
  IFS='|' read -r c0 c1 c2 c3 c4 c5 <<< "$row"
  [ ${#c0} -gt $w0 ] && w0=${#c0}
  [ ${#c1} -gt $w1 ] && w1=${#c1}
  [ ${#c2} -gt $w2 ] && w2=${#c2}
  [ ${#c3} -gt $w3 ] && w3=${#c3}
  [ ${#c4} -gt $w4 ] && w4=${#c4}
  [ ${#c5} -gt $w5 ] && w5=${#c5}
done

w0=$((w0 + 2))
w1=$((w1 + 2))
w2=$((w2 + 2))
w3=$((w3 + 2))
w4=$((w4 + 2))
w5=$((w5 + 2))

make_border() {
  local char="$1"
  printf "+%s+%s+%s+%s+%s+%s+\n" \
    "$(printf "%${w0}s" "" | tr ' ' "$char")" \
    "$(printf "%${w1}s" "" | tr ' ' "$char")" \
    "$(printf "%${w2}s" "" | tr ' ' "$char")" \
    "$(printf "%${w3}s" "" | tr ' ' "$char")" \
    "$(printf "%${w4}s" "" | tr ' ' "$char")" \
    "$(printf "%${w5}s" "" | tr ' ' "$char")"
}

echo "Summary"
make_border "="
printf "| %-*s | %-*s | %-*s | %*s | %*s | %-*s |\n" \
  $((w0 - 2)) "$hdr_col0" \
  $((w1 - 2)) "$hdr_col1" \
  $((w2 - 2)) "$hdr_col2" \
  $((w3 - 2)) "$hdr_col3" \
  $((w4 - 2)) "$hdr_col4" \
  $((w5 - 2)) "$hdr_col5"
make_border "="

for row in "${ROWS[@]}"; do
  IFS='|' read -r c0 c1 c2 c3 c4 c5 <<< "$row"
  printf "| %-*s | %-*s | %-*s | %*s | %*s | %-*s |\n" \
    $((w0 - 2)) "$c0" \
    $((w1 - 2)) "$c1" \
    $((w2 - 2)) "$c2" \
    $((w3 - 2)) "$c3" \
    $((w4 - 2)) "$c4" \
    $((w5 - 2)) "$c5"
  make_border "-"
done

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
if [ "$ANY_UPDATED" = true ]; then
  echo "Result: Skills successfully updated: $(IFS='; '; echo "${UPDATED_DETAILS[*]}")"
  if [ "$UPDATE_SUPERMEMORY" = true ]; then
    echo "Supermemory: $supermemory_status (namespace: $SUPERMEMORY_NS)"
  fi
else
  if [ "$DRY_RUN" = true ]; then
    echo "Result: Dry run complete. No modifications made."
  else
    echo "Result: All repositories are already up to date."
  fi
fi
echo "Elapsed: ${ELAPSED}s"
