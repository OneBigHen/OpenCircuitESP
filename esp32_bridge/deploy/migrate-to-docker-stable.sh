#!/usr/bin/env bash
# Stand up the collector on docker-stable with a copy of the live archive. Does NOT cut the ESP32 over
# and does NOT stop the source collector: both run side by side until you switch (see PRODUCTION.md).
# Run from the docker-dev checkout:  deploy/migrate-to-docker-stable.sh [--yes]
set -euo pipefail
DEST_HOST="${DEST_HOST:-docker-stable}"; DEST_DIR=/srv/ringbridge
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
[ "${1:-}" = "--yes" ] || { echo "This copies the collector, its .env keys and a snapshot of the archive to $DEST_HOST:$DEST_DIR. Re-run with --yes."; exit 1; }

echo "== preflight"
ssh -o BatchMode=yes "$DEST_HOST" 'docker --version >/dev/null && ! ss -ltn | grep -q ":8765 "' || { echo "docker missing or port 8765 busy on $DEST_HOST"; exit 1; }
[ -f "$ROOT/.env" ] || { echo "missing $ROOT/.env"; exit 1; }

echo "== consistent snapshot of the live archive"
SNAP="migrate-$(date +%Y%m%d-%H%M%S).db"
docker exec ringconn-collector python /app/archive_tools.py backup --database /data/ringconn.db --output "/data/backups/$SNAP"

echo "== copy source, compose, keys and snapshot"
ssh "$DEST_HOST" "mkdir -p $DEST_DIR/src/esp32_bridge $DEST_DIR/storage && chmod 700 $DEST_DIR/storage"
rsync -a --delete --exclude storage --exclude .env --exclude '__pycache__' --exclude firmware/.pio --exclude firmware/include/secrets.h \
  "$ROOT/collector" "$ROOT/deploy" "$DEST_HOST:$DEST_DIR/src/esp32_bridge/"
ssh "$DEST_HOST" "cp $DEST_DIR/src/esp32_bridge/deploy/docker-stable/compose.yaml $DEST_DIR/compose.yaml && cp $DEST_DIR/src/esp32_bridge/deploy/backup.sh $DEST_DIR/backup.sh && chmod +x $DEST_DIR/backup.sh"
scp -q "$ROOT/.env" "$DEST_HOST:$DEST_DIR/.env" && ssh "$DEST_HOST" "chmod 600 $DEST_DIR/.env"
scp -q "$ROOT/storage/backups/$SNAP" "$DEST_HOST:$DEST_DIR/storage/ringconn.db"
ssh "$DEST_HOST" "mkdir -p $DEST_DIR/storage/backups && chown -R 10001:10001 $DEST_DIR/storage && chmod 700 $DEST_DIR/storage/backups"

echo "== start and verify"
ssh "$DEST_HOST" "cd $DEST_DIR && docker compose up -d --build"
for i in $(seq 1 30); do
  [ "$(ssh "$DEST_HOST" 'docker inspect -f "{{.State.Health.Status}}" ringconn-collector 2>/dev/null')" = healthy ] && break; sleep 3
done
ssh "$DEST_HOST" 'docker inspect -f "container health: {{.State.Health.Status}}" ringconn-collector'
ssh "$DEST_HOST" "cd $DEST_DIR && docker exec ringconn-collector python /app/archive_tools.py check --database /data/ringconn.db"
echo "== install the daily backup timer"
ssh "$DEST_HOST" "sudo cp $DEST_DIR/src/esp32_bridge/deploy/ringbridge-backup.* /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable --now ringbridge-backup.timer && systemctl list-timers ringbridge-backup.timer --no-pager | head -3"
echo "Done. Collector is up on $DEST_HOST:8765 with a snapshot of the archive. Cut over per PRODUCTION.md."
