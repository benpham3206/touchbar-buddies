#!/bin/zsh
# Builds build/TouchBarBuddies.app: one universal binary (Apple Silicon + Intel) for macOS 12 or newer,
# signed (see the end). Overwrites in place; nothing is deleted.
#
#   ./build.sh            universal (what install.sh and package.sh ship)
#   ./build.sh --native   this Mac's CPU only: twice as fast, for trying changes (./tbb uses it)
set -euo pipefail
cd "${0:A:h}"

APP=build/TouchBarBuddies.app
MIN_MACOS=12.0   # keep in sync with LSMinimumSystemVersion in Info.plist
ARCHS=(arm64 x86_64)
[[ ${1:-} == --native ]] && ARCHS=($(uname -m))

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Compile once per CPU type, then join them into one binary.
for arch in $ARCHS; do
  extra=()
  # Newer Command Line Tools ship Swift's back-compat libraries for Apple Silicon only,
  # so the Intel build links without them.
  [[ $arch == x86_64 ]] && extra=(-runtime-compatibility-version none)
  swiftc -O -swift-version 5 -target $arch-apple-macosx$MIN_MACOS $extra Sources/*.swift -o build/TouchBarBuddies-$arch
done
lipo -create build/TouchBarBuddies-${^ARCHS} -output "$APP/Contents/MacOS/TouchBarBuddies"

cp -f Info.plist "$APP/Contents/Info.plist"
# No artwork is bundled: the app extracts the sprites from the user's own Claude/ChatGPT apps on first run.
# Your own "TouchBarBuddies Local" certificate (tools/make-signing-cert.sh) keeps the signature the same from build
# to build, so macOS remembers the Accessibility permission; without it, ad-hoc (a new signature every build).
SIGN_ID="TouchBarBuddies Local"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1 && codesign --force --sign "$SIGN_ID" "$APP" 2>/dev/null; then
  signed="signed: $SIGN_ID"
else
  codesign --force --sign - "$APP" >/dev/null
  signed="ad-hoc signed"
fi
echo "built $APP (${(j:+:)ARCHS}, $signed)"
