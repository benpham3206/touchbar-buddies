import AppKit
import ImageIO
import UniformTypeIdentifiers

// Draws the Touch Bar offscreen with the app's real Scene + StripView code, so you (or an AI agent) can
// SEE an animation without a Touch Bar. Nothing is shown on the real Touch Bar. `./tbb render` wraps it.
//
//   TouchBarBuddies --render <out.gif | out.png> [options]
//
//   A .gif is an animation. A .png is a filmstrip, one row per moment labeled with its time:
//   the easy way for an AI agent to look at motion in a single image.
//
//   --do <command> [--at <sec>]   run a command (see ./tbb commands) at that time (default 0.5 s); repeatable
//   --seconds <n>                 how long to record (default 8)
//   --claude <state>              idle | working | asleep: how Clawd starts (default idle)
//   --codex <state>               the same for Codex
//   --zoom                        only the two buddy pockets, side by side and magnified
//   --scale <n>                   pixels per point (default 2 = the real Touch Bar; 4 with --zoom)
//   --fps <n>                     GIF frame rate: 10, 12, 15, 20 or 30 (default 20)
//   --every <sec>                 PNG: one row every <sec> seconds (default 0.5; 0 = a single frame at the end)
//   --live                        also let the buddies do their own random things (idle habits, games)
enum Renderer {
  struct Options {
    var out = URL(fileURLWithPath: "touchbar.gif")
    var seconds = 8.0
    var cues: [(at: Double, command: String)] = []
    var claude = AgentState(appRunning: true, present: true)
    var codex = AgentState(appRunning: true, present: true)
    var zoom = false
    var scale: Int?
    var fps = 20
    var every = 0.5
    var live = false
  }

  static let tick = 1.0 / 60     // simulate at 60 steps a second, the live app's fastest rate
  static let preroll = 2.0       // seconds simulated before the first frame, so the Zzz are already floating

  /// Handles `--render …` and returns the exit code.
  static func run(_ args: [String]) -> Int32 {
    do {
      let o = try parse(args)
      try render(o)
      return 0
    } catch {
      FileHandle.standardError.write(Data("render: \(error)\n".utf8))
      return 1
    }
  }

  // MARK: Options

  struct UsageError: Error, CustomStringConvertible { let description: String }

  static func parse(_ args: [String]) throws -> Options {
    var o = Options()
    var i = args.firstIndex(of: "--render")!
    func value(_ flag: String) throws -> String {
      i += 1
      guard i < args.count else { throw UsageError(description: "\(flag) needs a value") }
      return args[i]
    }
    func number(_ flag: String) throws -> Double {
      let s = try value(flag)
      guard let n = Double(s), n >= 0 else { throw UsageError(description: "\(flag) wants a number, not \"\(s)\"") }
      return n
    }
    func state(_ flag: String) throws -> AgentState {
      switch try value(flag) {
      case "idle": return AgentState(appRunning: true, present: true)
      case "working": return AgentState(appRunning: true, present: true, working: true)
      case "asleep": return AgentState()
      case let s: throw UsageError(description: "\(flag) is idle, working or asleep, not \"\(s)\"")
      }
    }
    o.out = URL(fileURLWithPath: try value("--render"))
    while i + 1 < args.count {
      i += 1
      switch args[i] {
      case "--do": o.cues.append((0.5, try value("--do")))
      case "--at":
        guard !o.cues.isEmpty else { throw UsageError(description: "--at goes after the --do it times") }
        o.cues[o.cues.count - 1].at = try number("--at")
      case "--seconds": o.seconds = try number("--seconds")
      case "--claude": o.claude = try state("--claude")
      case "--codex": o.codex = try state("--codex")
      case "--zoom": o.zoom = true
      case "--scale": o.scale = max(1, Int(try number("--scale")))
      case "--fps":
        o.fps = Int(try number("--fps"))
        guard [10, 12, 15, 20, 30, 60].contains(o.fps) else { throw UsageError(description: "--fps must divide 60 (10, 12, 15, 20, 30)") }
      case "--every": o.every = try number("--every")
      case "--live": o.live = true
      case let flag: throw UsageError(description: "unknown option \(flag)")
      }
    }
    guard ["gif", "png"].contains(o.out.pathExtension.lowercased()) else {
      throw UsageError(description: "the output file must end in .gif or .png")
    }
    return o
  }

  // MARK: Rendering

  static func render(_ o: Options) throws {
    Icons.reuseSaved = true   // button glyphs saved by the live app, so this also works in sandboxes (see Icons)
    let bank = Bank(resources: AssetCache.directory)
    guard bank.hasClawd || bank.hasCodex else {
      throw UsageError(description: "no sprites in \(AssetCache.directory.path) — run ./tbb sprites")
    }
    let scene = Scene(bank: bank)
    scene.scripted = !o.live
    // Tapping a sleeping buddy "opens" its app: here nothing opens, the buddy just wakes up a moment later.
    scene.onLaunch = { who in
      scene.after(0.8) { scene.setState(buddy(who, scene), AgentState(appRunning: true, present: true)) }
    }
    scene.clawd.state = o.claude
    scene.codex.state = o.codex
    scene.clawd.lastZ = 0.9   // so the two snorers' Zzz don't rise in step

    let strip = StripView(scene: scene)
    strip.fixedLayout = StripView.defaultLayout   // everyone renders the same bar
    strip.volumeIcon = .volume2
    strip.frame = NSRect(x: 0, y: 0, width: 1004, height: 30)
    strip.relayout()

    let scale = o.scale ?? (o.zoom ? 4 : 2)
    let gif = o.out.pathExtension.lowercased() == "gif"
    // Which simulation steps become images: every GIF frame, each filmstrip row, or (--every 0) just the last one.
    let lastStep = Int((o.seconds / tick).rounded())
    let wantsImage: (Int) -> Bool
    if gif { wantsImage = { n in n % (60 / o.fps) == 0 && n < lastStep } }
    else if o.every == 0 { wantsImage = { n in n == lastStep } }
    else { wantsImage = { n in n % max(1, Int((o.every / tick).rounded())) == 0 } }

    var cues = o.cues.sorted { $0.at < $1.at }
    var images: [(t: Double, image: CGImage)] = []
    var nextBlink = preroll + 1.5
    for n in -Int(preroll / tick)...lastStep {
      let t = preroll + Double(n) * tick
      while let cue = cues.first, cue.at + preroll <= t + 1e-9 {
        cues.removeFirst()
        perform(cue.command, scene)
      }
      // Scripted mode has no idle habits, so Clawd blinks on a steady beat instead.
      let c = scene.clawd
      if scene.scripted && c.base == .idle && !c.busy && t >= nextBlink {
        c.still = bank.cBlink
        c.stillUntil = t + 0.13
        nextBlink = t + 3.1
      }
      scene.update(t, tick)
      if n >= 0 && wantsImage(n) {
        var img = snapshot(strip, scale: scale)
        if o.zoom { img = pockets(img, scene, scale: scale) }
        images.append((t - preroll, img))
      }
    }

    guard !images.isEmpty else { throw UsageError(description: "nothing to draw: make --seconds longer") }
    if gif { try writeGIF(images, fps: o.fps, to: o.out) } else { try writePNG(filmstrip(images, scale: scale), to: o.out) }
    let size = images.first.map { "\($0.image.width)×\($0.image.height)" } ?? "?"
    let count = "\(images.count) \(gif ? "frame" : "row")\(images.count == 1 ? "" : "s")"
    print("wrote \(o.out.path) (\(count), \(size))")
    if scene.clawd.busy || scene.codex.busy || !scene.clawd.inPocket || !scene.codex.inPocket {
      print("note: the buddies were still busy at the end; try a longer --seconds")
    }
  }

  private static func buddy(_ who: Who, _ scene: Scene) -> Buddy { who == .clawd ? scene.clawd : scene.codex }

  /// The same commands `./tbb send` gives the live app (see AppDelegate.handle in main.swift).
  private static func perform(_ command: String, _ scene: Scene) {
    let awake = AgentState(appRunning: true, present: true)
    func toggle(_ b: Buddy, _ change: (inout AgentState) -> Void) {
      var s = b.state
      change(&s)
      scene.setState(b, s)
    }
    switch command {
    case "absent-claude", "absent-codex":
      toggle(command.hasSuffix("claude") ? scene.clawd : scene.codex) { s in s = s.present ? AgentState() : awake }
    case "work-claude", "work-codex":
      toggle(command.hasSuffix("claude") ? scene.clawd : scene.codex) { s in
        s.working.toggle()
        if s.working { s.appRunning = true; s.present = true }
      }
    case "ultra-claude", "ultra-codex":
      // Ultra only shows while working, so switching it on also starts the work.
      toggle(command.hasSuffix("claude") ? scene.clawd : scene.codex) { s in
        s.ultra.toggle()
        if s.ultra { s.working = true; s.appRunning = true; s.present = true }
      }
    case "slider-volume", "slider-brightness":
      print("note: \(command) only works in the live app (./tbb send \(command))")
    default:
      scene.command(command)
    }
  }

  // MARK: Images

  /// Draws the strip into a bitmap the way the Touch Bar shows it: `scale` pixels per point.
  static func snapshot(_ view: StripView, scale: Int) -> CGImage {
    let ctx = bitmap(Int(view.bounds.width) * scale, Int(view.bounds.height) * scale)
    ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    // Some things (the spinner and code glyphs) draw through NSGraphicsContext.current.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
  }

  /// Codex's pocket and Clawd's pocket (with a little of the buttons around them), side by side.
  private static func pockets(_ full: CGImage, _ scene: Scene, scale: Int) -> CGImage {
    let margin: CGFloat = 10, gap = 3 * scale
    let rects = [scene.codex.pocket, scene.clawd.pocket].map { p in
      CGRect(x: (p.minX - margin) * CGFloat(scale), y: 0, width: (p.width + 2 * margin) * CGFloat(scale), height: CGFloat(full.height)).integral
    }
    let ctx = bitmap(Int(rects[0].width + rects[1].width) + gap, full.height)
    ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    var x: CGFloat = 0
    for r in rects {
      ctx.draw(full.cropping(to: r)!, in: CGRect(x: x, y: 0, width: r.width, height: r.height))
      x += r.width + CGFloat(gap)
    }
    return ctx.makeImage()!
  }

  /// Stacks the frames top to bottom, each labeled with its time on the left.
  private static func filmstrip(_ images: [(t: Double, image: CGImage)], scale: Int) -> CGImage {
    let labelWidth = 34 * scale, w = images[0].image.width, h = images[0].image.height, gap = scale
    let ctx = bitmap(labelWidth + w, images.count * (h + gap) - gap)
    ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let font = NSFont.monospacedDigitSystemFont(ofSize: CGFloat(9 * scale), weight: .medium)
    for (k, frame) in images.enumerated() {
      let y = ctx.height - (k + 1) * h - k * gap
      ctx.draw(frame.image, in: CGRect(x: labelWidth, y: y, width: w, height: h))
      let label = NSAttributedString(string: String(format: "%.1fs", frame.t), attributes: [.font: font, .foregroundColor: NSColor.white])
      label.draw(at: NSPoint(x: CGFloat(2 * scale), y: CGFloat(y) + (CGFloat(h) - label.size().height) / 2))
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
  }

  private static func bitmap(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  }

  // MARK: Files

  private static func writeGIF(_ images: [(t: Double, image: CGImage)], fps: Int, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, images.count, nil) else {
      throw UsageError(description: "can't write \(url.path)")
    }
    let gif = kCGImagePropertyGIFDictionary as String
    CGImageDestinationSetProperties(dest, [gif: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
    for (k, frame) in images.enumerated() {
      // GIF delays are whole hundredths of a second; round the running total so the timing never drifts.
      let delay = (Double(k + 1) * 100 / Double(fps)).rounded() - (Double(k) * 100 / Double(fps)).rounded()
      CGImageDestinationAddImage(dest, frame.image, [gif: [kCGImagePropertyGIFDelayTime as String: delay / 100]] as CFDictionary)
    }
    guard CGImageDestinationFinalize(dest) else { throw UsageError(description: "can't write \(url.path)") }
  }

  private static func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
      throw UsageError(description: "can't write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw UsageError(description: "can't write \(url.path)") }
  }
}
