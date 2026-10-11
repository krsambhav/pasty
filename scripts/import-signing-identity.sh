#!/usr/bin/env bash
# CI helper: imports the code-signing identity from the MACOS_SIGNING_P12 (base64) and
# MACOS_SIGNING_PASSWORD secrets into a temporary keychain, and exports SIGN_IDENTITY and
# SIGN_KEYCHAIN for scripts/build-app.sh. Does nothing when the secret isn't set.
set -euo pipefail

if [[ -z "${MACOS_SIGNING_P12:-}" ]]; then
  echo "No signing identity configured; building ad hoc."
  exit 0
fi

KEYCHAIN="$RUNNER_TEMP/pasty-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"
P12="$RUNNER_TEMP/pasty-signing.p12"
echo "$MACOS_SIGNING_P12" | base64 --decode > "$P12"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$P12" -k "$KEYCHAIN" -P "${MACOS_SIGNING_PASSWORD:-}" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" > /dev/null
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')

# A self-signed certificate must be trusted for code signing before codesign will use it.
CERT="$RUNNER_TEMP/pasty-signing.cer"
IDENTITY="$(security find-certificate -a -k "$KEYCHAIN" | sed -n 's/.*"alis"<blob>="\(.*\)"/\1/p' | head -1)"
security find-certificate -c "$IDENTITY" -p "$KEYCHAIN" > "$CERT"
sudo security add-trusted-cert -d -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT"
security find-identity -v -p codesigning "$KEYCHAIN"
rm -f "$P12"

echo "SIGN_IDENTITY=$IDENTITY" >> "$GITHUB_ENV"
echo "SIGN_KEYCHAIN=$KEYCHAIN" >> "$GITHUB_ENV"
echo "Signing with: $IDENTITY"
