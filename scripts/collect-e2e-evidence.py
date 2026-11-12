#!/usr/bin/env python3
import argparse
import base64
import json
import re
from pathlib import Path


def collect(log: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    reports = []
    for line in log.read_text(encoding="utf-8-sig").splitlines():
        media = re.search(r"E2E_(IMAGE|AUDIO) ([a-z-]+\.(?:png|wav)) ([A-Za-z0-9+/=]+)$", line)
        if media:
            (destination / media[2]).write_bytes(base64.b64decode(media[3], validate=True))
        start = line.find('{"checks":')
        if start >= 0:
            reports.append(json.loads(line[start:]))
    (destination / "checks.json").write_text(json.dumps(reports, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"reports": len(reports), "checks": sum(row["checks"] for row in reports),
                      "failures": sum(len(row["failed"]) for row in reports),
                      "unverified": [name for row in reports for name in row["unverified"]]}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("log", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    collect(args.log, args.destination)
