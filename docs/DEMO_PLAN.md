# Demo video

**Status:** done. `docs/demo.mp4` (1920×1080, 30 fps, H.264, about 32 s, about 9 MB) and `docs/demo.gif` (960×540,
15 fps, a 10 s highlight, under 2 MB) are in the README: `[![30-second demo](docs/demo.gif)](docs/demo.mp4)`.

```
tools/demo/render.sh                     # docs/demo.mp4 + docs/demo.gif
tools/demo/render.sh --stills 3,12.5     # PNGs of those moments (seconds of the video) in build/demo/stills
tools/demo/render.sh --fresh             # a new take of the Touch Bar frames (see "Randomness")
```

## What's left (user feedback on the first cut)

1. **Sound effects, no voiceover**: taps, pops, typing clicks, whooshes for the trips across the bar, a chime for
   the high-five and the confetti. The events are already known (`do` cues, `timeline.json` mode changes, things
   in flight); mix them into an AAC track with AVAssetWriter.
2. **Fix the laptop's perspective**: the keyboard looks off at that angle. Rework the deck/keyboard mockup
   (`drawDeck`, `deckPoint`) so the keys, trackpad and Touch Bar sit on one consistent plane.
3. The "Maybe later" README visuals at the end of this file.

## Why it's rendered, not recorded

- A screen recording would need Screen Recording permission, and it would show private Claude/ChatGPT
  chats. So everything is rendered.
- The Touch Bar comes from the app's **real** drawing code (`Scene` + `StripView`), stepped offscreen by
  `TouchBarBuddies --render <folder>` (Sources/Render.swift, scripted mode). Nothing shows on the Touch Bar.
- The laptop, the app windows, the bubbles and the captions are drawn by the compositor.
- The app windows are generic **mockups**, not screenshots, with no real user data:
  - "ChatGPT · Codex": a `>_` prompt box reading "Ask Codex to build something";
  - "Claude": an orange "✻ Welcome to Claude Code" box.

## How it fits together

1. **`tools/demo/storyboard.txt`**: one cue per line, in the renderer's seconds. `do` lines are commands for the
   renderer; `say`, `prompt`, `caption`, `title`, `confetti`, `end`, `stop`, `ramp` and `gif` are for the
   compositor. The file's header lists the formats.
2. **`render.sh`** turns the `do` lines into `--do <cmd> --at <t>` and runs
   `TouchBarBuddies --render build/demo/frames --claude asleep --codex asleep --fps 60 …`: `NNNN.png` per frame at
   8 px/pt, plus `timeline.json` (the pockets, and per frame each buddy's `x`, `hop`, `mode`, `busy`, `ultra`,
   `left`, and the things in the air). The frames (about 600 MB) are reused while the cues and the app stay
   the same, so stills and the final video show the same take.
3. **`compose.swift`** reads both and draws each video frame:
   - a stylized MacBook with a desktop mockup, a dock whose icon bounces when a buddy is tapped awake, and each
     app's window growing out of it into its half of the screen when the buddy wakes up. The windows type the
     prompt, stream code while the buddy works (violet "ultra" lines in ultra mode), and finish when it
     finishes. Work start/end come from the `mode` changes in `timeline.json`;
   - the whole strip on the keyboard deck (the 8× frame scaled down), with a glowing dot on anything thrown
     across the bar, which is only a few pixels there;
   - two magnifier lenses at 8 px/pt (the frames 1:1), Codex on the left and Clawd on the right. Each follows its
     buddy across the bar; when the two get close both switch to one shared camera (nothing shows twice; the gap
     between the lenses hides part of the bar like a window frame), then slide together into one wide lens;
   - speech bubbles pointing at the buddy's head, tap ripples (from `do tap-*`), caption pills, the title and end
     cards (github.com/benpham3206/touchbar-buddies);
   - `ramp` stretches (the long runs across the bar) play 4–5× faster with a "▶▶ 5×" badge; all overlays run on
     the video's clock, so text never races.
4. Export: H.264 through AVAssetWriter (2.6 Mbps, BT.709; built for a macOS 13 target, where its classic API isn't
   deprecated yet), and the GIF through ImageIO from the `gif` range.

`COMPOSE_DEBUG=1 build/demo/compose build/demo/frames tools/demo/storyboard.txt x` prints the time map and
the lens cameras, handy when retiming the storyboard.

## The story (about 32 s)

Title → tap Codex (jump, runs off behind the brightness button, peeks, runs back in) and the ChatGPT · Codex
window opens on the left → tap Clawd (cloud load-in) and the Claude window opens on the right → speech bubbles →
both get to work; Codex runs a note over to Clawd in person (fast-forwarded) → ULTRA: violet Clawd typing fast,
Codex's purple rings of symbols → Clawd finishes and drives the result back in his kart: high-five, confetti,
Codex finishes too → a game of catch → end card.

## Randomness

The app picks some things at random. The one that matters: Clawd's errand vehicle (kart or cloud). The ramps and
the cues after the delivery assume the kart; if a take comes out with the cloud, run `render.sh --fresh` until it
doesn't (the vehicle shows in `timeline.json` as Clawd's speed: 250 pt/s for the kart, 170 for the cloud).
Rebuilding the app also triggers a new take.

## Known issues

- **Codex looks soft in the 8× lenses.** `Bank` keeps his sprite at 2× the point size. Clawd is pixel art and
  stays sharp.
- **Things carried overhead touch the top of the lens**: the envelope and the ✓ sit near the top of the 30 pt bar,
  as on the real Touch Bar.
- **The ball in the game of catch is small between the lenses**: only the deck strip (with its glowing dot)
  shows it mid-flight.

## Maybe later (README visuals, only when asked)

- An ultra close-up GIF: `./tbb render docs/ultra.gif --zoom --do ultra-claude --do ultra-codex --seconds 6`.
- A "messages while they both work" GIF.
- A real screenshot of the brightness/volume popover: `./tbb send slider-volume`, then `./tbb shot docs/slider.png`.
