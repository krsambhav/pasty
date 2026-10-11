#!/usr/bin/env bash
# Builds a universal (Apple Silicon + Intel) Release Pasty.app into build/Release and zips it.
# Usage: scripts/build-app.sh [Debug|Release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIGURATION="${1:-Release}"
DERIVED="build/DerivedData"

xcodebuild \
  -project Pasty.xcodeproj \
  -scheme Pasty \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" \
  build | tee build-xcodebuild.log | grep -E "^(\*\*|.*(error|warning):)" || true

if ! grep -q "BUILD SUCCEEDED" build-xcodebuild.log; then
  echo "xcodebuild failed — last 60 lines:" >&2
  tail -60 build-xcodebuild.log >&2
  exit 1
fi

mkdir -p "build/$CONFIGURATION"
rm -rf "build/$CONFIGURATION/Pasty.app"
cp -R "$DERIVED/Build/Products/$CONFIGURATION/Pasty.app" "build/$CONFIGURATION/Pasty.app"
ditto -c -k --keepParent "build/$CONFIGURATION/Pasty.app" build/Pasty.zip
echo "Built build/$CONFIGURATION/Pasty.app"
