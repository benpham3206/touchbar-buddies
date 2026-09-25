import AppKit

// Button glyphs for the recreated Expanded Control Strip.
// SF Symbols where they match; Mission Control, Launchpad, mute and sleep are traced from the native bar.
enum Icon: Hashable, CaseIterable {
  case brightness, missionControl, launchpad, keyboardDown, keyboardUp, rewind, playPause, forward, mute, volume, sleep, lock
  case volume1, volume2, volume3                       // volume button shows the current level
  case closeDark, sunMin, sunMax, speakerMin, speakerMax  // slider popover
}

enum Icons {
  private static var cache: [Icon: CGImage] = [:]

  /// Drawing SF Symbols needs a full GUI app, which sandboxes (like Codex's) don't allow. So the live app saves
  /// every glyph it draws here, and `--render` sets `reuseSaved` to read them back instead of drawing them.
  static var savedDir: URL { AssetCache.directory.deletingLastPathComponent().appendingPathComponent("icons") }
  static var reuseSaved = false

  /// A 72×30pt (144×60px) image with the glyph centered as on a native button.
  static func image(_ icon: Icon) -> CGImage {
    if let img = cache[icon] { return img }
    let file = savedDir.appendingPathComponent("\(icon).png")
    let img: CGImage
    if reuseSaved {
      img = SheetLoader.image(file) ?? render(icon, symbols: false)   // missing: blank rather than crash
    } else {
      img = render(icon)
      save(img, to: file)
    }
    cache[icon] = img
    return img
  }

  /// The live app draws and saves every glyph up front, so renders always find them.
  static func saveAll() {
    // Drawn and written in the background: drawing 20 SF Symbols on the main thread stalled the animation.
    saver.async {
      for icon in Icon.allCases { write(render(icon), to: savedDir.appendingPathComponent("\(icon).png")) }
    }
  }

  /// PNG encoding and disk writes happen in the background so the Touch Bar's animation never waits on them.
  private static let saver = DispatchQueue(label: "dev.touchbarbuddies.icons", qos: .utility)

  private static func save(_ img: CGImage, to file: URL) {
    saver.async { write(img, to: file) }
  }

  private static func write(_ img: CGImage, to file: URL) {
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
  }

  private static func render(_ icon: Icon, symbols: Bool = true) -> CGImage {
    let ctx = CGContext(data: nil, width: 144, height: 60, bitsPerComponent: 8, bytesPerRow: 144 * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: 2, y: 2)
    // Traced coordinates are top-left based, like the screenshots they came from.
    ctx.translateBy(x: 0, y: 30)
    ctx.scaleBy(x: 1, y: -1)
    let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ns
    ctx.setStrokeColor(.white)
    ctx.setFillColor(.white)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // SF Symbols need a full GUI app (see `reuseSaved`), so a render may skip them.
    func symbol(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight, color: NSColor = .white) {
      if symbols { drawSymbol(name, size, weight, color: color) }
    }
    switch icon {
    case .brightness: symbol("sun.max.fill", 16, .semibold)
    case .keyboardDown: symbol("light.min", 17, .bold)
    case .keyboardUp: symbol("light.max", 17, .bold)
    case .rewind: symbol("backward.fill", 18.5, .medium)
    case .playPause: symbol("playpause.fill", 18.5, .medium)
    case .forward: symbol("forward.fill", 18.5, .medium)
    case .volume: symbol("speaker.fill", 18.5, .medium)
    case .volume1: symbol("speaker.wave.1.fill", 18.5, .medium)
    case .volume2: symbol("speaker.wave.2.fill", 18.5, .medium)
    case .volume3: symbol("speaker.wave.3.fill", 18.5, .medium)
    case .lock: symbol("lock.fill", 16, .medium)
    case .closeDark: symbol("xmark", 10.5, .heavy, color: .black)
    case .sunMin: symbol("sun.min.fill", 12.5, .medium)
    case .sunMax: symbol("sun.max.fill", 15.5, .medium)
    case .speakerMin: symbol("speaker.wave.1.fill", 14, .medium)
    case .speakerMax: symbol("speaker.wave.3.fill", 16, .medium)

    case .missionControl:
      ctx.setLineWidth(1)
      for r in [CGRect(x: 26, y: 7.5, width: 10.5, height: 6), CGRect(x: 42, y: 9.5, width: 6, height: 11), CGRect(x: 30, y: 18, width: 9, height: 5.5)] {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 1.2, cornerHeight: 1.2, transform: nil))
      }
      ctx.strokePath()

    case .launchpad:
      ctx.setLineWidth(1)
      for y in [8.5, 16.5] as [CGFloat] { for x in [26, 34, 42] as [CGFloat] {
        ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: 6, height: 5), cornerWidth: 1.1, cornerHeight: 1.1, transform: nil))
      } }
      ctx.strokePath()

    case .mute:
      ctx.beginTransparencyLayer(auxiliaryInfo: nil)
      // Speaker
      ctx.addPath(CGPath(roundedRect: CGRect(x: 25, y: 12, width: 6.5, height: 6), cornerWidth: 0.8, cornerHeight: 0.8, transform: nil))
      ctx.fillPath()
      ctx.move(to: CGPoint(x: 30.5, y: 12.2)); ctx.addLine(to: CGPoint(x: 34.6, y: 8.3))
      ctx.addLine(to: CGPoint(x: 34.6, y: 21.7)); ctx.addLine(to: CGPoint(x: 30.5, y: 17.8)); ctx.closePath()
      ctx.fillPath()
      // Dimmed sound waves
      ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.42))
      ctx.setLineWidth(1)
      for (r, a) in [(7.25, 31.0), (11.0, 36.0), (14.5, 40.0)] as [(CGFloat, CGFloat)] {
        let rad = a * .pi / 180
        ctx.addArc(center: CGPoint(x: 31, y: 14.9), radius: r, startAngle: -rad, endAngle: rad, clockwise: false)
        ctx.strokePath()
      }
      // Slash with a cut-out gap
      let a = CGPoint(x: 23.5, y: 6), b = CGPoint(x: 49, y: 23.5)
      ctx.setBlendMode(.clear)
      ctx.setLineWidth(3.9)
      ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
      ctx.setBlendMode(.normal)
      ctx.setStrokeColor(.white)
      ctx.setLineWidth(1.7)
      ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
      ctx.endTransparencyLayer()

    case .sleep:
      ctx.setLineWidth(1.05)
      ctx.addEllipse(in: CGRect(x: 36.5 - 8.5, y: 15 - 8.5, width: 17, height: 17))
      ctx.strokePath()
      ctx.move(to: CGPoint(x: 31.5, y: 18)); ctx.addLine(to: CGPoint(x: 42.5, y: 18))
      ctx.strokePath()
    }
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
  }

  private static func drawSymbol(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight, color: NSColor) {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: [color]))
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
    let s = img.size
    img.draw(in: NSRect(x: 36 - s.width / 2, y: 15 - s.height / 2, width: s.width, height: s.height),
             from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
  }
}
