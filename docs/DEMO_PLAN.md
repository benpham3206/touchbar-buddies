# Demo video plan (parked)

**Goal**
- `docs/demo.mp4`: about 30 s, 1920×1080, 30 fps, H.264, no audio, ≤ about 12 MB so it can live in git.
- `docs/demo.gif`: a short highlight, ≤ about 6 MB.
- Both show Codex and Clawd waking up, talking, working, going ULTRA and playing on the Touch Bar.
- The README embeds the GIF linked to the MP4: `[![30-second demo](docs/demo.gif)](docs/demo.mp4)`.

**Status:** paused. `agent/demo` is merged with `main`, and `Sources/` is identical to `main`: there are no
app-code changes on this branch. The compositor (`tools/demo/compose.swift`) compiles, and before the merge
it produced good-looking stills. It needs a new frame source, because the old `--render-demo` mode was
replaced by main's `Sources/Render.swift` (see "Next steps"). No video or GIF exists yet.

## Why it's rendered, not recorded

- A screen recording would need Screen Recording permission, and it would show private Claude/ChatGPT
  chats. So everything is rendered.
- The Touch Bar comes from the app's **real** drawing code (`Scene` + `StripView`), stepped offscreen.
  `Render.swift` already does this, with `scene.scripted = true`.
- The laptop, the app windows, the bubbles and the captions are drawn by the compositor.
- The app windows are generic **mockups**, not screenshots, with no real user data:
  - "ChatGPT · Codex": a `>_` prompt box reading "Ask Codex to build something";
  - "Claude": an orange "✻ Welcome to Claude Code" box.

## What the compositor draws (`tools/demo/compose.swift`)

A standalone swiftc program:

```
swiftc -O -swift-version 5 tools/demo/compose.swift -o build/demo/compose
build/demo/compose <framesDir> <out.mp4> <out.gif>
build/demo/compose <framesDir> --stills <outDir> 1,11,24    # check chosen timestamps as PNGs
```

- **Laptop:**
  - a stylized MacBook;
  - a desktop mockup with a menu bar (including the app's Clawd menu-bar icon);
  - a dock whose icon bounces on launch, with the app window growing out of it into the left or right half;
  - the windows type the prompt, then stream code; Claude's shows its spinner line;
  - confetti across the screen when the work is done;
  - title and end cards drawn on the screen.
- **Touch Bar:** the full strip on the keyboard deck at 1.1 px/pt, plus two magnifier lenses at 8 px/pt:
  - Codex on the left and Clawd on the right, with name tags;
  - each lens connects to the strip with a translucent cone;
  - each lens slides over to include a visiting buddy.
- **Overlays:** speech bubbles pointing at the buddy's head inside its lens, with `>_`/`✻` in the buddies'
  colors; tap ripples (in the lens and on the strip); a caption pill at the bottom.
- **Export:** H.264 through AVAssetWriter (3 Mbps, BT.709). The GIF comes from ImageIO: 960×540 at
  15 fps over `gifRange`. The export path compiles but has never been run end to end.
- **Current input (old format):**
  - `framesDir/strip@2x/NNNN.png` and `framesDir/strip@8x/NNNN.png`;
  - `framesDir/timeline.json`, with `frames[i].codex/clawd = {x, hop, mode, busy}` and the pocket rects;
  - `events`: `tap`, `open`, `work`, `say`, `prompt`, `caption`, `title`, `end`.

  For reference, the old renderer that wrote this format is at commit `1b3f10f`:
  `git show 1b3f10f:Sources/Demo.swift`.

## Next steps (in order)

1. **Add a frame-dump output to `Sources/Render.swift`.** About 30 lines; don't add a second renderer.
   - `--render <folder>` (a path with no extension) writes `NNNN.png` per frame at `--scale 8 --fps 30`.
   - It also writes `timeline.json`:
     - pocket rects;
     - per frame, for each buddy: `x`, `hop`, `mode` (`"\(b.base)"`), `busy` and `state.ultra`.
2. **Move the storyboard into `tools/demo/storyboard.txt`.** One cue per line, for example
   `7.2 do wave`, `7.2 say codex hey Clawd! 👋 | 1.7`, `14.8 caption They work when … | 4.8`.
   - `do` lines become `--do <cmd> --at <t>` for the renderer, started with
     `--claude asleep --codex asleep --seconds 31`.
   - Everything else is read by the compositor.
3. **Adapt `compose.swift` to the new input:**
   - read the storyboard plus the new timeline.json;
   - tap ripples come from `do tap-*`;
   - "app opens" is the first frame whose mode isn't `sleep`;
   - work start and end come from the `mode` changes;
   - use the 8× frames for both the lenses (1:1) and the deck strip (downscale), and drop `strip@2x`.
   - Add a small `tools/demo/render.sh` that builds, renders and composes, using `AssetCache.directory`
     sprites via the app.
4. **Update the storyboard for the current features** (about 30 s):
   1. tap-to-wake: Codex jumps, Clawd rides in on his cloud, and the windows open;
   2. talking bubbles. `packets` now throws `{}`, so change ">_ a Touch Bar app" to something like
      "{ } let's build a Touch Bar app";
   3. both working, with `message` flying both ways;
   4. a short ULTRA moment (`ultra-claude` + `ultra-codex`: purple Clawd typing fast, Codex's purple
      radiating symbols);
   5. done → confetti;
   6. `visit-codex` (Codex runs over) and/or `visit-clawd-car` (Clawd drives over), with the high-five;
   7. `toss`;
   8. the end card "github.com/benpham3206/touchbar-buddies".
5. **Check stills** at about 15 timestamps across the whole timeline. Look for clipping, bubble overlap,
   readability, and what the lens framing does during the visits.
6. **Export and verify.**
   - Run `ffprobe` on the MP4: expect 1920×1080, 30 fps, h264, yuv420p, and ≤ about 12 MB.
     If it's too big, lower `AVVideoAverageBitRateKey`.
   - Check the GIF is ≤ about 6 MB. If not, crop it to the deck and lenses, drop to 12 fps, or shorten
     `gifRange`.
7. **README visuals.** The user has parked these too; do them only when asked.
   - Add the demo GIF linked to the MP4, and keep `docs/touchbar.gif` + `docs/closeup.gif`.
   - Add these, each < 1.5 MB:
     - an ultra close-up GIF: `./tbb render docs/ultra.gif --zoom --do ultra-claude --do ultra-codex --seconds 6`;
     - a "messages while they both work" GIF;
     - a real screenshot of the brightness/volume popover: `./tbb send slider-volume`, then
       `./tbb shot docs/slider.png`.
   - Update the text:
     - messages while both work;
     - `{}` packets;
     - a spoiler-free ultra/ultracode teaser.

## Known issues and decisions

- **Clawd doesn't drive back after the high-five.** At 250 pt/s the round trip plus catch across the bar
  would push the video to about 35 s, so he stays with Codex for the catch and the end card.
- **Codex looks soft in the 8× lenses.** `Bank` keeps his sprite at 2× the point size. Clawd is pixel art
  and stays sharp.
- **Clawd's lens shows his empty pocket while he's away.** Decide whether to dim it, pan it along with
  him, or merge the two lenses.
- **The Claude window's block caret covers the first letter of its placeholder text.**
- **Deprecation warnings.** The AVAssetWriter APIs are deprecated in macOS 27 (warnings only; they still
  work).
- **Assets and disk.** Sprite art is never committed: render from `AssetCache.directory`. The frame dumps
  (about 200 MB at 8×) belong in git-ignored `build/demo/`.
