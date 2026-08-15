#!/bin/bash
#
# backup-app.sh — Generic backup script: mirrors an app's data directory to
# an NFS-mounted NAS location, using an atomic swap so the destination is
# always a complete, consistent copy (safe for restic or similar tools to
# back up from). Retention/versioning is left to restic, not this script.
#
# Usage:
#   backup-app.sh -n <app_name> -s <source_dir> -d <nas_dest_dir> [options]
#
# Required:
#   -n  App name (used for logging/locking), e.g. "actualbudget"
#   -s  Source data directory to back up, e.g. /opt/actualbudget/data
#   -d  Destination directory on the NFS mount that mirrors the source,
#       e.g. /mnt/nas-backups/actualbudget  (this is what restic should
#       point its backup job at)
#
# Optional:
#   -b  Command to run BEFORE copying (e.g. "docker stop actualbudget")
#   -a  Command to run AFTER copying (e.g. "docker start actualbudget")
#   -q  Quiet mode — only log errors, not routine progress
#
# Example:
#   ./backup-app.sh -n vaultwarden -s /opt/vaultwarden/data \
#       -d /mnt/nas-backups/vaultwarden \
#       -b "docker stop vaultwarden" -a "docker start vaultwarden"
#
# Add to cron, e.g.:
#   0 3 * * * /usr/local/bin/backup-app.sh -n vaultwarden -s /opt/vaultwarden/data -d /mnt/nas-backups/vaultwarden -b "docker stop vaultwarden" -a "docker start vaultwarden" -q >> /var/log/backup-vaultwarden.log 2>&1
#
# Then point a restic backup job at the destination directories on the NAS,
# scheduled to run after all app mirror jobs have finished, e.g.:
#   restic backup /mnt/nas-backups/vaultwarden /mnt/nas-backups/actualbudget

set -euo pipefail

# ---------- Defaults ----------
PRE_CMD=""
POST_CMD=""
QUIET=0

# ---------- Parse args ----------
usage() {
    grep '^#' "$0" | sed -n '2,30p' | sed 's/^#//'
    exit 1
}

while getopts "n:s:d:b:a:qh" opt; do
    case "$opt" in
        n) APP="$OPTARG" ;;
        s) SRC_DIR="$OPTARG" ;;
        d) DEST_DIR="$OPTARG" ;;
        b) PRE_CMD="$OPTARG" ;;
        a) POST_CMD="$OPTARG" ;;
        q) QUIET=1 ;;
        h|*) usage ;;
    esac
done

: "${APP:?Missing -n <app_name>}"
: "${SRC_DIR:?Missing -s <source_dir>}"
: "${DEST_DIR:?Missing -d <nas_dest_dir>}"

if [ ! -d "$SRC_DIR" ]; then
    echo "ERROR: source directory '$SRC_DIR' does not exist" >&2
    exit 1
fi

log() {
    [ "$QUIET" -eq 1 ] && [ "$1" != "ERROR" ] && return 0
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# ---------- Locking (prevent overlapping runs for the same app) ----------
LOCK_FILE="/tmp/backup-${APP}.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "ERROR: another backup for '$APP' is already running. Exiting."
    exit 1
fi

# ---------- Setup ----------
DEST_PARENT="$(dirname "$DEST_DIR")"
mkdir -p "$DEST_PARENT"
TMP_DEST="${DEST_DIR}.tmp-$$"
OLD_DEST="${DEST_DIR}.old-$$"

cleanup() {
    rm -rf "$TMP_DEST" "$OLD_DEST" 2>/dev/null || true
}
trap cleanup EXIT

# ---------- Pre-backup hook ----------
if [ -n "$PRE_CMD" ]; then
    log "Running pre-backup command: $PRE_CMD"
    eval "$PRE_CMD"
fi

run_post() {
    if [ -n "$POST_CMD" ]; then
        log "Running post-backup command: $POST_CMD"
        eval "$POST_CMD"
    fi
}

# ---------- Copy data directory to NAS (staged, then swapped in atomically) ----------
log "Copying '$SRC_DIR' -> '$TMP_DEST'"
rm -rf "$TMP_DEST"
if ! cp -r "$SRC_DIR" "$TMP_DEST"; then
    log "ERROR: copy to NAS failed for $APP"
    run_post
    exit 1
fi

# App can come back up now that the copy is done — don't hold it down
# through the swap/verify steps below.
run_post

# ---------- Verify copy looks complete before swapping it in ----------
SRC_COUNT=$(find "$SRC_DIR" | wc -l)
TMP_COUNT=$(find "$TMP_DEST" | wc -l)
if [ "$SRC_COUNT" != "$TMP_COUNT" ]; then
    log "ERROR: item count mismatch (source=$SRC_COUNT copied=$TMP_COUNT), aborting swap"
    exit 1
fi

# ---------- Atomic swap into place ----------
if [ -d "$DEST_DIR" ]; then
    mv "$DEST_DIR" "$OLD_DEST"
fi
mv "$TMP_DEST" "$DEST_DIR"
rm -rf "$OLD_DEST"

log "Backup of '$APP' complete: $DEST_DIR ($TMP_COUNT items)"
