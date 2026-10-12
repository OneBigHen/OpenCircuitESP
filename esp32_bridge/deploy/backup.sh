#!/usr/bin/env bash
# Consistent online SQLite backup of the RingConn archive, with retention.
# Usage: backup.sh [project-dir]   (default /srv/ringbridge). Run daily from the systemd timer.
set -euo pipefail
DIR="${1:-/srv/ringbridge}"; KEEP="${KEEP:-14}"
STAMP="$(date +%Y-%m-%d-%H%M)"
cd "$DIR"
mkdir -p storage/backups && chmod 700 storage/backups
docker exec ringconn-collector python /app/archive_tools.py backup \
  --database /data/ringconn.db --output "/data/backups/ringconn-$STAMP.db"
# Keep the newest $KEEP backups.
ls -1t storage/backups/ringconn-*.db 2>/dev/null | tail -n +"$((KEEP+1))" | xargs -r rm -f --
echo "backup ok: storage/backups/ringconn-$STAMP.db ($(ls storage/backups/ringconn-*.db | wc -l) kept)"
