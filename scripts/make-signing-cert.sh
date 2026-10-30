#!/bin/sh
# Creates a local, self-signed code signing certificate for Glint.
#
# Why this exists: an ad-hoc signature (`codesign -s -`) gives the app a
# designated requirement of `cdhash H"..."` — the hash of that exact binary.
# macOS ties the Screen Recording (TCC) grant to that requirement, so every
# rebuild produces a new identity and the permission silently stops applying.
# System Settings keeps showing "Glint" with the switch on, but it refers to a
# binary that no longer exists.
#
# Signing with a certificate instead gives a designated requirement of
# `identifier "com.brentc22.Glint" and certificate leaf = H"..."`. Both halves
# stay the same across rebuilds, so the grant survives.
#
# The certificate is self-signed and not trusted by the system. That is fine:
# codesign accepts it, and Gatekeeper already rejects this app either way
# (see Install in the README). It buys a stable identity,
# not trust.
#
# Release builds are signed with this same certificate in CI (see Releasing in the
# README), so installed copies accept updates and keep the grant across versions.
#
# Usage:
#   scripts/make-signing-cert.sh            create the identity in the login keychain
#   scripts/make-signing-cert.sh --export DIR
#                                           also write DIR/glint-signing.p12 and print its
#                                           base64, for the GitHub secret GLINT_SIGNING_P12
#                                           (the password "glint" goes in GLINT_SIGNING_PASSWORD)
#
# Safe to re-run: it does not create a second identity. With --export it writes the
# .p12 only on the run that creates the identity. If the identity already exists, the
# script prints the Keychain Access steps to export it by hand instead: `security export`
# cannot pick one identity out of the keychain (it dumps all of them), so it is not used.
# To remove it: Keychain Access > login > "Glint Self-Signed", delete. Releases signed
# with a different certificate are refused by every installed copy, so keep a backup.

set -eu

NAME="Glint Self-Signed"
PASSWORD="glint"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
EXPORT_DIR=""

if [ "${1:-}" = "--export" ]; then
    EXPORT_DIR="${2:-}"
    if [ -z "$EXPORT_DIR" ]; then
        echo "usage: $0 [--export <dir>]" >&2
        exit 2
    fi
elif [ $# -gt 0 ]; then
    echo "usage: $0 [--export <dir>]" >&2
    exit 2
fi

if security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "identity \"$NAME\" already exists — nothing to do"
    if [ -n "$EXPORT_DIR" ]; then
        cat >&2 <<EOF2
--export only works on the run that creates the identity, and "$NAME" already exists.
Export it from Keychain Access instead:
  1. Open Keychain Access, select the "login" keychain and the "My Certificates" tab.
  2. Select "$NAME" (expand it: the private key must be under it).
  3. File > Export Items..., format "Personal Information Exchange (.p12)", save as
     $EXPORT_DIR/glint-signing.p12 with the password "$PASSWORD".
  4. base64 -i $EXPORT_DIR/glint-signing.p12 | pbcopy
     and paste it into the GitHub secret GLINT_SIGNING_P12. The password goes into
     GLINT_SIGNING_PASSWORD. Delete the .p12 afterwards.
EOF2
        exit 1
    fi
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    >/dev/null 2>"$TMP/openssl.log" || { cat "$TMP/openssl.log" >&2; exit 1; }

# macOS `security` cannot read PKCS#12 files written with OpenSSL 3's default
# algorithms, so ask for the older ones explicitly. Without this the import
# fails with "MAC verification failed during PKCS12 import (wrong password?)",
# which is misleading — the password is fine.
openssl pkcs12 -export \
    -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" \
    -passout "pass:$PASSWORD" -name "$NAME" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 \
    >/dev/null 2>"$TMP/openssl.log" || { cat "$TMP/openssl.log" >&2; exit 1; }

# Only codesign may use the key without a prompt. Not `-A` (any app): the key is what
# makes a binary count as Glint for the Screen Recording grant, so a process that could
# sign with it silently could inherit that grant.
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign

echo "created code signing identity \"$NAME\""

if [ -n "$EXPORT_DIR" ]; then
    mkdir -p "$EXPORT_DIR"
    cp "$TMP/cert.p12" "$EXPORT_DIR/glint-signing.p12"
    echo "wrote $EXPORT_DIR/glint-signing.p12 (password: $PASSWORD)"
    echo "store this as the GitHub secret GLINT_SIGNING_P12:"
    base64 -i "$EXPORT_DIR/glint-signing.p12"
fi
echo "run 'make install' to sign Glint with it"
