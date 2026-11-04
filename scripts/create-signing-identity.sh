#!/bin/sh
# Create a self-signed code-signing identity for local builds of Browser Picker.
#
#   scripts/create-signing-identity.sh                 # "Browser Picker Local" in the login keychain
#   scripts/create-signing-identity.sh --name "X"      # another name
#   scripts/create-signing-identity.sh --keychain PATH # another keychain (absolute path)
#   scripts/create-signing-identity.sh --dry-run       # print what it would do
#   scripts/create-signing-identity.sh --no-trust      # skip step 3 (for testing; codesign
#                                                      # will not use the identity)
#
# Why: macOS keeps the Accessibility and Automation grants by the app's
# designated requirement. An ad-hoc signature's requirement is its cdhash,
# which changes with every build, so every rebuild loses the grants. With a
# certificate the requirement is "this bundle ID, signed by this certificate",
# which stays the same across rebuilds, so the grants survive. `make install`
# picks up an identity with this name by itself.
#
# What it does, once (it exits early when the identity already exists):
#   1. makes a 2048-bit RSA key and a self-signed certificate, valid for ten
#      years, with the code-signing extended key usage, in a private temp dir;
#   2. imports both into the keychain, letting /usr/bin/codesign use the key;
#   3. trusts the certificate for code signing only, for your user. codesign
#      refuses an untrusted identity ("no identity found"). macOS asks for
#      your password to confirm this step.
# The private key never leaves the keychain afterwards: the temp dir is
# deleted on exit. The certificate can sign code on this Mac only; it is not
# trusted anywhere else and Gatekeeper does not accept it for downloads.
#
# To undo (the trust setting first, while the certificate is still there):
#   security find-certificate -c "Browser Picker Local" -p > bp.pem
#   security remove-trusted-cert bp.pem && rm bp.pem
#   security delete-identity -c "Browser Picker Local"   # key and certificate
set -eu

name="Browser Picker Local"
keychain="$HOME/Library/Keychains/login.keychain-db"
dry_run=0
trust=1

while [ $# -gt 0 ]; do
  case "$1" in
    --name) name=${2:?--name needs a value}; shift 2 ;;
    --keychain) keychain=${2:?--keychain needs a path}; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    --no-trust) trust=0; shift ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (see --help)" >&2; exit 2 ;;
  esac
done

case "$keychain" in
  /*) ;;
  # `security` resolves a bare name to ~/Library/Keychains/<name>, not to the
  # current directory, so insist on a full path.
  *) echo "--keychain needs an absolute path, got: $keychain" >&2; exit 2 ;;
esac
[ -f "$keychain" ] || { echo "no such keychain: $keychain" >&2; exit 1; }

# The OpenSSL in /usr/bin is LibreSSL, whose PKCS#12 defaults `security
# import` can read. Homebrew's OpenSSL 3 defaults to AES/PBKDF2, which it
# cannot ("MAC verification failed"), so use /usr/bin/openssl explicitly.
OPENSSL=/usr/bin/openssl

if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
  echo "A certificate named \"$name\" is already in $keychain:"
  security find-identity -p codesigning "$keychain" | grep -F "\"$name\"" || true
  echo "Nothing to do. If it shows CSSMERR_TP_NOT_TRUSTED, trust it for code signing:"
  echo "  security find-certificate -c \"$name\" -p \"$keychain\" > /tmp/bp.pem"
  echo "  security add-trusted-cert -r trustRoot -p codeSign -k \"$keychain\" /tmp/bp.pem"
  exit 0
fi

if [ "$dry_run" = 1 ]; then
  echo "would create a self-signed code-signing identity \"$name\" in $keychain,"
  echo "allow /usr/bin/codesign to use its key, and trust it for code signing (asks for your password)"
  exit 0
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bp-identity.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM
umask 077

cat > "$tmp/req.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

"$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -config "$tmp/req.cnf" -extensions ext \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null

# A throwaway password: the bundle exists only to carry the key into the
# keychain and is deleted with the temp dir.
pass=$("$OPENSSL" rand -hex 16)
"$OPENSSL" pkcs12 -export -name "$name" -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -out "$tmp/identity.p12" -passout "pass:$pass"

# -T: codesign may use the key without a keychain prompt each time.
security import "$tmp/identity.p12" -k "$keychain" -f pkcs12 -P "$pass" -T /usr/bin/codesign >/dev/null
echo "imported \"$name\" into $keychain"

# User-domain trust for code signing only. macOS shows a password dialog.
if [ "$trust" = 0 ]; then
  echo "skipped the trust step (--no-trust)"
  security find-identity -p codesigning "$keychain" | grep -F "\"$name\""
  exit 0
fi
echo "trusting it for code signing (macOS asks for your password)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$tmp/cert.pem"

echo
security find-identity -v -p codesigning "$keychain" | grep -F "\"$name\"" || {
  echo "\"$name\" is in the keychain but not yet a valid code-signing identity." >&2
  exit 1
}
cat <<EOF

Done. \`make install\` now signs with "$name" (or pass SIGN_IDENTITY="$name").
The first build may ask to let codesign use the key: choose Always Allow.
After the first install with it, allow Browser Picker under Accessibility
once more. Later rebuilds keep the grant.
EOF
