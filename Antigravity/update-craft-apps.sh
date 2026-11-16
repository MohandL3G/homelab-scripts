#!/usr/bin/env bash
#
# update-craft-apps.sh — Check for updates to local Craft applications in CT 103,
# download latest releases from GitHub, install via apt, and update Anchor persistent memory.
#
# Run inside CT 103 (Antigravity guest) as root, or invoked straight from GitHub raw:
#
#   dry run:  bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/Antigravity/update-craft-apps.sh)" _ --dry
#   real run: bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/Antigravity/update-craft-apps.sh)"
#   force:    bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/Antigravity/update-craft-apps.sh)" _ --force
#
# Options (in any order, all optional):
#   --dry, -n          Report available updates without downloading or installing
#   --verbose, -v      Show detailed logs during checks, downloads, and apt operations
#   --force, -f        Force download and reinstall even if versions match
#   --no-anchor        Skip updating Anchor persistent memory after successful install
#   --no-memory        Alias for --no-anchor
#   --no-supermemory   (Deprecated) Alias for --no-anchor
#   --temp-dir=DIR     Override temporary download directory (default: /tmp/craft-update)
#   --help, -h         Show this help message
#
# The leading "_" is a throwaway $0 so the options land in $1 when invoked via bash -c.
#
# Features:
#   - Manages all 6 Craft applications: photocraft, deckcraft, wordcraft, gridcraft, pdfcraft, filmcraft
#   - Queries installed version from dpkg (or fallback to <app>-cli --version)
#   - Queries upstream GitHub releases via gh CLI (or fallback to GitHub REST API)
#   - Downloads amd64 Debian package into temporary directory
#   - Installs cleanly via apt-get install with dependency resolution
#   - Verifies /usr/bin/<app>-cli --version post-install
#   - Automatically updates Anchor persistent memory note
#     ([Changelog] Homelab Events Archive) with new version tags and update summary
#   - Renders a clean ASCII summary table with dynamic column sizing
#
set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults and Option Parsing
# -----------------------------------------------------------------------------
DRY_RUN=false
VERBOSE=false
FORCE=false
UPDATE_ANCHOR=true
TEMP_DIR="/tmp/craft-update"
ANCHOR_PY="/root/home/.agents/skills/anchor/scripts/anchor.py"
ANCHOR_NOTE="[Changelog] Homelab Events Archive"
ANCHOR_NOTE_ID="fba357f4-b48f-43a9-87ac-300228e7bcba"

usage() {
  cat <<'EOF'
Usage: update-craft-apps.sh [OPTIONS]

Options:
  --dry, -n           Check and report updates only; make no changes
  --verbose, -v       Show detailed logs during checks, downloads, and apt operations
  --force, -f         Force download and reinstall even if up to date
  --no-anchor         Skip updating Anchor memory even if applications are updated
  --no-memory         Alias for --no-anchor
  --no-supermemory    (Deprecated) Alias for --no-anchor
  --temp-dir=DIR      Temporary download directory (default: /tmp/craft-update)
  -h, --help          Show this help message
EOF
  exit 0
}

# Handle leading throwaway $0 if present (e.g. bash -c "$(curl ...)" _ --dry)
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
    --no-anchor|--no-memory|--no-supermemory)
      UPDATE_ANCHOR=false
      shift
      ;;
    --temp-dir=*)
      TEMP_DIR="${1#*=}"
      shift
      ;;
    --temp-dir)
      if [ $# -gt 1 ]; then
        TEMP_DIR="$2"
        shift 2
      else
        echo "Error: --temp-dir requires a directory argument" >&2
        exit 1
      fi
      ;;
    -h|--help)
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
  echo "=== Antigravity Craft Apps Update (DRY RUN) — $TIMESTAMP ==="
else
  echo "=== Antigravity Craft Apps Update — $TIMESTAMP ==="
fi
echo ""

# -----------------------------------------------------------------------------
# Application Definitions & Helpers
# -----------------------------------------------------------------------------
APPS=(
  "photocraft:storytold/photocraft"
  "deckcraft:storytold/deckcraft"
  "wordcraft:storytold/wordcraft"
  "gridcraft:storytold/gridcraft"
  "pdfcraft:storytold/pdfcraft"
  "filmcraft:storytold/filmcraft"
)

get_installed_version() {
  local app="$1"
  local raw=""

  # 1. Query dpkg database
  raw=$(dpkg-query -W -f='${Version}' "$app" 2>/dev/null || true)
  if [ -n "$raw" ]; then
    raw="${raw#*:}" # strip epoch if present
    raw="${raw%-*}" # strip debian revision (-1, etc.)
    echo "$raw"
    return 0
  fi

  # 2. Fallback to CLI binary in PATH or /usr/bin
  local bin="${app}-cli"
  if [ -x "/usr/bin/$bin" ]; then
    raw=$(/usr/bin/"$bin" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
    if [ -n "$raw" ]; then
      echo "$raw"
      return 0
    fi
  elif command -v "$bin" >/dev/null 2>&1; then
    raw=$("$bin" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
    if [ -n "$raw" ]; then
      echo "$raw"
      return 0
    fi
  fi

  echo "none"
  return 0
}

get_upstream_release_info() {
  local app="$1"
  local repo="$2"
  local tag=""
  local asset=""
  local url=""

  # Try gh CLI first
  if command -v gh >/dev/null 2>&1; then
    tag=$(gh release view --repo "$repo" --json tagName -q .tagName 2>/dev/null || true)
    if [ -n "$tag" ]; then
      asset=$(gh release view --repo "$repo" --json assets -q '.assets[].name' 2>/dev/null | grep -E '(linux-x86_64|amd64).*\.deb$' | head -n1 || true)
    fi
  fi

  # Fallback to GitHub REST API
  if [ -z "$tag" ] || [ -z "$asset" ]; then
    if command -v curl >/dev/null 2>&1; then
      local api_json
      api_json=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null || true)
      if [ -n "$api_json" ]; then
        if [ -z "$tag" ]; then
          if command -v jq >/dev/null 2>&1; then
            tag=$(echo "$api_json" | jq -r '.tag_name // empty' 2>/dev/null || true)
          else
            tag=$(echo "$api_json" | grep -o '"tag_name": *"[^"]*"' | head -n1 | cut -d'"' -f4 || true)
          fi
        fi
        if [ -z "$asset" ] || [ -z "$url" ]; then
          if command -v jq >/dev/null 2>&1; then
            local info
            info=$(echo "$api_json" | jq -r '.assets[] | select(.name | test("(linux-x86_64|amd64).*\\.deb$")) | "\(.name)|\(.browser_download_url)"' 2>/dev/null | head -n1 || true)
            if [ -n "$info" ]; then
              asset="${info%%|*}"
              url="${info##*|}"
            fi
          fi
        fi
      fi
    fi
  fi

  tag="${tag#v}"
  [ -z "$tag" ] && tag="unknown"
  echo "$tag|$asset|$url"
}

# -----------------------------------------------------------------------------
# Update Processing
# -----------------------------------------------------------------------------
declare -a ROWS=()
ANY_UPDATED=false
ANY_ERRORS=false
UPDATED_DETAILS=()
ERROR_DETAILS=()

for app_entry in "${APPS[@]}"; do
  app="${app_entry%%:*}"
  repo="${app_entry##*:}"

  if [ -t 1 ] && [ "$VERBOSE" = false ]; then
    printf "\r\033[KChecking %s..." "$app"
  elif [ "$VERBOSE" = true ]; then
    echo "Checking application: $app ($repo)..."
  fi

  ver_installed=$(get_installed_version "$app")
  
  release_info=$(get_upstream_release_info "$app" "$repo")
  IFS='|' read -r ver_upstream deb_asset deb_url <<< "$release_info"

  if [ "$VERBOSE" = true ]; then
    echo "  Installed: $ver_installed"
    echo "  Upstream:  $ver_upstream (Asset: ${deb_asset:-none})"
  fi

  status="up-to-date"

  if [ "$ver_upstream" = "unknown" ]; then
    status="error"
    ANY_ERRORS=true
    ERROR_DETAILS+=("$app: Unable to determine upstream release")
  elif [ "$ver_installed" != "$ver_upstream" ] || [ "$FORCE" = true ]; then
    if [ "$DRY_RUN" = true ]; then
      status="needs-update"
    else
      # Real download and update
      app_temp_dir="$TEMP_DIR/$app"
      mkdir -p "$app_temp_dir"

      if [ -z "$deb_asset" ]; then
        status="error"
        ANY_ERRORS=true
        ERROR_DETAILS+=("$app: No amd64/x86_64 deb asset found in release")
      else
        deb_file="$app_temp_dir/$deb_asset"
        download_ok=false

        if [ "$VERBOSE" = true ]; then
          echo "  Downloading $deb_asset..."
        fi

        # Attempt download with gh
        if command -v gh >/dev/null 2>&1; then
          if [ "$VERBOSE" = true ]; then
            gh release download --repo "$repo" -p "$deb_asset" -D "$app_temp_dir" --clobber && download_ok=true || true
          else
            gh release download --repo "$repo" -p "$deb_asset" -D "$app_temp_dir" --clobber --quiet 2>/dev/null && download_ok=true || true
          fi
        fi

        # Fallback download with curl
        if [ "$download_ok" = false ] || [ ! -f "$deb_file" ]; then
          if [ -z "$deb_url" ] && command -v curl >/dev/null 2>&1; then
            deb_url="https://github.com/$repo/releases/download/v$ver_upstream/$deb_asset"
          fi
          if [ -n "$deb_url" ]; then
            if [ "$VERBOSE" = true ]; then
              curl -fSL -o "$deb_file" "$deb_url" && download_ok=true || true
            else
              curl -fsSL -o "$deb_file" "$deb_url" 2>/dev/null && download_ok=true || true
            fi
          fi
        fi

        if [ ! -f "$deb_file" ] || [ ! -s "$deb_file" ]; then
          status="error"
          ANY_ERRORS=true
          ERROR_DETAILS+=("$app: Failed to download $deb_asset")
          rm -rf "$app_temp_dir"
        else
          # Install using apt-get
          if [ "$VERBOSE" = true ]; then
            echo "  Installing $deb_asset via apt-get..."
          fi

          install_ok=false
          if [ "$VERBOSE" = true ]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb_file" && install_ok=true || true
          else
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$deb_file" >/dev/null 2>&1 && install_ok=true || true
          fi

          # Clean up downloaded deb
          rm -f "$deb_file"
          rmdir "$app_temp_dir" 2>/dev/null || true

          if [ "$install_ok" = false ]; then
            status="error"
            ANY_ERRORS=true
            ERROR_DETAILS+=("$app: apt-get install failed")
          else
            # Verification step
            ver_after=$(get_installed_version "$app")
            cli_ver=""
            if [ -x "/usr/bin/${app}-cli" ]; then
              cli_ver=$(/usr/bin/"${app}-cli" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)
            fi

            if [ "$ver_after" = "$ver_upstream" ] || [ "$cli_ver" = "$ver_upstream" ]; then
              if [ "$FORCE" = true ] && [ "$ver_installed" = "$ver_upstream" ]; then
                status="reinstalled"
              else
                status="updated"
              fi
              ANY_UPDATED=true
              UPDATED_DETAILS+=("$app: $ver_installed -> $ver_upstream")
            else
              status="error"
              ANY_ERRORS=true
              ERROR_DETAILS+=("$app: Verification failed (post-install: $ver_after, expected: $ver_upstream)")
            fi
          fi
        fi
      fi
    fi
  else
    status="up-to-date"
  fi

  ROWS+=("$app|$ver_installed|$ver_upstream|$status")
done

# Clean up top-level temp dir if empty
rmdir "$TEMP_DIR" 2>/dev/null || true

if [ -t 1 ] && [ "$VERBOSE" = false ]; then
  printf "\r\033[K"
fi

# -----------------------------------------------------------------------------
# Anchor Memory Update (if updates applied)
# -----------------------------------------------------------------------------
anchor_status="skipped"
if [ "$ANY_UPDATED" = true ] && [ "$UPDATE_ANCHOR" = true ] && [ "$DRY_RUN" = false ]; then
  if [ -f "$ANCHOR_PY" ]; then
    if [ "$VERBOSE" = true ]; then
      echo "Updating Anchor memory note: $ANCHOR_NOTE..."
    fi

    timestamp=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
    changelog_content="### [$timestamp]
### Craft Applications Updated in CT 103
- **Debian Packages Updated:**"
    for item in "${UPDATED_DETAILS[@]}"; do
      changelog_content="$changelog_content
  * $item"
    done

    if python3 "$ANCHOR_PY" memory append "$ANCHOR_NOTE_ID" --content "$changelog_content" >/dev/null 2>&1; then
      anchor_status="updated"
    elif python3 "$ANCHOR_PY" memory append "$ANCHOR_NOTE" --content "$changelog_content" >/dev/null 2>&1; then
      anchor_status="updated"
    else
      anchor_status="append-failed"
    fi
  else
    anchor_status="anchor-cli-not-found"
  fi
fi

# -----------------------------------------------------------------------------
# Summary Table Rendering
# -----------------------------------------------------------------------------
hdr_col0="Application"
hdr_col1="Installed"
hdr_col2="Upstream"
hdr_col3="Status"

w0=${#hdr_col0}
w1=${#hdr_col1}
w2=${#hdr_col2}
w3=${#hdr_col3}

for row in "${ROWS[@]}"; do
  IFS='|' read -r c0 c1 c2 c3 <<< "$row"
  [ ${#c0} -gt $w0 ] && w0=${#c0}
  [ ${#c1} -gt $w1 ] && w1=${#c1}
  [ ${#c2} -gt $w2 ] && w2=${#c2}
  [ ${#c3} -gt $w3 ] && w3=${#c3}
done

w0=$((w0 + 2))
w1=$((w1 + 2))
w2=$((w2 + 2))
w3=$((w3 + 2))

make_border() {
  local char="$1"
  printf "+%s+%s+%s+%s+\n" \
    "$(printf "%${w0}s" "" | tr ' ' "$char")" \
    "$(printf "%${w1}s" "" | tr ' ' "$char")" \
    "$(printf "%${w2}s" "" | tr ' ' "$char")" \
    "$(printf "%${w3}s" "" | tr ' ' "$char")"
}

echo "Summary"
make_border "="
printf "| %-*s | %-*s | %-*s | %-*s |\n" \
  $((w0 - 2)) "$hdr_col0" \
  $((w1 - 2)) "$hdr_col1" \
  $((w2 - 2)) "$hdr_col2" \
  $((w3 - 2)) "$hdr_col3"
make_border "="

for row in "${ROWS[@]}"; do
  IFS='|' read -r c0 c1 c2 c3 <<< "$row"
  printf "| %-*s | %-*s | %-*s | %-*s |\n" \
    $((w0 - 2)) "$c0" \
    $((w1 - 2)) "$c1" \
    $((w2 - 2)) "$c2" \
    $((w3 - 2)) "$c3"
  make_border "-"
done

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
if [ "$ANY_UPDATED" = true ]; then
  echo "Result: Craft applications successfully updated: $(IFS='; '; echo "${UPDATED_DETAILS[*]}")"
  if [ "$UPDATE_ANCHOR" = true ]; then
    echo "Anchor: $anchor_status (Note: $ANCHOR_NOTE)"
  fi
elif [ "$ANY_ERRORS" = true ]; then
  echo "Result: Update completed with errors: $(IFS='; '; echo "${ERROR_DETAILS[*]}")"
else
  if [ "$DRY_RUN" = true ]; then
    echo "Result: Dry run complete. No modifications made."
  else
    echo "Result: All applications are already up to date."
  fi
fi
echo "Elapsed: ${ELAPSED}s"
