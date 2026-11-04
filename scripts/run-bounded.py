#!/usr/bin/env python3
"""Bound a native check even when its main run loop stops servicing timers."""
import argparse
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.timeout <= 0 or not command:
        parser.error("a positive timeout and command are required")
    args.log.parent.mkdir(parents=True, exist_ok=True)
    with args.log.open("wb") as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT)
        try:
            return process.wait(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            print(f"Timed out after {args.timeout:g}s: {command[0]}", flush=True)
            if sys.platform == "darwin":
                try:
                    subprocess.run(["/usr/bin/sample", str(process.pid), "2", "-file",
                                    str(args.log.with_suffix(".sample.txt"))],
                                   stdout=log, stderr=subprocess.STDOUT, timeout=10, check=False)
                except (OSError, subprocess.TimeoutExpired) as error:
                    print(f"Stack sample unavailable: {error}", flush=True)
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            return 124


if __name__ == "__main__":
    sys.exit(main())
