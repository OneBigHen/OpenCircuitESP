"""Add-on entrypoint: turn /data/options.json into the collector's environment, then start it."""
import json, os, sys

options = json.load(open("/data/options.json"))
env = {
    "RING_DB": "/data/ringconn.db",
    "RING_TOKEN": options.get("ring_token", ""),
    "RING_VIEW_TOKEN": options.get("view_token", ""),
    "RING_HA_TOKEN": options.get("ha_token", ""),
    "RING_SECURE_COOKIE": "1" if options.get("secure_cookie") else "0",
}
if len(env["RING_TOKEN"]) < 20:
    sys.exit("Set ring_token in the add-on options to a random string of at least 20 characters.")
for key, value in env.items():
    if value or key == "RING_SECURE_COOKIE":
        os.environ[key] = value
    else:
        os.environ.pop(key, None)
os.execv(sys.executable, [sys.executable, "-u", "/app/app.py"])
