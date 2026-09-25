#!/bin/zsh
# Re-renders the README animations, docs/touchbar.gif and docs/closeup.gif, with ./tbb render.
# Run it after changing an animation that the story below shows.
set -euo pipefail
cd "${0:A:h}/.."

story=(
  --claude asleep --codex asleep
  --do tap-codex --at 0.5 --do tap-clawd --at 1.8        # tap to wake them (in the app, this opens Claude/ChatGPT)
  --do wave --at 5.5
  --do toss --at 7.5                                     # a game of catch
  --do visit-clawd-car --at 16                           # Clawd drives over for a high-five
  --do absent-claude --at 27 --do absent-codex --at 27.3 # back to sleep, so the loop is seamless
  --seconds 29
)
./tbb render docs/touchbar.gif $story
./tbb render docs/closeup.gif --zoom $story
