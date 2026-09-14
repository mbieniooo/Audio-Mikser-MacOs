#!/bin/bash
# Creates the local self-signed code-signing identity "Mikser Dev" in the login keychain, once.
# Why: macOS keys the System Audio Recording permission to the signing identity, so every build
# must be signed by the same certificate or the permission prompt keeps coming back.
# Dialogs you may see once: a trust-settings authorization (your login password) and, on the first
# codesign, "codesign wants to use the key" — click "Always Allow".
set -euo pipefail

NAME="Mikser Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

valid()   { security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; }
present() { security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; }

if valid; then
  echo "identity already present and valid:"
  security find-identity -v -p codesigning "$KEYCHAIN" | grep "\"$NAME\""
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if present; then
  echo "identity exists but is not yet trusted for code signing; setting trust only"
  security find-certificate -c "$NAME" -p "$KEYCHAIN" > "$TMP/cert.pem"
else
  cat > "$TMP/openssl.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = Mieszko
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
CNF
  openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" >/dev/null 2>&1
  PASS="$(openssl rand -hex 16)"
  if ! openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/mikser.p12" \
       -passout "pass:$PASS" -name "$NAME" >/dev/null 2>&1; then
    openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/mikser.p12" \
       -passout "pass:$PASS" -name "$NAME" >/dev/null 2>&1
  fi
  security import "$TMP/mikser.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  echo "imported the key and certificate into the login keychain"
fi

if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"; then
  echo "could not set the trust setting automatically."
fi

if valid; then
  echo "identity ready:"
  security find-identity -v -p codesigning "$KEYCHAIN" | grep "\"$NAME\""
  openssl x509 -in "$TMP/cert.pem" -noout -fingerprint -sha1
else
  cat <<MSG
The certificate is imported but macOS does not yet trust it for code signing.
Do this once, by hand:
  1. Open Keychain Access, choose the "login" keychain, category "My Certificates".
  2. Double-click "$NAME", open "Trust".
  3. Set "Code Signing" to "Always Trust", close the window, enter your password.
Then run scripts/make-cert.sh again to confirm.
MSG
  exit 1
fi
