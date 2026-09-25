import AppKit

// Tiny pixel-art effects (hearts, sparks, Zzz, balls…) drawn on a point grid.

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

enum Palette {
  static let clawd = rgb(215, 119, 87)
  static let codex = rgb(96, 128, 255)
  static let codexLight = rgb(150, 190, 255)
  static let heart = rgb(255, 105, 140)
  static let gold = rgb(255, 214, 90)
  static let white = rgb(255, 255, 255)
  static let confetti: [CGColor] = [clawd, codex, gold, rgb(140, 220, 150), heart, white]
}

struct Pen {
  let ctx: CGContext
  var ox: CGFloat
  var oy: CGFloat
  var s: CGFloat

  func px(_ x: Int, _ y: Int, _ w: Int = 1, _ h: Int = 1, _ c: CGColor) {
    ctx.setFillColor(c)
    ctx.fill(CGRect(x: ox + CGFloat(x) * s, y: oy + CGFloat(y) * s, width: CGFloat(w) * s, height: CGFloat(h) * s))
  }

  /// Rows are listed top → bottom; `#` is filled.
  func bitmap(_ rows: [String], _ x: Int, _ y: Int, _ c: CGColor, flip: Bool = false) {
    for (i, row) in rows.enumerated() {
      let yy = y + rows.count - 1 - i
      let chars = Array(flip ? String(row.reversed()) : row)
      var run = -1
      for j in 0...chars.count {
        if j < chars.count && chars[j] == "#" {
          if run < 0 { run = j }
        } else if run >= 0 {
          px(x + run, yy, j - run, 1, c)
          run = -1
        }
      }
    }
  }
}

enum Sprite {
  static let heart = [".#.#.", "#####", "#####", ".###.", "..#.."]
  static let spark = ["..#..", "..#..", "##.##", "..#..", "..#.."]
  static let star = [".#.", "###", ".#."]
  static let zed = ["####", "..#.", ".#..", "####"]
  static let note = [".###", ".#.#", ".#..", "##..", "##.."]
  static let bang = ["#", "#", "#", ".", "#"]
  static let ball = [".##.", "####", "####", ".##."]
  static let plane = ["#.....", "###...", ".#####", "###...", "#....."]
  static let dust = [".#.", "#.#", ".#."]

  static func size(_ rows: [String]) -> (w: Int, h: Int) { (rows.map(\.count).max() ?? 0, rows.count) }
}
