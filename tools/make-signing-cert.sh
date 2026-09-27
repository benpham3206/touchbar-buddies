#!/bin/zsh
# Creates a self-signed code-signing certificate, "TouchBarBuddies Local", in your login keychain (once).
# build.sh signs with it when it's there, so every build keeps the same signature and macOS remembers the
# Accessibility permission across updates (ad-hoc builds get a new signature each time, so it resets).
# The certificate stays on this Mac and is only good for signing your own builds. Remove it any time in
# Keychain Access (login keychain > My Certificates); builds then go back to ad-hoc signing.
set -euo pipefail
NAME="TouchBarBuddies Local"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "\"$NAME\" is already in your keychain."
  exit 0
fi
SSL=/usr/bin/openssl   # macOS's own LibreSSL writes a .p12 that `security import` reads as is
tmp=$(mktemp -d)
cd "$tmp"
$SSL req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" -keyout key.pem -out cert.pem \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null
pass=$($SSL rand -hex 16)
$SSL pkcs12 -export -inkey key.pem -in cert.pem -name "$NAME" -out id.p12 -passout "pass:$pass"
# -T: codesign may use the key without asking every build.
security import id.p12 -k "$HOME/Library/Keychains/login.keychain-db" -P "$pass" -T /usr/bin/codesign >/dev/null
cd /
/usr/bin/trash "$tmp"   # the key now lives only in the keychain
echo "Added \"$NAME\" to your login keychain. Run ./install.sh, then allow Accessibility one last time."
