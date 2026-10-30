#!/bin/bash
# Creates a self-signed code-signing certificate in your login keychain.
#
# Why: macOS ties Accessibility permission to an app's code signature. Ad-hoc signatures change on
# every build, so the permission silently stops working after each rebuild. Signing every build with
# the same certificate keeps the permission. This certificate is only for local development; public
# releases need a Developer ID certificate.
#
#   scripts/create-dev-cert.sh [name]                    create it (once)
#   scripts/create-dev-cert.sh --allow-codesign [name]   stop the keychain password prompt at every build
set -euo pipefail

ALLOW_ONLY=false
if [ "${1:-}" = "--allow-codesign" ]; then
  ALLOW_ONLY=true
  shift
fi
NAME="${1:-Slated Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Lets codesign use the key without asking. `security import -T` alone isn't enough since macOS 10.12:
# the key's partition list must include Apple's tools too, or every build asks for the login keychain
# password ("codesign wants to access key …"). macOS asks for that password once, here, in the terminal.
allow_codesign() {
  echo "macOS needs your login password once so that builds can sign without asking again."
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -t private -l "$NAME" "$KEYCHAIN" >/dev/null
  echo "Done: codesign can use \"$NAME\" without asking."
}

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
  if $ALLOW_ONLY; then
    allow_codesign
  else
    echo "\"$NAME\" already exists. If every build asks for your keychain password, run:"
    echo "  scripts/create-dev-cert.sh --allow-codesign"
  fi
  exit 0
elif $ALLOW_ONLY; then
  echo "There's no \"$NAME\" certificate yet: run 'make dev-cert' first." >&2
  exit 1
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
# Named after the certificate: keychain prompts call the key by the imported file's name.
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/$NAME.p12" -passout pass:slated-dev
security import "$TMP/$NAME.p12" -k "$KEYCHAIN" -P slated-dev -T /usr/bin/codesign >/dev/null
allow_codesign

echo "Created \"$NAME\". Builds made with 'make app' are now signed with it."
