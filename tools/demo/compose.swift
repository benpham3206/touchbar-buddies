// Builds the README demo (docs/demo.mp4 + docs/demo.gif) around Touch Bar frames drawn by the app's real
// Scene + StripView code (`TouchBarBuddies --render <folder>`: NNNN.png at 8 px/pt plus timeline.json).
//
// It draws a stylized MacBook: a desktop mockup on the screen (the ChatGPT · Codex and Claude windows are simple
// generic mockups, not screenshots, with no real user data), the whole Touch Bar strip on the keyboard deck, and
// two magnifier lenses, one per buddy, that follow their buddy across the bar and merge into one wide lens when
// the two meet. Speech bubbles, taps, captions and the title / end cards come from tools/demo/storyboard.txt.
//
//   tools/demo/render.sh does it all. By hand:
//   swiftc -O -swift-version 5 -target $(uname -m)-apple-macos13 tools/demo/compose.swift -o build/demo/compose
//   build/demo/compose <framesDir> <storyboard.txt> <out.mp4> [out.gif]
//   build/demo/compose <framesDir> <storyboard.txt> --stills <outDir> 1.5,7.8,24   (seconds of the video)

import AppKit
import AudioToolbox
import AVFoundation
import CoreText
import ImageIO
import UniformTypeIdentifiers

// MARK: - Inputs

struct BuddyInfo: Decodable { let x, hop: Double; let mode: String; let busy, ultra: Bool }
struct FrameInfo: Decodable { let t: Double; let codex, clawd: BuddyInfo; let flying: [[Double]] }
struct Timeline: Decodable {
  let fps, scale: Int
  let codexPocket, clawdPocket: [Double]
  let frames: [FrameInfo]
}

/// A storyboard line (in the renderer's seconds), or an event derived from the frames (in seconds of the video).
struct Cue {
  var t: Double
  var kind: String
  var who: String? = nil
  var text: String? = nil
  var dur: Double? = nil
  var x: Double? = nil
}
struct Ramp { let from, to, speed: Double }

func fail(_ s: String) -> Never {
  FileHandle.standardError.write(Data("compose: \(s)\n".utf8))
  exit(1)
}

let args = CommandLine.arguments
guard args.count >= 4 else {
  print("usage: compose <framesDir> <storyboard.txt> <out.mp4> [out.gif] | compose <framesDir> <storyboard.txt> --stills <outDir> <t1,t2,…>")
  exit(1)
}
let framesDir = URL(fileURLWithPath: args[1])
guard let tlData = try? Data(contentsOf: framesDir.appendingPathComponent("timeline.json")),
      let tl = try? JSONDecoder().decode(Timeline.self, from: tlData) else { fail("no timeline.json in \(framesDir.path)") }
guard tl.scale == 8 else { fail("the frames must be 8 px/pt (--scale 8)") }
let srcFps = Double(tl.fps)
let fps = 30.0                  // the video's frame rate

// MARK: - Storyboard

var cues: [Cue] = [], ramps: [Ramp] = [], gifRange = 0.0...0.0
guard let board = try? String(contentsOfFile: args[2], encoding: .utf8) else { fail("can't read \(args[2])") }
for raw in board.components(separatedBy: .newlines) {
  let line = raw.trimmingCharacters(in: .whitespaces)
  if line.isEmpty || line.hasPrefix("#") { continue }
  let words = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
  let numbers = line.split(separator: " ").compactMap { Double($0) }
  if words[0] == "ramp" && numbers.count == 3 { ramps.append(Ramp(from: numbers[0], to: numbers[1], speed: numbers[2])); continue }
  if words[0] == "gif" && numbers.count == 2 { gifRange = numbers[0]...numbers[1]; continue }
  guard let t = Double(words[0]), words.count >= 2 else { fail("can't read the storyboard line \"\(line)\"") }
  var cue = Cue(t: t, kind: words[1])
  var rest = words.count > 2 ? words[2] : ""
  if let bar = rest.range(of: "|", options: .backwards) {
    cue.dur = Double(rest[bar.upperBound...].trimmingCharacters(in: .whitespaces))
    rest = rest[..<bar.lowerBound].trimmingCharacters(in: .whitespaces)
  }
  if cue.kind == "say" || cue.kind == "prompt" {
    let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
    cue.who = parts.first
    rest = parts.count > 1 ? parts[1] : ""
  }
  cue.text = rest.isEmpty ? nil : rest
  cues.append(cue)
}

// MARK: - Time: the video's frames → the renderer's seconds (faster through the ramps)

func smoothstep(_ x: Double) -> Double { let u = min(1, max(0, x)); return u * u * (3 - 2 * u) }

/// How fast the video plays at renderer time `s`: 1, or a ramp's speed (eased in and out over 0.4 s).
func speed(_ s: Double) -> Double {
  var v = 1.0
  for r in ramps {
    let w = smoothstep((s - r.from) / 0.4) * smoothstep((r.to - s) / 0.4)
    v = max(v, 1 + (r.speed - 1) * w)
  }
  return v
}

let lastSrc = Double(tl.frames.count - 1) / srcFps
let stopSrc = min(cues.first { $0.kind == "stop" }?.t ?? lastSrc, lastSrc)
let srcTimes: [Double] = {
  var out: [Double] = [], s = 0.0
  while s < stopSrc { out.append(s); s += speed(s) / fps }
  return out
}()
let frameCount = srcTimes.count
let videoLength = Double(frameCount) / fps

func srcIndex(_ src: Double) -> Int { min(tl.frames.count - 1, max(0, Int((src * srcFps).rounded()))) }
/// The source frame shown on video frame `i`.
func info(_ i: Int) -> FrameInfo { tl.frames[srcIndex(srcTimes[min(i, frameCount - 1)])] }
func sourceFrame(_ i: Int) -> Int { srcIndex(srcTimes[min(i, frameCount - 1)]) }

/// Seconds of video at renderer time `src`.
func videoTime(_ src: Double) -> Double {
  var lo = 0, hi = srcTimes.count
  while lo < hi { let mid = (lo + hi) / 2; if srcTimes[mid] < src - 1e-9 { lo = mid + 1 } else { hi = mid } }
  return Double(lo) / fps
}

/// Ramp speed on video frame `i`.
func speedAt(_ i: Int) -> Double { speed(srcTimes[min(i, frameCount - 1)]) }

// MARK: - Events (seconds of video)

let tlEvents: [Cue] = {
  var out: [Cue] = []
  for c in cues {
    var e = c
    e.t = videoTime(c.t)
    if c.kind == "do" {
      // A tap on a buddy: a ripple where it stands.
      guard let cmd = c.text, cmd == "tap-codex" || cmd == "tap-clawd" else { continue }
      let who = cmd == "tap-codex" ? "codex" : "clawd"
      let f = tl.frames[srcIndex(c.t)]
      out.append(Cue(t: e.t, kind: "tap", who: who, x: (who == "codex" ? f.codex : f.clawd).x))
    } else {
      out.append(e)
    }
  }
  // From the frames: when each app opens (the buddy wakes up), when its agent starts and finishes work.
  for who in ["codex", "clawd"] {
    var prev: BuddyInfo?
    for (i, f) in tl.frames.enumerated() {
      let b = who == "codex" ? f.codex : f.clawd
      if let p = prev {
        let t = videoTime(Double(i) / srcFps)
        if p.mode == "sleep" && b.mode != "sleep" { out.append(Cue(t: t, kind: "open", who: who)) }
        if (p.mode == "work") != (b.mode == "work") { out.append(Cue(t: t, kind: b.mode == "work" ? "work" : "done", who: who)) }
      }
      prev = b
    }
  }
  return out.sorted { $0.t < $1.t }
}()

func event(_ kind: String, _ who: String? = nil) -> Cue? { tlEvents.first { $0.kind == kind && (who == nil || $0.who == who) } }
func events(_ kind: String) -> [Cue] { tlEvents.filter { $0.kind == kind } }
func workStart(_ who: String) -> Double? { event("work", who)?.t }
func workEnd(_ who: String) -> Double? {
  guard let on = workStart(who) else { return nil }
  return tlEvents.first { $0.kind == "done" && $0.who == who && $0.t > on }?.t
}

// MARK: - Procedural sound cues

enum SoundKind { case tap, pop, typing, foot, cloud, kart, flight, chime, sparkle }
struct SoundCue {
  let kind: SoundKind
  let start, duration: Double
  let panStart, panEnd, gain: Double
}

func soundCue(_ kind: SoundKind, at start: Double, duration: Double, fromX: Double = 502,
              toX: Double? = nil, gain: Double = 1) -> SoundCue {
  func pan(_ x: Double) -> Double { min(1, max(-1, x / 1004 * 2 - 1)) }
  return SoundCue(kind: kind, start: start, duration: max(0.015, duration),
                  panStart: pan(fromX), panEnd: pan(toX ?? fromX), gain: gain)
}

/// Long buddy movements are measured in source time, then placed in the edited video time.
func travelSounds() -> [SoundCue] {
  var out: [SoundCue] = []
  for who in ["codex", "clawd"] {
    var first: Int?, last: Int?, direction = 0
    var speeds: [Double] = []
    func close() {
      guard let a = first, let b = last else { first = nil; last = nil; speeds = []; return }
      let from = who == "codex" ? info(a).codex.x : info(a).clawd.x
      let to = who == "codex" ? info(b).codex.x : info(b).clawd.x
      let duration = Double(b - a) / fps
      if abs(to - from) >= 70, duration >= 0.06, let medianSpeed = speeds.sorted().dropFirst(max(0, speeds.count / 2)).first {
        let kind: SoundKind = who == "codex" ? .foot : (medianSpeed >= 210 ? .kart : .cloud)
        out.append(soundCue(kind, at: Double(a) / fps, duration: duration, fromX: from, toX: to, gain: 0.55))
      }
      first = nil; last = nil; direction = 0; speeds = []
    }

    if frameCount > 1 {
      for i in 1..<frameCount {
        let a = who == "codex" ? info(i - 1).codex.x : info(i - 1).clawd.x
        let b = who == "codex" ? info(i).codex.x : info(i).clawd.x
        let dx = b - a, dt = max(0.001, srcTimes[i] - srcTimes[i - 1])
        let velocity = abs(dx) / dt
        let sign = dx > 0 ? 1 : dx < 0 ? -1 : 0
        if velocity >= 65 && abs(dx) >= 0.6 {
          if first != nil && sign != 0 && direction != 0 && sign != direction { close() }
          if first == nil { first = i - 1; direction = sign }
          last = i
          speeds.append(velocity)
        } else if let lastIndex = last, Double(i - lastIndex) / fps > 0.12 {
          close()
        }
      }
      close()
    }
  }
  return out
}

func flightSounds() -> [SoundCue] {
  var out: [SoundCue] = []
  let deliverAt = cues.first { $0.kind == "do" && $0.text == "deliver" }.map { videoTime($0.t) }
  let tossAt = cues.first { $0.kind == "do" && $0.text == "toss" }.map { videoTime($0.t) } ?? videoLength
  var first: Int?, fromX = 502.0, toX = 502.0
  var deliveryChime = false
  func close(_ end: Int) {
    guard let start = first else { return }
    let t0 = Double(start) / fps, t1 = Double(end) / fps
    let duration = max(0.04, t1 - t0)
    if !deliveryChime, let deliverAt, t0 >= deliverAt - 0.03, t0 < tossAt {
      deliveryChime = true
      out.append(soundCue(.chime, at: t1, duration: 0.48, fromX: toX, gain: 0.8))
      out.append(soundCue(.sparkle, at: t1 + 0.025, duration: 0.38, fromX: toX, gain: 0.48))
    } else {
      let crossesBar = abs(toX - fromX) >= 140
      if crossesBar { out.append(soundCue(.flight, at: t0, duration: duration, fromX: fromX, toX: toX, gain: 0.32)) }
      out.append(soundCue(.pop, at: t1, duration: 0.12, fromX: toX, gain: 0.42))
    }
    first = nil
  }

  for i in 0..<frameCount {
    if let p = info(i).flying.first {
      if first == nil { first = i; fromX = p[0] }
      toX = p[0]
    } else if first != nil {
      close(i)
    }
  }
  if first != nil { close(frameCount - 1) }
  return out
}

let soundCues: [SoundCue] = {
  var out: [SoundCue] = []
  for e in events("tap") { out.append(soundCue(.tap, at: e.t, duration: 0.075, fromX: e.x ?? 502, gain: 0.7)) }
  for e in events("open") { out.append(soundCue(.pop, at: e.t + 0.025, duration: 0.13, fromX: e.who == "codex" ? 106 : 898, gain: 0.68)) }

  for who in ["codex", "clawd"] {
    var wasWorking = false, next = 0.0
    let panX = who == "codex" ? 106.0 : 898.0
    for i in 0..<frameCount {
      let t = Double(i) / fps
      let b = who == "codex" ? info(i).codex : info(i).clawd
      let working = b.mode == "work"
      if working && !wasWorking { next = t + 0.06 }
      if working && t + 1e-6 >= next {
        out.append(soundCue(.typing, at: t, duration: 0.022, fromX: panX, gain: b.ultra ? 0.34 : 0.27))
        let rate = b.ultra ? 0.105 : 0.205
        let wobble = 0.94 + 0.11 * (0.5 + 0.5 * sin(t * 17 + (who == "codex" ? 0 : 1.7)))
        next = t + rate * wobble
      }
      wasWorking = working
    }
  }

  out += travelSounds()
  out += flightSounds()
  for c in cues where c.kind == "confetti" {
    let t = videoTime(c.t)
    out.append(soundCue(.pop, at: t, duration: 0.15, gain: 0.52))
    out.append(soundCue(.sparkle, at: t + 0.035, duration: 0.42, gain: 0.5))
  }
  return out.sorted { $0.start < $1.start }
}()

// MARK: - Layout (1920×1080, y grows downward)

let W: CGFloat = 1920, H: CGFloat = 1080
let lid = CGRect(x: 460, y: 26, width: 1000, height: 574)
let display = CGRect(x: 478, y: 44, width: 964, height: 532)
// The deck meets the lid at the hinge, so its back edge is exactly the lid's width; it only widens toward the viewer.
let deckTop: CGFloat = 604, deckTopL = lid.minX, deckTopR = lid.maxX
let deckBottom: CGFloat = 1130, deckBotL: CGFloat = 250, deckBotR: CGFloat = 1670

let deckProjection: (a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, e: CGFloat, f: CGFloat, g: CGFloat, h: CGFloat) = {
  let p0 = CGPoint(x: deckTopL, y: deckTop), p1 = CGPoint(x: deckTopR, y: deckTop)
  let p2 = CGPoint(x: deckBotR, y: deckBottom), p3 = CGPoint(x: deckBotL, y: deckBottom)
  let dx1 = p1.x - p2.x, dx2 = p3.x - p2.x, dx3 = p0.x - p1.x + p2.x - p3.x
  let dy1 = p1.y - p2.y, dy2 = p3.y - p2.y, dy3 = p0.y - p1.y + p2.y - p3.y
  let denominator = dx1 * dy2 - dx2 * dy1
  let g = (dx3 * dy2 - dx2 * dy3) / denominator
  let h = (dx1 * dy3 - dx3 * dy1) / denominator
  return (p1.x - p0.x + g * p1.x, p3.x - p0.x + h * p3.x, p0.x,
          p1.y - p0.y + g * p1.y, p3.y - p0.y + h * p3.y, p0.y, g, h)
}()

/// Project a normalized point on the deck through the same four corners for every component.
func deckPoint(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
  let p = deckProjection
  let w = p.g * u + p.h * v + 1
  return CGPoint(x: (p.a * u + p.b * v + p.c) / w, y: (p.d * u + p.e * v + p.f) / w)
}

func deckQuad(_ u0: CGFloat, _ v0: CGFloat, _ u1: CGFloat, _ v1: CGFloat) -> CGPath {
  let p = CGMutablePath()
  p.addLines(between: [deckPoint(u0, v0), deckPoint(u1, v0), deckPoint(u1, v1), deckPoint(u0, v1)])
  p.closeSubpath()
  return p
}

func deckBounds(_ u0: CGFloat, _ v0: CGFloat, _ u1: CGFloat, _ v1: CGFloat) -> CGRect {
  deckQuad(u0, v0, u1, v1).boundingBox
}

let barU0: CGFloat = 0.05, barU1: CGFloat = 0.95
let barV0: CGFloat = 0.08, barV1: CGFloat = 0.162
let bar = deckBounds(barU0, barV0, barU1, barV1)
let zoom: CGFloat = 8                                      // lens: pixels per point (the 8× frames, 1:1)
let lensW: CGFloat = 640, lensH: CGFloat = 240, lensY: CGFloat = 806, lensMargin: CGFloat = 56
let menuH: CGFloat = 24
let captionY: CGFloat = 704                                // the caption band, between the strip and the lenses

// MARK: - Colors & fonts

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
func white(_ a: CGFloat) -> CGColor { CGColor(gray: 1, alpha: a) }
func black(_ a: CGFloat) -> CGColor { CGColor(gray: 0, alpha: a) }

let codexBlue = rgb(96, 128, 255), codexLight = rgb(150, 190, 255)
let clawdOrange = rgb(217, 119, 87)
let green = rgb(98, 210, 130), red = rgb(255, 110, 110), pink = rgb(255, 122, 178), amber = rgb(255, 196, 110)
let ink = rgb(29, 29, 31)
let violet = rgb(167, 139, 250)          // the app's ultra color (Palette.violet)
let confettiColors = [clawdOrange, codexBlue, rgb(255, 214, 90), green, rgb(255, 105, 140), white(1)]

func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .systemFont(ofSize: size, weight: weight) }
func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .monospacedSystemFont(ofSize: size, weight: weight) }

// MARK: - Small helpers

func clamp01(_ x: CGFloat) -> CGFloat { min(1, max(0, x)) }
func lerp(_ a: CGFloat, _ b: CGFloat, _ u: CGFloat) -> CGFloat { a + (b - a) * u }
func easeOut(_ x: CGFloat) -> CGFloat { 1 - pow(1 - clamp01(x), 3) }
func easeInOut(_ x: CGFloat) -> CGFloat { let u = clamp01(x); return u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2 }
func easeOutBack(_ x: CGFloat) -> CGFloat {
  let u = clamp01(x), c1: CGFloat = 1.6, c3 = c1 + 1
  return 1 + c3 * pow(u - 1, 3) + c1 * pow(u - 1, 2)
}
/// 0 → 1 over `fadeIn` seconds from `start`, back to 0 over `fadeOut` seconds before `end`.
func envelope(_ t: Double, _ start: Double, _ end: Double, _ fadeIn: Double = 0.25, _ fadeOut: Double = 0.25) -> CGFloat {
  guard t >= start && t <= end else { return 0 }
  return clamp01(CGFloat(min((t - start) / fadeIn, (end - t) / fadeOut)))
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
  let rad = max(0, min(radius, r.width / 2, r.height / 2))
  return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}

func fill(_ ctx: CGContext, _ path: CGPath, _ color: CGColor) {
  ctx.addPath(path)
  ctx.setFillColor(color)
  ctx.fillPath()
}

func stroke(_ ctx: CGContext, _ path: CGPath, _ color: CGColor, _ width: CGFloat) {
  ctx.addPath(path)
  ctx.setStrokeColor(color)
  ctx.setLineWidth(width)
  ctx.strokePath()
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
  CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// Fills `path` with a vertical gradient between the path's top and bottom.
func fillVertical(_ ctx: CGContext, _ path: CGPath, _ colors: [CGColor]) {
  let box = path.boundingBox
  ctx.saveGState()
  ctx.addPath(path)
  ctx.clip()
  ctx.drawLinearGradient(gradient(colors), start: CGPoint(x: 0, y: box.minY), end: CGPoint(x: 0, y: box.maxY), options: [])
  ctx.restoreGState()
}

func glow(_ ctx: CGContext, _ c: CGPoint, _ radius: CGFloat, _ color: CGColor) {
  ctx.drawRadialGradient(gradient([color, color.copy(alpha: 0)!]), startCenter: c, startRadius: 0,
                         endCenter: c, endRadius: radius, options: [])
}

/// Draws an image upright inside `r` (the context is flipped).
func drawImage(_ ctx: CGContext, _ img: CGImage, _ r: CGRect, quality: CGInterpolationQuality = .high) {
  ctx.saveGState()
  ctx.translateBy(x: r.minX, y: r.maxY)
  ctx.scaleBy(x: 1, y: -1)
  ctx.interpolationQuality = quality
  ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
  ctx.restoreGState()
}

/// Runs `body` as one group faded to `alpha` (so overlapping parts don't double up).
func faded(_ ctx: CGContext, _ alpha: CGFloat, _ body: () -> Void) {
  guard alpha > 0.001 else { return }
  if alpha >= 0.999 { body(); return }
  ctx.saveGState()
  ctx.setAlpha(alpha)
  ctx.beginTransparencyLayer(auxiliaryInfo: nil)
  body()
  ctx.endTransparencyLayer()
  ctx.restoreGState()
}

/// Scales everything `body` draws by `s` around `p`.
func scaled(_ ctx: CGContext, _ s: CGFloat, around p: CGPoint, _ body: () -> Void) {
  ctx.saveGState()
  ctx.translateBy(x: p.x, y: p.y)
  ctx.scaleBy(x: s, y: s)
  ctx.translateBy(x: -p.x, y: -p.y)
  body()
  ctx.restoreGState()
}

// Deterministic randomness, so every render is identical.
struct SplitMix {
  var state: UInt64
  mutating func next() -> CGFloat {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return CGFloat(Double((z ^ (z >> 31)) >> 11) / Double(1 << 53))
  }
  mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * next() }
}

// MARK: - Text

/// A run of text in one style.
struct Span {
  var text: String
  var color: CGColor
  var font: NSFont
  init(_ text: String, _ color: CGColor, _ font: NSFont) { self.text = text; self.color = color; self.font = font }
}

func makeLine(_ spans: [Span]) -> CTLine {
  let s = NSMutableAttributedString()
  for sp in spans {
    s.append(NSAttributedString(string: sp.text, attributes: [
      .font: sp.font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): sp.color,
    ]))
  }
  return CTLineCreateWithAttributedString(s)
}

func width(_ line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }

func draw(_ ctx: CGContext, _ line: CTLine, x: CGFloat, baseline: CGFloat) {
  ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // upright glyphs in the flipped context
  ctx.textPosition = CGPoint(x: x, y: baseline)
  CTLineDraw(line, ctx)
}

/// One line of text centered on `cx`.
func drawCentered(_ ctx: CGContext, _ spans: [Span], cx: CGFloat, baseline: CGFloat) {
  let l = makeLine(spans)
  draw(ctx, l, x: cx - width(l) / 2, baseline: baseline)
}

/// Keeps the first `n` characters of a styled line (for typing / streaming effects).
func prefix(_ spans: [Span], _ n: Int) -> [Span] {
  var out: [Span] = [], left = n
  for sp in spans where left > 0 {
    let take = min(left, sp.text.count)
    out.append(Span(String(sp.text.prefix(take)), sp.color, sp.font))
    left -= take
  }
  return out
}

func charCount(_ spans: [Span]) -> Int { spans.reduce(0) { $0 + $1.text.count } }


// MARK: - Lenses

/// One magnifier on one frame: where it is on screen and which part of the strip it shows (1 pt = `zoom` px).
struct Lens {
  let rect: CGRect
  let center: CGFloat          // strip x (points) at the lens's center
  let merge: CGFloat           // 0 = two separate lenses … 1 = one wide lens made of both halves
  let isLeft: Bool
  var label: String { isLeft ? "Codex" : "Clawd" }
  var color: CGColor { isLeft ? codexBlue : clawdOrange }
  var halfView: CGFloat { rect.width / 2 / zoom }

  func screenX(_ stripX: CGFloat) -> CGFloat { rect.midX + (stripX - center) * zoom }
  func shows(_ stripX: CGFloat, margin: CGFloat = 6) -> Bool { abs(stripX - center) < halfView - margin }
}

func pocketMid(_ p: [Double]) -> CGFloat { CGFloat(p[0] + p[2] / 2) }
let codexHome = pocketMid(tl.codexPocket), clawdHome = pocketMid(tl.clawdPocket)

/// A centered moving average, twice (≈ Gaussian): the camera eases in and out with no lag.
func smoothed(_ a: [CGFloat], radius: Int) -> [CGFloat] {
  var v = a
  for _ in 0..<2 {
    var prefix = [CGFloat](repeating: 0, count: v.count + 1)
    for (i, x) in v.enumerated() { prefix[i + 1] = prefix[i] + x }
    v = v.indices.map { i in
      let lo = max(0, i - radius), hi = min(v.count - 1, i + radius)
      return (prefix[hi + 1] - prefix[lo]) / CGFloat(hi - lo + 1)
    }
  }
  return v
}

/// Each lens follows its own buddy once it leaves home (a step or two inside its pocket doesn't count). As the two buddies get close, both lenses switch to one shared camera (so nothing shows
/// twice; the gap between the lenses hides a strip of the bar like a window frame would), then slide together
/// into one wide view of both. Computed for the whole video up front, so the camera never lags behind.
let lensTrack: (left: [CGFloat], right: [CGFloat], mid: [CGFloat], shared: [CGFloat], merge: [CGFloat]) = {
  func follow(_ x: CGFloat, _ home: CGFloat, behind: CGFloat = 0) -> CGFloat {
    home + (x + behind - home) * CGFloat(smoothstep(Double(abs(x - home) - 15) / 40))
  }
  var l: [CGFloat] = [], r: [CGFloat] = [], mid: [CGFloat] = [], c: [CGFloat] = [], m: [CGFloat] = []
  for i in 0..<frameCount {
    let f = info(i), xc = CGFloat(f.codex.x), xl = CGFloat(f.clawd.x)
    l.append(follow(xc, codexHome))
    r.append(follow(xl, clawdHome, behind: 12))   // (his kart sits a little right of where he stands)
    mid.append((xc + xl) / 2)
    let d = Double(abs(xl - xc))
    c.append(CGFloat(smoothstep((260 - d) / 80)))
    m.append(CGFloat(smoothstep((150 - d) / 60)))
  }
  // (Positions only need a light touch: they're smooth already, and heavy smoothing lags where a ramp speeds up.)
  return (smoothed(l, radius: 2), smoothed(r, radius: 2), smoothed(mid, radius: 2), smoothed(c, radius: 5), smoothed(m, radius: 5))
}()

func lenses(_ i: Int) -> [Lens] {
  let m = lensTrack.merge[i], mid = lensTrack.mid[i], c = lensTrack.shared[i]
  let wL = lerp(lensW, W / 2 - lensMargin, m)
  let left = CGRect(x: lensMargin, y: lensY, width: wL, height: lensH)
  let xR = lerp(W - lensMargin - lensW, W / 2, m)
  let right = CGRect(x: xR, y: lensY, width: W - lensMargin - xR, height: lensH)
  // The shared camera: the middle of the screen looks at the point between the two buddies.
  return [Lens(rect: left, center: lerp(lensTrack.left[i], mid + (left.midX - W / 2) / zoom, c), merge: m, isLeft: true),
          Lens(rect: right, center: lerp(lensTrack.right[i], mid + (right.midX - W / 2) / zoom, c), merge: m, isLeft: false)]
}

/// The lens showing a buddy: its own if it can, else the other one.
func lensShowing(_ who: String, _ x: CGFloat, _ i: Int) -> Lens {
  let ls = lenses(i)
  let own = who == "codex" ? ls[0] : ls[1], other = who == "codex" ? ls[1] : ls[0]
  return own.shows(x) || !other.shows(x) ? own : other
}

func stripPoint(_ x: CGFloat, _ y: CGFloat = 15) -> CGPoint {
  let u = barU0 + x / 1004 * (barU1 - barU0)
  let v = barV1 - y / 30 * (barV1 - barV0)
  return deckPoint(u, v)
}

func stripToBar(_ x: CGFloat) -> CGFloat { stripPoint(x).x }

/// A rectangle with its left and right corners rounded separately (the seam side of a merging lens squares off).
func corners(_ r: CGRect, left: CGFloat, right: CGFloat) -> CGPath {
  let a = max(0.01, left), b = max(0.01, right)
  let p = CGMutablePath()
  p.move(to: CGPoint(x: r.minX + a, y: r.minY))
  p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: b)
  p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: b)
  p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: a)
  p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: a)
  p.closeSubpath()
  return p
}

func lensShape(_ l: Lens, _ r: CGRect, _ radius: CGFloat) -> CGPath {
  let seam = radius * (1 - l.merge)
  return l.isLeft ? corners(r, left: radius, right: seam) : corners(r, left: seam, right: radius)
}

// MARK: - Dock icons (pre-rendered once)

struct DockIcon { let image: CGImage; let app: String? }

func renderIcon(_ top: CGColor, _ bottom: CGColor, symbol: String? = nil, text: String? = nil, font: NSFont? = nil) -> CGImage {
  let px = 96
  let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  let r = CGRect(x: 4, y: 4, width: 88, height: 88)
  ctx.saveGState()
  ctx.addPath(rounded(r, 21))
  ctx.clip()
  ctx.drawLinearGradient(gradient([top, bottom]), start: CGPoint(x: 0, y: 92), end: CGPoint(x: 0, y: 4), options: [])
  ctx.restoreGState()
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
  if let symbol {
    let config = NSImage.SymbolConfiguration(pointSize: 44, weight: .medium).applying(.init(paletteColors: [.white]))
    if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
      let s = img.size
      img.draw(in: NSRect(x: 48 - s.width / 2, y: 48 - s.height / 2, width: s.width, height: s.height))
    }
  }
  if let text, let font {
    let str = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white])
    let s = str.size()
    str.draw(at: NSPoint(x: 48 - s.width / 2, y: 48 - s.height / 2))
  }
  NSGraphicsContext.restoreGraphicsState()
  return ctx.makeImage()!
}

let dockIcons: [DockIcon] = [
  DockIcon(image: renderIcon(rgb(92, 170, 255), rgb(40, 110, 230), symbol: "folder.fill"), app: nil),
  DockIcon(image: renderIcon(rgb(80, 210, 200), rgb(30, 140, 170), symbol: "globe"), app: nil),
  DockIcon(image: renderIcon(rgb(120, 200, 255), rgb(50, 130, 240), symbol: "envelope.fill"), app: nil),
  DockIcon(image: renderIcon(rgb(52, 52, 58), rgb(14, 14, 16), text: ">_", font: mono(36, .bold)), app: "codex"),
  DockIcon(image: renderIcon(rgb(232, 138, 104), rgb(200, 100, 70), text: "✻", font: sans(52, .bold)), app: "clawd"),
  DockIcon(image: renderIcon(rgb(255, 120, 150), rgb(230, 60, 100), symbol: "music.note"), app: nil),
  DockIcon(image: renderIcon(rgb(170, 172, 180), rgb(110, 112, 120), symbol: "gearshape.fill"), app: nil),
]
let dockIconSize: CGFloat = 42
let dockRect: CGRect = {
  let w = CGFloat(dockIcons.count) * dockIconSize + CGFloat(dockIcons.count - 1) * 10 + 20
  return CGRect(x: display.midX - w / 2, y: display.maxY - 8 - 56, width: w, height: 56)
}()
func dockIconRect(_ i: Int) -> CGRect {
  CGRect(x: dockRect.minX + 10 + CGFloat(i) * (dockIconSize + 10), y: dockRect.minY + 5, width: dockIconSize, height: dockIconSize)
}
func dockIconRect(app: String) -> CGRect { dockIconRect(dockIcons.firstIndex { $0.app == app }!) }

// MARK: - App window mockups

let windowTop = display.minY + menuH + 14
let windowH = dockRect.minY - 14 - windowTop
let windowW = (display.width - 14 * 3) / 2
let codexWindow = CGRect(x: display.minX + 14, y: windowTop, width: windowW, height: windowH)
let claudeWindow = CGRect(x: display.maxX - 14 - windowW, y: windowTop, width: windowW, height: windowH)
let titleBarH: CGFloat = 32

let codeFont = mono(12.5), codeBold = mono(12.5, .semibold)
let dim = white(0.45), text = white(0.9)


let codexStream: [[Span]] = [
  [Span("• ", dim, codeFont), Span("Explored ", text, codeBold), Span("Sources/StripView.swift", codexLight, codeFont)],
  [Span("• ", dim, codeFont), Span("Edited ", text, codeBold), Span("Sources/StripView.swift ", codexLight, codeFont),
   Span("+31 ", green, codeFont), Span("−4", red, codeFont)],
  [Span("    func ", pink, codeFont), Span("relayout", codexLight, codeFont), Span("() {", text, codeFont)],
  [Span("      let ", pink, codeFont), Span("items = ", text, codeFont), Span("controlStripItems", codexLight, codeFont), Span("()", text, codeFont)],
  [Span("      pockets = ", text, codeFont), Span("gaps", codexLight, codeFont), Span("(in: items, width: ", text, codeFont),
   Span("1004", amber, codeFont), Span(")", text, codeFont)],
  [Span("    }", text, codeFont)],
  [Span("• ", dim, codeFont), Span("Ran ", text, codeBold), Span("./build.sh", codexLight, codeFont)],
]
let codexDone: [[Span]] = [
  [Span("  ✓ built, 0 warnings", green, codeBold)],
  [Span("• ", dim, codeFont), Span("Done. The strip is ready.", text, codeFont)],
]
let claudeStream: [[Span]] = [
  [Span("⏺ ", clawdOrange, codeFont), Span("Update", text, codeBold), Span("(Sources/Scene.swift)", text, codeFont)],
  [Span("  ⎿ ", dim, codeFont), Span("+ case \"toss\": go { toss(a, b) }", green, codeFont)],
  [Span("    ", dim, codeFont), Span("+ throwThing(.ball, from: a, to: b)", green, codeFont)],
  [Span("⏺ ", clawdOrange, codeFont), Span("Update", text, codeBold), Span("(Sources/Bank.swift)", text, codeFont)],
  [Span("  ⎿ ", dim, codeFont), Span("+ cHappy = strip(\"waving\").slice(4...9)", green, codeFont)],
  [Span("⏺ ", clawdOrange, codeFont), Span("Bash", text, codeBold), Span("(./build.sh)", text, codeFont)],
  [Span("  ⎿ ", dim, codeFont), Span("built build/TouchBarBuddies.app", dim, codeFont)],
]
let claudeDone: [[Span]] = [
  [Span("⏺ ", green, codeFont), Span("All set: the buddies are animated.", text, codeBold)],
]

/// Lines revealed `since` seconds ago at `cps` characters/second, with a short pause after each line.
func revealed(_ lines: [[Span]], since: Double, cps: Double) -> [[Span]] {
  guard since > 0 else { return [] }
  var budget = Int(since * cps)
  var out: [[Span]] = []
  for l in lines {
    let n = charCount(l)
    if budget >= n { out.append(l); budget -= n + 6 } else { out.append(prefix(l, budget)); break }
    if budget <= 0 { break }
  }
  return out
}

/// Typed text for a window's prompt box (types over ~1.2 s, then waits for its buddy to start work).
func typedPrompt(_ who: String, _ t: Double) -> String? {
  guard let e = event("prompt", who), t >= e.t, let s = e.text else { return nil }
  if let on = workStart(who), t >= on { return nil }
  let n = Int((t - e.t) / 1.2 * Double(s.count))
  return String(s.prefix(max(0, n)))
}

func caretOn(_ t: Double) -> Bool { Int(t * 2.2) % 2 == 0 }

/// The current video frame (the windows ask whether their buddy is in ultra mode).
var cur = 0
func ultra(_ who: String) -> Bool {
  let f = info(cur), b = who == "codex" ? f.codex : f.clawd
  return b.ultra && b.mode == "work"
}

func drawChrome(_ ctx: CGContext, _ r: CGRect, title: String, body: CGColor, bar barColor: CGColor) {
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: black(0.55))
  fill(ctx, rounded(r, 12), body)
  ctx.restoreGState()
  ctx.saveGState()
  ctx.addPath(rounded(r, 12))
  ctx.clip()
  ctx.setFillColor(barColor)
  ctx.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: titleBarH))
  ctx.setFillColor(white(0.07))
  ctx.fill(CGRect(x: r.minX, y: r.minY + titleBarH - 1, width: r.width, height: 1))
  ctx.restoreGState()
  for (k, c) in [rgb(255, 95, 87), rgb(254, 188, 46), rgb(40, 200, 64)].enumerated() {
    fill(ctx, CGPath(ellipseIn: CGRect(x: r.minX + 14 + CGFloat(k) * 20, y: r.minY + 10, width: 12, height: 12), transform: nil), c)
  }
  drawCentered(ctx, [Span(title, white(0.75), sans(13, .semibold))], cx: r.midX, baseline: r.minY + 21)
  stroke(ctx, rounded(r.insetBy(dx: 0.5, dy: 0.5), 12), white(0.12), 1)
}

/// Lines of a transcript, newest at the bottom, clipped to `area`.
func drawTranscript(_ ctx: CGContext, _ lines: [[Span]], in area: CGRect, lineH: CGFloat = 19) {
  let fit = Int(area.height / lineH)
  for (k, l) in lines.suffix(fit).enumerated() {
    draw(ctx, makeLine(l), x: area.minX, baseline: area.minY + lineH * CGFloat(k) + 14)
  }
}

func drawCodexWindow(_ ctx: CGContext, _ t: Double) {
  let r = codexWindow
  drawChrome(ctx, r, title: "ChatGPT · Codex", body: rgb(24, 24, 27), bar: rgb(32, 32, 36))
  let on = workStart("codex"), off = workEnd("codex")
  let started = on.map { t >= $0 } ?? false

  // Start screen: a >_ badge and a big question, fading away once the work starts.
  let heroAlpha = started ? 1 - clamp01(CGFloat(t - on!) / 0.3) : 1
  faded(ctx, heroAlpha) {
    let badge = CGRect(x: r.midX - 32, y: r.minY + titleBarH + 64, width: 64, height: 64)
    fill(ctx, rounded(badge, 16), white(0.06))
    stroke(ctx, rounded(badge.insetBy(dx: 0.5, dy: 0.5), 16), white(0.14), 1)
    drawCentered(ctx, [Span(">_", white(0.92), mono(26, .bold))], cx: badge.midX, baseline: badge.midY + 9)
    drawCentered(ctx, [Span("What should we build?", white(0.92), sans(24, .semibold))], cx: r.midX, baseline: badge.maxY + 44)
    drawCentered(ctx, [Span("~/touchbar-buddies", white(0.4), mono(13))], cx: r.midX, baseline: badge.maxY + 70)
  }

  // Prompt box.
  let box = CGRect(x: r.minX + 16, y: r.maxY - 16 - 52, width: r.width - 32, height: 52)
  fill(ctx, rounded(box, 16), white(0.05))
  stroke(ctx, rounded(box.insetBy(dx: 0.5, dy: 0.5), 16), white(0.15), 1)
  let typed = typedPrompt("codex", t)
  var spans = [Span(">_  ", codexLight, mono(15, .bold))]
  if let typed { spans.append(Span(typed, white(0.95), sans(15))) } else { spans.append(Span("Ask Codex to build something", white(0.38), sans(15))) }
  let line = makeLine(spans)
  draw(ctx, line, x: box.minX + 18, baseline: box.midY + 5)
  if typed != nil && caretOn(t) {
    ctx.setFillColor(codexLight)
    ctx.fill(CGRect(x: box.minX + 18 + width(line) + 2, y: box.midY - 9, width: 2, height: 18))
  }
  let send = CGRect(x: box.maxX - 12 - 30, y: box.midY - 15, width: 30, height: 30)
  fill(ctx, CGPath(ellipseIn: send, transform: nil), typed?.isEmpty == false ? white(0.92) : white(0.2))
  drawCentered(ctx, [Span("↑", typed?.isEmpty == false ? ink : white(0.6), sans(16, .bold))], cx: send.midX, baseline: send.midY + 6)

  guard started, let on else { return }
  // Transcript: the request, then Codex's work streaming in.
  let ask = event("prompt", "codex")?.text ?? ""
  let askLine = makeLine([Span(ask, white(0.95), sans(14))])
  let bubble = CGRect(x: r.maxX - 16 - width(askLine) - 28, y: r.minY + titleBarH + 16, width: width(askLine) + 28, height: 34)
  faded(ctx, clamp01(CGFloat(t - on) / 0.2)) {
    fill(ctx, rounded(bubble, 14), white(0.09))
    draw(ctx, askLine, x: bubble.minX + 14, baseline: bubble.midY + 5)
  }
  var lines = revealed(codexStream, since: t - on - 0.35, cps: 55)
  if let off, t >= off {
    lines = codexStream + [[]] + revealed(codexDone, since: t - off, cps: 50)
  } else if t - on > 0.35 {
    let dots = String(repeating: ".", count: Int(t * 3) % 4)
    lines.append([])
    lines.append(ultra("codex")
      ? [Span("◦ Working", violet, codeBold), Span(" · ultra" + dots, violet, codeFont)]
      : [Span("◦ Working" + dots, white(0.5), codeFont)])
  }
  drawTranscript(ctx, lines, in: CGRect(x: r.minX + 20, y: bubble.maxY + 14, width: r.width - 40, height: box.minY - bubble.maxY - 20))
}

func drawClaudeWindow(_ ctx: CGContext, _ t: Double) {
  let r = claudeWindow
  drawChrome(ctx, r, title: "Claude", body: rgb(27, 26, 24), bar: rgb(36, 35, 32))
  let on = workStart("clawd"), off = workEnd("clawd")
  let started = on.map { t >= $0 } ?? false

  // Claude Code's welcome box.
  let welcome = CGRect(x: r.minX + 16, y: r.minY + titleBarH + 14, width: r.width - 32, height: 92)
  stroke(ctx, rounded(welcome, 8), clawdOrange, 1.5)
  draw(ctx, makeLine([Span("✻ ", clawdOrange, mono(14, .bold)), Span("Welcome to Claude Code", white(0.95), mono(14, .bold))]),
       x: welcome.minX + 16, baseline: welcome.minY + 28)
  draw(ctx, makeLine([Span("/help for help, /status for your setup", white(0.45), mono(12.5))]), x: welcome.minX + 16, baseline: welcome.minY + 55)
  draw(ctx, makeLine([Span("cwd: ~/touchbar-buddies", white(0.45), mono(12.5))]), x: welcome.minX + 16, baseline: welcome.minY + 76)

  // Prompt box. The block caret sits after the "> ", with the placeholder just past it.
  let box = CGRect(x: r.minX + 16, y: r.maxY - 16 - 46, width: r.width - 32, height: 46)
  stroke(ctx, rounded(box, 8), white(0.3), 1)
  let typed = typedPrompt("clawd", t)
  let mark = makeLine([Span("> ", white(0.8), mono(14, .bold))])
  draw(ctx, mark, x: box.minX + 14, baseline: box.midY + 5)
  let textX = box.minX + 14 + width(mark)
  var caretX = textX
  if let typed {
    let l = makeLine([Span(typed, white(0.95), mono(14))])
    draw(ctx, l, x: textX, baseline: box.midY + 5)
    caretX = textX + width(l) + 1
  } else if !started {
    draw(ctx, makeLine([Span("Try \"refactor the scene\"", white(0.35), mono(14))]), x: textX + 12, baseline: box.midY + 5)
  }
  if (typed != nil || !started) && caretOn(t) {
    ctx.setFillColor(white(0.85))
    ctx.fill(CGRect(x: caretX, y: box.midY - 9, width: 8, height: 17))
  }

  guard started, let on else { return }
  let ask = event("prompt", "clawd")?.text ?? ""
  let asked: [[Span]] = [[Span("> " + ask, white(0.5), codeFont)], []]
  var lines = asked + revealed(claudeStream, since: t - on - 0.3, cps: 55)
  if let off, t >= off {
    lines = asked + claudeStream + [[]] + revealed(claudeDone, since: t - off - 0.2, cps: 40)
  } else {
    let hot = ultra("clawd")
    let spinner = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"][Int(t / (hot ? 0.06 : 0.12)) % 10]
    let color = hot ? violet : clawdOrange
    lines.append([])
    lines.append([Span(spinner + " ", color, codeBold), Span(hot ? "Ultracoding… " : "Animating… ", color, codeFont),
                  Span("(esc to interrupt)", white(0.4), codeFont)])
  }
  drawTranscript(ctx, lines, in: CGRect(x: r.minX + 22, y: welcome.maxY + 12, width: r.width - 44, height: box.minY - welcome.maxY - 20))
}

// MARK: - Desktop

func drawMenuBar(_ ctx: CGContext) {
  let r = CGRect(x: display.minX, y: display.minY, width: display.width, height: menuH)
  ctx.setFillColor(black(0.3))
  ctx.fill(r)
  var x = r.minX + 18
  for (k, item) in ["Finder", "File", "Edit", "View", "Go", "Window", "Help"].enumerated() {
    let l = makeLine([Span(item, white(0.88), sans(13, k == 0 ? .bold : .regular))])
    draw(ctx, l, x: x, baseline: r.minY + 17)
    x += width(l) + 20
  }
  let clock = makeLine([Span("Thu 9:41 AM", white(0.88), sans(13, .medium))])
  draw(ctx, clock, x: r.maxX - 16 - width(clock), baseline: r.minY + 17)
  // Touch Bar Buddies' own menu-bar icon: Clawd's silhouette.
  let rows = ["..########..", "..#.####.#..", "############", "############", "..########..", "..########..", "..#.#..#.#..", "..#.#..#.#.."]
  let ox = r.maxX - 16 - width(clock) - 34, oy = r.minY + 5.5
  ctx.setFillColor(white(0.88))
  for (y, row) in rows.enumerated() {
    for (xx, ch) in row.enumerated() where ch == "#" {
      ctx.fill(CGRect(x: ox + CGFloat(xx) * 1.5, y: oy + CGFloat(y) * 1.5, width: 1.5, height: 1.5))
    }
  }
}

func drawDock(_ ctx: CGContext, _ t: Double) {
  fill(ctx, rounded(dockRect, 16), white(0.13))
  stroke(ctx, rounded(dockRect.insetBy(dx: 0.5, dy: 0.5), 16), white(0.2), 1)
  for (k, icon) in dockIcons.enumerated() {
    var r = dockIconRect(k)
    if let app = icon.app, let tap = tlEvents.first(where: { $0.kind == "tap" && $0.who == app }) {
      // Bounce while the app launches, then show the "running" dot.
      let open = event("open", app)?.t ?? .infinity
      if t >= tap.t && t < open + 0.25 { r.origin.y -= abs(sin(CGFloat(t - tap.t) * .pi / 0.42)) * 16 }
      if t >= open { fill(ctx, CGPath(ellipseIn: CGRect(x: r.midX - 2.5, y: dockRect.maxY - 6, width: 5, height: 5), transform: nil), white(0.8)) }
    }
    drawImage(ctx, icon.image, r)
  }
}

/// A window flying out of its dock icon into place (and back when the end card comes up).
func drawWindow(_ ctx: CGContext, _ t: Double, app: String, target: CGRect, _ body: (CGContext, Double) -> Void) {
  guard let open = event("open", app)?.t, t >= open else { return }
  let end = event("end")?.t ?? .infinity
  var u = easeOut(CGFloat(t - open) / 0.5)
  if t > end { u = 1 - easeInOut(CGFloat(t - end) / 0.45) }
  guard u > 0.001 else { return }
  let icon = dockIconRect(app: app)
  let s = lerp(icon.width / target.width, 1, u)
  let c = CGPoint(x: lerp(icon.midX, target.midX, u), y: lerp(icon.midY, target.midY, u))
  ctx.saveGState()
  ctx.translateBy(x: c.x, y: c.y)
  ctx.scaleBy(x: s, y: s)
  ctx.translateBy(x: -target.midX, y: -target.midY)
  faded(ctx, clamp01(u * 2.5)) { body(ctx, t) }
  ctx.restoreGState()
}

func drawConfetti(_ ctx: CGContext, _ t: Double) {
  for (n, e) in events("confetti").enumerated() where t >= e.t && t < e.t + 3 {
    var rng = SplitMix(state: 42 + UInt64(n))
    let age = CGFloat(t - e.t)
    for _ in 0..<120 {
      let x0 = rng.range(display.minX, display.maxX), delay = rng.range(0, 0.35)
      let vx = rng.range(-70, 70), vy = rng.range(40, 260), spin = rng.range(-9, 9), w = rng.range(7, 11)
      let color = confettiColors[Int(rng.next() * CGFloat(confettiColors.count)) % confettiColors.count]
      let a = age - delay
      guard a > 0 else { continue }
      let p = CGPoint(x: x0 + vx * a, y: display.minY + menuH - 10 + vy * a + 260 * a * a)
      ctx.saveGState()
      ctx.translateBy(x: p.x, y: p.y)
      ctx.rotate(by: spin * a)
      ctx.scaleBy(x: 1, y: abs(cos(spin * a * 0.7)) * 0.8 + 0.2)
      ctx.setAlpha(clamp01(3 - a))
      ctx.setFillColor(color)
      ctx.fill(CGRect(x: -w / 2, y: -w * 0.35, width: w, height: w * 0.7))
      ctx.restoreGState()
    }
  }
}

func drawTitle(_ ctx: CGContext, _ big: String, _ small: [Span], alpha: CGFloat, rise: CGFloat, extra: [Span]? = nil) {
  faded(ctx, alpha) {
    let cy = display.midY - 40 + rise
    drawCentered(ctx, [Span(big, white(0.97), sans(76, .bold))], cx: display.midX, baseline: cy)
    drawCentered(ctx, small, cx: display.midX, baseline: cy + 56)
    if let extra {
      let l = makeLine(extra)
      let pill = CGRect(x: display.midX - width(l) / 2 - 18, y: cy + 88, width: width(l) + 36, height: 40)
      fill(ctx, rounded(pill, 20), white(0.1))
      stroke(ctx, rounded(pill.insetBy(dx: 0.5, dy: 0.5), 20), white(0.2), 1)
      draw(ctx, l, x: pill.minX + 18, baseline: pill.midY + 8)
    }
  }
}

func drawDisplay(_ ctx: CGContext, _ t: Double) {
  ctx.saveGState()
  ctx.addPath(rounded(display, 6))
  ctx.clip()
  // Wallpaper: deep blue with soft Codex-blue and Clawd-orange light.
  ctx.drawLinearGradient(gradient([rgb(24, 27, 52), rgb(11, 12, 22)]), start: CGPoint(x: display.minX, y: display.minY),
                         end: CGPoint(x: display.maxX, y: display.maxY), options: [])
  glow(ctx, CGPoint(x: display.minX + display.width * 0.18, y: display.minY + display.height * 0.8), 460, rgb(70, 100, 255, 0.34))
  glow(ctx, CGPoint(x: display.minX + display.width * 0.85, y: display.minY + display.height * 0.2), 420, rgb(217, 119, 87, 0.3))
  glow(ctx, CGPoint(x: display.midX, y: display.minY), 360, rgb(150, 90, 220, 0.16))

  if let title = event("title") {
    let end = title.t + (title.dur ?? 2)
    let a = t < end - 0.5 ? 1 : clamp01(CGFloat(end - t) / 0.5)
    drawTitle(ctx, "Touch Bar Buddies", [Span("Codex & Clawd live in your Touch Bar", white(0.78), sans(30))],
              alpha: a, rise: -14 * (1 - a))
  }
  drawWindow(ctx, t, app: "codex", target: codexWindow) { c, tt in drawCodexWindow(c, tt) }
  drawWindow(ctx, t, app: "clawd", target: claudeWindow) { c, tt in drawClaudeWindow(c, tt) }
  drawMenuBar(ctx)
  drawDock(ctx, t)
  drawConfetti(ctx, t)
  if let end = event("end")?.t, t > end + 0.25 {
    let a = easeOut(CGFloat(t - end - 0.25) / 0.6)
    drawTitle(ctx, "Touch Bar Buddies",
              [Span("github.com/benpham3206/touchbar-buddies", codexLight, sans(30, .medium))],
              alpha: a, rise: 16 * (1 - a),
              extra: [Span("free & open source", white(0.85), sans(20, .semibold))])
  }
  ctx.restoreGState()
}

// MARK: - Laptop body

func drawBackground(_ ctx: CGContext) {
  ctx.drawLinearGradient(gradient([rgb(20, 23, 40), rgb(7, 8, 13)]), start: .zero, end: CGPoint(x: 0, y: H), options: [])
  glow(ctx, CGPoint(x: W / 2, y: 430), 1000, rgb(70, 90, 190, 0.22))
}

func drawLid(_ ctx: CGContext) {
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 60, color: black(0.6))
  fill(ctx, rounded(lid, 26), rgb(30, 31, 35))
  ctx.restoreGState()
  stroke(ctx, rounded(lid.insetBy(dx: 1, dy: 1), 25), rgb(92, 95, 104), 2)
  fill(ctx, rounded(lid.insetBy(dx: 9, dy: 9), 18), rgb(6, 6, 8))
  fill(ctx, CGPath(ellipseIn: CGRect(x: W / 2 - 3, y: lid.minY + 7, width: 6, height: 6), transform: nil), rgb(28, 30, 36))
}

func drawDeck(_ ctx: CGContext) {
  // Hinge, then the deck in perspective: rows spread toward the viewer.
  fillVertical(ctx, rounded(CGRect(x: lid.minX + 50, y: lid.maxY - 4, width: lid.width - 100, height: 12), 5), [rgb(14, 15, 17), rgb(40, 41, 46)])
  let deck = deckQuad(0, 0, 1, 1)
  fillVertical(ctx, deck, [rgb(64, 66, 73), rgb(44, 46, 51)])
  ctx.move(to: deckPoint(0, 0)); ctx.addLine(to: deckPoint(1, 0))
  ctx.setStrokeColor(rgb(120, 123, 132)); ctx.setLineWidth(1.5); ctx.strokePath()

  // Keyboard: five rows of keys (widths in key units), then the trackpad.
  let rows: [[CGFloat]] = [
    Array(repeating: 1, count: 13) + [1.6],
    [1.5] + Array(repeating: 1, count: 12) + [1.1],
    [1.8] + Array(repeating: 1, count: 11) + [1.8],
    [2.3] + Array(repeating: 1, count: 10) + [2.3],
    [1, 1, 1, 1.3, 5.2, 1.3, 1, 1, 1, 1],
  ]
  let u0: CGFloat = 0.09, u1: CGFloat = 0.91
  for (r, keys) in rows.enumerated() {
    let v0 = 0.205 + CGFloat(r) * 0.068, v1 = v0 + 0.058
    let total = keys.reduce(0, +)
    let unit = (u1 - u0) / total
    var u = u0
    for k in keys {
      let left = u + unit * 0.065, right = u + unit * (k - 0.065)
      let key = deckQuad(left, v0, right, v1)
      fill(ctx, key, rgb(16, 17, 19))
      let bevel = CGMutablePath()
      bevel.move(to: deckPoint(left + unit * 0.025, v0 + 0.006))
      bevel.addLine(to: deckPoint(right - unit * 0.025, v0 + 0.006))
      stroke(ctx, bevel, white(0.07), 1)
      u += unit * k
    }
  }
  let pad = deckQuad(0.33, 0.57, 0.67, 0.91)
  fill(ctx, pad, rgb(58, 60, 66))
  stroke(ctx, pad, rgb(78, 80, 88), 1.5)
}

/// Things thrown across the bar (the ball, a message, a result) are only a few pixels on the deck strip: a glowing
/// comet there shows where they are between the lenses.
func drawInFlight(_ ctx: CGContext, _ i: Int) {
  for back in stride(from: 6, through: 0, by: -1) where i - back >= 0 {
    let fade = 1 - CGFloat(back) / 7
    for p in info(i - back).flying {
      let c = stripPoint(CGFloat(p[0]), CGFloat(p[1]))
      if back == 0 { glow(ctx, c, 26, white(0.5)) }
      fill(ctx, CGPath(ellipseIn: CGRect(x: c.x - 3.5 * fade, y: c.y - 3.5 * fade, width: 7 * fade, height: 7 * fade), transform: nil),
           white(0.85 * fade))
    }
  }
}

func drawTouchBar(_ ctx: CGContext, _ strip8: CGImage) {
  let frame = deckQuad(barU0 - 0.004, barV0 - 0.012, barU1 + 0.004, barV1 + 0.012)
  fill(ctx, frame, rgb(4, 4, 5))
  stroke(ctx, frame, rgb(26, 27, 30), 1)

  ctx.saveGState()
  // Small affine slices keep the image content aligned with the deck's projective plane.
  let slices = 24
  for i in 0..<slices {
    let x0 = CGFloat(i) / CGFloat(slices) * bar.width
    let x1 = CGFloat(i + 1) / CGFloat(slices) * bar.width
    let u0 = lerp(barU0, barU1, CGFloat(i) / CGFloat(slices))
    let u1 = lerp(barU0, barU1, CGFloat(i + 1) / CGFloat(slices))
    let p0 = deckPoint(u0, barV0), p1 = deckPoint(u1, barV0), p3 = deckPoint(u0, barV1)
    let a = (p1.x - p0.x) / (x1 - x0), b = (p1.y - p0.y) / (x1 - x0)
    let c = (p3.x - p0.x) / bar.height, d = (p3.y - p0.y) / bar.height
    let transform = CGAffineTransform(a: a, b: b, c: c, d: d, tx: p0.x - a * x0, ty: p0.y - b * x0)
    ctx.saveGState()
    ctx.addPath(deckQuad(u0, barV0, u1, barV1))
    ctx.clip()
    ctx.concatenate(transform)
    drawImage(ctx, strip8, CGRect(x: 0, y: 0, width: bar.width, height: bar.height))
    ctx.restoreGState()
  }
  ctx.restoreGState()
  // Touch ID follows the same plane at the right edge.
  let tid = deckQuad(0.958, barV0, 0.985, barV1)
  fill(ctx, tid, rgb(10, 10, 12))
  stroke(ctx, tid, rgb(40, 41, 45), 1)
}

// MARK: - Lens drawing

func lensAppear(_ t: Double) -> CGFloat { easeOutBack(CGFloat(t - 0.15) / 0.55) }

/// The translucent beams from the part of the strip each lens shows up to the lens (one shape where they overlap).
func drawCones(_ ctx: CGContext, _ ls: [Lens], _ t: Double) {
  let p = CGMutablePath()
  var sources: [CGRect] = []
  for l in ls {
    let a = stripToBar(l.center - l.halfView), b = stripToBar(l.center + l.halfView)
    let src = CGRect(x: a, y: bar.minY - 2, width: b - a, height: bar.height + 4)
    sources.append(src)
    let outer = l.rect.insetBy(dx: -8, dy: -8)
    p.addLines(between: [CGPoint(x: src.minX, y: src.maxY), CGPoint(x: src.maxX, y: src.maxY),
                         CGPoint(x: outer.maxX - 20, y: outer.minY + 2), CGPoint(x: outer.minX + 20, y: outer.minY + 2)])
    p.closeSubpath()
  }
  faded(ctx, clamp01(CGFloat(t - 0.15) / 0.4)) {
    ctx.saveGState()
    ctx.addPath(p)
    ctx.clip()
    ctx.drawLinearGradient(gradient([white(0.16), white(0.03)]), start: CGPoint(x: 0, y: bar.maxY), end: CGPoint(x: 0, y: lensY - 8), options: [])
    ctx.restoreGState()
    for s in sources { stroke(ctx, rounded(s, 4), white(0.75), 1.5) }
  }
}

func drawLenses(_ ctx: CGContext, _ ls: [Lens], _ t: Double, _ strip8: CGImage) {
  let s = lensAppear(t)
  guard s > 0.01 else { return }
  let m = ls[0].merge
  scaled(ctx, 0.8 + 0.2 * s, around: CGPoint(x: W / 2, y: lensY)) {
    faded(ctx, clamp01(s * 1.5)) {
      // Frames first, so where the two meet the pictures cover the seam.
      for l in ls {
        let outer = l.rect.insetBy(dx: -8, dy: -8)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 40, color: black(0.7))
        fillVertical(ctx, lensShape(l, outer, 30), [rgb(226, 228, 233), rgb(150, 154, 162)])
        ctx.restoreGState()
        stroke(ctx, lensShape(l, outer.insetBy(dx: 0.75, dy: 0.75), 29), white(0.7 * (1 - m)), 1.5)
      }
      if m > 0 {
        let whole = ls[0].rect.union(ls[1].rect).insetBy(dx: -8, dy: -8)
        stroke(ctx, rounded(whole.insetBy(dx: 0.75, dy: 0.75), 29), white(0.7 * m), 1.5)
      }
      for l in ls {
        let r = l.rect
        ctx.saveGState()
        ctx.addPath(lensShape(l, r, 23))
        ctx.clip()
        ctx.setFillColor(black(1))
        ctx.fill(r)
        // The 8× frame, 1:1 and snapped to whole pixels so nothing gets resampled.
        let x = (r.midX - l.center * zoom).rounded()
        drawImage(ctx, strip8, CGRect(x: x, y: r.minY, width: CGFloat(strip8.width), height: CGFloat(strip8.height)), quality: .none)
        // A little glass sheen.
        ctx.drawLinearGradient(gradient([white(0.10), white(0)]), start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.minY + 90), options: [])
        ctx.restoreGState()
        stroke(ctx, lensShape(l, r.insetBy(dx: -0.5, dy: -0.5), 23), black(0.8 * (1 - m)), 2)
      }
      if m > 0 {
        let whole = ls[0].rect.union(ls[1].rect)
        stroke(ctx, rounded(whole.insetBy(dx: -0.5, dy: -0.5), 23), black(0.8 * m), 2)
      }
      // Name tags on the frame's bottom edge.
      for l in ls {
        let outer = l.rect.insetBy(dx: -8, dy: -8)
        let name = makeLine([Span(l.label, white(0.95), sans(17, .semibold))])
        let tagW = width(name) + 42
        let tag = CGRect(x: l.isLeft ? outer.minX + 26 : outer.maxX - 26 - tagW, y: outer.maxY - 15, width: tagW, height: 30)
        fill(ctx, rounded(tag, 15), rgb(20, 21, 25))
        stroke(ctx, rounded(tag.insetBy(dx: 0.5, dy: 0.5), 15), white(0.25), 1)
        fill(ctx, CGPath(ellipseIn: CGRect(x: tag.minX + 13, y: tag.midY - 5, width: 10, height: 10), transform: nil), l.color)
        draw(ctx, name, x: tag.minX + 30, baseline: tag.midY + 6)
      }
    }
  }
}

// MARK: - Taps, bubbles, captions

func drawTaps(_ ctx: CGContext, _ i: Int, _ t: Double) {
  for e in events("tap") {
    let age = CGFloat(t - e.t)
    guard age >= -0.25, age < 0.9, let who = e.who, let x = e.x else { continue }
    let lens = lensShowing(who, CGFloat(x), i)
    let c = CGPoint(x: lens.screenX(CGFloat(x)), y: lens.rect.maxY - 12 * zoom)
    if age < 0 {
      // Fingertip coming down.
      let u = 1 + age / 0.25
      fill(ctx, CGPath(ellipseIn: CGRect(x: c.x - 40, y: c.y - 40, width: 80, height: 80), transform: nil), white(0.22 * u))
      continue
    }
    let press = clamp01(1 - age / 0.3)
    fill(ctx, CGPath(ellipseIn: CGRect(x: c.x - 40, y: c.y - 40, width: 80, height: 80), transform: nil), white(0.3 * press))
    let rr = 36 + 110 * easeOut(age / 0.8), a = 0.75 * (1 - age / 0.9)
    stroke(ctx, CGPath(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2), transform: nil), white(a), 4)
    // And a tiny one on the real-size strip.
    let bc = stripPoint(CGFloat(x))
    let br = 5 + 22 * easeOut(age / 0.8)
    stroke(ctx, CGPath(ellipseIn: CGRect(x: bc.x - br, y: bc.y - br, width: br * 2, height: br * 2), transform: nil), white(a), 2)
  }
}

/// Greedy word wrap.
func wrap(_ words: [String], font: NSFont, maxWidth: CGFloat) -> [String] {
  var lines: [String] = [], cur = ""
  for w in words {
    let next = cur.isEmpty ? w : cur + " " + w
    if !cur.isEmpty && width(makeLine([Span(next, ink, font)])) > maxWidth { lines.append(cur); cur = w } else { cur = next }
  }
  if !cur.isEmpty { lines.append(cur) }
  return lines
}

/// Speech text with the buddies' signature glyphs (>_ and ✻) picked out in their colors.
func bubbleSpans(_ s: String, _ font: NSFont) -> [Span] {
  for (glyph, color) in [(">_", codexBlue), ("✻", clawdOrange)] where s.hasPrefix(glyph) {
    return [Span(glyph, color, glyph == ">_" ? mono(font.pointSize, .heavy) : sans(font.pointSize, .heavy)),
            Span(String(s.dropFirst(glyph.count)), ink, font)]
  }
  return [Span(s, ink, font)]
}

func drawBubbles(_ ctx: CGContext, _ i: Int, _ t: Double) {
  let f = info(i)
  let font = sans(29, .semibold)
  for e in events("say") {
    guard let who = e.who, let s = e.text, let dur = e.dur, t >= e.t, t <= e.t + dur else { continue }
    let b = who == "codex" ? f.codex : f.clawd
    let lens = lensShowing(who, CGFloat(b.x), i)
    let headPt: CGFloat = who == "codex" ? 23 : 17
    let tip = CGPoint(x: lens.screenX(CGFloat(b.x)), y: max(lens.rect.minY + 14, lens.rect.maxY - (headPt + CGFloat(b.hop) + 4) * zoom))

    let lines = wrap(s.components(separatedBy: " "), font: font, maxWidth: 430).map { makeLine(bubbleSpans($0, font)) }
    let lineH: CGFloat = 37
    let w = (lines.map(width).max() ?? 0) + 48, h = CGFloat(lines.count) * lineH + 26
    // Above the lens, leaning toward the outside so the two sides never collide.
    let lean: CGFloat = who == "codex" ? -40 : 40
    let minX = who == "codex" ? 26 : W / 2 + 40, maxX = who == "codex" ? W / 2 - 40 : W - 26
    let x = min(max(tip.x - w / 2 + lean, minX), maxX - w)
    let box = CGRect(x: x, y: lens.rect.minY - 30 - h, width: w, height: h)

    let pop = easeOutBack(CGFloat(t - e.t) / 0.28)
    let out = clamp01(CGFloat(t - (e.t + dur - 0.2)) / 0.2)
    scaled(ctx, (0.55 + 0.45 * pop) * (1 - 0.12 * out), around: tip) {
      faded(ctx, clamp01(CGFloat(t - e.t) / 0.1) * (1 - out)) {
        let tailX = min(max(tip.x, box.minX + 34), box.maxX - 34)
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: tailX - 16, y: box.maxY - 2))
        tail.addQuadCurve(to: tip, control: CGPoint(x: tailX - 4, y: (box.maxY + tip.y) / 2))
        tail.addQuadCurve(to: CGPoint(x: tailX + 16, y: box.maxY - 2), control: CGPoint(x: tailX + 10, y: (box.maxY + tip.y) / 2))
        tail.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: black(0.45))
        fill(ctx, rounded(box, 24), white(1))
        fill(ctx, tail, white(1))
        ctx.restoreGState()
        // A thin accent under the text in the speaker's color.
        let accent = who == "codex" ? codexBlue : clawdOrange
        fill(ctx, rounded(CGRect(x: box.minX + 20, y: box.maxY - 9, width: box.width - 40, height: 3), 1.5), accent.copy(alpha: 0.55)!)
        for (k, l) in lines.enumerated() {
          draw(ctx, l, x: box.midX - width(l) / 2, baseline: box.minY + 13 + lineH * CGFloat(k) + 28)
        }
      }
    }
  }
}

func drawPill(_ ctx: CGContext, _ l: CTLine, cy: CGFloat, height h: CGFloat, alpha a: CGFloat, pad: CGFloat) {
  let pill = CGRect(x: (W / 2 - width(l) / 2 - pad).rounded(), y: cy - h / 2, width: width(l) + 2 * pad, height: h)
  faded(ctx, a) {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 20, color: black(0.5))
    fill(ctx, rounded(pill, h / 2), rgb(18, 19, 24, 0.94))
    ctx.restoreGState()
    stroke(ctx, rounded(pill.insetBy(dx: 0.5, dy: 0.5), h / 2), white(0.18), 1)
    draw(ctx, l, x: pill.minX + pad, baseline: pill.midY + h * 0.16)
  }
}

func drawCaptions(_ ctx: CGContext, _ t: Double) {
  for e in events("caption") {
    guard let s = e.text, let dur = e.dur else { continue }
    let a = envelope(t, e.t, e.t + dur, 0.35, 0.35)
    guard a > 0 else { continue }
    drawPill(ctx, makeLine([Span(s, white(0.97), sans(27, .semibold))]), cy: captionY + 27 + 8 * (1 - a), height: 54, alpha: a, pad: 26)
  }
}

/// "▶▶ 4×" between the lenses while a ramp plays the long runs faster.
func drawFastForward(_ ctx: CGContext, _ i: Int) {
  let v = speedAt(i)
  guard v > 1.05, let top = ramps.map(\.speed).max() else { return }
  let a = clamp01(CGFloat((v - 1) / (top - 1)) * 2) * (1 - lensTrack.merge[i])
  let shown = ramps.filter { srcTimes[i] > $0.from - 0.4 && srcTimes[i] < $0.to + 0.4 }.map(\.speed).max() ?? top
  let l = makeLine([Span("▶▶ ", white(0.9), sans(20, .bold)), Span(String(format: "%g×", shown), white(0.97), sans(22, .bold))])
  drawPill(ctx, l, cy: lensY + lensH / 2, height: 44, alpha: a, pad: 20)
}

// MARK: - Frame

func stripFrame(_ n: Int) -> CGImage {
  let url = framesDir.appendingPathComponent(String(format: "%04d.png", n))
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fail("missing frame \(url.path)")
  }
  return img
}

func renderFrame(_ i: Int, into ctx: CGContext) {
  cur = i
  let t = Double(i) / fps
  let strip8 = stripFrame(sourceFrame(i))
  let ls = lenses(i)
  ctx.saveGState()
  ctx.translateBy(x: 0, y: H)
  ctx.scaleBy(x: 1, y: -1)
  drawBackground(ctx)
  drawLid(ctx)
  drawDisplay(ctx, t)
  drawDeck(ctx)
  drawTouchBar(ctx, strip8)
  drawInFlight(ctx, i)
  drawCones(ctx, ls, t)
  drawLenses(ctx, ls, t, strip8)
  drawTaps(ctx, i, t)
  drawCaptions(ctx, t)
  drawFastForward(ctx, i)
  drawBubbles(ctx, i, t)
  if t < 0.4 {
    ctx.setFillColor(black(1 - CGFloat(t / 0.4)))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
  }
  ctx.restoreGState()
}

// MARK: - Procedural audio

let audioSampleRate = 48_000
let audioSamplesPerVideoFrame = audioSampleRate / Int(fps)
let audioPeak = 0.48                                  // about -6.4 dBFS, with headroom for AAC

func noiseSample(_ sample: Int, _ seed: Int) -> Double {
  let x = sin(Double(sample) * 12.9898 + Double(seed) * 78.233) * 43758.5453
  return (x - floor(x)) * 2 - 1
}

func sweep(_ from: Double, _ to: Double, _ t: Double, _ duration: Double) -> Double {
  let slope = (to - from) / max(0.001, duration)
  return sin(2 * .pi * (from * t + slope * t * t * 0.5))
}

func synthesizeAudio() -> [Int16] {
  let frameTotal = frameCount * audioSamplesPerVideoFrame
  var left = [Float](repeating: 0, count: frameTotal)
  var right = [Float](repeating: 0, count: frameTotal)

  for (eventIndex, cue) in soundCues.enumerated() {
    let start = max(0, Int((cue.start * Double(audioSampleRate)).rounded()))
    guard start < frameTotal else { continue }
    let count = min(frameTotal - start, max(1, Int((cue.duration * Double(audioSampleRate)).rounded())))
    let duration = Double(count) / Double(audioSampleRate)
    for j in 0..<count {
      let u = Double(j) / Double(max(1, count - 1))
      let t = Double(j) / Double(audioSampleRate)
      let rawNoise = noiseSample(start + j, eventIndex + 1)
      let highNoise = rawNoise - noiseSample(start + j - 1, eventIndex + 1) * 0.72
      var sample = 0.0

      switch cue.kind {
      case .tap:
        let env = exp(-t * 75)
        sample = (sweep(1750, 950, t, duration) * 0.52 + rawNoise * 0.38) * env
      case .pop:
        let env = exp(-t * 28)
        sample = (sweep(620, 250, t, duration) * 0.58 + rawNoise * 0.32) * env
      case .typing:
        let env = exp(-t * 190)
        sample = (rawNoise * 0.48 + sweep(2100, 1300, t, duration) * 0.42) * env
      case .foot:
        let env = pow(max(0, sin(.pi * u)), 0.9)
        let step = 0.78 + 0.22 * sin(2 * .pi * 5.5 * t)
        sample = (highNoise * 0.45 + sweep(720, 420, t, duration) * 0.16) * env * step
      case .cloud:
        let env = pow(max(0, sin(.pi * u)), 1.15)
        sample = (highNoise * 0.46 + sweep(480, 1120, t, duration) * 0.22) * env
      case .kart:
        let env = pow(max(0, sin(.pi * u)), 0.95)
        sample = (sweep(92, 148, t, duration) * 0.43 + highNoise * 0.25) * env
      case .flight:
        let env = pow(max(0, sin(.pi * u)), 1.1)
        sample = (highNoise * 0.5 + sweep(880, 520, t, duration) * 0.18) * env
      case .chime:
        let env = exp(-t * 7.5)
        sample = (sin(2 * .pi * 660 * t) * 0.34 + sin(2 * .pi * 990 * t) * 0.23
                  + sin(2 * .pi * 1320 * t) * 0.1) * env
      case .sparkle:
        let env = exp(-t * 9)
        sample = (sin(2 * .pi * 1480 * t) * 0.28 + sin(2 * .pi * 2050 * t) * 0.2
                  + sin(2 * .pi * 2760 * t) * 0.12) * env
      }

      let pan = cue.panStart + (cue.panEnd - cue.panStart) * u
      let angle = (pan + 1) * .pi / 4
      let value = Float(sample * cue.gain)
      left[start + j] += value * Float(cos(angle))
      right[start + j] += value * Float(sin(angle))
    }
  }

  let peak = max(left.map { abs($0) }.max() ?? 0, right.map { abs($0) }.max() ?? 0)
  let scale = peak > 0 ? Float(audioPeak) / peak : 1
  var pcm = [Int16](repeating: 0, count: frameTotal * 2)
  for i in 0..<frameTotal {
    let l = min(1, max(-1, left[i] * scale))
    let r = min(1, max(-1, right[i] * scale))
    pcm[i * 2] = Int16((l * Float(Int16.max)).rounded())
    pcm[i * 2 + 1] = Int16((r * Float(Int16.max)).rounded())
  }
  return pcm
}

func audioFormat() -> CMAudioFormatDescription? {
  var asbd = AudioStreamBasicDescription(mSampleRate: Double(audioSampleRate), mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4,
    mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
  var format: CMAudioFormatDescription?
  let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0,
    layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
  return status == noErr ? format : nil
}

func audioSampleBuffer(_ pcm: [Int16], start: Int, count: Int,
                       format: CMAudioFormatDescription) -> CMSampleBuffer? {
  let bytesPerFrame = 2 * MemoryLayout<Int16>.size     // `start` / `count` are stereo frames: two samples each
  let byteCount = count * bytesPerFrame
  var block: CMBlockBuffer?
  let blockStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
    blockLength: byteCount, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
    dataLength: byteCount, flags: 0, blockBufferOut: &block)
  guard blockStatus == kCMBlockBufferNoErr, let block else { return nil }
  let copyStatus = pcm.withUnsafeBytes { bytes -> OSStatus in
    guard let base = bytes.baseAddress else { return -1 }
    let source = base.advanced(by: start * bytesPerFrame)
    return CMBlockBufferReplaceDataBytes(with: source, blockBuffer: block, offsetIntoDestination: 0,
                                         dataLength: byteCount)
  }
  guard copyStatus == kCMBlockBufferNoErr else { return nil }
  var timing = CMSampleTimingInfo(duration: CMTime(value: CMTimeValue(count), timescale: CMTimeScale(audioSampleRate)),
    presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(audioSampleRate)),
    decodeTimeStamp: .invalid)
  var sample: CMSampleBuffer?
  let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
    formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
    sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
  return status == noErr ? sample : nil
}

/// AVAssetWriter encodes AAC into MOV where the system encoder is available.
func encodeAudioWithWriter(_ pcm: [Int16], format: CMAudioFormatDescription) -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-audio-\(UUID().uuidString).mov")
  guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { fail("can't create the AAC encoder") }
  let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVSampleRateKey: audioSampleRate,
    AVNumberOfChannelsKey: 2,
    AVEncoderBitRateKey: 128_000,
  ])
  guard writer.canAdd(input) else { fail("AAC encoding isn't available") }
  writer.add(input)
  writer.startWriting()
  writer.startSession(atSourceTime: .zero)
  let totalFrames = pcm.count / 2
  for start in stride(from: 0, to: totalFrames, by: audioSamplesPerVideoFrame) {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    let count = min(audioSamplesPerVideoFrame, totalFrames - start)
    guard let sample = audioSampleBuffer(pcm, start: start, count: count, format: format), input.append(sample) else {
      fail("AAC encoding failed: \(String(describing: writer.error))")
    }
  }
  input.markAsFinished()
  let done = DispatchSemaphore(value: 0)
  writer.finishWriting { done.signal() }
  done.wait()
  guard writer.status == .completed else { fail("AAC encoding failed: \(String(describing: writer.error))") }
  return url
}

func le16(_ value: UInt16) -> [UInt8] {
  [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)]
}

func le32(_ value: UInt32) -> [UInt8] {
  [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)]
}

/// Some macOS installs have no AAC AudioConverter component; ffmpeg is only needed on those systems.
func encodeAudioWithFFmpeg(_ pcm: [Int16]) -> URL {
  let root = FileManager.default.temporaryDirectory
  let waveURL = root.appendingPathComponent("demo-audio-\(UUID().uuidString).wav")
  let encodedURL = root.appendingPathComponent("demo-audio-\(UUID().uuidString).m4a")
  let bytes = pcm.count * MemoryLayout<Int16>.size
  var wave = Data("RIFF".utf8)
  wave.append(contentsOf: le32(UInt32(36 + bytes)))
  wave.append(contentsOf: Data("WAVEfmt ".utf8))
  wave.append(contentsOf: le32(16))
  wave.append(contentsOf: le16(1))
  wave.append(contentsOf: le16(2))
  wave.append(contentsOf: le32(UInt32(audioSampleRate)))
  wave.append(contentsOf: le32(UInt32(audioSampleRate * 4)))
  wave.append(contentsOf: le16(4))
  wave.append(contentsOf: le16(16))
  wave.append(contentsOf: Data("data".utf8))
  wave.append(contentsOf: le32(UInt32(bytes)))
  wave.append(pcm.withUnsafeBytes { Data($0) })
  do { try wave.write(to: waveURL) } catch { fail("can't write temporary PCM audio: \(error)") }

  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", waveURL.path,
                       "-vn", "-c:a", "aac", "-b:a", "128k", "-ar", "48000", "-ac", "2", "-f", "mp4", encodedURL.path]
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  do { try process.run(); process.waitUntilExit() } catch { fail("AAC encoder unavailable (install ffmpeg): \(error)") }
  try? FileManager.default.removeItem(at: waveURL)
  guard process.terminationStatus == 0 else { fail("ffmpeg couldn't encode the synthesized AAC track") }
  return encodedURL
}

func encodeAudio(_ pcm: [Int16], format: CMAudioFormatDescription) -> URL {
  let source = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(audioSampleRate), channels: 2, interleaved: true)
  let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVSampleRateKey: audioSampleRate,
    AVNumberOfChannelsKey: 2,
    AVEncoderBitRateKey: 128_000,
  ]
  if let source, let output = AVAudioFormat(settings: settings), AVAudioConverter(from: source, to: output) != nil {
    return encodeAudioWithWriter(pcm, format: format)
  }
  print("audio: system AAC encoder unavailable; using the installed ffmpeg encoder")
  return encodeAudioWithFFmpeg(pcm)
}

func readEncodedAudio(_ url: URL) -> (samples: [CMSampleBuffer], format: CMAudioFormatDescription) {
  let asset = AVURLAsset(url: url)
  guard let track = asset.tracks(withMediaType: .audio).first,
        let reader = try? AVAssetReader(asset: asset) else { fail("can't read the encoded AAC track") }
  let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
  guard reader.canAdd(output) else { fail("can't read encoded AAC packets") }
  reader.add(output)
  guard reader.startReading() else { fail("AAC track reader failed: \(String(describing: reader.error))") }
  var samples: [CMSampleBuffer] = []
  while let sample = output.copyNextSampleBuffer() {
    guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
    samples.append(sample)
  }
  guard reader.status == .completed, !samples.isEmpty else { fail("AAC track reader failed: \(String(describing: reader.error))") }
  guard let format = CMSampleBufferGetFormatDescription(samples[0]) else { fail("encoded AAC has no format description") }
  return (samples, format)
}

func readEncodedVideo(_ url: URL) -> (samples: [CMSampleBuffer], format: CMVideoFormatDescription) {
  let asset = AVURLAsset(url: url)
  guard let track = asset.tracks(withMediaType: .video).first,
        let reader = try? AVAssetReader(asset: asset) else { fail("can't read the encoded H.264 track") }
  let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
  guard reader.canAdd(output) else { fail("can't read encoded H.264 packets") }
  reader.add(output)
  guard reader.startReading() else { fail("H.264 track reader failed: \(String(describing: reader.error))") }
  var samples: [CMSampleBuffer] = []
  while let sample = output.copyNextSampleBuffer() {
    guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
    samples.append(sample)
  }
  guard reader.status == .completed, !samples.isEmpty else { fail("H.264 track reader failed: \(String(describing: reader.error))") }
  guard let format = CMSampleBufferGetFormatDescription(samples[0]) else { fail("encoded H.264 has no format description") }
  return (samples, format)
}

func makeContext(_ w: Int, _ h: Int, data: UnsafeMutableRawPointer? = nil, bytesPerRow: Int = 0) -> CGContext {
  CGContext(data: data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
}

func writePNG(_ img: CGImage, _ url: URL) {
  let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, img, nil)
  CGImageDestinationFinalize(dest)
}

// MARK: - Stills mode

// COMPOSE_DEBUG=1: print the time map and the lens cameras (every 0.1 s of video) instead of drawing anything.
if ProcessInfo.processInfo.environment["COMPOSE_DEBUG"] != nil {
  print("deck bar \(bar), corners \(deckPoint(barU0, barV0)) \(deckPoint(barU1, barV0)) \(deckPoint(barU1, barV1)) \(deckPoint(barU0, barV1))")
  for i in stride(from: 0, to: frameCount, by: 3) {
    let f = info(i), ls = lenses(i)
    print(String(format: "%.2f src %.2f  codex %.0f  L %.0f  clawd %.0f  R %.0f  c %.2f m %.2f", Double(i) / fps, srcTimes[i], f.codex.x, ls[0].center, f.clawd.x, ls[1].center, lensTrack.shared[i], ls[0].merge))
  }
  exit(0)
}

if args[3] == "--stills" {
  guard args.count >= 6 else { fail("--stills <outDir> <t1,t2,…>") }
  let out = URL(fileURLWithPath: args[4])
  try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
  for s in args[5].split(separator: ",") {
    guard let sec = Double(s) else { fail("\(s) isn't a number of seconds") }
    let i = min(frameCount - 1, Int((sec * fps).rounded()))
    let ctx = makeContext(Int(W), Int(H))
    renderFrame(i, into: ctx)
    writePNG(ctx.makeImage()!, out.appendingPathComponent("still-\(s).png"))
  }
  print("wrote stills to \(out.path) (the video is \(String(format: "%.1f", videoLength)) s)")
  exit(0)
}

// MARK: - Video (H.264) + GIF highlight

let mp4URL = URL(fileURLWithPath: args[3])
let gifURL = args.count > 4 ? URL(fileURLWithPath: args[4]) : nil
let gifStep = 2                    // every 2nd frame → 15 fps
let gifSize = CGSize(width: 960, height: 540)

func videoSettings() -> [String: Any] {
  [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: Int(W),
    AVVideoHeightKey: Int(H),
    AVVideoCompressionPropertiesKey: [
      AVVideoAverageBitRateKey: 2_600_000,
      AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      AVVideoMaxKeyFrameIntervalKey: 60,
      AVVideoExpectedSourceFrameRateKey: Int(fps),
    ],
    AVVideoColorPropertiesKey: [
      AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
      AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
      AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ],
  ]
}

func writerHasH264Encoder() -> Bool {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("video-probe-\(UUID().uuidString).mov")
  defer { try? FileManager.default.removeItem(at: url) }
  guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings())
  guard writer.canAdd(input) else { return false }
  writer.add(input)
  let available = writer.startWriting()
  writer.cancelWriting()
  return available
}

func addGIFFrame(_ context: CGContext, _ i: Int, to frames: inout [CGImage]) {
  let t = Double(i) / fps
  guard gifURL != nil, gifRange.contains(t), i % gifStep == 0 else { return }
  let small = makeContext(Int(gifSize.width), Int(gifSize.height))
  small.interpolationQuality = .high
  small.draw(context.makeImage()!, in: CGRect(origin: .zero, size: gifSize))
  frames.append(small.makeImage()!)
}

func encodeVideoWithWriter(_ gifFrames: inout [CGImage]) -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-video-\(UUID().uuidString).mov")
  guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { fail("can't create the H.264 writer") }
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings())
  input.expectsMediaDataInRealTime = false
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: Int(W),
    kCVPixelBufferHeightKey as String: Int(H),
  ])
  guard writer.canAdd(input) else { fail("H.264 video input isn't available") }
  writer.add(input)
  guard writer.startWriting() else { fail("H.264 encoding failed: \(String(describing: writer.error))") }
  writer.startSession(atSourceTime: .zero)
  for i in 0..<frameCount {
    while !input.isReadyForMoreMediaData { usleep(2000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    let pb = buffer!
    CVPixelBufferLockBaseAddress(pb, [])
    let ctx = makeContext(Int(W), Int(H), data: CVPixelBufferGetBaseAddress(pb), bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
    renderFrame(i, into: ctx)
    addGIFFrame(ctx, i, to: &gifFrames)
    CVPixelBufferUnlockBaseAddress(pb, [])
    adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
    if i % 90 == 0 { print("frame \(i)/\(frameCount)") }
  }
  input.markAsFinished()
  let done = DispatchSemaphore(value: 0)
  writer.finishWriting { done.signal() }
  done.wait()
  guard writer.status == .completed else { fail("H.264 encoding failed: \(String(describing: writer.error))") }
  return url
}

func encodeVideoWithFFmpeg(_ gifFrames: inout [CGImage]) -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo-video-\(UUID().uuidString).mp4")
  let process = Process()
  let pipe = Pipe()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  process.arguments = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
    "-f", "rawvideo", "-pixel_format", "bgra", "-video_size", "1920x1080", "-framerate", "30", "-i", "pipe:0",
    "-an", "-c:v", "libx264", "-preset", "fast", "-profile:v", "high", "-b:v", "2600k", "-maxrate", "2600k",
    "-bufsize", "5200k", "-g", "60", "-bf", "0", "-pix_fmt", "yuv420p", "-color_primaries", "bt709",
    "-color_trc", "bt709", "-colorspace", "bt709", "-movflags", "+faststart", "-f", "mp4", url.path]
  process.standardInput = pipe
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  do { try process.run() } catch { fail("H.264 encoder unavailable (install ffmpeg): \(error)") }
  let handle = pipe.fileHandleForWriting
  let rowBytes = Int(W) * 4, frameBytes = rowBytes * Int(H)
  let pixels = UnsafeMutableRawPointer.allocate(byteCount: frameBytes, alignment: 64)
  defer { pixels.deallocate() }
  for i in 0..<frameCount {
    let ctx = makeContext(Int(W), Int(H), data: pixels, bytesPerRow: rowBytes)
    renderFrame(i, into: ctx)
    addGIFFrame(ctx, i, to: &gifFrames)
    let bytes = Data(bytesNoCopy: pixels, count: frameBytes, deallocator: .none)
    do { try handle.write(contentsOf: bytes) } catch { fail("couldn't stream a frame to ffmpeg: \(error)") }
    if i % 90 == 0 { print("frame \(i)/\(frameCount)") }
  }
  try? handle.close()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { fail("ffmpeg couldn't encode the H.264 video") }
  return url
}

func encodeVideo(_ gifFrames: inout [CGImage]) -> URL {
  if writerHasH264Encoder() { return encodeVideoWithWriter(&gifFrames) }
  print("video: system H.264 encoder unavailable; using the installed ffmpeg encoder")
  return encodeVideoWithFFmpeg(&gifFrames)
}

let pcmAudio = synthesizeAudio()
guard let audioDescription = audioFormat() else { fail("can't create the PCM audio format") }
print("audio: synthesized \(soundCues.count) event(s), peak about \(String(format: "%.1f", 20 * log10(audioPeak))) dBFS")
let encodedAudioURL = encodeAudio(pcmAudio, format: audioDescription)
let encodedAudio = readEncodedAudio(encodedAudioURL)
var gifFrames: [CGImage] = []
let encodedVideoURL = encodeVideo(&gifFrames)
let encodedVideo = readEncodedVideo(encodedVideoURL)

let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString).mp4")
guard let writer = try? AVAssetWriter(outputURL: tmpURL, fileType: .mp4) else { fail("can't write \(tmpURL.path)") }
let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: encodedAudio.format)
audioInput.expectsMediaDataInRealTime = false
let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: encodedVideo.format)
videoInput.expectsMediaDataInRealTime = false
guard writer.canAdd(videoInput), writer.canAdd(audioInput) else { fail("MP4 writer can't mux the H.264 and AAC tracks") }
writer.add(videoInput)
writer.add(audioInput)
guard writer.startWriting() else { fail("MP4 writer couldn't start: \(String(describing: writer.error))") }
writer.startSession(atSourceTime: .zero)
print("mux: AVAssetWriter accepted AAC and H.264 packet tracks")

let muxQueue = DispatchQueue(label: "demo.mp4.mux")
let muxGroup = DispatchGroup()
let muxLock = NSLock()
var muxFailure: String?
func recordMuxFailure(_ message: String) {
  muxLock.lock()
  if muxFailure == nil { muxFailure = message }
  muxLock.unlock()
}

// Let AVAssetWriter request each track as its muxer has room; busy-waiting one input can starve the other.
var videoIndex = 0
muxGroup.enter()
videoInput.requestMediaDataWhenReady(on: muxQueue) {
  while videoInput.isReadyForMoreMediaData {
    guard videoIndex < encodedVideo.samples.count else {
      videoInput.markAsFinished()
      muxGroup.leave()
      return
    }
    guard videoInput.append(encodedVideo.samples[videoIndex]) else {
      recordMuxFailure("H.264 mux failed: \(String(describing: writer.error))")
      videoInput.markAsFinished()
      muxGroup.leave()
      return
    }
    videoIndex += 1
  }
}

let audioQueue = DispatchQueue(label: "demo.mp4.audio")
var audioIndex = 0
muxGroup.enter()
audioInput.requestMediaDataWhenReady(on: audioQueue) {
  while audioInput.isReadyForMoreMediaData {
    guard audioIndex < encodedAudio.samples.count else {
      audioInput.markAsFinished()
      muxGroup.leave()
      return
    }
    guard audioInput.append(encodedAudio.samples[audioIndex]) else {
      recordMuxFailure("AAC mux failed: \(String(describing: writer.error))")
      audioInput.markAsFinished()
      muxGroup.leave()
      return
    }
    audioIndex += 1
  }
}

muxGroup.wait()
muxLock.lock()
let muxError = muxFailure
muxLock.unlock()
if let muxError { fail(muxError) }
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { fail("video failed: \(String(describing: writer.error))") }
try? FileManager.default.removeItem(at: encodedAudioURL)
try? FileManager.default.removeItem(at: encodedVideoURL)
let fm = FileManager.default
if fm.fileExists(atPath: mp4URL.path) { _ = try? fm.replaceItemAt(mp4URL, withItemAt: tmpURL) } else { try? fm.moveItem(at: tmpURL, to: mp4URL) }
print("wrote \(mp4URL.path) (\(String(format: "%.1f", videoLength)) s, AAC audio)")

if let gifURL, !gifFrames.isEmpty {
  let dest = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, gifFrames.count, nil)!
  let gif = kCGImagePropertyGIFDictionary as String
  CGImageDestinationSetProperties(dest, [gif: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
  for (k, img) in gifFrames.enumerated() {
    // GIF delays are whole centiseconds: alternate 6/7 to average 15 fps.
    let delay = k % 3 == 1 ? 0.06 : 0.07
    CGImageDestinationAddImage(dest, img, [gif: [kCGImagePropertyGIFDelayTime as String: delay]] as CFDictionary)
  }
  CGImageDestinationFinalize(dest)
  print("wrote \(gifURL.path) (\(gifFrames.count) frames)")
}
