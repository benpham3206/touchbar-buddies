#!/bin/zsh
# Turns Clawd's live usage bar on or off: sets (or removes) Claude Code's status line command so it hands the plan's
# usage to Touch Bar Buddies (TouchBarBuddies --claude-statusline, see Sources/Usage.swift). Terminal sessions
# also show "5h 45% · wk 21%" as their status line. Run it yourself; it edits your Claude Code settings.
#
#   zsh tools/claude-statusline.sh on    point Claude Code's status line at the installed app
#   zsh tools/claude-statusline.sh off   remove it again (only if it's ours)
#
# Leaves any other status line you've set up alone.
set -euo pipefail
settings="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
app="$HOME/Applications/TouchBarBuddies.app/Contents/MacOS/TouchBarBuddies"
mode=${1:-}
[[ $mode == on || $mode == off ]] || { print "usage: zsh $0 on|off"; exit 2; }
[[ -f $settings ]] || print '{}' > "$settings"
# JavaScript for Automation ships with every Mac, so no python or jq is needed to edit the JSON.
osascript -l JavaScript - "$settings" "$mode" "$app" <<'JS'
function run(argv) {
  const [path, mode, app] = argv
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null).js
  const s = JSON.parse(text || '{}')
  const ours = s.statusLine && String(s.statusLine.command || '').includes('--claude-statusline')
  if (mode === 'on') {
    if (s.statusLine && !ours) return 'You already have a status line, so it was left alone. Add --claude-statusline to it yourself if you like.'
    s.statusLine = { type: 'command', command: `'${app}' --claude-statusline` }
  } else {
    if (!ours) return 'No Touch Bar Buddies status line to remove.'
    delete s.statusLine
  }
  $(JSON.stringify(s, null, 2) + '\n').writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null)
  return mode === 'on' ? `Clawd's usage bar is on (${path}).` : `Removed it from ${path}.`
}
JS
