#!/usr/bin/env python3
"""
Seed a ConnectionProfile into the geistty app's UserDefaults on a booted
iOS Simulator so testReconnectLastButton can verify the home-screen
Reconnect button.

The profile is written to ConnectionProfileManager's "connection_profiles"
UserDefaults key as JSON-encoded data (matching how the Swift JSONEncoder
+ UserDefaults.set(_:forKey:) round-trip stores it). lastConnectedAt is
set to ~30s ago so the profile lands in `recents.first` immediately on
launch.

Usage:
    python3 tools/seed_recent_profile.py [DEVICE_UDID]

DEVICE_UDID defaults to "booted". Bundle id is hardcoded as com.geistty.app.

Notes:
- The simctl get_app_container path is the *data* container (per-app
  sandbox), which contains Library/Preferences/<bundle-id>.plist once
  the app has launched at least once. We tolerate a missing file by
  creating an empty plist on the fly.
- Date encoding: Swift's JSONEncoder defaults to .deferredToDate which
  serializes Date as a TimeInterval since the Cocoa reference date
  (2001-01-01 UTC). We match exactly.
"""
import json, plistlib, uuid, datetime, pathlib, subprocess, sys, os

BUNDLE_ID = "com.geistty.app"
HOST = "test.rebex.net"
USERNAME = "demo"
PORT = 22

def app_container(udid: str) -> pathlib.Path:
    out = subprocess.check_output(
        ["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"],
        text=True,
    ).strip()
    return pathlib.Path(out)

def main(udid: str = "booted") -> int:
    container = app_container(udid)
    plist_path = container / "Library" / "Preferences" / f"{BUNDLE_ID}.plist"
    plist_path.parent.mkdir(parents=True, exist_ok=True)

    ref = datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)
    now = datetime.datetime.now(datetime.timezone.utc)
    secs = (now - ref).total_seconds()

    profile = {
        "id": str(uuid.uuid4()).upper(),
        "name": f"{HOST} ({USERNAME})",
        "host": HOST,
        "port": PORT,
        "username": USERNAME,
        "authMethod": "password",
        "useTmux": False,
        "enableFilesIntegration": False,
        "createdAt": secs - 60,
        "lastConnectedAt": secs - 30,
        "isFavorite": False,
    }
    profiles_data = json.dumps([profile]).encode("utf-8")

    existing: dict = {}
    if plist_path.exists():
        existing = plistlib.loads(plist_path.read_bytes())
    existing["connection_profiles"] = profiles_data
    plist_path.write_bytes(plistlib.dumps(existing, fmt=plistlib.FMT_BINARY))

    print(f"seeded {USERNAME}@{HOST}:{PORT} into {plist_path}")
    print(f"  payload: {len(profiles_data)} bytes")
    print(f"  lastConnectedAt: {now - datetime.timedelta(seconds=30)}")
    return 0

if __name__ == "__main__":
    udid = sys.argv[1] if len(sys.argv) > 1 else "booted"
    sys.exit(main(udid))
