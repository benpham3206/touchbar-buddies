#!/bin/zsh
# Builds the app and zips it into dist/TouchBarBuddies.zip, ready to attach to a GitHub Release.
set -euo pipefail
cd "${0:A:h}"

zsh ./build.sh
mkdir -p dist
# ditto keeps the app bundle's permissions and signature intact (plain zip can break them).
ditto -c -k --keepParent build/TouchBarBuddies.app dist/TouchBarBuddies.zip
echo "packaged dist/TouchBarBuddies.zip"
