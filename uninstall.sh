#!/bin/zsh
# Uninstalls Touch Bar Buddies: stops it (the normal Control Strip comes back), then moves the app
# and its login item to the Trash. Claude and ChatGPT are not touched.
#
#   ./uninstall.sh            (or: zsh ~/.touchbar-buddies/uninstall.sh)
#   ./uninstall.sh --dry-run  shows what it would do
set -euo pipefail

LABEL=dev.touchbarbuddies
APP=$HOME/Applications/TouchBarBuddies.app
PLIST=$HOME/Library/LaunchAgents/$LABEL.plist
DRY=0
if [[ ${1:-} == --dry-run ]]; then DRY=1; fi

# Runs a command, or only prints it with --dry-run.
run() {
  if (( DRY )); then print "    would run: $*"; else "$@"; fi
}

# Moves something to the Trash instead of deleting it (same helper as in install.sh).
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

# Unloading the LaunchAgent sends SIGTERM, and the app restores the native Control Strip before it exits.
run launchctl bootout gui/$UID/$LABEL 2>/dev/null || true
run pkill -x TouchBarBuddies || true   # a copy started by hand
run trash "$PLIST"
run trash "$APP"

if (( DRY )); then print "Dry run finished: nothing was changed."; exit 0; fi
print "Touch Bar Buddies is uninstalled; the app and its login item are in the Trash."
print "(The source in ~/.touchbar-buddies, if you used the one-line installer, can go to the Trash too.)"
