#!/bin/bash
# Pinned toolchain setup for CI: XcodeGen 2.46.0 by checksum, project generation, and the committed
# Package.resolved so SwiftPM resolves exactly the reviewed KeyboardShortcuts revision.
set -euo pipefail
XG_VERSION=2.46.0
XG_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
curl -fsSL -o /tmp/xcodegen.zip "https://github.com/yonaskolb/XcodeGen/releases/download/${XG_VERSION}/xcodegen.zip"
echo "${XG_SHA256}  /tmp/xcodegen.zip" | shasum -a 256 -c -
rm -rf /tmp/xcodegen && unzip -q /tmp/xcodegen.zip -d /tmp
/tmp/xcodegen/bin/xcodegen version
/tmp/xcodegen/bin/xcodegen generate
mkdir -p ShareXMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved ShareXMac.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
