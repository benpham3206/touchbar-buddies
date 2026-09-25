# Touch Bar Buddies: notes for AI agents

You are probably running inside Claude or ChatGPT/Codex, the very apps this project watches.
**Never quit, kill or relaunch Claude.app or ChatGPT.app, and never open `claude://` or `codex://` URLs.**

## What this is

A small macOS menu-bar app (Swift + AppKit; no Xcode project, no packages) that replaces the MacBook Pro
Touch Bar's Expanded Control Strip with a faithful copy of it. The copy's first and last gaps are two
"pockets" for two animated mascots: the Codex pet on the left and Clawd, Claude Code's pixel crab, on
the right. Private Touch Bar calls (`TouchBarPrivate.swift`) put one full-width custom view, `StripView`,
on the bar. `StripView` draws the buttons and hands the pockets to a `Scene` with two `Buddy`s.
`ActivityMonitor` checks once a second whether Claude and Codex are open and busy. `Scene` turns those
states, plus touches and debug commands, into queued `Step`s (play a clip, walk somewhere, hop), along
with particles and thrown things. The artwork is never in the repo: on first launch `AssetCache` builds a
sprite cache from the user's own installed apps and the public claude.ai GIFs, and `Bank` cuts it into
`Clip`s.

## Files

| File | What's in it |
|---|---|
| `Sources/main.swift` | `AppDelegate`: puts the bar on screen, wires ActivityMonitor to Scene, the menu bar menu, debug commands (`handle`), command-line modes (`--build-sprites`, `--render`) |
| `Sources/StripView.swift` | The whole Touch Bar view: Control Strip layout (`relayout`), button drawing, touches, the render loop (adaptive frame rate, see `tick`), what each button does (`fire`) |
| `Sources/Scene.swift` | The buddies' world: `Step`, `Buddy`, reactions to app state and touches, idle habits, the director that starts games, interactions, effects, drawing |
| `Sources/Bank.swift` | Every animation `Clip` for both buddies, cut from the sprite cache (`c…` = Clawd, `x…` = Codex) |
| `Sources/Clip.swift` | `Clip` (frames, timing, anchor, `draw`) and the image helpers `SheetLoader` / `PixelGrid` |
| `Sources/PixelArt.swift` | Colors (`Palette`) and the tiny effect bitmaps (`Sprite.heart`, `.star`, `.ball`, `.plane`…) |
| `Sources/Activity.swift` | `ActivityMonitor` / `AgentState`: is each app open, is its agent busy (CPU of its process tree, or an open turn in its session log), is it in ultra / ultracode (`CodexUltra`, `ClaudeUltra`) |
| `Sources/AssetCache.swift` | Builds `~/Library/Application Support/TouchBarBuddies/sprites` from claude.ai GIFs, Claude.app and ChatGPT.app |
| `Sources/Asar.swift` | Reads single files out of an Electron `app.asar` (the Codex sprite sheet lives in one) |
| `Sources/AppLauncher.swift` | Opens Claude / ChatGPT on their coding screens and tiles their windows (Accessibility) |
| `Sources/SystemControls.swift` | What the buttons do: brightness, volume, mute, keyboard light, media keys, Mission Control, sleep, lock |
| `Sources/SliderPopover.swift` | The brightness/volume slider, drawn like the native one |
| `Sources/Icons.swift` | Button glyphs: SF Symbols plus a few shapes traced from the real bar |
| `Sources/TouchBarPrivate.swift` | The private DFRFoundation / NSTouchBar calls that let an app replace the Control Strip |
| `Sources/Render.swift` | `--render`: draws the Touch Bar offscreen to a GIF or a PNG filmstrip |
| `tbb` | Helper for trying changes: `run`, `send`, `render`, `shot`, `logs`, `sprites`, `commands` |
| `build.sh` | `swiftc` to a universal, ad-hoc-signed `build/TouchBarBuddies.app` (`--native`: this Mac's CPU only, faster) |
| `install.sh` / `uninstall.sh` | Build, copy to `~/Applications`, and register the login LaunchAgent / undo all of that. Both take `--dry-run` |
| `package.sh` | Zips the app for a GitHub Release |
| `docs/make-gifs.sh` | Re-renders the README GIFs (`docs/touchbar.gif`, `docs/closeup.gif`) |

## How it fits together

```
ActivityMonitor (every 2 s) ── AgentState (open? busy? ultra?) ──▶ Scene.setState ──▶ arrive / fallAsleep / startWork / finishWork
StripView touches ──▶ Scene.tap / longPress                 (buttons ──▶ StripView.fire ──▶ SystemControls)
./tbb send <cmd> ──▶ AppDelegate.handle ──▶ Scene.command
StripView timer (6–60 fps, from Scene.pace) ──▶ Scene.update(now, dt) ──▶ Buddy.update (runs the Step queue), timers, particles
StripView.draw ──▶ buttons, then Scene.draw ──▶ Clip.draw + effects ──▶ the Touch Bar
```

### Drawing and animation

- **Coordinates:** points, origin bottom-left, y up. The bar is 1004 × 30 pt (2008 × 60 px, 2 px per pt).
  `Scene.ground` is 1. Each buddy lives in `buddy.pocket`, about 68 pt wide on the stock layout.
- **Clip** (`Clip.swift`): frames + per-frame durations + `anchorX` / `baseline` (where the character's
  center and feet are). Variations: `slice(a...b)`, `pick([i, j])`, `still(i, seconds)`, `speed(x)`.
  Clawd's art is 1 art pixel = 1 pt and faces right; he's mirrored automatically when he faces left
  (`facesRight`). Codex has separate left/right run rows.
- **Bank** (`Bank.swift`): the named clips, e.g. `cStand cBlink cLookL cLookR cHappy cLoaf cSquat cScuttle
  cWave cLurk cCloudMount cCloudRide cCloudDismount cRaceIn cRaceDrive cRaceOut cWorkIn cWorkLoop cWorkOut`
  for Clawd and `xIdle xRunR xRunL xWave xJump xFailed xWaiting xWork xReview xSleep codexLook(degrees:)`
  for Codex. The top of `Bank` is the current list.
- **Buddy** (`Scene.swift`): `x`, `hop`, `facingLeft`, `pocket`, `state` (an `AgentState`), `base`
  (`.sleep` / `.idle` / `.work`) and a queue of `Step`s. With an empty queue a buddy shows its base pose
  (asleep, typing on its laptop, or standing).
- **Step:** one beat. `clip` (+ `loop`, `hold` seconds), `moveTo` + `speed` (+ `run: true` for the walk
  cycle), `face`, `hopV` (jump), `until` (a condition), `onStart` / `onEnd`. `clipRect` / `leftEdge` are for
  peeking out from behind a button. Queue steps with `b.enqueue([...])`. `b.interrupt()` clears the queue.
- **Scene helpers:** `after(seconds) { … }` (timers on the scene clock), `emit(.bitmap(Sprite.heart, Palette.heart), at:)`
  for particles, `throwThing(_:from:to:arc:)` (the catcher raises its arms in time), `sparkle`, `puff`,
  `confetti`, `highFive`. Step builders: `happyHop`, `hopSteps`, `waveStep`, `throwSteps`, `catchSteps`, `stroll`.
- **Frame rate (battery):** the render loop runs at the speed `Scene.pace` asks for: 60 fps while something flies
  across the bar, 30 for hops/walks/particles/ultra, 12 for plain sprite animation, 10 while both sleep. It also
  redraws only the pockets (`Scene.redrawAreas`) unless something is drawn outside them (`drawsOutsidePockets`).
  Steps with `moveTo`, hops, particles and projectiles are already covered; if you add a new kind of smooth motion
  or something drawn outside the pockets, teach `pace` / `drawsOutsidePockets` about it or it will look choppy or leave trails.
- **Ultra / ultracode:** when Codex runs at `ultra` effort or Claude Code gets an `ultracode` prompt, that agent's
  `AgentState.ultra` is true while it works: Clawd turns violet and types fast, Codex's symbols radiate in purple.
  Try it with `./tbb send ultra-claude` / `ultra-codex` (or `--do` them in a render). Holding both buddies for 0.8 s
  is a secret 8-second boost (`Scene.ultraBoost`).
- **Messages while both work:** when both buddies are busy, the director (`direct()`) has them send each other a ✻ or
  an envelope every few seconds without stopping (`message` command).
- **Games:** only one at a time. `begin()` sets `interacting`, and the game **must** call `end()` when it's
  done (a 30 s safety limit ends a stuck one). `direct()` starts a random game from `startInteraction()` (a weighted list)
  every 14–30 s when both buddies are idle, or `support()` when one of them is working.
- **Commands:** `Scene.command(name)` is a switch of named triggers (`go { … }` interrupts both buddies
  and calls `begin()` for you). App-level ones (`work-claude`, `absent-codex`, `slider-volume`…) are in
  `AppDelegate.handle`. `./tbb commands` lists both, read straight from the code. Unknown names are ignored.
- **What the app can know:** only whether each app (or its CLI) is running, and whether its agent is
  busy (CPU). There's no signal for "tests passed"; the closest is finishing work (`finishWork`).

## Recipes

Every new animation gets a **command name**, so you can trigger it on demand in a render or in the live app.

### Add an interaction (both buddies)

1. In `Scene.swift`, under `// MARK: Interactions`, add `private func myThing() { … }`. Build it from
   steps (`a.enqueue([...])`), timers (`after(0.8) { … }`) and effects, and call `self.end()` once it's over.
2. Give it a command in `command(_:)`: `case "my-thing": go { myThing() }`.
3. To let it happen on its own, add it to the `options` in `startInteraction()` with a weight (the others use 8–22).
4. Check it: `./tbb render /tmp/my-thing.png --do my-thing --seconds 8`, then look at the PNG.

### Add an idle habit (one buddy, when nothing else is going on)

1. In `idleHabits(_:)`, add a band to that buddy's `switch r` (for example `case ..<0.90:`). The bands
   are cumulative probabilities: keep them in increasing order.
2. Put the steps in a small builder, e.g. `private func yawn(_ b: Buddy) -> [Step]`, and add a command:
   `case "yawn": clawd.interrupt(); clawd.enqueue(yawn(clawd))`.
3. Check it with `./tbb render /tmp/yawn.png --do yawn`. `--live` also runs the random habits, if you want
   to see it come up by itself.

### React to Claude / Codex (open, busy, done)

`setState` calls `arrive`, `fallAsleep`, `startWork` and `finishWork`. Add your steps there. In a render,
`--do work-claude` switches Claude to busy, a second `--do work-claude --at 4` switches it back (that
plays `finishWork`), and `--claude asleep` + `--do tap-clawd` plays the wake-up.

### Add a clip from the sprite sheets

- Look at the sheets first. Each one is a strip of frames, left to right:
  `~/Library/Application Support/TouchBarBuddies/sprites/clawd/<name>.png`. The frame size and count are in
  `clawd.json` next to it. Codex is one sheet, `codex/codex.webp`: 8 columns × 11 rows of 192 × 208 px cells.
- **Clawd:** in `Bank.init`, load a strip with `strip("waving", need: 16)`, cut it (`.slice`, `.pick`,
  `.still`), then add a `let cMyClip: Clip` property and assign it. New expressions can be pixel-edited
  from a frame (`SheetLoader.edit`; see how `blink` and `lookL` are made).
- **A new Clawd GIF:** add `(name, path)` to `AssetCache.gifs` (it must be a real file under
  `https://claude.ai/images/clawd/`), run `./tbb sprites`, then load it in `Bank` with `strip(name, need:)`.
- **Codex:** `row(r, [ms per frame…])` turns sheet row `r` into a clip. Rows: 0 idle, 1 run right, 2 run
  left, 3 wave, 4 jump, 5 failed, 6 waiting, 7 working, 8 review, 9–10 look directions.
- Then use it: `Step(clip: bank.cMyClip)`.

### Add a debug command

- An animation: add a `case "name": …` to `Scene.command(_:)`.
- Something app-level (menus, the monitor, the slider): add it to `AppDelegate.handle(_:)` in
  `main.swift`, and to `Renderer.perform` in `Render.swift` if renders should understand it too.
- `./tbb commands` picks it up by itself. Try it with `./tbb send name` or `./tbb render … --do name`.

### Change what a button does or how the bar looks

- Behaviour: `StripView.fire(_:)` maps each `Action` to `SystemControls`. Holding and sliding are in
  `touchesBegan` / `touchesMoved` / `touchesEnded`, and auto-repeat is in `tick()`.
- Layout: `StripView.relayout()` reads the user's Control Strip items (`com.apple.controlstrip`
  `FullCustomized`) and gives the first and last flexible spaces to the pockets.
- Glyphs: `Icons.swift`. The slider: `SliderPopover.swift`. Colors: `StripView.buttonColor`, `pressedColor`.

### Add an effect bitmap

Add rows to `Sprite` in `PixelArt.swift` (`#` = filled) and a color to `Palette` if needed, then
`emit(.bitmap(Sprite.myThing, Palette.gold), at: CGPoint(x: b.x, y: 20), vy: 12)` from `Scene`.

## Verify your change

1. **Render it (no Touch Bar needed):** `./tbb render out.png --do <command> --seconds 8`. It builds if
   needed and draws the real `Scene` + `StripView` offscreen, in scripted mode (no random habits or games),
   with the stock Control Strip layout. A `.png` is a filmstrip, one row every `--every 0.5` s labeled
   with its time, so open it and look. Useful options: `--zoom` (the two pockets, magnified), `--every 0.2`
   for fast motion, `--scale 1` for long timelines, `--claude working|asleep`, `--codex …`, and several
   `--do x --at t`. Use a `.gif` for a real animation. It prints a note if the buddies were still busy
   at the end. Roughly: `toss` takes 8 s, `visit-clawd-car` 11 s.
2. **Build what users build:** `./build.sh` (universal, macOS 12 target) must succeed. Guard newer APIs
   with `if #available(macOS 13, *)`.
3. **On the real Touch Bar:** `./tbb run` (builds, restarts the app from `build/`), `./tbb send <command>`,
   and `./tbb shot out.png` saves what the Touch Bar really shows (2008 × 60; the terminal needs Screen
   Recording permission). If an installed copy is running, `./tbb run` replaces it until the next login.
   `./install.sh` makes the change permanent.
4. If you changed something the README GIFs show, run `docs/make-gifs.sh`.

## Logs

`./tbb logs` follows `~/Library/Logs/TouchBarBuddies.log`. The LaunchAgent and `./tbb run` send the app's
output there. Sprite building logs `[sprites] …` lines. `TBB_DEBUG=1 ./tbb run` also logs the
busy/idle sampling every second (`[activity] …`). `TBB_SPRITES_DIR=/some/dir` points the app at another
sprite folder.

## Common failures

| Symptom | Fix |
|---|---|
| `render: no sprites …`, or a buddy is missing | `./tbb sprites` rebuilds the cache and says what's missing. Clawd needs internet (claude.ai GIFs); Codex needs the ChatGPT desktop app with Codex |
| A render shows nothing happening | Typo in the command name (unknown commands are ignored): `./tbb commands` |
| Clawd scuttles instead of typing on a laptop | Claude.app isn't installed, so there's no laptop video. It's a fallback, not a bug |
| Build error about an API | It's newer than macOS 12: wrap it in `#available`. The Intel slice builds with `-runtime-compatibility-version none` |
| Window tiling / media keys stopped after a rebuild | Every ad-hoc build has a new signature: remove TouchBarBuddies under Privacy & Security > Accessibility and add it again |
| Touch Bar shows the normal Control Strip | The app isn't running (`pgrep -x TouchBarBuddies`), or macOS dropped the bar: menu bar icon > Refresh Touch Bar, or `./tbb run` |
| The Control Strip didn't come back after quitting | `killall ControlStrip` (macOS restarts it) |
| A game never ends / the buddies stop playing | The interaction didn't call `end()` |

## Rules

- **Never commit sprite art.** Anthropic's and OpenAI's artwork stays in the user's sprite cache;
  `assets/` and `Resources/` are git-ignored. Rendered GIFs/PNGs of the app (like `docs/*.gif`) are fine.
- Keep it simple: plain `swiftc`, no dependencies, no Xcode project. Swift 5 mode, macOS 12 deployment
  target, 2-space indent, short comments that say *why*.
- Only one copy of the app should be on the Touch Bar. `--render` never shows anything, so use it freely.
- Move files to the Trash (`/usr/bin/trash`) instead of deleting them.
- Don't change macOS settings, and don't ask for permissions on the user's behalf.
