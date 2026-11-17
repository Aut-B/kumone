import json
import re
import sys

data = json.load(sys.stdin)
candidates = []
for runtime, devices in data["devices"].items():
    version_match = re.search(r"(\d+)-(\d+)", runtime)
    version = tuple(map(int, version_match.groups())) if version_match else (0, 0)
    for device in devices:
        name = device.get("name", "")
        if device.get("isAvailable") and "iPhone" in name:
            score = (version, 1 if "Pro Max" in name else 0, name)
            candidates.append((score, device["udid"], name))

if not candidates:
    sys.exit("No available iPhone simulator")

_, simulator_udid, simulator_name = max(candidates, key=lambda item: item[0])
print(f"Selected iPhone simulator: {simulator_name} ({simulator_udid})", file=sys.stderr)
print(simulator_udid)
