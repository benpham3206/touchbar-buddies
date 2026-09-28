import AppKit

// New Clawd art that ships inside Claude Code itself: pixel-art SVGs embedded in the `claude` binary, like
// "Clawd stirs a steaming pot" (CLAWD_COOKING_SVG, new in 2.1.284). AssetCache looks in the newest installed Claude Code
// once per version (see refreshClawdSVGs), and each animated one it finds becomes a strip, so new art turns up here
// without an update to this app.
//
// They're drawn by a tiny SVG + SMIL interpreter rather than WebKit: the art is rects and straight-line paths on an
// 8-unit grid, animated with <animate> / <animateTransform> (value lists, keyTimes, spline easing, negative begins).
// Anything outside that subset is refused, so a future SVG that needs more is skipped (and logged) instead of drawn wrong.
enum ClawdSVG {
  struct Found { let title: String; let svg: String }

  /// Every installed Claude Code binary, oldest version first: the CLI's (~/.local/share/claude/versions) and the
  /// copies the Claude app keeps for its Code tab.
  static func installs() -> [(version: String, binary: URL)] {
    let home = NSHomeDirectory(), fm = FileManager.default
    var out: [(version: String, binary: URL)] = []
    let cli = home + "/.local/share/claude/versions"
    for v in (try? fm.contentsOfDirectory(atPath: cli)) ?? [] { out.append((v, URL(fileURLWithPath: "\(cli)/\(v)"))) }
    let app = home + "/Library/Application Support/Claude/claude-code"
    for v in (try? fm.contentsOfDirectory(atPath: app)) ?? [] {
      out.append((v, URL(fileURLWithPath: "\(app)/\(v)/claude.app/Contents/MacOS/claude")))
    }
    return out.filter { fm.isExecutableFile(atPath: $0.binary.path) }
      .sorted { $0.version.compare($1.version, options: .numeric) == .orderedAscending }
  }

  /// The animated Clawd SVGs in a binary: <svg …><title>Clawd …</title>…</svg> with at least one <animate…>
  /// (each also has a still twin, which is skipped).
  static func find(in binary: URL) -> [Found] {
    guard let data = try? Data(contentsOf: binary, options: .alwaysMapped) else { return [] }
    let open = Data("<svg xmlns=".utf8), close = Data("</svg>".utf8)
    var out: [Found] = [], seen = Set<String>()
    var from = data.startIndex
    while let start = data.range(of: open, in: from..<data.endIndex) {
      guard let end = data.range(of: close, in: start.upperBound..<min(data.endIndex, start.upperBound + 100_000)) else { break }
      from = end.upperBound
      guard let svg = String(data: data[start.lowerBound..<end.upperBound], encoding: .utf8),
            let t0 = svg.range(of: "<title>"), let t1 = svg.range(of: "</title>", range: t0.upperBound..<svg.endIndex)
      else { continue }
      let title = String(svg[t0.upperBound..<t1.lowerBound])
      guard title.hasPrefix("Clawd"), svg.contains("<animate"), seen.insert(title).inserted else { continue }
      out.append(Found(title: title, svg: svg))
    }
    return out
  }

  // MARK: Rendering

  struct Strip {
    let image: CGImage        // the frames side by side
    let frameSize: (w: Int, h: Int)
    let count: Int
    let delayMS: Int
    let anchor: CGFloat       // points from the frame's left edge to Clawd's center
    let baseline: CGFloat     // points from the frame's bottom to his feet
  }

  /// Renders one loop at `fps`, `pxPerArt` image pixels per art pixel (the art grid is 8 SVG units). The full-width
  /// floor line some scenes stand on is left out: the Touch Bar has its own ground. Nil if it uses anything unsupported.
  static func render(_ svg: String, fps: Double = 12, pxPerArt: CGFloat = 2) -> Strip? {
    guard let root = Parser.parse(svg), root.name == "svg", let box = root.viewBox else { return nil }
    let scale = pxPerArt / 8
    let w = Int((box.width * scale).rounded()), h = Int((box.height * scale).rounded())
    let period = root.longestLoop
    let count = max(1, Int((period * fps).rounded()))
    guard w > 0, h > 0, count < 400,
          let ctx = CGContext(data: nil, width: w * count, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    for i in 0..<count {
      ctx.saveGState()
      // SVG's y grows down; frame i sits at x = i * w.
      ctx.translateBy(x: CGFloat(i * w), y: CGFloat(h))
      ctx.scaleBy(x: scale, y: -scale)
      ctx.translateBy(x: -box.minX, y: -box.minY)
      ctx.clip(to: box)
      ctx.setShouldAntialias(false)   // shape-rendering="crispEdges": hard pixel edges, like the browser
      root.draw(in: ctx, at: Double(i) / Double(count) * period, floorWidth: box.width)
      ctx.restoreGState()
    }
    guard let image = ctx.makeImage() else { return nil }
    // Where Clawd stands: the most common run of his orange (the rows of his body), and the bottom of it.
    let (center, feet) = root.clawdBody()
    return Strip(image: image, frameSize: (w, h), count: count, delayMS: Int((period / Double(count) * 1000).rounded()),
                 anchor: (center - box.minX) / 8, baseline: (box.maxY - feet) / 8)
  }

  // MARK: The subset: a small DOM

  fileprivate final class Node {
    let name: String
    var attrs: [String: String]
    var children: [Node] = []
    init(_ name: String, _ attrs: [String: String]) { self.name = name; self.attrs = attrs }

    var viewBox: CGRect? {
      let v = (attrs["viewBox"] ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
      return v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil
    }

    var animations: [Node] { children.filter { $0.name == "animate" || $0.name == "animateTransform" } }

    /// The longest animation's duration: one loop of the whole scene.
    var longestLoop: Double {
      max(animations.compactMap { Anim.seconds($0.attrs["dur"]) }.max() ?? 0, children.map(\.longestLoop).max() ?? 0, 0.1)
    }

    /// Attributes at time `t`, with this element's animations applied.
    func attributes(at t: Double) -> [String: String] {
      var a = attrs
      for anim in animations {
        guard let key = anim.attrs["attributeName"], let value = Anim.value(anim, at: t) else { continue }
        if anim.name == "animateTransform" {
          a["transform"] = "\(anim.attrs["type"] ?? "translate")(\(value.map { String($0) }.joined(separator: " ")))"
        } else {
          a[key] = String(value.first ?? 0)
        }
      }
      return a
    }

    func draw(in ctx: CGContext, at t: Double, floorWidth: CGFloat) {
      let a = attributes(at: t)
      let opacity = CGFloat(Double(a["opacity"] ?? "1") ?? 1)
      guard opacity > 0.001 else { return }
      ctx.saveGState()
      defer { ctx.restoreGState() }
      if let tr = a["transform"] { ctx.concatenate(Self.transform(tr)) }
      let layered = opacity < 1 && (name == "g" || name == "svg")
      // A translucent group fades as one (a layer), without fading its children a second time inside it.
      if layered { ctx.setAlpha(opacity); ctx.beginTransparencyLayer(auxiliaryInfo: nil); ctx.setAlpha(1) }
      else if opacity < 1 { ctx.setAlpha(opacity) }
      switch name {
      case "svg", "g":
        for c in children { c.draw(in: ctx, at: t, floorWidth: floorWidth) }
      case "rect":
        let n = { (k: String) in CGFloat(Double(a[k] ?? "0") ?? 0) }
        let r = CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height"))
        if r.width >= floorWidth { break }                       // the floor line: the Touch Bar has its own ground
        if let fill = Self.color(a["fill"] ?? "#000") { ctx.setFillColor(fill); ctx.fill(r) }
      case "path":
        let path = Self.path(a["d"] ?? "")
        if let fill = Self.color(a["fill"] ?? "#000") { ctx.addPath(path); ctx.setFillColor(fill); ctx.fillPath() }
        if let stroke = Self.color(a["stroke"] ?? "none") {
          ctx.addPath(path)
          ctx.setStrokeColor(stroke)
          ctx.setLineWidth(CGFloat(Double(a["stroke-width"] ?? "1") ?? 1))
          ctx.setLineCap(a["stroke-linecap"] == "square" ? .square : a["stroke-linecap"] == "round" ? .round : .butt)
          ctx.strokePath()
        }
      default: break
      }
      if layered { ctx.endTransparencyLayer() }
    }

    /// The middle of the most common horizontal run of Clawd's orange, and the lowest point of it (SVG units, at t 0).
    func clawdBody() -> (center: CGFloat, feet: CGFloat) {
      var runs: [CGFloat: Int] = [:], feet: CGFloat = 0
      func visit(_ n: Node) {
        if n.attrs["fill"]?.lowercased() == "#d77757" {
          for r in Self.rects(n) { runs[r.midX, default: 0] += 1; feet = max(feet, r.maxY) }
        }
        n.children.forEach(visit)
      }
      visit(self)
      return (runs.max { $0.value < $1.value }?.key ?? 0, feet)
    }

    /// The axis-aligned rectangles a rect or an "M x y h w v h h -w z" path is made of.
    static func rects(_ n: Node) -> [CGRect] {
      let v = { (k: String) in CGFloat(Double(n.attrs[k] ?? "0") ?? 0) }
      if n.name == "rect" { return [CGRect(x: v("x"), y: v("y"), width: v("width"), height: v("height"))] }
      guard n.name == "path" else { return [] }
      return path(n.attrs["d"] ?? "").boundingBoxesOfSubpaths()
    }

    static func color(_ s: String) -> CGColor? {
      guard s.hasPrefix("#") else { return nil }   // "none"
      var hex = String(s.dropFirst())
      if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
      guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
      return CGColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    /// translate(x y) / rotate(a cx cy) / scale(x y), one or several.
    static func transform(_ s: String) -> CGAffineTransform {
      var t = CGAffineTransform.identity
      let scanner = Scanner(string: s)
      while let name = scanner.scanCharacters(from: .letters) {
        _ = scanner.scanString("(")
        let args = (scanner.scanUpToString(")") ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        _ = scanner.scanString(")")
        let a = args.map { CGFloat($0) }
        switch name {
        case "translate": t = t.translatedBy(x: a.first ?? 0, y: a.count > 1 ? a[1] : 0)
        case "scale": t = t.scaledBy(x: a.first ?? 1, y: a.count > 1 ? a[1] : (a.first ?? 1))
        case "rotate":
          let angle = (a.first ?? 0) * .pi / 180
          if a.count == 3 { t = t.translatedBy(x: a[1], y: a[2]).rotated(by: angle).translatedBy(x: -a[1], y: -a[2]) }
          else { t = t.rotated(by: angle) }
        default: break
        }
      }
      return t
    }

    /// M/L/H/V/Z, absolute and relative: all these pixel-art paths use.
    static func path(_ d: String) -> CGPath {
      let p = CGMutablePath()
      var cur = CGPoint.zero, start = CGPoint.zero
      var cmd: Character = "M"
      var nums: [CGFloat] = []
      func flush() {
        var i = 0
        func next() -> CGFloat? { guard i < nums.count else { return nil }; defer { i += 1 }; return nums[i] }
        let rel = cmd.isLowercase
        switch cmd.uppercased() {
        case "M", "L":
          var first = cmd.uppercased() == "M"
          while let x = next(), let y = next() {
            let pt = rel ? CGPoint(x: cur.x + x, y: cur.y + y) : CGPoint(x: x, y: y)
            if first { p.move(to: pt); start = pt; first = false } else { p.addLine(to: pt) }
            cur = pt
          }
        case "H": while let x = next() { cur.x = rel ? cur.x + x : x; p.addLine(to: cur) }
        case "V": while let y = next() { cur.y = rel ? cur.y + y : y; p.addLine(to: cur) }
        case "Z": p.closeSubpath(); cur = start
        default: break
        }
        nums.removeAll()
      }
      var number = ""
      func endNumber() { if let v = Double(number) { nums.append(CGFloat(v)) }; number = "" }
      for ch in d {
        if ch.isLetter { endNumber(); flush(); cmd = ch }
        else if ch == "-" { endNumber(); number = "-" }
        else if ch == " " || ch == "," { endNumber() }
        else { number.append(ch) }
      }
      endNumber(); flush()
      return p
    }
  }

  // MARK: SMIL timing

  fileprivate enum Anim {
    static func seconds(_ s: String?) -> Double? {
      guard var s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
      var k = 1.0
      if s.hasSuffix("ms") { s.removeLast(2); k = 0.001 } else if s.hasSuffix("s") { s.removeLast() }
      return Double(s).map { $0 * k }
    }

    /// The animated value (a list of numbers) at time `t`: repeating loops, keyTimes, linear / spline / discrete.
    static func value(_ a: Node, at t: Double) -> [Double]? {
      let frames = (a.attrs["values"] ?? "").split(separator: ";").map {
        $0.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
      }
      guard let dur = seconds(a.attrs["dur"]), dur > 0, frames.count >= 1 else { return nil }
      let begin = seconds(a.attrs["begin"]) ?? 0
      guard t >= begin else { return nil }   // (not started yet: the static value shows)
      let p = ((t - begin).truncatingRemainder(dividingBy: dur)) / dur
      guard frames.count > 1 else { return frames[0] }
      let keys = a.attrs["keyTimes"].map { $0.split(separator: ";").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
        ?? (0..<frames.count).map { Double($0) / Double(frames.count - 1) }
      guard keys.count == frames.count else { return nil }
      var k = 0
      while k < keys.count - 2 && p >= keys[k + 1] { k += 1 }
      let span = keys[k + 1] - keys[k]
      var u = span > 0 ? min(1, max(0, (p - keys[k]) / span)) : 0
      switch a.attrs["calcMode"] ?? "linear" {
      case "discrete": return frames[p >= keys[k + 1] ? k + 1 : k]
      case "spline":
        let splines = (a.attrs["keySplines"] ?? "").split(separator: ";").map {
          $0.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        }
        if k < splines.count, splines[k].count == 4 { u = bezier(splines[k], u) }
      default: break
      }
      let from = frames[k], to = frames[k + 1]
      return zip(from, to).map { $0 + ($1 - $0) * u }
    }

    /// CSS-style cubic-bezier easing: y at x = u, for the control points (x1 y1 x2 y2).
    static func bezier(_ c: [Double], _ u: Double) -> Double {
      func b(_ t: Double, _ p1: Double, _ p2: Double) -> Double { 3 * (1 - t) * (1 - t) * t * p1 + 3 * (1 - t) * t * t * p2 + t * t * t }
      var lo = 0.0, hi = 1.0
      for _ in 0..<30 { let mid = (lo + hi) / 2; if b(mid, c[0], c[2]) < u { lo = mid } else { hi = mid } }
      return b((lo + hi) / 2, c[1], c[3])
    }
  }

  // MARK: Parsing (refuses what the renderer can't draw)

  fileprivate final class Parser: NSObject, XMLParserDelegate {
    private static let elements: Set<String> = ["svg", "title", "g", "rect", "path", "animate", "animateTransform"]
    private static let animatable: Set<String> = ["opacity", "x", "y", "width", "height", "transform"]
    private var stack: [Node] = []
    private var root: Node?
    private var refused = false

    static func parse(_ svg: String) -> Node? {
      let p = Parser()
      let x = XMLParser(data: Data(svg.utf8))
      x.delegate = p
      guard x.parse(), !p.refused else { return nil }
      return p.root
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
      if !Self.elements.contains(name) || attributes["style"] != nil || attributes["class"] != nil { refused = true }
      if name.hasPrefix("animate"), let key = attributes["attributeName"], !Self.animatable.contains(key) { refused = true }
      if name == "animateTransform", !["translate", "rotate", "scale"].contains(attributes["type"] ?? "translate") { refused = true }
      let node = Node(name, attributes)
      stack.last?.children.append(node)
      if root == nil { root = node }
      stack.append(node)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
      stack.removeLast()
    }
  }
}

private extension CGPath {
  /// The bounding box of each closed subpath ("M x y h … z" rectangles).
  func boundingBoxesOfSubpaths() -> [CGRect] {
    var boxes: [CGRect] = []
    var current: CGRect?
    applyWithBlock { e in
      let pts = e.pointee.points
      switch e.pointee.type {
      case .moveToPoint:
        if let c = current { boxes.append(c) }
        current = CGRect(origin: pts[0], size: .zero)
      case .addLineToPoint: current = current?.union(CGRect(origin: pts[0], size: .zero))
      case .closeSubpath: if let c = current { boxes.append(c) }; current = nil
      default: break
      }
    }
    if let c = current { boxes.append(c) }
    return boxes
  }
}
