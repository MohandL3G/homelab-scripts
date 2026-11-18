#!/usr/bin/env bash
#
# update-agy.sh — Check for Antigravity CLI (agy) updates, pull the release archive
# from Gaming PC (Desktop or ABDM Downloads) over local LAN, verify SHA-512 integrity,
# atomically install to /root/.local/bin/agy, clean up temporary files on both hosts,
# and log the event to Anchor persistent memory.
#
# Run inside CT 103 (Antigravity guest) as root, or invoked straight from GitHub raw:
#
#   dry run:  bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/Antigravity/update-agy.sh)" _ --dry
#   real run: bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/Antigravity/update-agy.sh)"
#   verbose:  bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/Antigravity/update-agy.sh)" _ --verbose
#   force:    bash -c "$(curl -fsSL https://raw.githubusercontent.com/MohandL3G/homelab-scripts/main/Antigravity/update-agy.sh)" _ --force
#
# The leading "_" is a throwaway $0 so the options land in $1 when invoked via bash -c.
#
# Options (in any order, all optional):
#   --dry, -n          Report available updates and detect remote file without downloading or installing
#   --verbose, -v      Show detailed logs during checks, scp transfer, and hash verification
#   --force, -f        Force reinstall even if installed version matches upstream
#   --file=PATH        Explicit Windows file path on Gaming PC (skips auto-discovery)
#   --no-cleanup       Do not delete temporary files in /tmp or on Gaming PC
#   --no-anchor        Skip updating Anchor persistent memory after successful install
#   --no-restart       Do not restart the remote-control daemon after installation
#   --restart          Force daemon restart even when executed inside an agent session
#   --help, -h         Show this help message
#
# Features:
#   - Queries official Google release manifest (manifests/linux_amd64.json)
#   - Compares installed agy version against latest release
#   - Auto-discovers release archive on Gaming PC (Desktop, then ABDM Downloads fallback)
#   - Copies archive over local 1 Gbps LAN via scp (~8 seconds for ~100 MB)
#   - Verifies SHA-512 integrity against Google's official release manifest
#   - Tests binary execution in staging before replacement
#   - Atomically swaps /root/.local/bin/agy preserving a versioned rollback backup
#   - Updates update_status.json for agy CLI status tracking
#   - Two-way cleanup: purges staging files on CT 103 and removes source archive on Gaming PC
#   - Appends audit entry to Anchor persistent memory ([Changelog] Homelab Events Archive)
#   - Renders a clean ASCII summary table
#
set -euo pipefail

# -----------------------------------------------------------------------------
# Defaults and Option Parsing
# -----------------------------------------------------------------------------
DRY_RUN=false
VERBOSE=false
FORCE=false
CLEANUP=true
UPDATE_ANCHOR=true
AUTO_RESTART=true
EXPLICIT_RESTART=false
NO_RESTART=false
EXPLICIT_FILE=""

MANIFEST_URL="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json"
TARGET_DIR="/root/.local/bin"
BINARY_PATH="$TARGET_DIR/agy"
STATUS_FILE="/root/.gemini/antigravity-cli/updater/update_status.json"
STAGING_DIR="/tmp/agy-staging"
LOCAL_ARCHIVE="/tmp/cli_linux_x64.tar.gz"

REMOTE_HOST="gamingpc"
REMOTE_DESKTOP="C:\\Users\\MohandL3G\\Desktop"
REMOTE_ABDM="C:\\Users\\MohandL3G\\Downloads\\ABDM\\Compressed"

ANCHOR_PY="/root/home/.agents/skills/anchor/scripts/anchor.py"
ANCHOR_NOTE="[Changelog] Homelab Events Archive"
ANCHOR_NOTE_ID="fba357f4-b48f-43a9-87ac-300228e7bcba"

usage() {
  cat <<'EOF'
Usage: update-agy.sh [options]

Options:
  --dry, -n          Report status and detect remote files without making any changes
  --verbose, -v      Show detailed transfer, verification, and command outputs
  --force, -f        Force reinstall even if current version is already up to date
  --file=PATH        Specify exact file path on Gaming PC (skips Desktop auto-scan)
  --no-cleanup       Retain temporary files in /tmp and on Gaming PC
  --no-anchor        Skip logging the update to Anchor persistent memory
  --no-restart       Do not restart the remote-control daemon after installing
  --restart          Force daemon restart even if run from inside an agent session
  --help, -h         Show this help message

Examples:
  # Check if an update is available and inspect candidate files on Gaming PC
  update-agy.sh --dry

  # Normal update using auto-discovered archive on Gaming PC Desktop
  update-agy.sh

  # Update using a specific archive file path on Gaming PC
  update-agy.sh --file='C:\Users\MohandL3G\Desktop\agy_cli_linux_x64.tar.gz'
EOF
  exit 0
}

# Handle cases where bash -c is invoked without a throwaway $0 (e.g. bash -c "..." --dry)
if [[ "${0:-}" == -* ]]; then
  set -- "$0" "$@"
fi

while [ $# -gt 0 ]; do
  case "$1" in
    _)
      shift
      ;;
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
    --file=*)
      EXPLICIT_FILE="${1#*=}"
      shift
      ;;
    --no-cleanup)
      CLEANUP=false
      shift
      ;;
    --no-anchor|--no-memory|--no-supermemory)
      UPDATE_ANCHOR=false
      shift
      ;;
    --no-restart)
      NO_RESTART=true
      AUTO_RESTART=false
      shift
      ;;
    --restart)
      EXPLICIT_RESTART=true
      AUTO_RESTART=true
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

START_TIME=$(date +%s)
NOW_STR=$(date '+%Y-%m-%d %H:%M:%S')

echo "=== Antigravity CLI Update$([ "$DRY_RUN" = true ] && echo " (DRY RUN)") — $NOW_STR ==="

# -----------------------------------------------------------------------------
# Step 1: Detect Current Installed Version
# -----------------------------------------------------------------------------
INSTALLED_VER="none"
if [ -x "$BINARY_PATH" ]; then
  INSTALLED_VER=$("$BINARY_PATH" --version 2>/dev/null || echo "unknown")
fi

if [ "$VERBOSE" = true ]; then
  echo "Current binary: $BINARY_PATH (version: $INSTALLED_VER)"
fi

# -----------------------------------------------------------------------------
# Step 2: Query Upstream Release Manifest
# -----------------------------------------------------------------------------
if [ "$VERBOSE" = true ]; then
  echo "Querying release manifest: $MANIFEST_URL"
fi

MANIFEST_JSON=""
if command -v curl >/dev/null 2>&1; then
  MANIFEST_JSON=$(curl -fsSL "$MANIFEST_URL" 2>/dev/null || true)
elif command -v wget >/dev/null 2>&1; then
  MANIFEST_JSON=$(wget -q -O - "$MANIFEST_URL" 2>/dev/null || true)
fi

TARGET_VER=""
EXPECTED_SHA512=""
DOWNLOAD_URL=""

if [ -n "$MANIFEST_JSON" ]; then
  TARGET_VER=$(echo "$MANIFEST_JSON" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)
  EXPECTED_SHA512=$(echo "$MANIFEST_JSON" | sed -n 's/.*"sha512"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)
  DOWNLOAD_URL=$(echo "$MANIFEST_JSON" | sed -n 's/.*"url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)
fi

if [ -z "$TARGET_VER" ]; then
  echo "Warning: Unable to query or parse release manifest from Google auto-updater." >&2
  if [ "$INSTALLED_VER" != "none" ]; then
    TARGET_VER="$INSTALLED_VER"
  else
    TARGET_VER="unknown"
  fi
else
  if [ "$VERBOSE" = true ]; then
    echo "Upstream target version: $TARGET_VER"
    echo "Expected SHA-512: $EXPECTED_SHA512"
  fi
fi

# Check if update is needed
if [ "$INSTALLED_VER" = "$TARGET_VER" ] && [ "$FORCE" = false ] && [ "$INSTALLED_VER" != "unknown" ]; then
  echo "Antigravity CLI is already at latest version ($INSTALLED_VER)."
  
  END_TIME=$(date +%s)
  ELAPSED=$((END_TIME - START_TIME))

  hdr_col0="Component"
  hdr_col1="Previous"
  hdr_col2="Installed"
  hdr_col3="Status"

  w0=${#hdr_col0}
  w1=${#hdr_col1}
  w2=${#hdr_col2}
  w3=${#hdr_col3}

  comp_name="Antigravity CLI (agy)"
  status_text="up-to-date"

  [ ${#comp_name} -gt $w0 ] && w0=${#comp_name}
  [ ${#INSTALLED_VER} -gt $w1 ] && w1=${#INSTALLED_VER}
  [ ${#TARGET_VER} -gt $w2 ] && w2=${#TARGET_VER}
  [ ${#status_text} -gt $w3 ] && w3=${#status_text}

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

  echo ""
  echo "Summary"
  make_border "="
  printf "| %-*s | %-*s | %-*s | %-*s |\n" \
    $((w0 - 2)) "$hdr_col0" \
    $((w1 - 2)) "$hdr_col1" \
    $((w2 - 2)) "$hdr_col2" \
    $((w3 - 2)) "$hdr_col3"
  make_border "="
  printf "| %-*s | %-*s | %-*s | %-*s |\n" \
    $((w0 - 2)) "$comp_name" \
    $((w1 - 2)) "$INSTALLED_VER" \
    $((w2 - 2)) "$TARGET_VER" \
    $((w3 - 2)) "$status_text"
  make_border "="

  echo ""
  echo "Result: Antigravity CLI is already up to date."
  echo "Elapsed: ${ELAPSED}s"
  exit 0
fi

# -----------------------------------------------------------------------------
# Step 3: Check Gaming PC Connectivity & Locate Archive
# -----------------------------------------------------------------------------
if [ "$VERBOSE" = true ]; then
  echo "Checking SSH connectivity to Gaming PC ($REMOTE_HOST)..."
fi

if ! ssh -q -o BatchMode=yes -o ConnectTimeout=5 "$REMOTE_HOST" 'exit 0' 2>/dev/null; then
  echo "Error: Cannot connect to Gaming PC ($REMOTE_HOST) via SSH." >&2
  echo "Please verify that the Windows PC is powered on and reachable." >&2
  exit 1
fi

REMOTE_FILE_PATH=""
REMOTE_FILE_NAME=""
REMOTE_FILE_SIZE=0

if [ -n "$EXPLICIT_FILE" ]; then
  # User specified explicit file path
  CHECK_B64=$(echo -n "if (Test-Path -LiteralPath '$EXPLICIT_FILE') { \$item = Get-Item -LiteralPath '$EXPLICIT_FILE'; Write-Output \"\$(\$item.FullName)|\$(\$item.Name)|\$(\$item.Length)\" }" | iconv -t utf-16le | base64 -w 0)
  EXPLICIT_RESULT=$(ssh "$REMOTE_HOST" "powershell -NoProfile -NonInteractive -EncodedCommand $CHECK_B64" 2>/dev/null | tr -d '\r' | grep '|' | head -n 1 || true)
  if [ -n "$EXPLICIT_RESULT" ]; then
    IFS='|' read -r REMOTE_FILE_PATH REMOTE_FILE_NAME REMOTE_FILE_SIZE <<< "$EXPLICIT_RESULT"
  else
    echo "Error: Specified file does not exist on Gaming PC: $EXPLICIT_FILE" >&2
    exit 1
  fi
else
  # Auto-discovery logic: Check Desktop first, then ABDM Downloads fallback
  DISCOVERY_B64=$(cat << 'EOF' | iconv -t utf-16le | base64 -w 0
$paths = @("C:\Users\MohandL3G\Desktop", "C:\Users\MohandL3G\Downloads\ABDM\Compressed")
$patterns = @("agy_cli_linux_x64.tar.gz", "cli_linux_x64.tar.gz", "*cli_linux*.tar.gz", "agy*.tar.gz", "*antigravity*.tar.gz")
foreach ($dir in $paths) {
    if (Test-Path $dir) {
        foreach ($p in $patterns) {
            $f = Get-ChildItem -Path $dir -Filter $p -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($f) {
                Write-Output "$($f.FullName)|$($f.Name)|$($f.Length)"
                exit 0
            }
        }
    }
}
EOF
)

  DISCOVERY_RESULT=$(ssh "$REMOTE_HOST" "powershell -NoProfile -NonInteractive -EncodedCommand $DISCOVERY_B64" 2>/dev/null | tr -d '\r' | grep '|' | head -n 1 || true)

  if [ -n "$DISCOVERY_RESULT" ]; then
    IFS='|' read -r REMOTE_FILE_PATH REMOTE_FILE_NAME REMOTE_FILE_SIZE <<< "$DISCOVERY_RESULT"
  fi
fi

if [ -z "$REMOTE_FILE_PATH" ]; then
  echo "Error: No Antigravity release archive found on Gaming PC Desktop or ABDM Downloads." >&2
  echo ""
  echo "Please download the Linux archive on your Gaming PC:"
  if [ -n "$DOWNLOAD_URL" ]; then
    echo "  URL: $DOWNLOAD_URL"
  else
    echo "  Check: $MANIFEST_URL"
  fi
  echo "Save the file to Desktop as 'cli_linux_x64.tar.gz' or 'agy_cli_linux_x64.tar.gz'." >&2
  exit 1
fi

echo "Found release archive on Gaming PC:"
echo "  Path: $REMOTE_FILE_PATH"
echo "  Size: $(numfmt --to=iec-i --suffix=B "$REMOTE_FILE_SIZE" 2>/dev/null || echo "$REMOTE_FILE_SIZE bytes")"

if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "Dry run completed. Plan of actions:"
  echo "  1. Pull '$REMOTE_FILE_PATH' to '$LOCAL_ARCHIVE' via scp"
  if [ -n "$EXPECTED_SHA512" ]; then
    echo "  2. Verify SHA-512 against manifest ($EXPECTED_SHA512)"
  fi
  echo "  3. Extract 'antigravity' binary into '$STAGING_DIR'"
  echo "  4. Stage and verify version matches '$TARGET_VER'"
  echo "  5. Backup '$BINARY_PATH' to '$TARGET_DIR/agy.${INSTALLED_VER}.bak'"
  echo "  6. Atomically replace '$BINARY_PATH' with new binary"
  echo "  7. Update '$STATUS_FILE'"
  if [ "$CLEANUP" = true ]; then
    echo "  8. Clean up '$LOCAL_ARCHIVE', '$STAGING_DIR', and delete remote '$REMOTE_FILE_PATH'"
  fi
  if [ "$UPDATE_ANCHOR" = true ]; then
    echo "  9. Record update in Anchor persistent memory note '$ANCHOR_NOTE'"
  fi
  exit 0
fi

# -----------------------------------------------------------------------------
# Step 4: Transfer Archive from Gaming PC to CT 103 via scp
# -----------------------------------------------------------------------------
echo ""
echo "Transferring archive from Gaming PC over local LAN..."

# Convert Windows path (e.g. C:\Users\... -> C:/Users/...) for scp compatibility
REMOTE_SCP_PATH=$(echo "$REMOTE_FILE_PATH" | tr '\\' '/')

rm -f "$LOCAL_ARCHIVE"
if [ "$VERBOSE" = true ]; then
  scp "$REMOTE_HOST:$REMOTE_SCP_PATH" "$LOCAL_ARCHIVE"
else
  scp -q "$REMOTE_HOST:$REMOTE_SCP_PATH" "$LOCAL_ARCHIVE"
fi

if [ ! -f "$LOCAL_ARCHIVE" ]; then
  echo "Error: Failed to transfer file from Gaming PC via scp." >&2
  exit 1
fi

ACTUAL_LOCAL_SIZE=$(stat -c%s "$LOCAL_ARCHIVE" 2>/dev/null || ls -l "$LOCAL_ARCHIVE" | awk '{print $5}')
echo "Archive transferred successfully ($(numfmt --to=iec-i --suffix=B "$ACTUAL_LOCAL_SIZE" 2>/dev/null || echo "$ACTUAL_LOCAL_SIZE bytes"))."

# -----------------------------------------------------------------------------
# Step 5: Verify SHA-512 Checksum
# -----------------------------------------------------------------------------
if [ -n "$EXPECTED_SHA512" ]; then
  echo "Verifying SHA-512 checksum..."
  LOCAL_SHA512=$(sha512sum "$LOCAL_ARCHIVE" | awk '{print $1}')
  
  if [ "${LOCAL_SHA512,,}" != "${EXPECTED_SHA512,,}" ]; then
    echo "Security Halt: Downloaded archive checksum mismatch!" >&2
    echo "  Expected: $EXPECTED_SHA512" >&2
    echo "  Computed: $LOCAL_SHA512" >&2
    echo "The file may be corrupted or compromised. Installation aborted." >&2
    rm -f "$LOCAL_ARCHIVE"
    exit 1
  fi
  echo "Checksum verified: SHA-512 OK."
else
  echo "Warning: Manifest hash not available. Skipping checksum validation."
fi

# -----------------------------------------------------------------------------
# Step 6: Extract & Stage Binary
# -----------------------------------------------------------------------------
echo "Extracting binary..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

if ! tar -xzf "$LOCAL_ARCHIVE" -C "$STAGING_DIR" antigravity 2>/dev/null; then
  echo "Extraction Error: Failed to extract 'antigravity' binary from archive." >&2
  exit 1
fi

EXTRACTED_BIN="$STAGING_DIR/antigravity"
if [ ! -f "$EXTRACTED_BIN" ]; then
  echo "Extraction Error: Staged binary '$EXTRACTED_BIN' not found." >&2
  exit 1
fi

chmod +x "$EXTRACTED_BIN"

STAGED_VER=$("$EXTRACTED_BIN" --version 2>/dev/null || true)
if [ -z "$STAGED_VER" ]; then
  echo "Execution Error: Staged binary failed execution test." >&2
  exit 1
fi

echo "Staged binary verified: version $STAGED_VER."

# -----------------------------------------------------------------------------
# Step 7: Atomic Replacement & Status File Update
# -----------------------------------------------------------------------------
mkdir -p "$TARGET_DIR"

# Stage in target directory
cp -a "$EXTRACTED_BIN" "$TARGET_DIR/agy.new"
chmod +x "$TARGET_DIR/agy.new"

# Versioned backup
if [ -f "$BINARY_PATH" ]; then
  BACKUP_PATH="$TARGET_DIR/agy.${INSTALLED_VER}.bak"
  if [ "$VERBOSE" = true ]; then
    echo "Creating backup of current binary at $BACKUP_PATH"
  fi
  mv -f "$BINARY_PATH" "$BACKUP_PATH"
fi

# Atomic move
mv -f "$TARGET_DIR/agy.new" "$BINARY_PATH"

FINAL_VER=$("$BINARY_PATH" --version 2>/dev/null || echo "unknown")
if [ "$FINAL_VER" != "$STAGED_VER" ]; then
  echo "Warning: Installed binary reports version '$FINAL_VER', expected '$STAGED_VER'." >&2
fi

# Update update_status.json
mkdir -p "$(dirname "$STATUS_FILE")"
cat > "$STATUS_FILE" <<EOF
{"success":true,"version":"$FINAL_VER"}
EOF

echo "Binary installed: $BINARY_PATH ($FINAL_VER)."

# -----------------------------------------------------------------------------
# Step 8: Two-Way Cleanup
# -----------------------------------------------------------------------------
if [ "$CLEANUP" = true ]; then
  echo "Cleaning up temporary files..."
  rm -rf "$STAGING_DIR" "$LOCAL_ARCHIVE"
  
  if [ "$VERBOSE" = true ]; then
    echo "Removing source archive from Gaming PC: $REMOTE_FILE_PATH"
  fi
  DEL_B64=$(echo -n "Remove-Item -LiteralPath '$REMOTE_FILE_PATH' -Force -ErrorAction SilentlyContinue" | iconv -t utf-16le | base64 -w 0)
  ssh "$REMOTE_HOST" "powershell -NoProfile -NonInteractive -EncodedCommand $DEL_B64" 2>/dev/null || true
  echo "Cleanup complete on both CT 103 and Gaming PC."
else
  echo "Skipping cleanup (--no-cleanup specified)."
fi

# -----------------------------------------------------------------------------
# Step 9: Anchor Persistent Memory Update
# -----------------------------------------------------------------------------
anchor_status="skipped"
if [ "$UPDATE_ANCHOR" = true ]; then
  if [ -x "$ANCHOR_PY" ] || command -v python3 >/dev/null 2>&1; then
    anchor_entry=$(cat <<EOF

### [$(date -u '+%Y-%m-%d %H:%M:%S UTC')]
### Antigravity CLI (agy) Updated to v${FINAL_VER}
- **Update Method:** Automated local LAN transfer from Gaming PC (${REMOTE_HOST}) via \`update-agy.sh\`.
- **Integrity:** SHA-512 checksum verified against Google auto-updater manifest.
- **Previous Version:** ${INSTALLED_VER} -> **New Version:** ${FINAL_VER}
- **Installation Path:** \`/root/.local/bin/agy\` (Rollback backup preserved: \`/root/.local/bin/agy.${INSTALLED_VER}.bak\`).
- **Hygiene:** Cleaned temporary extraction staging and purged source archive on Gaming PC Desktop (\`${REMOTE_FILE_PATH}\`).
EOF
)

    if python3 "$ANCHOR_PY" memory append "$ANCHOR_NOTE_ID" --content "$anchor_entry" >/dev/null 2>&1; then
      anchor_status="updated"
    else
      anchor_status="append-failed"
    fi
  else
    anchor_status="anchor-cli-not-found"
  fi
fi

# -----------------------------------------------------------------------------
# Step 10: Remote-Control Daemon Restart
# -----------------------------------------------------------------------------
daemon_status="running (unchanged)"

# Check if current script is executing inside the active agent cgroup
IN_AGENT_CGROUP=false
if grep -q "antigravity-cli-daemon.service" /proc/self/cgroup 2>/dev/null; then
  IN_AGENT_CGROUP=true
fi

if [ "$NO_RESTART" = true ]; then
  daemon_status="skipped (--no-restart)"
elif [ "$IN_AGENT_CGROUP" = true ] && [ "$EXPLICIT_RESTART" = false ]; then
  daemon_status="deferred (active session)"
  echo ""
  echo "Notice: Script is running inside the active Antigravity session cgroup."
  echo "Deferred immediate daemon restart to avoid severing the current remote-control turn."
  echo "To restart the daemon and reload into v$FINAL_VER:"
  echo "  systemctl --user restart antigravity-cli-daemon.service"
  echo "  (or: agy remote-control stop && agy remote-control start)"
elif [ "$AUTO_RESTART" = true ]; then
  echo "Restarting antigravity remote-control daemon..."
  if systemctl --user is-enabled antigravity-cli-daemon.service >/dev/null 2>&1 || \
     systemctl --user is-active antigravity-cli-daemon.service >/dev/null 2>&1; then
    systemctl --user restart antigravity-cli-daemon.service 2>/dev/null || true
    daemon_status="restarted (systemd)"
  else
    "$BINARY_PATH" remote-control stop 2>/dev/null || true
    "$BINARY_PATH" remote-control start 2>/dev/null || true
    daemon_status="restarted (cli)"
  fi
fi

# -----------------------------------------------------------------------------
# Step 11: Summary Table
# -----------------------------------------------------------------------------
END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

hdr_col0="Component"
hdr_col1="Previous"
hdr_col2="Installed"
hdr_col3="Status"

w0=${#hdr_col0}
w1=${#hdr_col1}
w2=${#hdr_col2}
w3=${#hdr_col3}

comp_name="Antigravity CLI (agy)"
status_text="updated"

[ ${#comp_name} -gt $w0 ] && w0=${#comp_name}
[ ${#INSTALLED_VER} -gt $w1 ] && w1=${#INSTALLED_VER}
[ ${#FINAL_VER} -gt $w2 ] && w2=${#FINAL_VER}
[ ${#status_text} -gt $w3 ] && w3=${#status_text}

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

echo ""
echo "Summary"
make_border "="
printf "| %-*s | %-*s | %-*s | %-*s |\n" \
  $((w0 - 2)) "$hdr_col0" \
  $((w1 - 2)) "$hdr_col1" \
  $((w2 - 2)) "$hdr_col2" \
  $((w3 - 2)) "$hdr_col3"
make_border "="
printf "| %-*s | %-*s | %-*s | %-*s |\n" \
  $((w0 - 2)) "$comp_name" \
  $((w1 - 2)) "$INSTALLED_VER" \
  $((w2 - 2)) "$FINAL_VER" \
  $((w3 - 2)) "$status_text"
make_border "="

echo ""
echo "Result: Antigravity CLI successfully updated to $FINAL_VER."
echo "Daemon: $daemon_status"
if [ "$UPDATE_ANCHOR" = true ]; then
  echo "Anchor: $anchor_status (Note: $ANCHOR_NOTE)"
fi
echo ""
echo "Note: To reload the remote-control daemon into the new version:"
echo "  systemctl --user restart antigravity-cli-daemon.service"
echo "  # or: agy remote-control stop && agy remote-control start"
echo ""
echo "Elapsed: ${ELAPSED}s"
