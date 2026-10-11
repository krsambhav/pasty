#!/usr/bin/env bash
# One-time setup, run on your Mac: creates a self-signed code-signing certificate for Pasty and
# stores it as GitHub Actions secrets, so every release is signed by the same identity.
#
# Why: macOS remembers the Accessibility permission per code signature. Ad-hoc builds get a new
# signature every time, so each update would need the permission granted again. With a stable
# certificate, the permission survives every update — and the updater only installs builds signed
# by that same certificate.
#
# Requires: the GitHub CLI (`brew install gh`, then `gh auth login`).
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/krsambhav/pasty/main/scripts/create-signing-identity.sh | bash
#   scripts/create-signing-identity.sh [owner/repo]
set -euo pipefail

REPO="${1:-krsambhav/pasty}"

if ! command -v gh >/dev/null; then
  echo "This needs the GitHub CLI. Install it with:  brew install gh && gh auth login" >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "Log in to GitHub first:  gh auth login" >&2
  exit 1
fi
if gh secret list --repo "$REPO" 2>/dev/null | grep -q '^MACOS_SIGNING_P12'; then
  echo "A signing identity is already configured for $REPO. Replacing it would make installed copies"
  echo "reject future updates (they only accept the same signer). Delete the MACOS_SIGNING_P12 secret"
  echo "first if you really want a new one."
  exit 1
fi
NAME="Pasty Self-Signed"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<CONF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CONF

# /usr/bin/openssl (LibreSSL) writes .p12 files that the macOS keychain can import.
/usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
PASSWORD="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/identity.p12" -passout "pass:$PASSWORD"

base64 -i "$WORK/identity.p12" | gh secret set MACOS_SIGNING_P12 --repo "$REPO"
printf '%s' "$PASSWORD" | gh secret set MACOS_SIGNING_PASSWORD --repo "$REPO"

echo "✓ Signing identity \"$NAME\" stored in $REPO's Actions secrets."
gh workflow run ci.yml --repo "$REPO" --ref main >/dev/null && echo "✓ Started a signed release build (takes ~5 minutes)."
echo
echo "When it finishes, install it once (this replaces the current copy):"
echo "  curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | bash"
echo "Then allow Pasty in System Settings › Privacy & Security › Accessibility one last time."
echo "Every update after that keeps the permission."
