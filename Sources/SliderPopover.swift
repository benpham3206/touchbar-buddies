import AppKit

/// The brightness / volume slider, drawn to match the native Control Strip popover.
/// Measured from screenshots of the real one: a 360pt panel followed by a 72pt zone holding a round ×.
/// The × lands on the tapped button when there's room on its left (volume); otherwise the whole
/// thing starts at the bar's left edge (brightness).
final class SliderPopover {
  enum Kind { case brightness, volume }

  static let panelWidth: CGFloat = 360
  static let closeZone: CGFloat = 72
  static let trackStart: CGFloat = 79     // from the panel's left edge
  static let trackLength: CGFloat = 202
  private static let trackBlue = CGColor(srgbRed: 18 / 255, green: 129 / 255, blue: 210 / 255, alpha: 1)
  private static let trackGray = CGColor(srgbRed: 115 / 255, green: 115 / 255, blue: 115 / 255, alpha: 1)
  private static let closeGray = CGColor(srgbRed: 176 / 255, green: 175 / 255, blue: 176 / 255, alpha: 1)

  let kind: Kind
  let panel: CGRect
  let closeCenter: CGPoint
  private let origin: CGRect              // the button it grows out of
  private let openedAt: Double
  private(set) var closedAt: Double?
  private(set) var value: Float
  private(set) var lastInteraction: Double
  var touching = false

  init(_ kind: Kind, from button: CGRect, barWidth: CGFloat, now: Double, animated: Bool = true) {
    self.kind = kind
    let x = min(max(0, button.minX - Self.panelWidth), barWidth - Self.panelWidth - Self.closeZone)
    panel = CGRect(x: x, y: 0, width: Self.panelWidth, height: 30)
    closeCenter = CGPoint(x: panel.maxX + Self.closeZone / 2, y: 15)
    origin = button
    openedAt = animated ? now : now - 1
    lastInteraction = now
    value = kind == .brightness ? SystemControls.brightness : SystemControls.volume
  }

  // MARK: Interaction

  func hitsClose(_ p: CGPoint) -> Bool { hypot(p.x - closeCenter.x, p.y - closeCenter.y) < 22 }
  func hitsPanel(_ p: CGPoint) -> Bool { panel.insetBy(dx: -6, dy: -10).contains(p) }

  /// Jump the knob to a finger position on the panel.
  func slide(toX x: CGFloat, now: Double) {
    set(Float((x - panel.minX - Self.trackStart) / Self.trackLength), now: now)
  }

  func set(_ v: Float, now: Double) {
    value = min(1, max(0, v))
    lastInteraction = now
    if kind == .brightness { SystemControls.brightness = value } else { SystemControls.volume = value }
  }

  func close(now: Double) {
    if closedAt == nil { closedAt = now }
  }

  func isGone(now: Double) -> Bool { closedAt.map { now - $0 > 0.15 } ?? false }

  // MARK: Drawing

  func draw(_ ctx: CGContext, now: Double) {
    // Grow out of the button when opening, shrink back into it when closing.
    var t = min(1, (now - openedAt) / 0.18)
    if let c = closedAt { t = min(t, max(0, 1 - (now - c) / 0.15)) }
    let e = CGFloat(1 - pow(1 - t, 3))
    let r = CGRect(x: origin.minX + (panel.minX - origin.minX) * e, y: 0,
                   width: origin.width + (panel.width - origin.width) * e, height: 30)
    ctx.setFillColor(StripView.buttonColor)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil))
    ctx.fillPath()

    ctx.saveGState()
    ctx.setAlpha(max(0, (e - 0.5) * 2))   // contents fade in during the second half of the grow
    ctx.clip(to: r)
    let (lo, hi): (Icon, Icon) = kind == .brightness ? (.sunMin, .sunMax) : (.speakerMin, .speakerMax)
    ctx.draw(Icons.image(lo), in: CGRect(x: panel.minX + 35.5 - 36, y: 0, width: 72, height: 30))
    ctx.draw(Icons.image(hi), in: CGRect(x: panel.minX + 323.5 - 36, y: 0, width: 72, height: 30))

    let track = CGRect(x: panel.minX + Self.trackStart, y: 13, width: Self.trackLength, height: 4)
    let knobX = track.minX + CGFloat(value) * track.width
    ctx.setFillColor(Self.trackGray)
    ctx.addPath(CGPath(roundedRect: track, cornerWidth: 2, cornerHeight: 2, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(Self.trackBlue)
    ctx.addPath(CGPath(roundedRect: CGRect(x: track.minX, y: track.minY, width: max(4, knobX - track.minX), height: 4), cornerWidth: 2, cornerHeight: 2, transform: nil))
    ctx.fillPath()

    // The knob grows while a finger is on it, like the native one.
    let size: CGFloat = touching ? 30 : 21
    ctx.setFillColor(CGColor.white)
    ctx.addPath(CGPath(roundedRect: CGRect(x: knobX - size / 2, y: 15 - size / 2, width: size, height: size), cornerWidth: 6, cornerHeight: 6, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()

    // Round × to the right of the panel.
    ctx.saveGState()
    ctx.setAlpha(e)
    ctx.setFillColor(Self.closeGray)
    ctx.fillEllipse(in: CGRect(x: closeCenter.x - 11, y: closeCenter.y - 11, width: 22, height: 22))
    ctx.draw(Icons.image(.closeDark), in: CGRect(x: closeCenter.x - 36, y: 0, width: 72, height: 30))
    ctx.restoreGState()
  }
}
