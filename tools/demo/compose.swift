// Builds the README demo (docs/demo.mp4 + docs/demo.gif) around the Touch Bar frames that
// `TouchBarBuddies --render-demo` rendered with the app's real drawing code.
//
// It draws a stylized MacBook: a desktop mockup on the screen (the ChatGPT · Codex and Claude windows
// are simple generic mockups, not screenshots), the whole Touch Bar strip on the keyboard deck, and two
// magnifier lenses with speech bubbles so the 30pt-tall buddies are easy to see.
//
//   swiftc -O -swift-version 5 tools/demo/compose.swift -o build/demo/compose
//   build/demo/compose <framesDir> <out.mp4> <out.gif>
//   build/demo/compose <framesDir> --stills <outDir> 1.5,7.8,24   (check single frames as PNGs)
//
// WORK IN PROGRESS: this still reads the frame dump of the old `--render-demo` mode (strip@2x/, strip@8x/,
// timeline.json with events). See docs/DEMO_PLAN.md for how to feed it from Sources/Render.swift.

import AppKit
import AVFoundation
import CoreText
import ImageIO
import UniformTypeIdentifiers

// MARK: - Timeline (written by Sources/Demo.swift)

struct BuddyInfo: Decodable { let x, hop: Double; let mode: String; let busy: Bool }
struct FrameInfo: Decodable { let t: Double; let codex, clawd: BuddyInfo; let speaking: [String] }
struct Event: Decodable {
  let t: Double
  let kind: String
  let who: String?
  let text: String?
  let dur: Double?
  let on: Bool?
  let x: Double?
}
struct Timeline: Decodable {
  let fps: Int
  let length: Double
  let width, height: Double
  let codexPocket, clawdPocket: [Double]
  let events: [Event]
  let frames: [FrameInfo]
}

let args = CommandLine.arguments
guard args.count >= 3 else {
  print("usage: compose <framesDir> <out.mp4> <out.gif> | compose <framesDir> --stills <outDir> <t1,t2,…>")
  exit(1)
}
let framesDir = URL(fileURLWithPath: args[1])
let tl = try! JSONDecoder().decode(Timeline.self, from: Data(contentsOf: framesDir.appendingPathComponent("timeline.json")))
let fps = Double(tl.fps)

func event(_ kind: String, _ who: String? = nil) -> Event? { tl.events.first { $0.kind == kind && (who == nil || $0.who == who) } }
func events(_ kind: String) -> [Event] { tl.events.filter { $0.kind == kind } }
func workTime(_ who: String, _ on: Bool) -> Double? { tl.events.first { $0.kind == "work" && $0.who == who && $0.on == on }?.t }

func stripFrame(_ i: Int, scale: Int) -> CGImage {
  let url = framesDir.appendingPathComponent(String(format: "strip@%dx/%04d.png", scale, i))
  let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
  return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}

// MARK: - Layout (1920×1080, y grows downward)

let W: CGFloat = 1920, H: CGFloat = 1080
let lid = CGRect(x: 460, y: 26, width: 1000, height: 574)
let display = CGRect(x: 478, y: 44, width: 964, height: 532)
let deckTop: CGFloat = 604, deckTopL: CGFloat = 352, deckTopR: CGFloat = 1568
let deckBottom: CGFloat = 1130, deckBotL: CGFloat = 96, deckBotR: CGFloat = 1824
let barPt: CGFloat = 1.1                                   // deck strip: pixels per point
let bar = CGRect(x: W / 2 - 1004 * barPt / 2, y: 626, width: 1004 * barPt, height: 30 * barPt)
let zoom: CGFloat = 8                                      // lens: pixels per point (the 8× frames, 1:1)
let lensW: CGFloat = 640, lensH: CGFloat = 240
let menuH: CGFloat = 24

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

/// A magnifier over part of the strip. It frames its buddy, and slides over to include a visitor.
struct Lens {
  let rect: CGRect             // where the magnified strip appears (inside the frame)
  let home: CGFloat            // strip x (points) it rests on: its buddy's pocket
  let label: String
  let color: CGColor
  var isLeft: Bool { rect.midX < W / 2 }
  var centers: [CGFloat] = []  // strip x at the lens center, per frame (smoothed like a camera)

  func screenX(_ stripX: CGFloat, _ i: Int) -> CGFloat { rect.midX + (stripX - centers[i]) * zoom }
  func shows(_ stripX: CGFloat, _ i: Int) -> Bool { abs(stripX - centers[i]) < lensW / zoom / 2 - 6 }
}

func pocketMid(_ p: [Double]) -> CGFloat { CGFloat(p[0] + p[2] / 2) }

func trackCenters(home: CGFloat) -> [CGFloat] {
  var c = home, out: [CGFloat] = []
  for f in tl.frames {
    // Everyone within ~100pt of home pulls the framing toward them (fading in as they get close).
    var sum = home * 0.001, weight: CGFloat = 0.001
    for x in [CGFloat(f.codex.x), CGFloat(f.clawd.x)] {
      let w = clamp01((110 - abs(x - home)) / 60)
      sum += x * w
      weight += w
    }
    c += (sum / weight - c) * (1 - exp(-1 / (fps * 0.25)))
    out.append(c)
  }
  return out
}

var lensL = Lens(rect: CGRect(x: 56, y: 806, width: lensW, height: lensH), home: pocketMid(tl.codexPocket), label: "Codex", color: codexBlue)
var lensR = Lens(rect: CGRect(x: W - 56 - lensW, y: 806, width: lensW, height: lensH), home: pocketMid(tl.clawdPocket), label: "Clawd", color: clawdOrange)
lensL.centers = trackCenters(home: lensL.home)
lensR.centers = trackCenters(home: lensR.home)

func lensFor(_ who: String, _ i: Int) -> Lens {
  let f = tl.frames[i]
  if who == "codex" { return lensL }
  return lensR.shows(CGFloat(f.clawd.x), i) || !lensL.shows(CGFloat(f.clawd.x), i) ? lensR : lensL
}

func stripToBar(_ x: CGFloat) -> CGFloat { bar.minX + x * barPt }

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
  [Span("• ", dim, codeFont), Span("Edited ", text, codeBold), Span("Sources/Scene.swift ", codexLight, codeFont),
   Span("+24 ", green, codeFont), Span("−2", red, codeFont)],
  [Span("    func ", pink, codeFont), Span("toss", codexLight, codeFont), Span("(_ a: Buddy, _ b: Buddy) {", text, codeFont)],
  [Span("      a.enqueue(", text, codeFont), Span("throwSteps", codexLight, codeFont), Span("(a, toward: b))", text, codeFont)],
  [Span("      after(", text, codeFont), Span("0.28", amber, codeFont), Span(") { ", text, codeFont),
   Span("throwThing", codexLight, codeFont), Span("(.ball) }", text, codeFont)],
  [Span("    }", text, codeFont)],
  [Span("• ", dim, codeFont), Span("Ran ", text, codeBold), Span("swift build && swift test", codexLight, codeFont)],
]
let codexDone: [[Span]] = [
  [Span("  ✓ 12 tests passed", green, codeBold)],
  [Span("• ", dim, codeFont), Span("Done. Ready to ship.", text, codeFont)],
]
let claudeStream: [[Span]] = [
  [Span("⏺ ", clawdOrange, codeFont), Span("Update", text, codeBold), Span("(Sources/Scene.swift)", text, codeFont)],
  [Span("  ⎿ ", dim, codeFont), Span("+ case \"packets\": go { packets() }", green, codeFont)],
  [Span("    ", dim, codeFont), Span("+ throwThing(.glyph(\"✻\"), to: codex)", green, codeFont)],
  [Span("⏺ ", clawdOrange, codeFont), Span("Update", text, codeBold), Span("(Sources/StripView.swift)", text, codeFont)],
  [Span("  ⎿ ", dim, codeFont), Span("+ scene.draw(ctx)", green, codeFont)],
  [Span("⏺ ", clawdOrange, codeFont), Span("Bash", text, codeBold), Span("(./build.sh)", text, codeFont)],
  [Span("  ⎿ ", dim, codeFont), Span("built build/TouchBarBuddies.app", dim, codeFont)],
]
let claudeDone: [[Span]] = [
  [Span("⏺ ", green, codeFont), Span("All set. Ship it! 🚀", text, codeBold)],
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

/// Typed text for a window's prompt box (types over ~1.3s, then waits for "enter").
func typedPrompt(_ who: String, _ t: Double) -> String? {
  guard let e = event("prompt", who), t >= e.t, let s = e.text else { return nil }
  if let on = workTime(who, true), t >= on { return nil }
  let n = Int((t - e.t) / 1.3 * Double(s.count))
  return String(s.prefix(max(0, n)))
}

func caretOn(_ t: Double) -> Bool { Int(t * 2.2) % 2 == 0 }

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
func drawTranscript(_ ctx: CGContext, _ lines: [[Span]], in area: CGRect, lineH: CGFloat = 19, caret: Bool = false) {
  let fit = Int(area.height / lineH)
  let shown = Array(lines.suffix(fit))
  for (k, l) in shown.enumerated() {
    let line = makeLine(l)
    let base = area.minY + lineH * CGFloat(k) + 14
    draw(ctx, line, x: area.minX, baseline: base)
    if caret && k == shown.count - 1 {
      ctx.setFillColor(white(0.8))
      ctx.fill(CGRect(x: area.minX + width(line) + 2, y: base - 11, width: 7, height: 14))
    }
  }
}

func drawCodexWindow(_ ctx: CGContext, _ t: Double) {
  let r = codexWindow
  drawChrome(ctx, r, title: "ChatGPT · Codex", body: rgb(24, 24, 27), bar: rgb(32, 32, 36))
  let on = workTime("codex", true), off = workTime("codex", false)
  let started = on.map { t >= $0 } ?? false

  // Start screen: a >_ badge and a big question, fading away once the work starts.
  let heroAlpha = started ? 1 - clamp01(CGFloat(t - on!) / 0.3) : 1
  faded(ctx, heroAlpha) {
    let badge = CGRect(x: r.midX - 32, y: r.minY + titleBarH + 70, width: 64, height: 64)
    fill(ctx, rounded(badge, 16), white(0.06))
    stroke(ctx, rounded(badge.insetBy(dx: 0.5, dy: 0.5), 16), white(0.14), 1)
    drawCentered(ctx, [Span(">_", white(0.92), mono(26, .bold))], cx: badge.midX, baseline: badge.midY + 9)
    drawCentered(ctx, [Span("What should we build?", white(0.92), sans(24, .semibold))], cx: r.midX, baseline: badge.maxY + 44)
    drawCentered(ctx, [Span("~/touchbar-buddies", white(0.4), mono(13))], cx: r.midX, baseline: badge.maxY + 70)
  }

  // Prompt box.
  let box = CGRect(x: r.minX + 16, y: r.maxY - 16 - 58, width: r.width - 32, height: 58)
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
  var lines = revealed(codexStream, since: t - on - 0.35, cps: 62)
  var working = true
  if let off, t >= off { lines = codexStream + revealed(codexDone, since: t - off, cps: 50); working = false }
  if working && t - on > 0.35 {
    let dots = String(repeating: ".", count: Int(t * 3) % 4)
    lines.append([Span("◦ Working" + dots, white(0.5), codeFont)])
  }
  drawTranscript(ctx, lines, in: CGRect(x: r.minX + 20, y: bubble.maxY + 14, width: r.width - 40, height: box.minY - bubble.maxY - 24))
}

func drawClaudeWindow(_ ctx: CGContext, _ t: Double) {
  let r = claudeWindow
  drawChrome(ctx, r, title: "Claude", body: rgb(27, 26, 24), bar: rgb(36, 35, 32))
  let on = workTime("clawd", true), off = workTime("clawd", false)
  let started = on.map { t >= $0 } ?? false

  // Claude Code's welcome box.
  let welcome = CGRect(x: r.minX + 16, y: r.minY + titleBarH + 14, width: r.width - 32, height: 98)
  stroke(ctx, rounded(welcome, 8), clawdOrange, 1.5)
  draw(ctx, makeLine([Span("✻ ", clawdOrange, mono(14, .bold)), Span("Welcome to Claude Code", white(0.95), mono(14, .bold))]),
       x: welcome.minX + 16, baseline: welcome.minY + 28)
  draw(ctx, makeLine([Span("/help for help, /status for your setup", white(0.45), mono(12.5))]), x: welcome.minX + 16, baseline: welcome.minY + 58)
  draw(ctx, makeLine([Span("cwd: ~/touchbar-buddies", white(0.45), mono(12.5))]), x: welcome.minX + 16, baseline: welcome.minY + 80)

  // Prompt box.
  let box = CGRect(x: r.minX + 16, y: r.maxY - 16 - 46, width: r.width - 32, height: 46)
  stroke(ctx, rounded(box, 8), white(0.3), 1)
  let typed = typedPrompt("clawd", t)
  var spans = [Span("> ", white(0.8), mono(14, .bold))]
  if let typed { spans.append(Span(typed, white(0.95), mono(14))) } else { spans.append(Span("Try \"pair with Codex\"", white(0.35), mono(14))) }
  let line = makeLine(spans)
  draw(ctx, line, x: box.minX + 14, baseline: box.midY + 5)
  if typed != nil || !started, caretOn(t) {
    ctx.setFillColor(white(0.85))
    ctx.fill(CGRect(x: box.minX + 14 + (typed == nil ? 16 : width(line) + 1), y: box.midY - 9, width: 8, height: 17))
  }

  guard started, let on else { return }
  let ask = event("prompt", "clawd")?.text ?? ""
  var lines: [[Span]] = [[Span("> " + ask, white(0.5), codeFont)], []]
  lines += revealed(claudeStream, since: t - on - 0.3, cps: 58)
  if let off, t >= off {
    lines = [[Span("> " + ask, white(0.5), codeFont)], []] + claudeStream + [[]] + revealed(claudeDone, since: t - off - 0.2, cps: 40)
  } else {
    let spinner = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"][Int(t / 0.12) % 10]
    lines.append([])
    lines.append([Span(spinner + " ", clawdOrange, codeBold), Span("Pairing… ", clawdOrange, codeFont), Span("(esc to interrupt)", white(0.4), codeFont)])
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
  let clock = makeLine([Span("Thu Sep 24   9:41 AM", white(0.88), sans(13, .medium))])
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
    if let app = icon.app, let tap = event("tap", app) {
      // Bounce while the app launches, then show the "running" dot.
      let open = event("open", app)?.t ?? .infinity
      if t >= tap.t && t < open + 0.2 { r.origin.y -= abs(sin(CGFloat(t - tap.t) * .pi / 0.42)) * 16 }
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
  guard let done = workTime("codex", false), t >= done, t < done + 3 else { return }
  var rng = SplitMix(state: 42)
  let age = CGFloat(t - done)
  for _ in 0..<110 {
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
    drawTitle(ctx, "Touch Bar Buddies", [Span("Clawd & Codex live in your Touch Bar", white(0.78), sans(30))],
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

/// A point on the keyboard deck: u = 0…1 across, v = 0…1 from the hinge toward you.
func deckPoint(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
  let y = lerp(deckTop, deckBottom, v)
  return CGPoint(x: lerp(lerp(deckTopL, deckBotL, v), lerp(deckTopR, deckBotR, v), u), y: y)
}

func deckQuad(_ u0: CGFloat, _ v0: CGFloat, _ u1: CGFloat, _ v1: CGFloat) -> CGPath {
  let p = CGMutablePath()
  p.addLines(between: [deckPoint(u0, v0), deckPoint(u1, v0), deckPoint(u1, v1), deckPoint(u0, v1)])
  p.closeSubpath()
  return p
}

func drawDeck(_ ctx: CGContext) {
  // Hinge, then the deck as a trapezoid (it's closer to us, so it's wider).
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
    let v0 = 0.115 + CGFloat(r) * 0.075, v1 = v0 + 0.064
    let total = keys.reduce(0, +)
    let unit = (u1 - u0) / total
    var u = u0
    for k in keys {
      let a = deckPoint(u + unit * 0.06, v0), b = deckPoint(u + unit * (k - 0.06), v1)
      let key = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
      fill(ctx, rounded(key, 5), rgb(16, 17, 19))
      fill(ctx, rounded(CGRect(x: key.minX + 1, y: key.minY + 1, width: key.width - 2, height: 2), 1), white(0.05))
      u += unit * k
    }
  }
  let pad = deckQuad(0.33, 0.52, 0.67, 0.92)
  fill(ctx, pad, rgb(58, 60, 66))
  stroke(ctx, pad, rgb(78, 80, 88), 1.5)
}

func drawTouchBar(_ ctx: CGContext, _ i: Int) {
  let frame = bar.insetBy(dx: -4, dy: -3)
  fill(ctx, rounded(frame, 6), rgb(4, 4, 5))
  stroke(ctx, rounded(frame.insetBy(dx: 0.5, dy: 0.5), 6), rgb(26, 27, 30), 1)
  drawImage(ctx, stripFrame(i, scale: 2), bar)
  // Touch ID button to the right.
  let tid = CGRect(x: frame.maxX + 10, y: frame.minY, width: frame.height, height: frame.height)
  fill(ctx, rounded(tid, 6), rgb(10, 10, 12))
  stroke(ctx, rounded(tid.insetBy(dx: 2.5, dy: 2.5), 5), rgb(40, 41, 45), 1)
}

// MARK: - Lenses

func lensAppear(_ t: Double) -> CGFloat { easeOutBack(CGFloat(t - 0.15) / 0.55) }

func drawCone(_ ctx: CGContext, _ lens: Lens, _ i: Int, _ t: Double) {
  let half = lensW / zoom / 2
  let a = stripToBar(lens.centers[i] - half), b = stripToBar(lens.centers[i] + half)
  let src = CGRect(x: a, y: bar.minY - 2, width: b - a, height: bar.height + 4)
  let outer = lens.rect.insetBy(dx: -8, dy: -8)
  let alpha = clamp01(CGFloat(t - 0.15) / 0.4)
  faded(ctx, alpha) {
    let p = CGMutablePath()
    p.addLines(between: [CGPoint(x: src.minX, y: src.maxY), CGPoint(x: src.maxX, y: src.maxY),
                         CGPoint(x: outer.maxX - 20, y: outer.minY + 2), CGPoint(x: outer.minX + 20, y: outer.minY + 2)])
    p.closeSubpath()
    ctx.saveGState()
    ctx.addPath(p)
    ctx.clip()
    ctx.drawLinearGradient(gradient([white(0.16), white(0.03)]), start: CGPoint(x: 0, y: src.maxY), end: CGPoint(x: 0, y: outer.minY), options: [])
    ctx.restoreGState()
    stroke(ctx, rounded(src, 4), white(0.75), 1.5)
  }
}

func drawLens(_ ctx: CGContext, _ lens: Lens, _ i: Int, _ t: Double, _ strip8: CGImage) {
  let s = lensAppear(t)
  guard s > 0.01 else { return }
  let r = lens.rect
  scaled(ctx, 0.8 + 0.2 * s, around: CGPoint(x: r.midX, y: r.minY)) {
    faded(ctx, clamp01(s * 1.5)) {
      let outer = r.insetBy(dx: -8, dy: -8)
      ctx.saveGState()
      ctx.setShadow(offset: CGSize(width: 0, height: -16), blur: 40, color: black(0.7))
      fillVertical(ctx, rounded(outer, 30), [rgb(226, 228, 233), rgb(150, 154, 162)])
      ctx.restoreGState()
      stroke(ctx, rounded(outer.insetBy(dx: 0.75, dy: 0.75), 29), white(0.7), 1.5)

      ctx.saveGState()
      ctx.addPath(rounded(r, 23))
      ctx.clip()
      ctx.setFillColor(black(1))
      ctx.fill(r)
      // The 8× frame, 1:1 and snapped to whole pixels so nothing gets resampled.
      let x = (r.midX - lens.centers[i] * zoom).rounded()
      drawImage(ctx, strip8, CGRect(x: x, y: r.minY, width: CGFloat(strip8.width), height: CGFloat(strip8.height)), quality: .none)
      // A little glass sheen.
      ctx.drawLinearGradient(gradient([white(0.10), white(0)]), start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.minY + 90), options: [])
      ctx.restoreGState()
      stroke(ctx, rounded(r.insetBy(dx: -0.5, dy: -0.5), 23), black(0.8), 2)

      // Name tag on the frame's bottom edge.
      let name = makeLine([Span(lens.label, white(0.95), sans(17, .semibold))])
      let tagW = width(name) + 42
      let tag = CGRect(x: lens.isLeft ? outer.minX + 26 : outer.maxX - 26 - tagW, y: outer.maxY - 15, width: tagW, height: 30)
      fill(ctx, rounded(tag, 15), rgb(20, 21, 25))
      stroke(ctx, rounded(tag.insetBy(dx: 0.5, dy: 0.5), 15), white(0.25), 1)
      fill(ctx, CGPath(ellipseIn: CGRect(x: tag.minX + 13, y: tag.midY - 5, width: 10, height: 10), transform: nil), lens.color)
      draw(ctx, name, x: tag.minX + 30, baseline: tag.midY + 6)
    }
  }
}

// MARK: - Taps, bubbles, captions

func drawTaps(_ ctx: CGContext, _ i: Int, _ t: Double) {
  for e in events("tap") {
    let age = CGFloat(t - e.t)
    guard age >= -0.25, age < 0.9, let who = e.who, let x = e.x else { continue }
    let lens = who == "codex" ? lensL : lensR
    let c = CGPoint(x: lens.screenX(CGFloat(x), i), y: lens.rect.maxY - 12 * zoom)
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
    let bc = CGPoint(x: stripToBar(CGFloat(x)), y: bar.midY)
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
  let f = tl.frames[i]
  let font = sans(29, .semibold)
  for e in events("say") {
    guard let who = e.who, let s = e.text, let dur = e.dur, t >= e.t, t <= e.t + dur else { continue }
    let lens = lensFor(who, i)
    let b = who == "codex" ? f.codex : f.clawd
    let headPt: CGFloat = who == "codex" ? 23 : 17
    let tip = CGPoint(x: lens.screenX(CGFloat(b.x), i), y: max(lens.rect.minY + 14, lens.rect.maxY - (headPt + CGFloat(b.hop) + 4) * zoom))

    let lines = wrap(s.components(separatedBy: " "), font: font, maxWidth: 390).map { makeLine(bubbleSpans($0, font)) }
    let lineH: CGFloat = 37
    let w = (lines.map(width).max() ?? 0) + 48, h = CGFloat(lines.count) * lineH + 26
    // Sit above the lens, leaning toward the outside of the frame so the two sides never collide.
    let lean: CGFloat = who == "codex" ? -40 : 40
    let minX = lens.isLeft ? 26 : W / 2 + 150, maxX = lens.isLeft ? W / 2 - 150 : W - 26
    let x = min(max(tip.x - w / 2 + lean, minX), maxX - w)
    let box = CGRect(x: x, y: lens.rect.minY - 30 - h, width: w, height: h)

    let pop = easeOutBack(CGFloat(t - e.t) / 0.28)
    let out = clamp01(CGFloat(t - (e.t + dur - 0.2)) / 0.2)
    scaled(ctx, (0.55 + 0.45 * pop) * (1 - 0.12 * out), around: tip) {
      faded(ctx, clamp01(CGFloat(t - e.t) / 0.1) * (1 - out)) {
        let tailX = min(max(tip.x, box.minX + 34), box.maxX - 34)
        let path = CGMutablePath()
        path.addPath(rounded(box, 24))
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: tailX - 16, y: box.maxY - 2))
        tail.addQuadCurve(to: tip, control: CGPoint(x: tailX - 4, y: (box.maxY + tip.y) / 2))
        tail.addQuadCurve(to: CGPoint(x: tailX + 16, y: box.maxY - 2), control: CGPoint(x: tailX + 10, y: (box.maxY + tip.y) / 2))
        tail.closeSubpath()
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: black(0.45))
        fill(ctx, path, white(1))
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

func drawCaptions(_ ctx: CGContext, _ t: Double) {
  for e in events("caption") {
    guard let s = e.text, let dur = e.dur else { continue }
    let a = envelope(t, e.t, e.t + dur, 0.35, 0.35)
    guard a > 0 else { continue }
    let l = makeLine([Span(s, white(0.97), sans(27, .semibold))])
    let pill = CGRect(x: W / 2 - width(l) / 2 - 26, y: 968 + 10 * (1 - a), width: width(l) + 52, height: 54)
    faded(ctx, a) {
      ctx.saveGState()
      ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 20, color: black(0.5))
      fill(ctx, rounded(pill, 27), rgb(18, 19, 24, 0.92))
      ctx.restoreGState()
      stroke(ctx, rounded(pill.insetBy(dx: 0.5, dy: 0.5), 27), white(0.18), 1)
      draw(ctx, l, x: pill.minX + 26, baseline: pill.midY + 9)
    }
  }
}

// MARK: - Frame

func renderFrame(_ i: Int, into ctx: CGContext) {
  let t = Double(i) / fps
  ctx.saveGState()
  ctx.translateBy(x: 0, y: H)
  ctx.scaleBy(x: 1, y: -1)
  drawBackground(ctx)
  drawLid(ctx)
  drawDisplay(ctx, t)
  drawDeck(ctx)
  drawTouchBar(ctx, i)
  drawCone(ctx, lensL, i, t)
  drawCone(ctx, lensR, i, t)
  let strip8 = stripFrame(i, scale: 8)
  drawLens(ctx, lensL, i, t, strip8)
  drawLens(ctx, lensR, i, t, strip8)
  drawTaps(ctx, i, t)
  drawCaptions(ctx, t)
  drawBubbles(ctx, i, t)
  if t < 0.4 {
    ctx.setFillColor(black(1 - CGFloat(t / 0.4)))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
  }
  ctx.restoreGState()
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

let frameCount = tl.frames.count

// MARK: - Stills mode

if args[2] == "--stills" {
  let out = URL(fileURLWithPath: args[3])
  try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
  for s in args[4].split(separator: ",") {
    let i = min(frameCount - 1, Int((Double(s)! * fps).rounded()))
    let ctx = makeContext(Int(W), Int(H))
    renderFrame(i, into: ctx)
    writePNG(ctx.makeImage()!, out.appendingPathComponent("still-\(s).png"))
  }
  print("wrote stills to \(out.path)")
  exit(0)
}

// MARK: - Video (H.264) + GIF highlight

let mp4URL = URL(fileURLWithPath: args[2])
let gifURL = args.count > 3 ? URL(fileURLWithPath: args[3]) : nil
let gifRange = 6.9...16.9          // seconds: small talk, packets flying, and getting to work
let gifStep = 2                    // every 2nd frame → 15 fps
let gifSize = CGSize(width: 960, height: 540)

let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("demo-\(UUID().uuidString).mp4")
let writer = try! AVAssetWriter(outputURL: tmpURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
  AVVideoCodecKey: AVVideoCodecType.h264,
  AVVideoWidthKey: Int(W),
  AVVideoHeightKey: Int(H),
  AVVideoCompressionPropertiesKey: [
    AVVideoAverageBitRateKey: 3_000_000,   // ~12 MB for 30 s: small enough to keep in git
    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
    AVVideoMaxKeyFrameIntervalKey: 60,
    AVVideoExpectedSourceFrameRateKey: tl.fps,
  ],
  AVVideoColorPropertiesKey: [
    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
  ],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
  kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
  kCVPixelBufferWidthKey as String: Int(W),
  kCVPixelBufferHeightKey as String: Int(H),
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

var gifFrames: [CGImage] = []
for i in 0..<frameCount {
  while !input.isReadyForMoreMediaData { usleep(2000) }
  var buffer: CVPixelBuffer?
  CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
  let pb = buffer!
  CVPixelBufferLockBaseAddress(pb, [])
  let ctx = makeContext(Int(W), Int(H), data: CVPixelBufferGetBaseAddress(pb), bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
  renderFrame(i, into: ctx)
  let t = Double(i) / fps
  if gifURL != nil && gifRange.contains(t) && i % gifStep == 0 {
    let small = makeContext(Int(gifSize.width), Int(gifSize.height))
    small.interpolationQuality = .high
    small.draw(ctx.makeImage()!, in: CGRect(origin: .zero, size: gifSize))
    gifFrames.append(small.makeImage()!)
  }
  CVPixelBufferUnlockBaseAddress(pb, [])
  adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(tl.fps)))
  if i % 60 == 0 { print("frame \(i)/\(frameCount)") }
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
guard writer.status == .completed else { print("video failed: \(String(describing: writer.error))"); exit(1) }
let fm = FileManager.default
if fm.fileExists(atPath: mp4URL.path) { _ = try! fm.replaceItemAt(mp4URL, withItemAt: tmpURL) } else { try! fm.moveItem(at: tmpURL, to: mp4URL) }
print("wrote \(mp4URL.path)")

if let gifURL {
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
