#!/bin/bash
# Run only on a disposable macOS account. This probe changes its login-item registration.
set -euo pipefail
APP="$PWD/build/Build/Products/Debug/ShareX.app"
test ! -e "$APP"
mkdir -p "$APP/Contents/MacOS"
cat > build/LoginProbe.swift <<'SWIFT'
import AppKit

@main
@MainActor
enum LoginProbe {
    static func main() {
        _ = NSApplication.shared
        E2ELaunchAtLogin.run(CommandLine.arguments.last ?? "default")
    }
}
SWIFT
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib
import sys
from pathlib import Path

Path(sys.argv[1]).write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "com.sharexmac.ShareX", "CFBundleExecutable": "ShareX",
    "CFBundleName": "ShareX", "CFBundlePackageType": "APPL", "CFBundleVersion": "6",
    "CFBundleShortVersionString": "0.1.5", "LSUIElement": True, "LSMinimumSystemVersion": "14.0",
}))
PY
swiftc -parse-as-library -swift-version 6 -target arm64-apple-macosx14.0 -D SHAREX_E2E \
  App/Sources/LaunchAtLogin.swift App/Sources/E2ELaunchAtLogin.swift build/LoginProbe.swift \
  -o "$APP/Contents/MacOS/ShareX"
bash scripts/e2e-login.sh
