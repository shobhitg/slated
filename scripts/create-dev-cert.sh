#!/bin/bash
# Creates a self-signed code-signing certificate in your login keychain.
#
# Why: macOS ties Accessibility permission to an app's code signature. Ad-hoc signatures change on
# every build, so the permission silently stops working after each rebuild. Signing every build with
# the same certificate keeps the permission. This certificate is only for local development; public
# releases need a Developer ID certificate.
set -euo pipefail

NAME="${1:-Slated Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# macOS's LibreSSL writes PKCS#12 files that `security import` understands.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/cert.p12" -passout pass:slated-dev
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P slated-dev -T /usr/bin/codesign >/dev/null

echo "Created \"$NAME\". Builds made with 'make app' are now signed with it."
echo "If macOS asks whether codesign may use the key, choose \"Always Allow\"."
