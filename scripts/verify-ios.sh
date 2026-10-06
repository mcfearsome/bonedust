#!/usr/bin/env bash
#
# Compiles every iOS source file against the iOS SDK without needing a simulator
# runtime or a provisioning profile.
#
# Why this exists: `xcodebuild` refuses to build without a usable destination, and a
# machine can easily have the SDK installed but no matching simulator runtime (see
# DECISIONS.md, "Toolchain"). This drives swiftc directly, so a type error or an
# exclusivity violation is caught in about twenty seconds regardless.
#
# It is a compile check, not a test run. `make test-core` runs the simulation and
# economy suites; `make test-app` runs the app-layer suite once a runtime exists.

set -euo pipefail

cd "$(dirname "$0")/.."

SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
PLATFORM=$(xcrun --sdk iphonesimulator --show-sdk-platform-path)
TARGET=${TARGET:-arm64-apple-ios17.0-simulator}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# SwiftPM generates the Bundle.module accessor during a package build. Compiling the
# sources by hand means providing it.
cat > "$WORK/BundleModuleStub.swift" <<'STUB'
import Foundation
extension Bundle {
    static let module = Bundle.main
}
STUB

echo "==> BonedustCore for $TARGET"
xcrun -sdk iphonesimulator swiftc \
  -target "$TARGET" -sdk "$SDK" \
  -swift-version 6 \
  -module-name BonedustCore -emit-module \
  -emit-module-path "$WORK/BonedustCore.swiftmodule" \
  $(find ios/BonedustCore/Sources/BonedustCore -name '*.swift') \
  "$WORK/BundleModuleStub.swift"

echo "==> Bonedust app module"
xcrun -sdk iphonesimulator swiftc \
  -target "$TARGET" -sdk "$SDK" \
  -swift-version 5 -enable-testing -parse-as-library \
  -module-name Bonedust -emit-module \
  -emit-module-path "$WORK/Bonedust.swiftmodule" \
  -I "$WORK" \
  $(find ios/Bonedust -name '*.swift')

echo "==> BonedustTests"
xcrun -sdk iphonesimulator swiftc \
  -target "$TARGET" -sdk "$SDK" \
  -swift-version 5 -typecheck -enable-testing \
  -I "$WORK" -I "$PLATFORM/Developer/usr/lib" \
  -F "$PLATFORM/Developer/Library/Frameworks" \
  $(find ios/BonedustTests -name '*.swift')

echo "==> BonedustUITests"
xcrun -sdk iphonesimulator swiftc \
  -target "$TARGET" -sdk "$SDK" \
  -swift-version 5 -typecheck \
  -I "$PLATFORM/Developer/usr/lib" \
  -F "$PLATFORM/Developer/Library/Frameworks" \
  $(find ios/BonedustUITests -name '*.swift')

echo "==> every iOS source compiles"
