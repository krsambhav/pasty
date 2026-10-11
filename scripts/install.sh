#!/usr/bin/env bash
# Installs Pasty — or updates an existing install — from the latest GitHub release.
#   curl -fsSL https://raw.githubusercontent.com/krsambhav/pasty/main/scripts/install.sh | bash
set -euo pipefail

REPO="${PASTY_REPO:-krsambhav/pasty}"
DEST="${PASTY_INSTALL_DIR:-/Applications}"
APP="$DEST/Pasty.app"
BASE="${PASTY_DOWNLOAD_BASE:-https://github.com/$REPO/releases/latest/download}"

if [[ "$(uname)" != "Darwin" ]]; then echo "Pasty runs on macOS only." >&2; exit 1; fi
major="$(sw_vers -productVersion | cut -d. -f1)"
if (( major < 14 )); then echo "Pasty needs macOS 14 Sonoma or later." >&2; exit 1; fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "→ Downloading the latest Pasty…"
curl -fsSL "$BASE/Pasty.zip" -o "$WORK/Pasty.zip"
curl -fsSL "$BASE/Pasty.zip.sha256" -o "$WORK/Pasty.zip.sha256"
(cd "$WORK" && shasum -a 256 -c Pasty.zip.sha256 >/dev/null) || { echo "Checksum mismatch — aborting." >&2; exit 1; }
ditto -x -k "$WORK/Pasty.zip" "$WORK/unpacked"
NEW_VERSION="$(defaults read "$WORK/unpacked/Pasty.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"

if [[ -d "$APP" ]]; then
  OLD_VERSION="$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
  echo "→ Updating Pasty $OLD_VERSION → $NEW_VERSION"
else
  echo "→ Installing Pasty $NEW_VERSION"
fi

# Quit a running copy so its bundle can be replaced.
if pgrep -x Pasty >/dev/null; then
  osascript -e 'tell application id "com.krsambhav.Pasty" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do pgrep -x Pasty >/dev/null || break; sleep 0.2; done
  pkill -x Pasty 2>/dev/null || true
fi

rm -rf "$APP"
mv "$WORK/unpacked/Pasty.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
[[ -n "${PASTY_NO_LAUNCH:-}" ]] || open "$APP"

echo "✓ Pasty $NEW_VERSION is installed in $DEST and running. Press ⌘⇧V to open it."
echo "  It keeps itself up to date from now on."
