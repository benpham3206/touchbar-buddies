#!/bin/zsh
# Installs Touch Bar Buddies and starts it now and at every login.
#
#   One-liner:        curl -fsSL https://raw.githubusercontent.com/benpham3206/touchbar-buddies/main/install.sh | zsh
#   From a checkout:  ./install.sh   (run it again after changing the code: it rebuilds and restarts)
#   Preview only:     ./install.sh --dry-run   (or: ... | zsh -s -- --dry-run)
#
# The one-liner downloads the source to ~/touchbar-buddies (or updates it). Either way the app is built
# on this Mac, so macOS has nothing to warn about, then copied to ~/Applications and registered as a
# LaunchAgent (the same one the app's "Open at Login" menu item writes). Run uninstall.sh to undo.
set -euo pipefail

REPO=https://github.com/benpham3206/touchbar-buddies
CLONE=$HOME/touchbar-buddies                   # where the one-liner keeps the source (open it in Claude Code or Codex!)
LABEL=dev.touchbarbuddies
APP=$HOME/Applications/TouchBarBuddies.app
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
LOG=$HOME/Library/Logs/TouchBarBuddies.log     # ./tbb logs shows it
SCRIPT=$0                                      # "zsh" when piped from curl (inside functions $0 is the function name)
DRY=0

say()  { print "==> $*"; }
fail() { print "error: $*" >&2; exit 1; }

# Runs a command, or only prints it with --dry-run.
run() {
  if (( DRY )); then print "    would run: $*"; else "$@"; fi
}

# Moves something to the Trash instead of deleting it. /usr/bin/trash exists on macOS 15+;
# older systems make the same Foundation call through JavaScript for Automation.
trash() {
  [[ -e $1 ]] || return 0
  if [[ -x /usr/bin/trash ]]; then
    /usr/bin/trash "$1"
  else
    osascript -l JavaScript -e 'function run(a) { ObjC.import("Foundation");
      if (!$.NSFileManager.defaultManager.trashItemAtURLResultingItemURLError($.NSURL.fileURLWithPath(a[0]), null, null))
        throw "could not move " + a[0] + " to the Trash" }' "$1" >/dev/null
  fi
}

write_agent_plist() {
  mkdir -p "${PLIST:h}"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/TouchBarBuddies</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
  plutil -lint "$PLIST" >/dev/null
}

wait_until_stopped() {
  for i in {1..20}; do
    pgrep -x TouchBarBuddies >/dev/null || return 0
    sleep 0.25
  done
}

# Everything runs from here, so a half-downloaded script never runs half its steps.
main() {
  if [[ ${1:-} == --dry-run ]]; then
    DRY=1
    say "Dry run: nothing will be changed."
  fi

  # 1. Requirements: a Mac with a Touch Bar, and Apple's Command Line Tools (for git and the Swift compiler).
  [[ $(uname) == Darwin ]] || fail "Touch Bar Buddies runs on macOS only."
  pgrep -x TouchBarServer >/dev/null || pgrep -x ControlStrip >/dev/null ||
    fail "This Mac doesn't seem to have a Touch Bar, so there's nowhere for the buddies to live."
  if ! xcode-select -p >/dev/null 2>&1; then
    print "Touch Bar Buddies is built from source and needs Apple's Command Line Tools. Install them with:"
    print "\n    xcode-select --install\n"
    print "then run this installer again."
    exit 1
  fi

  # 2. Find the source: this checkout, or ~/touchbar-buddies for the one-liner.
  local src=${SCRIPT:A:h}
  if [[ ! -f $SCRIPT || ! -f $src/build.sh ]]; then
    src=$CLONE
    if [[ -d $src/.git ]]; then
      say "Updating the source in $src"
      # Your own changes are kept: if they clash with the update, the update waits.
      run git -C "$src" pull --ff-only --quiet ||
        say "Couldn't update (you changed the same files?), so building your copy as it is."
    elif [[ -f $src/build.sh ]]; then
      say "Using the source in $src (not a git download, so it isn't updated)"
    elif [[ -e $src ]]; then
      fail "$src already exists but isn't a Touch Bar Buddies download. Move it away, then try again."
    else
      say "Downloading the source to $src"
      run git clone --quiet --depth 1 "$REPO" "$src"
    fi
  fi

  # 3. Build.
  say "Building (takes about a minute)"
  run zsh "$src/build.sh" ||
    fail "The build failed. Update your Command Line Tools (System Settings > Software Update), then try again."

  # 4. Stop a running copy. It puts the normal Control Strip back as it quits.
  say "Stopping any running copy"
  run launchctl bootout gui/$UID/$LABEL 2>/dev/null || true
  run pkill -x TouchBarBuddies || true   # a copy started by hand
  run wait_until_stopped

  # 5. Install the app (the old copy goes to the Trash).
  say "Installing to $APP"
  run mkdir -p "${APP:h}"
  run trash "$APP"
  run ditto "$src/build/TouchBarBuddies.app" "$APP"

  # 6. Start it now and at every login.
  say "Starting it (and at every login)"
  run write_agent_plist
  run launchctl bootstrap gui/$UID "$PLIST"

  if (( DRY )); then say "Dry run finished: nothing was changed."; return; fi
  print "
Done! Clawd and Codex now live in your Touch Bar. Tap a sleeping buddy to open its app.
(The first start takes a few seconds while the sprites are made from your Claude and ChatGPT apps.)

Optional: to let the buddies tile Claude and ChatGPT side by side and use the media keys, allow
Accessibility for TouchBarBuddies: menu bar icon > \"Allow Window Tiling & Media Keys…\"
(or System Settings > Privacy & Security > Accessibility). Each new build has a new signature,
so after an update, remove TouchBarBuddies from that list and add it again.

Make it yours: open ${(q-)src} in Claude Code or Codex and ask for a new animation.
To uninstall: zsh ${(q-)src}/uninstall.sh"
}

main "$@"
