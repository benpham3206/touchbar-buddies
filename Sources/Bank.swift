import AppKit

// All animation clips for both buddies, built from the sprite cache (see AssetCache.swift).
//  • Clawd: Claude's own pixel animations (1 art pixel = 1pt = 2 Touch Bar pixels, perfectly crisp).
//  • Codex: the official Codex pet sheet (192×208 cells), downscaled to fit the 30pt bar.
// A buddy whose sprites are missing gets blank clips and has…=false, so Scene simply leaves him out.
final class Bank {
  let hasClawd, hasCodex: Bool
  // Clawd
  let cStand, cBlink, cLookL, cLookR, cHappy, cLoaf, cLoafBreath, cSquat: Clip
  let cScuttle, cWave, cWaveLoop, cLurk: Clip
  let cCloudIntro, cCloudMount, cCloudRide, cCloudDismount: Clip
  let cRaceIn, cRaceDrive, cRaceOut: Clip
  let cWorkIn, cWorkLoop, cWorkOut: Clip
  // Codex
  let xIdle, xIdleCalm, xRunR, xRunL, xWave, xJump, xFailed, xWaiting, xWork, xReview, xSleep: Clip
  let xLook: [Clip]

  init(resources: URL) {
    // MARK: Clawd
    let dir = resources.appendingPathComponent("clawd")
    let manifest = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("clawd.json")))) as? [String: Any] ?? [:]
    // Stand-in for a missing strip: enough blank frames for every slice below.
    let blank = Clip(frames: Array(repeating: Self.blankImage(24, 17), count: 70), durations: Array(repeating: 0.083, count: 70),
                     size: CGSize(width: 24, height: 17), anchorX: 12, baseline: 0)
    var missing: [String] = []
    // `need` = frames the slices below rely on; a strip with fewer (say, new art upstream) counts as missing.
    func strip(_ name: String, need: Int) -> Clip {
      guard let m = manifest[name] as? [String: Any], let size = m["frame"] as? [Int], let count = m["count"] as? Int, count >= need,
            let sheet = SheetLoader.image(dir.appendingPathComponent("\(name).png")),
            sheet.width >= size[0] * count, sheet.height >= size[1] else {
        missing.append(name)
        return blank
      }
      let delays = (m["delays_ms"] as? [Int]) ?? Array(repeating: 83, count: count)
      let frames = (0..<count).map { sheet.cropping(to: CGRect(x: $0 * size[0], y: 0, width: size[0], height: size[1]))! }
      // Every clip starts on the standing pose, so its first frame tells us where Clawd's center is.
      let anchor = frames.lazy.compactMap(SheetLoader.contentBox).first?.midX ?? CGFloat(size[0]) / 2
      return Clip(frames: frames, durations: delays.map { Double($0) / 1000 }, size: CGSize(width: size[0], height: size[1]),
                  anchorX: anchor, baseline: 0)
    }
    let crab = strip("crabwalking", need: 20), waving = strip("waving", need: 16), cloud = strip("cloud-once", need: 62)
    let race = strip("racingcar", need: 48), laptop = strip("laptop", need: 43)
    var lurk = strip("lurking", need: 1)
    hasClawd = missing.allSatisfy { $0 == "laptop" }   // the laptop has a fallback below
    lurk.anchorX = 0  // peeks in from its left edge

    // Expression variants, pixel-edited from the standing frame (crop coords: eyes are 2×2 at x 6/16, y 3).
    let stand = crab.frames[0]
    let (probe, pw, _) = SheetLoader.rgba(stand)
    let body = probe[6 * pw + 10], eye = probe[3 * pw + 6]
    probe.deallocate()
    func eyes(_ img: CGImage, _ draw: (PixelGrid) -> Void) -> CGImage {
      SheetLoader.edit(img) { g in
        g.fill(6, 3, 2, 2, body); g.fill(16, 3, 2, 2, body)
        draw(g)
      }
    }
    let blink = eyes(stand) { g in g.fill(6, 4, 2, 1, eye); g.fill(16, 4, 2, 1, eye) }
    let lookL = eyes(stand) { g in g.fill(5, 3, 2, 2, eye); g.fill(15, 3, 2, 2, eye) }
    let lookR = eyes(stand) { g in g.fill(7, 3, 2, 2, eye); g.fill(17, 3, 2, 2, eye) }
    let happy = eyes(stand) { g in
      for x in [5, 15] { g[x, 4] = eye; g[x + 1, 3] = eye; g[x + 2, 3] = eye; g[x + 3, 4] = eye }
    }
    let loaf = SheetLoader.edit(blink) { g in g.fill(0, 13, g.w, 4, 0); g.shiftDown(4) }
    let loafBreath = SheetLoader.edit(loaf) { g in g.fill(4, 5, 16, 1, 0) }

    // Front-facing poses are symmetric (or pick their gaze explicitly), so they're never mirrored.
    var front = crab.still(0)
    front.facesRight = false
    cStand = front; cBlink = front.with(blink); cLookL = front.with(lookL); cLookR = front.with(lookR)
    cHappy = front.with(happy); cLoaf = front.with(loaf); cLoafBreath = front.with(loafBreath)
    var squat = waving.still(4, 0.1)
    squat.facesRight = false
    cSquat = squat
    cScuttle = crab.slice(4...19)
    cWave = waving
    cWaveLoop = waving.slice(6...15)
    cLurk = lurk
    cCloudIntro = cloud
    cCloudMount = cloud.slice(0...14)
    cCloudRide = cloud.slice(15...50)
    cCloudDismount = cloud.slice(51...61)
    // The helmet-on frames are taller than the Touch Bar; skip them (a dust puff covers the cut).
    let fits = { (i: Int) -> Bool in (SheetLoader.contentBox(race.frames[i])?.height ?? 0) <= 29 }
    cRaceIn = race.pick((0...11).filter(fits))
    cRaceDrive = race.pick((12...35).filter(fits))
    cRaceOut = race.pick((36...47).filter(fits))
    if missing.contains("laptop") {
      // No laptop video (Claude app not installed): Clawd scuttles in place while he works.
      cWorkIn = crab.still(0, 0.2)
      cWorkLoop = crab.slice(4...19)
      cWorkOut = crab.still(0, 0.2)
    } else {
      cWorkIn = laptop.slice(4...17)
      cWorkLoop = laptop.slice(18...33)
      cWorkOut = laptop.slice(34...42)
    }

    // MARK: Codex
    let cellW = 192, cellH = 208
    let sheet = SheetLoader.image(resources.appendingPathComponent("codex/codex.webp"))
      .flatMap { $0.width >= 8 * cellW && $0.height >= 11 * cellH ? $0 : nil }
    hasCodex = sheet != nil
    let k: CGFloat = 22.0 / 170.0                   // standing Codex (170px) → 22pt tall
    let pxW = Int((CGFloat(cellW) * k * 2).rounded()), pxH = Int((CGFloat(cellH) * k * 2).rounded())
    func cell(_ r: Int, _ c: Int) -> CGImage {
      guard let sheet else { return Self.blankImage(pxW, pxH) }
      let crop = sheet.cropping(to: CGRect(x: c * cellW, y: r * cellH, width: cellW, height: cellH))!
      // Two-step downscale keeps the outline crisp.
      let mid = Self.resample(crop, cellW / 2, cellH / 2)
      return Self.resample(mid, pxW, pxH)
    }
    let ptSize = CGSize(width: CGFloat(pxW) / 2, height: CGFloat(pxH) / 2)
    let scaleY = ptSize.height / CGFloat(cellH)
    func row(_ r: Int, _ ms: [Int], baselineRows: Int = 8) -> Clip {
      Clip(frames: ms.indices.map { cell(r, $0) }, durations: ms.map { Double($0) / 1000 }, size: ptSize,
           anchorX: ptSize.width * 95.5 / CGFloat(cellW), baseline: CGFloat(baselineRows) * scaleY, pixelated: false, facesRight: false)
    }
    xIdle = row(0, [280, 110, 110, 140, 140, 320])
    xIdleCalm = xIdle.speed(1.0 / 3)
    xRunR = row(1, [120, 120, 120, 120, 120, 120, 120, 220])
    xRunL = row(2, [120, 120, 120, 120, 120, 120, 120, 220])
    xWave = row(3, [140, 140, 140, 280])
    xJump = row(4, [140, 140, 140, 140, 280])
    xFailed = row(5, [140, 140, 140, 140, 140, 140, 140, 240])
    xWaiting = row(6, [150, 150, 150, 150, 150, 260])
    xWork = row(7, [120, 120, 120, 120, 120, 220])
    xReview = row(8, [150, 150, 150, 150, 150, 280])
    xSleep = xIdle.still(1)
    let lookA = row(9, Array(repeating: 1000, count: 8), baselineRows: 19)
    let lookB = row(10, Array(repeating: 1000, count: 8), baselineRows: 19)
    xLook = (0..<16).map { $0 < 8 ? lookA.still($0) : lookB.still($0 - 8) }
  }

  /// Clawd in ultracode mode: the same clip with his orange body turned violet (eyes and laptop untouched).
  /// Frames are recolored the first time they're needed, then reused.
  func violet(_ clip: Clip) -> Clip {
    var c = clip
    c.frames = clip.frames.map { img in
      if let done = violetFrames[ObjectIdentifier(img)], done.source === img { return done.violet }
      let violet = SheetLoader.edit(img) { g in
        for i in 0..<(g.w * g.h) {
          if Self.near(g.buf[i], Self.clawdBody) { g.buf[i] = Self.violetBody }
          else if Self.near(g.buf[i], Self.clawdShade) { g.buf[i] = Self.violetShade }
        }
      }
      violetFrames[ObjectIdentifier(img)] = (img, violet)
      return violet
    }
    return c
  }

  private var violetFrames: [ObjectIdentifier: (source: CGImage, violet: CGImage)] = [:]
  // Pixels as SheetLoader.rgba stores them (bytes R, G, B, A in memory).
  private static func pixel(_ r: UInt32, _ g: UInt32, _ b: UInt32) -> UInt32 { 0xFF00_0000 | b << 16 | g << 8 | r }
  // The GIFs and the laptop video use slightly different oranges (215 vs 217 red…), so match loosely.
  private static let clawdBody = pixel(216, 119, 87), clawdShade = pixel(190, 104, 76)
  private static let violetBody = pixel(167, 139, 250), violetShade = pixel(139, 92, 246)   // #A78BFA, #8B5CF6
  private static func near(_ a: UInt32, _ b: UInt32) -> Bool {
    guard a >> 24 == 0xFF else { return false }
    return (0..<3).allSatisfy { c in abs(Int((a >> (8 * c)) & 0xFF) - Int((b >> (8 * c)) & 0xFF)) <= 6 }
  }

  /// Codex look frame for a direction in degrees (0 = up, 90 = right, clockwise).
  func codexLook(degrees: CGFloat) -> Clip {
    var d = degrees.truncatingRemainder(dividingBy: 360)
    if d < 0 { d += 360 }
    return xLook[Int((d / 22.5).rounded()) % 16]
  }

  private static func blankImage(_ w: Int, _ h: Int) -> CGImage {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
  }

  private static func resample(_ img: CGImage, _ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
  }
}
