#!/bin/zsh
# Builds build/TouchBarBuddies.app: one universal binary (Apple Silicon + Intel) for macOS 12 or newer,
# ad-hoc signed. Overwrites in place; nothing is deleted.
set -euo pipefail
cd "${0:A:h}"

APP=build/TouchBarBuddies.app
MIN_MACOS=12.0   # keep in sync with LSMinimumSystemVersion in Info.plist

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Compile once per CPU type, then join the two into one universal binary.
for arch in arm64 x86_64; do
  extra=()
  # Newer Command Line Tools ship Swift's back-compat library for Apple Silicon only. The app uses no
  # Swift concurrency (the only thing that library patches on macOS 12), so the Intel build skips it.
  [[ $arch == x86_64 ]] && extra=(-runtime-compatibility-version none)
  swiftc -O -swift-version 5 -target $arch-apple-macosx$MIN_MACOS $extra Sources/*.swift -o build/TouchBarBuddies-$arch
done
lipo -create build/TouchBarBuddies-arm64 build/TouchBarBuddies-x86_64 -output "$APP/Contents/MacOS/TouchBarBuddies"

cp -f Info.plist "$APP/Contents/Info.plist"
# No artwork is bundled: the app extracts the sprites from the user's own Claude/ChatGPT apps on first run.
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
