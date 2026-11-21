#!/usr/bin/env bash
# Decrypt the build for this OS. The private key only exists in $RUNNER_TEMP for the length of this script.
set -eu
TAG=$1
umask 077
K="$RUNNER_TEMP/.k.pem"
trap 'rm -f "$K"' EXIT
printf '%s' "$SEEDFALL_KEY" | base64 --decode > "$K" 2>/dev/null || { echo "key decode failed"; exit 1; }
cat build/$TAG.p7m.part-* > "$RUNNER_TEMP/$TAG.p7m"
( cd build && shasum -a 256 -c "$TAG.sha256" >/dev/null 2>&1 ) || { echo "build parts corrupted"; exit 1; }
mkdir -p work
# macOS: stock LibreSSL first (same tool as the owner's decrypt one-liner), Linux: OpenSSL
OSSL=openssl
[ "$TAG" = "mac" ] && OSSL=/usr/bin/openssl
if ! "$OSSL" smime -decrypt -binary -inform DER -inkey "$K" -in "$RUNNER_TEMP/$TAG.p7m" -out "$RUNNER_TEMP/$TAG.tar" >/dev/null 2>&1; then
  openssl smime -decrypt -binary -inform DER -inkey "$K" -in "$RUNNER_TEMP/$TAG.p7m" -out "$RUNNER_TEMP/$TAG.tar" >/dev/null 2>&1 || { echo "decrypt failed"; exit 1; }
  echo "decrypt: fallback openssl" > "$RUNNER_TEMP/decrypt_note"
else
  echo "decrypt: $OSSL ok" > "$RUNNER_TEMP/decrypt_note"
fi
rm -f "$K"
tar -xf "$RUNNER_TEMP/$TAG.tar" -C work >/dev/null 2>&1
rm -f "$RUNNER_TEMP/$TAG.p7m" "$RUNNER_TEMP/$TAG.tar"
if [ "$TAG" = "mac" ]; then
  ( cd work && unzip -q game.zip >/dev/null 2>&1 && rm -f game.zip )
fi
echo "build ready"
