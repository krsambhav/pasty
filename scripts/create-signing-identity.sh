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
# Usage: scripts/create-signing-identity.sh [owner/repo]
set -euo pipefail

REPO="${1:-krsambhav/pasty}"
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

echo "Done. The next push to main publishes a release signed by \"$NAME\"."
echo "Install that release once (and allow Accessibility once); every later update keeps the permission."
