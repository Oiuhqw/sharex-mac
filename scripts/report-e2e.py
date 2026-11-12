#!/usr/bin/env python3
import base64
import json
from pathlib import Path


def report(root: Path) -> None:
    for path in sorted(root.rglob("results.json")):
        data = json.loads(path.read_text())
        checks = data.get("results", [])
        failed = [row for row in checks if not row.get("pass") and row.get("status") != "unverifiable"]
        unverified = [row.get("name") for row in checks if row.get("status") == "unverifiable"]
        print(json.dumps({"file": str(path), "checks": len(checks), "failed": failed,
                          "unverified": unverified, "pass": data.get("pass")}, sort_keys=True))
    for name in ["round-loupe.png", "style-feedback.png", "smart-erase.png", "loupe.png", "onscreen-orientation.png"]:
        path = root / name
        if path.is_file() and path.stat().st_size <= 250_000:
            print(f"E2E_IMAGE {name} {base64.b64encode(path.read_bytes()).decode('ascii')}")
    sound = root / "capture-click.wav"
    if sound.is_file() and sound.stat().st_size <= 250_000:
        print(f"E2E_AUDIO {sound.name} {base64.b64encode(sound.read_bytes()).decode('ascii')}")


if __name__ == "__main__":
    report(Path("e2e-out"))
    report(Path("perf-out"))
    for name in ["runner-before.log", "runner-after.log"]:
        path = Path("perf-out") / name
        if path.is_file():
            print(f"PERF_CONTEXT {name}\n{path.read_text()}")
