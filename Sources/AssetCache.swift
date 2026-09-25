import AppKit
import AVFoundation
import ImageIO
import VideoToolbox

// Builds the sprite cache from things the user already has, so this repo never ships Anthropic's or OpenAI's art:
//  • Clawd: the public GIFs on claude.ai (the same files the Claude app shows) + the laptop video inside Claude.app.
//  • Codex: the pet sprite sheet packed inside the Codex desktop app (ChatGPT.app → app.asar).
// Layout, exactly as Bank reads it: clawd/<name>.png + clawd/clawd.json, and codex/codex.webp.
// Entry points: `directory`, `prepare()` (at launch), `build(force:)` and `summary()` (for --build-sprites).
enum AssetCache {
  /// ~/Library/Application Support/TouchBarBuddies/sprites (TBB_SPRITES_DIR overrides it, for testing).
  static var directory: URL {
    if let custom = ProcessInfo.processInfo.environment["TBB_SPRITES_DIR"], !custom.isEmpty {
      return URL(fileURLWithPath: custom, isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("TouchBarBuddies/sprites", isDirectory: true)
  }

  // Clawd's GIFs, keyed by the name Bank uses.
  private static let gifs: [(name: String, path: String)] = [
    ("crabwalking", "core/Clawd-CrabWalking.gif"),
    ("waving", "core/Clawd-Waving.gif"),
    ("lurking", "core/Clawd-Lurking.gif"),
    ("cloud-once", "persona/Clawd-Cloud-once.gif"),
    ("racingcar", "persona/Clawd-RacingCar.gif"),
  ]
  private static let gifBase = "https://claude.ai/images/clawd/"
  private static let laptopVideo = "Contents/Resources/ion-dist/images/install-hub/clawd-laptop.mov"
  private static let claudeIDs = ["com.anthropic.claudefordesktop"]
  private static let codexIDs = ["com.openai.codex", "com.openai.chat"]
  private static let codexSheetSize = (w: 1536, h: 2288)   // 8×11 cells of 192×208

  // Every Clawd animation lives on the same 55×37-pixel stage, scaled up by a (possibly non-integer) factor.
  private static let stageW = 55, stageH = 37

  private static var clawdDir: URL { directory.appendingPathComponent("clawd") }
  private static var codexURL: URL { directory.appendingPathComponent("codex/codex.webp") }
  private static var manifestURL: URL { clawdDir.appendingPathComponent("clawd.json") }

  // MARK: Entry points

  /// Called at launch: builds whatever is missing (a few seconds, first launch only), then returns the folder for Bank.
  static func prepare() -> URL {
    if !isComplete { build() }
    return directory
  }

  private static var isComplete: Bool {
    let m = readManifest()
    return (gifs.map(\.name) + ["laptop"]).allSatisfy { has($0, m) } && exists(codexURL)
  }

  /// Builds every missing piece (every piece when `force`). If a source is unavailable
  /// (offline, app not installed) that piece is skipped and any older copy is kept.
  static func build(force: Bool = false) {
    let fm = FileManager.default
    try? fm.createDirectory(at: clawdDir, withIntermediateDirectories: true)
    try? fm.createDirectory(at: codexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    log("building in \(directory.path)")
    var manifest = readManifest()
    manifest["stage"] = [stageW, stageH]
    func save(_ name: String, _ strip: Strip?, _ why: String) {
      guard let strip, writePNG(strip.image, to: clawdDir.appendingPathComponent("\(name).png")) else {
        log("\(name): missing — \(why)")
        return
      }
      manifest[name] = strip.entry
      let size = strip.entry["frame"] as! [Int]
      log("\(name): \(strip.entry["count"]!) frames, \(size[0])×\(size[1])")
    }

    for (name, path) in gifs where force || !has(name, manifest) {
      let url = URL(string: gifBase + path)!
      guard let data = download(url) else { log("\(name): missing — couldn't download \(url) (offline?)"); continue }
      save(name, stripFromGIF(data), "couldn't decode \(url.lastPathComponent)")
    }

    if force || !has("laptop", manifest) {
      let video = apps(claudeIDs, fallback: "/Applications/Claude.app")
        .map { $0.appendingPathComponent(laptopVideo) }
        .first { exists($0) }
      if let video { save("laptop", stripFromVideo(video), "couldn't read \(video.path)") }
      else { log("laptop: missing — Claude app not found (Clawd scuttles while he works instead)") }
    }
    if let json = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
      try? json.write(to: manifestURL, options: .atomic)
    }

    if force || !exists(codexURL) {
      if let sheet = codexSheet(in: apps(codexIDs, fallback: "/Applications/ChatGPT.app")) {
        try? sheet.data.write(to: codexURL, options: .atomic)
        log("codex: \(sheet.source)")
      } else {
        log("codex: missing — no codex-spritesheet*.webp found in the Codex (ChatGPT) app")
      }
    }
  }

  /// A short found/missing report, for `--build-sprites`.
  static func summary() -> String {
    let m = readManifest()
    let missing = gifs.map(\.name).filter { !has($0, m) }
    let clawd = missing.isEmpty ? "found" : "MISSING (\(missing.joined(separator: ", ")))"
    let laptop = has("laptop", m) ? "found" : "missing, so Clawd scuttles while he works"
    return """
      Sprites in \(directory.path)
        Clawd:  \(clawd)
        Laptop: \(laptop)
        Codex:  \(exists(codexURL) ? "found" : "MISSING (needs the Codex desktop app)")
      """
  }

  // MARK: Clawd

  /// One animation: its frames laid out left to right, plus its clawd.json entry.
  private struct Strip {
    let image: CGImage
    let entry: [String: Any]
  }

  /// Clawd GIF → native-resolution strip. Each art pixel is read at its block's center.
  private static func stripFromGIF(_ data: Data) -> Strip? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    var frames: [[UInt32]] = [], delays: [Int] = []
    for i in 0..<CGImageSourceGetCount(src) {
      guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { return nil }
      let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any]
      let gif = props?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
      let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double) ?? 0.083
      delays.append(Int((d * 1000).rounded()))
      let (buf, W, H) = SheetLoader.rgba(img)
      defer { buf.deallocate() }
      let bx = Double(W) / Double(stageW), by = Double(H) / Double(stageH)
      var f = [UInt32](repeating: 0, count: stageW * stageH)
      for y in 0..<stageH { for x in 0..<stageW {
        // Majority vote over a small patch at the block center — robust to the odd AA/dither pixel.
        var counts: [UInt32: Int] = [:]
        for dy in -2...2 { for dx in -2...2 {
          let sx = min(W - 1, max(0, Int((Double(x) + 0.5) * bx) + dx)), sy = min(H - 1, max(0, Int((Double(y) + 0.5) * by) + dy))
          counts[buf[sy * W + sx], default: 0] += 1
        } }
        let v = counts.max { $0.value < $1.value }!.key
        f[y * stageW + x] = (v >> 24) > 0x40 ? v : 0   // alpha is the high byte (RGBA little-endian → ABGR word)
      } }
      frames.append(f)
    }
    return makeStrip(frames, delays: delays, boxes: true)
  }

  /// clawd-laptop.mov → strip. Video compression smears colors, so each block is snapped to the GIF palette,
  /// and the black laptop (invisible on the Touch Bar) is recolored gray while Clawd's eyes stay black.
  private static func stripFromVideo(_ url: URL) -> Strip? {
    guard let frames = blocking({ try await laptopFrames(url) }), !frames.isEmpty else { return nil }
    return makeStrip(frames, delays: Array(repeating: 83, count: frames.count), boxes: false)
  }

  // Palette sampled from crabwalking.png: body, shade, eye.
  private static let palette = [(215, 119, 87), (190, 103, 76), (0, 0, 0)]
  private static let laptopGray: UInt32 = 0xFF_A8_A2_9C   // ABGR
  private static func pack(_ c: (Int, Int, Int)) -> UInt32 { 0xFF00_0000 | UInt32(c.2) << 16 | UInt32(c.1) << 8 | UInt32(c.0) }

  /// Decodes the video in order and samples it at 12 fps, mid-frame (one pose per sample).
  /// (AVAssetImageGenerator seeking now and then returned a neighboring frame; reading straight through is deterministic.)
  private static func laptopFrames(_ url: URL) async throws -> [[UInt32]] {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    reader.add(output)
    guard reader.startReading() else { return [] }
    var decoded: [(time: Double, frame: [UInt32])] = []   // snapped right away: full-size frames are ~20 MB each
    while let sample = output.copyNextSampleBuffer() {
      var img: CGImage?
      guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
      VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &img)
      if let img { decoded.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, snapLaptopFrame(img))) }
    }
    guard reader.status == .completed else { return [] }
    return (0..<Int((duration * 12).rounded(.down))).compactMap { i in
      decoded.last { $0.time <= (Double(i) + 0.5) / 12 }?.frame   // the frame on screen at that moment
    }
  }

  private static func snapLaptopFrame(_ img: CGImage) -> [UInt32] {
    let (buf, W, H) = SheetLoader.rgba(img)
    defer { buf.deallocate() }
    let (body, shade, eye) = (pack(palette[0]), pack(palette[1]), pack(palette[2]))
    let bx = Double(W) / Double(stageW), by = Double(H) / Double(stageH)
    var f = [UInt32](repeating: 0, count: stageW * stageH)
    for y in 0..<stageH { for x in 0..<stageW {
      var votes = [0, 0, 0, 0]   // none, body, shade, eye
      for dy in stride(from: -8, through: 8, by: 4) { for dx in stride(from: -8, through: 8, by: 4) {
        let sx = min(W - 1, max(0, Int((Double(x) + 0.5) * bx) + dx)), sy = min(H - 1, max(0, Int((Double(y) + 0.5) * by) + dy))
        let v = buf[sy * W + sx]
        let a = Int(v >> 24)
        if a < 128 { votes[0] += 1; continue }
        let r = Int(v & 0xFF) * 255 / a, g = Int(v >> 8 & 0xFF) * 255 / a, b = Int(v >> 16 & 0xFF) * 255 / a
        let dist = { (p: (Int, Int, Int)) in (r - p.0) * (r - p.0) + (g - p.1) * (g - p.1) + (b - p.2) * (b - p.2) }
        let k = palette.indices.min { dist(palette[$0]) < dist(palette[$1]) }!
        votes[k + 1] += 1
      } }
      let k = votes.indices.max { votes[$0] < votes[$1] }!
      f[y * stageW + x] = k == 0 ? 0 : pack(palette[k - 1])
    } }
    // A dark blob that mostly touches body is an eye (edge eyes in the 3/4 view touch air on one side);
    // the laptop is thin line work that mostly touches air.
    let isBody = { (x: Int, y: Int) -> Bool in
      x >= 0 && y >= 0 && x < stageW && y < stageH && (f[y * stageW + x] == body || f[y * stageW + x] == shade)
    }
    var g = f
    var seen = Set<Int>()
    for start in 0..<(stageW * stageH) where f[start] == eye && !seen.contains(start) {
      var blob: [Int] = [], stack = [start], bodyN = 0, otherN = 0
      seen.insert(start)
      while let k = stack.popLast() {
        blob.append(k)
        let (x, y) = (k % stageW, k / stageW)
        for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
          let nk = ny * stageW + nx
          if nx >= 0 && ny >= 0 && nx < stageW && ny < stageH && f[nk] == eye {
            if !seen.contains(nk) { seen.insert(nk); stack.append(nk) }
          } else if isBody(nx, ny) { bodyN += 1 } else { otherN += 1 }
        }
      }
      if blob.count > 8 || bodyN * 10 < (bodyN + otherN) * 6 { for k in blob { g[k] = laptopGray } }
    }
    return g
  }

  /// Crops stage-sized frames to their union bounding box and lays them out left to right.
  private static func makeStrip(_ frames: [[UInt32]], delays: [Int], boxes: Bool) -> Strip? {
    var minX = stageW, maxX = -1, minY = stageH, maxY = -1
    for f in frames { for y in 0..<stageH { for x in 0..<stageW where f[y * stageW + x] != 0 {
      minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } } }
    guard maxX >= 0 else { return nil }
    let fw = maxX - minX + 1, fh = maxY - minY + 1, n = frames.count, sheetW = fw * n
    guard let ctx = CGContext(data: nil, width: sheetW, height: fh, bitsPerComponent: 8, bytesPerRow: sheetW * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let data = ctx.data else { return nil }
    let out = data.assumingMemoryBound(to: UInt32.self)
    for (i, f) in frames.enumerated() { for y in 0..<fh { for x in 0..<fw {
      out[y * sheetW + i * fw + x] = f[(y + minY) * stageW + (x + minX)]
    } } }
    // Per-frame content boxes (crop coords, top-left origin) help the app place/align poses. The laptop has none.
    let boxList: [[Int]] = !boxes ? [] : frames.map { f in
      var a = stageW, b = -1, c = stageH, d = -1
      for y in 0..<stageH { for x in 0..<stageW where f[y * stageW + x] != 0 { a = min(a, x); b = max(b, x); c = min(c, y); d = max(d, y) } }
      return b < 0 ? [] : [a - minX, c - minY, b - a + 1, d - c + 1]
    }
    guard let image = ctx.makeImage() else { return nil }
    return Strip(image: image, entry: ["frame": [fw, fh], "count": n, "origin": [minX, minY], "delays_ms": delays, "boxes": boxList])
  }

  // MARK: Codex

  /// The Codex pet sheet from an installed Codex app. Today it's webview/assets/codex-spritesheet-v6-….webp inside
  /// Contents/Resources/app.asar; loose files are searched too. A future version may be renamed (v7…),
  /// so any codex-spritesheet*.webp with the right pixel size will do, newest first.
  private static func codexSheet(in apps: [URL]) -> (data: Data, source: String)? {
    let isSheet = { (name: String) in name.hasPrefix("codex-spritesheet") && name.hasSuffix(".webp") }
    for app in apps {
      let resources = app.appendingPathComponent("Contents/Resources")
      var found: [(name: String, read: () -> Data?)] = []
      if let asar = Asar(url: resources.appendingPathComponent("app.asar")) {
        for e in asar.entries where isSheet(e.name) { found.append((e.name, { asar.read(e) })) }
      }
      let walker = FileManager.default.enumerator(at: resources, includingPropertiesForKeys: nil)
      while let url = walker?.nextObject() as? URL {
        if isSheet(url.lastPathComponent) { found.append((url.lastPathComponent, { try? Data(contentsOf: url) })) }
      }
      for c in found.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedDescending }) {
        guard let data = c.read(), let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              props[kCGImagePropertyPixelWidth as String] as? Int == codexSheetSize.w,
              props[kCGImagePropertyPixelHeight as String] as? Int == codexSheetSize.h else { continue }
        return (data, "\(c.name) from \(app.path)")
      }
    }
    return nil
  }

  // MARK: Helpers

  /// Installed copies of an app, by bundle id, plus its usual location.
  private static func apps(_ bundleIDs: [String], fallback: String) -> [URL] {
    var urls = bundleIDs.flatMap { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }
    urls.append(URL(fileURLWithPath: fallback))
    var seen = Set<String>()
    return urls.filter { exists($0) && seen.insert($0.standardizedFileURL.path).inserted }
  }

  // Ephemeral: the sprite folder is our cache, so skip URLSession's own disk cache (and cookies).
  private static let session = URLSession(configuration: .ephemeral)

  private static func download(_ url: URL) -> Data? {
    let request: URLRequest = {
      var r = URLRequest(url: url, timeoutInterval: 20)
      // claude.ai turns away requests that don't look like a browser.
      r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                 forHTTPHeaderField: "User-Agent")
      return r
    }()
    return blocking {
      let (data, response) = try await session.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
      return data
    }
  }

  /// Runs async work from plain synchronous code (the build is a simple one-shot sequence).
  private static func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) -> T? {
    let box = ResultBox<T>(), done = DispatchSemaphore(value: 0)
    Task.detached {
      box.value = try? await work()
      done.signal()
    }
    done.wait()
    return box.value
  }

  private static func writePNG(_ img: CGImage, to url: URL) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(dest, img, nil)
    return CGImageDestinationFinalize(dest)
  }

  private static func readManifest() -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL))) as? [String: Any] ?? [:]
  }

  private static func has(_ name: String, _ manifest: [String: Any]) -> Bool {
    manifest[name] != nil && exists(clawdDir.appendingPathComponent("\(name).png"))
  }

  private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  private static func log(_ s: String) { FileHandle.standardError.write(Data("[sprites] \(s)\n".utf8)) }
}

private final class ResultBox<T>: @unchecked Sendable { var value: T? }
