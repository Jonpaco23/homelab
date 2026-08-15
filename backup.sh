#!/bin/bash
#
# backup-app.sh — Generic backup script: tar a data directory and push it to
# an NFS-mounted NAS, with retention pruning, logging, and locking.
#
# Usage:
#   backup-app.sh -n <app_name> -s <source_dir> -d <nas_dest_dir> [options]
#
# Required:
#   -n  App name (used for filenames/logs), e.g. "actualbudget"
#   -s  Source data directory to back up, e.g. /opt/actualbudget/data
#   -d  Destination directory on the NFS mount, e.g. /mnt/nas-backups/actualbudget
#
# Optional:
#   -k  Days to keep backups (default: 14)
#   -b  Command to run BEFORE backup (e.g. "docker stop actualbudget")
#   -a  Command to run AFTER backup (e.g. "docker start actualbudget")
#   -t  Local temp dir for staging the archive (default: /tmp/backups)
#   -q  Quiet mode — only log errors, not routine progress
#
# Example:
#   ./backup-app.sh -n vaultwarden -s /opt/vaultwarden/data \
#       -d /mnt/nas-backups/vaultwarden -k 14 \
#       -b "docker stop vaultwarden" -a "docker start vaultwarden"
#
# Add to cron, e.g.:
#   0 3 * * * /usr/local/bin/backup-app.sh -n vaultwarden -s /opt/vaultwarden/data -d /mnt/nas-backups/vaultwarden -b "docker stop vaultwarden" -a "docker start vaultwarden" >> /var/log/backup-vaultwarden.log 2>&1

set -euo pipefail

# ---------- Defaults ----------
KEEP_DAYS=14
LOCAL_TMP=/tmp/backups
PRE_CMD=""
POST_CMD=""
QUIET=0

# ---------- Parse args ----------
usage() {
    grep '^#' "$0" | sed -n '2,30p' | sed 's/^#//'
    exit 1
}

while getopts "n:s:d:k:b:a:t:qh" opt; do
    case "$opt" in
        n) APP="$OPTARG" ;;
        s) SRC_DIR="$OPTARG" ;;
        d) DEST_DIR="$OPTARG" ;;
        k) KEEP_DAYS="$OPTARG" ;;
        b) PRE_CMD="$OPTARG" ;;
        a) POST_CMD="$OPTARG" ;;
        t) LOCAL_TMP="$OPTARG" ;;
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
DATE=$(date +%Y%m%d-%H%M%S)
mkdir -p "$LOCAL_TMP" "$DEST_DIR"
ARCHIVE_NAME="${APP}-${DATE}.tar.gz"
LOCAL_ARCHIVE="${LOCAL_TMP}/${ARCHIVE_NAME}"

cleanup() {
    rm -f "$LOCAL_ARCHIVE"
}
trap cleanup EXIT

# ---------- Pre-backup hook ----------
if [ -n "$PRE_CMD" ]; then
    log "Running pre-backup command: $PRE_CMD"
    eval "$PRE_CMD"
fi

# Ensure post-hook always runs, even if backup fails, if a pre-hook ran
run_post() {
    if [ -n "$POST_CMD" ]; then
        log "Running post-backup command: $POST_CMD"
        eval "$POST_CMD"
    fi
}
if [ -n "$PRE_CMD" ]; then
    trap 'run_post; cleanup' EXIT
fi

# ---------- Archive ----------
log "Archiving '$SRC_DIR' -> '$LOCAL_ARCHIVE'"
tar -czf "$LOCAL_ARCHIVE" -C "$(dirname "$SRC_DIR")" "$(basename "$SRC_DIR")"

# ---------- Post-backup hook (restart app etc.) as early as possible ----------
if [ -n "$PRE_CMD" ]; then
    run_post
    trap cleanup EXIT   # reset trap so run_post doesn't fire twice
fi

# ---------- Copy to NAS ----------
log "Copying archive to NAS: $DEST_DIR"
REMOTE_TMP="${DEST_DIR}/.${ARCHIVE_NAME}.partial"
if ! cp "$LOCAL_ARCHIVE" "$REMOTE_TMP"; then
    log "ERROR: copy to NAS failed for $APP"
    rm -f "$REMOTE_TMP"
    exit 1
fi
# Atomic rename into place once the full copy has landed
if ! mv "$REMOTE_TMP" "${DEST_DIR}/${ARCHIVE_NAME}"; then
    log "ERROR: rename on NAS failed for $APP"
    rm -f "$REMOTE_TMP"
    exit 1
fi

# ---------- Verify ----------
REMOTE_FILE="${DEST_DIR}/${ARCHIVE_NAME}"
LOCAL_SIZE=$(stat -c%s "$LOCAL_ARCHIVE" 2>/dev/null || stat -f%z "$LOCAL_ARCHIVE")
REMOTE_SIZE=$(stat -c%s "$REMOTE_FILE" 2>/dev/null || stat -f%z "$REMOTE_FILE")
if [ "$LOCAL_SIZE" != "$REMOTE_SIZE" ]; then
    log "ERROR: size mismatch after copy (local=$LOCAL_SIZE remote=$REMOTE_SIZE)"
    exit 1
fi
log "Backup verified: $REMOTE_FILE ($REMOTE_SIZE bytes)"

# ---------- Prune old backups on NAS ----------
log "Pruning backups older than $KEEP_DAYS days in $DEST_DIR"
find "$DEST_DIR" -maxdepth 1 -name "${APP}-*.tar.gz" -mtime "+${KEEP_DAYS}" -print -delete | while read -r f; do
    log "Deleted old backup: $f"
done

log "Backup of '$APP' complete."
