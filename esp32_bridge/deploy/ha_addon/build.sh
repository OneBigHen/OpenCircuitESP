#!/usr/bin/env bash
# Assemble a ready-to-install add-on folder: ./dist/ringconn_collector (collector sources + add-on files).
# Copy that folder to /addons/ringconn_collector on Home Assistant (Samba share "addons"), then
# Settings > Add-ons > Add-on store > Check for updates > Local add-ons > RingConn Collector.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; SRC="$HERE/../../collector"; OUT="$HERE/dist/ringconn_collector"
rm -rf "$OUT"; mkdir -p "$OUT/app"
cp "$HERE/ringconn_collector/"{config.yaml,Dockerfile,run.py,DOCS.md} "$OUT/"
cp "$SRC/"{app.py,browser_auth.py,health_views.py,observations.py,archive_tools.py} "$OUT/app/"
cp -r "$SRC/web" "$OUT/app/web"
echo "built $OUT"
