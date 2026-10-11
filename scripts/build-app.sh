#!/usr/bin/env bash
# Builds a universal (Apple Silicon + Intel) Release Pasty.app into build/Release and zips it.
# Usage: scripts/build-app.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-Release}"
DERIVED="build/DerivedData"

# Versioning: CI passes its run number so every release has a higher CFBundleVersion, which is
# what the in-app updater compares. Local builds stay at 1.0.0 (1).
BUILD_NUMBER="${BUILD_NUMBER:-1}"
MARKETING_VERSION="${MARKETING_VERSION:-1.0.$((BUILD_NUMBER > 1 ? BUILD_NUMBER : 0))}"

# Signing: ad hoc by default. With SIGN_IDENTITY (and optionally SIGN_KEYCHAIN), builds are signed
# with that certificate, which keeps macOS permissions (Accessibility) across updates.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SIGN_FLAGS="--timestamp=none"
if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then SIGN_FLAGS="$SIGN_FLAGS --keychain $SIGN_KEYCHAIN"; fi
echo "Building $MARKETING_VERSION ($BUILD_NUMBER), signing identity: $SIGN_IDENTITY"

xcodebuild \
  -project Pasty.xcodeproj \
  -scheme Pasty \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  OTHER_CODE_SIGN_FLAGS="$SIGN_FLAGS" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  MARKETING_VERSION="$MARKETING_VERSION" \
  build > build-xcodebuild.log 2>&1 || true
grep -E "warning:" build-xcodebuild.log | grep -v "^note" | sort -u | head -80 || true

if ! grep -q "BUILD SUCCEEDED" build-xcodebuild.log; then
  echo "xcodebuild failed. Errors:" >&2
  grep -E "error:" build-xcodebuild.log | sort -u | head -150 >&2 || tail -60 build-xcodebuild.log >&2
  exit 1
fi

mkdir -p "build/$CONFIGURATION"
rm -rf "build/$CONFIGURATION/Pasty.app"
cp -R "$DERIVED/Build/Products/$CONFIGURATION/Pasty.app" "build/$CONFIGURATION/Pasty.app"
codesign --verify --deep --strict "build/$CONFIGURATION/Pasty.app"
ditto -c -k --keepParent "build/$CONFIGURATION/Pasty.app" build/Pasty.zip
(cd build && shasum -a 256 Pasty.zip > Pasty.zip.sha256)
echo "Built build/$CONFIGURATION/Pasty.app"
