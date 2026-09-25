#!/bin/zsh
# Renders the README demo from tools/demo/storyboard.txt: the Touch Bar frames with the app's real drawing
# code (TouchBarBuddies --render, offscreen; nothing shows on the Touch Bar), then the video around them.
#
#   tools/demo/render.sh                     docs/demo.mp4 + docs/demo.gif
#   tools/demo/render.sh --stills 3,12.5     PNGs of those moments (seconds of the video) in build/demo/stills
#   tools/demo/render.sh --fresh …           render the Touch Bar frames again even if the cues didn't change
#
# The frames (about 600 MB at 8 px/pt, 60 fps) stay in build/demo/frames and are reused while the storyboard's
# `do` lines and the app stay the same, so stills and the final video show the very same take.
set -euo pipefail
cd "${0:A:h}/../.."

BOARD=tools/demo/storyboard.txt
OUT=build/demo
FRAMES=$OUT/frames
BIN=build/TouchBarBuddies.app/Contents/MacOS/TouchBarBuddies
fresh=0
[[ ${1:-} == --fresh ]] && { fresh=1; shift }

if [[ ! -x $BIN || -n $(find Sources Info.plist -newer $BIN) ]]; then zsh build.sh --native; fi
mkdir -p $OUT
if [[ ! -x $OUT/compose || tools/demo/compose.swift -nt $OUT/compose ]]; then
  # (A macOS 13 target: AVAssetWriter's classic API is only deprecated from macOS 27 on.)
  swiftc -O -swift-version 5 -target $(uname -m)-apple-macos13 tools/demo/compose.swift -o $OUT/compose
fi

# The renderer's cues: the storyboard's `do` lines, recorded until a little after `stop`.
cues=(--claude asleep --codex asleep --fps 60)
seconds=40
while read -r t kind rest; do
  if [[ $t == \#* ]]; then continue; fi
  if [[ $kind == do ]]; then cues+=(--do $rest --at $t); fi
  if [[ $kind == stop ]]; then printf -v seconds %.1f $(( t + 0.5 )); fi
done < $BOARD
cues+=(--seconds $seconds)

if (( fresh )) || [[ ! -f $FRAMES/timeline.json || $BIN -nt $FRAMES/timeline.json || "$(cat $FRAMES/cues.txt 2>/dev/null)" != "$cues" ]]; then
  $BIN --render $FRAMES $cues
  print -r -- "$cues" > $FRAMES/cues.txt
fi

if [[ ${1:-} == --stills ]]; then
  $OUT/compose $FRAMES $BOARD --stills $OUT/stills ${2:?which seconds, e.g. 3,12.5}
else
  $OUT/compose $FRAMES $BOARD docs/demo.mp4 docs/demo.gif
fi
