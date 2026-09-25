import AppKit
import ImageIO

// Clip: one animation (frames + how long each shows) and how to draw it, plus the small image helpers
// Bank and AssetCache use to cut and pixel-edit sprite sheets.

/// A sequence of frames plus where the character's feet/center sit inside each frame.
struct Clip {
  var frames: [CGImage]
  var durations: [Double]
  var size: CGSize          // points
  var anchorX: CGFloat      // points from frame left to the character's center line
  var baseline: CGFloat     // points from frame bottom to the feet
  var pixelated = true
  var facesRight = true     // Clawd art is drawn facing right and gets mirrored; Codex has its own left/right rows

  var total: Double { durations.reduce(0, +) }

  /// The frame showing `t` seconds into the clip.
  func index(at t: Double, loop: Bool) -> Int {
    guard frames.count > 1, total > 0 else { return 0 }
    var tt = loop ? t.truncatingRemainder(dividingBy: total) : min(max(0, t), total - 0.0001)
    for (i, d) in durations.enumerated() {
      if tt < d { return i }
      tt -= d
    }
    return frames.count - 1
  }

  // Variations of a clip: some of its frames, faster/slower, one frozen frame, or a replacement image.

  func slice(_ r: ClosedRange<Int>) -> Clip {
    var c = self
    c.frames = Array(frames[r])
    c.durations = Array(durations[r])
    return c
  }

  func pick(_ idx: [Int]) -> Clip {
    var c = self
    c.frames = idx.map { frames[$0] }
    c.durations = idx.map { durations[$0] }
    return c
  }

  func speed(_ s: Double) -> Clip {
    var c = self
    c.durations = durations.map { $0 / s }
    return c
  }

  func still(_ i: Int, _ seconds: Double = 1) -> Clip {
    var c = self
    c.frames = [frames[i]]
    c.durations = [seconds]
    return c
  }

  func with(_ img: CGImage) -> Clip {
    var c = self
    c.frames = [img]
    c.durations = [1]
    return c
  }

  /// Draws frame `i` with the character's center at `x` and feet at `y` (points), snapped to the 2× pixel grid.
  func draw(_ i: Int, in ctx: CGContext, x: CGFloat, y: CGFloat, mirror: Bool = false, alpha: CGFloat = 1, squashY: CGFloat = 1) {
    let snap = { (v: CGFloat) in (v * 2).rounded() / 2 }
    let rect = CGRect(x: snap(x - anchorX), y: snap(y - baseline), width: size.width, height: size.height * squashY)
    ctx.saveGState()
    if mirror {
      ctx.translateBy(x: snap(x) * 2, y: 0)
      ctx.scaleBy(x: -1, y: 1)
    }
    ctx.setAlpha(alpha)
    ctx.interpolationQuality = pixelated ? .none : .high
    ctx.draw(frames[min(i, frames.count - 1)], in: rect)
    ctx.restoreGState()
  }
}

// MARK: - Loading

enum SheetLoader {
  static func image(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
  }

  /// Bounding box of non-transparent pixels (top-left origin), nil if empty.
  static func contentBox(_ img: CGImage) -> CGRect? {
    let (buf, w, h) = rgba(img)
    defer { buf.deallocate() }
    var minX = w, maxX = -1, minY = h, maxY = -1
    for y in 0..<h { for x in 0..<w where buf[y * w + x] >> 24 > 0x20 {
      minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
  }

  static func rgba(_ img: CGImage) -> (UnsafeMutablePointer<UInt32>, Int, Int) {
    let w = img.width, h = img.height
    let buf = UnsafeMutablePointer<UInt32>.allocate(capacity: w * h)
    buf.initialize(repeating: 0, count: w * h)
    let ctx = CGContext(data: buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (buf, w, h)
  }

  static func makeImage(_ buf: UnsafeMutablePointer<UInt32>, _ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return ctx.makeImage()!
  }

  /// Pixel-edit a copy of an image. Coordinates are top-left origin.
  static func edit(_ img: CGImage, _ body: (inout PixelGrid) -> Void) -> CGImage {
    let (buf, w, h) = rgba(img)
    defer { buf.deallocate() }
    var grid = PixelGrid(buf: buf, w: w, h: h)
    body(&grid)
    return makeImage(buf, w, h)
  }
}

struct PixelGrid {
  let buf: UnsafeMutablePointer<UInt32>
  let w: Int, h: Int
  subscript(x: Int, y: Int) -> UInt32 {
    get { x >= 0 && y >= 0 && x < w && y < h ? buf[y * w + x] : 0 }
    nonmutating set { if x >= 0 && y >= 0 && x < w && y < h { buf[y * w + x] = newValue } }
  }
  func fill(_ x: Int, _ y: Int, _ cw: Int, _ ch: Int, _ v: UInt32) {
    for yy in y..<(y + ch) { for xx in x..<(x + cw) { self[xx, yy] = v } }
  }
  /// Move every pixel down by `dy` rows (content at the bottom is dropped).
  func shiftDown(_ dy: Int) {
    for y in stride(from: h - 1, through: 0, by: -1) { for x in 0..<w { self[x, y] = y - dy >= 0 ? self[x, y - dy] : 0 } }
  }
}
