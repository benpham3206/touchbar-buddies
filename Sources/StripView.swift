import AppKit
import QuartzCore

// The whole Touch Bar: a faithful copy of the Expanded Control Strip (laid out like the user's own),
// with the first gap given to Codex and the last gap to Clawd. It draws the buttons, lets Scene draw the
// buddies on top, and turns touches into button presses or buddy taps.
final class StripView: NSView {
  enum Action { case brightness, missionControl, launchpad, keyboardDown, keyboardUp, rewind, playPause, forward, mute, volume, sleep, lock }

  struct Button {
    let action: Action
    let icon: Icon
    var rect: CGRect
  }

  enum Target { case button(Int), buddy(Who), popover, none }

  /// One finger on the bar.
  struct TouchState {
    var target: Target
    var start: CGPoint
    var began: Double
    var moved = false
    var longFired = false          // a long press already happened, so lifting isn't a tap
    var lastRepeat: Double = 0     // keyboard-backlight auto-repeat
    var startValue: Float = 0      // brightness/volume when the finger went down (press-and-slide)
  }

  // Colors measured from screenshots of the native strip.
  static let buttonColor = CGColor(srgbRed: 55 / 255, green: 54 / 255, blue: 55 / 255, alpha: 1)
  static let pressedColor = CGColor(srgbRed: 96 / 255, green: 95 / 255, blue: 98 / 255, alpha: 1)
  /// macOS's stock Expanded Control Strip, used when the user never customized theirs.
  static let defaultLayout = [
    "com.apple.system.brightness", "NSTouchBarItemIdentifierFlexibleSpace", "com.apple.system.mission-control",
    "com.apple.system.launchpad", "NSTouchBarItemIdentifierFlexibleSpace", "com.apple.system.group.keyboard-brightness",
    "NSTouchBarItemIdentifierFlexibleSpace", "com.apple.system.group.media", "NSTouchBarItemIdentifierFlexibleSpace",
    "com.apple.system.mute", "com.apple.system.volume", "NSTouchBarItemIdentifierFlexibleSpace", "com.apple.system.sleep",
  ]

  let scene: Scene
  /// Control Strip item ids to lay out instead of the user's own (the offline renderer uses the stock layout).
  var fixedLayout: [String]?
  /// The volume button's glyph shows the current level; refreshed twice a second.
  var volumeIcon: Icon = .volume

  private var buttons: [Button] = []
  private var pressed: Int?
  private var touchStates: [AnyHashable: TouchState] = [:]
  private var timer: Timer?
  private var fps: Double = 0
  private var lastTick: Double = 0
  private var lastFrameFull = true
  private var nextVolumeCheck: Double = 0
  private let volumeQueue = DispatchQueue(label: "dev.touchbarbuddies.volume", qos: .utility)
  private var laidOutWidth: CGFloat = -1
  private var popover: SliderPopover?     // brightness / volume slider, when open

  init(scene: Scene) {
    self.scene = scene
    super.init(frame: NSRect(x: 0, y: 0, width: 1004, height: 30))
    allowedTouchTypes = [.direct]
  }

  required init?(coder: NSCoder) { fatalError() }

  override var intrinsicContentSize: NSSize { NSSize(width: 1004, height: 30) }

  // MARK: Layout

  override func layout() {
    super.layout()
    if bounds.width != laidOutWidth { relayout() }
  }

  /// Lays the buttons out left to right, then gives the leftover width to the two buddy pockets.
  func relayout() {
    // Buttons are about to be rebuilt: forget presses in flight so no touch points at an old button index.
    pressed = nil
    touchStates = touchStates.filter { if case .button = $0.value.target { return false } else { return true } }
    laidOutWidth = bounds.width
    let ids = fixedLayout
      ?? (CFPreferencesCopyAppValue("FullCustomized" as CFString, "com.apple.controlstrip" as CFString) as? [String])
      ?? Self.defaultLayout

    // Each Control Strip item is a group of buttons (action, icon, width in points, and the gap between
    // them) or a flexible space. Anything we don't draw (Siri, screenshot…) is skipped.
    enum Segment { case group([(Action, Icon, CGFloat)], gap: CGFloat), flex }
    let segments: [Segment] = ids.compactMap { id in
      switch id {
      case "com.apple.system.brightness": return .group([(.brightness, .brightness, 72)], gap: 0)
      case "com.apple.system.mission-control": return .group([(.missionControl, .missionControl, 72)], gap: 0)
      case "com.apple.system.launchpad": return .group([(.launchpad, .launchpad, 72)], gap: 0)
      case "com.apple.system.group.keyboard-brightness": return .group([(.keyboardDown, .keyboardDown, 75), (.keyboardUp, .keyboardUp, 75)], gap: 1.5)
      case "com.apple.system.group.media": return .group([(.rewind, .rewind, 73), (.playPause, .playPause, 73), (.forward, .forward, 73)], gap: 2)
      case "com.apple.system.mute": return .group([(.mute, .mute, 72)], gap: 0)
      case "com.apple.system.volume": return .group([(.volume, .volume, 72)], gap: 0)
      case "com.apple.system.sleep": return .group([(.sleep, .sleep, 72)], gap: 0)
      case "com.apple.system.screen-lock": return .group([(.lock, .lock, 72)], gap: 0)
      case "NSTouchBarItemIdentifierFlexibleSpace": return .flex
      default: return nil
      }
    }
    // Fixed width: buttons, gaps inside groups, and the 16pt spacing between neighbouring groups.
    var fixed: CGFloat = 0
    var flexCount = 0
    var prevWasGroup = false
    for s in segments {
      switch s {
      case let .group(list, gap):
        fixed += list.map(\.2).reduce(0, +) + gap * CGFloat(list.count - 1) + (prevWasGroup ? 16 : 0)
        prevWasGroup = true
      case .flex:
        flexCount += 1
        prevWasGroup = false
      }
    }
    let spare = max(0, bounds.width - fixed)
    // The two buddy pockets get the room; any other gap shrinks to a sliver.
    let sliver: CGFloat = flexCount > 2 ? min(10, spare / CGFloat(flexCount * 3)) : 0
    let pocket = flexCount >= 2 ? (spare - sliver * CGFloat(flexCount - 2)) / 2 : spare / 2

    var x: CGFloat = 0
    var flexIndex = 0
    var codexPocket = CGRect.zero, clawdPocket = CGRect.zero
    buttons = []
    prevWasGroup = false
    for s in segments {
      switch s {
      case let .group(list, gap):
        if prevWasGroup { x += 16 }
        for (i, (action, icon, width)) in list.enumerated() {
          if i > 0 { x += gap }
          buttons.append(Button(action: action, icon: icon, rect: CGRect(x: x, y: 0, width: width, height: 30)))
          x += width
        }
        prevWasGroup = true
      case .flex:
        let isFirst = flexIndex == 0, isLast = flexIndex == flexCount - 1
        let w = flexCount == 1 ? pocket * 2 : (isFirst || isLast) ? pocket : sliver
        if flexCount == 1 {
          codexPocket = CGRect(x: x, y: 0, width: w / 2, height: 30)
          clawdPocket = CGRect(x: x + w / 2, y: 0, width: w / 2, height: 30)
        } else if isFirst {
          codexPocket = CGRect(x: x, y: 0, width: w, height: 30)
        } else if isLast {
          clawdPocket = CGRect(x: x, y: 0, width: w, height: 30)
        }
        x += w
        flexIndex += 1
        prevWasGroup = false
      }
    }
    scene.layout(codexPocket: codexPocket, clawdPocket: clawdPocket)
    needsDisplay = true
  }

  // MARK: Render loop

  // Battery: the loop runs only as fast as the scene needs (60 fps while things fly across the bar, 30 for hops and
  // sparkles, 12 for plain sprite animation — the art's own frame rate — and 10 while both sleep), and redraws just
  // the two pockets when nothing else moves. Nothing is skipped: every animation still plays at its own speed.

  /// Starts the animation loop (also stopped while the screen sleeps).
  func start() {
    guard timer == nil else { return }
    lastTick = CACurrentMediaTime()
    run(at: 30)
    needsDisplay = true
  }

  func stop() {
    timer?.invalidate()
    timer = nil
    fps = 0
  }

  private func run(at newFPS: Double) {
    guard newFPS != fps else { return }
    timer?.invalidate()
    let t = Timer(timeInterval: 1 / newFPS, repeats: true) { [weak self] _ in self?.tick() }
    t.tolerance = 0.05 / newFPS   // a little slack lets macOS batch wake-ups; more makes frames land unevenly
    RunLoop.main.add(t, forMode: .common)
    timer = t
    fps = newFPS
  }


  /// One animation frame: advance the scene, handle held fingers, and redraw if anything changed.
  private func tick() {
    let now = CACurrentMediaTime()
    // A frame arriving far too late means something blocked the main thread: log it (`./tbb logs`) to find out what.
    if fps > 0 && now - lastTick > max(0.15, 3 / fps) {
      NSLog("[hitch] frame %.0f ms late at %.0f fps", (now - lastTick - 1 / fps) * 1000, fps)
    }
    let dt = min(0.05, now - lastTick)
    lastTick = now
    scene.update(now, dt)

    // Secret: hold both buddies at the same time for a moment → both go ultra for a few seconds.
    var held: [Who: (key: AnyHashable, began: Double)] = [:]
    for (key, st) in touchStates {
      if case let .buddy(who) = st.target, !st.longFired, !st.moved { held[who] = (key, st.began) }
    }
    if held.count == 2, now - held.values.map(\.began).max()! > 0.8 {
      for h in held.values { touchStates[h.key]?.longFired = true }   // letting go is then neither a tap nor a long-press
      scene.ultraBoost()
    }

    for (key, st) in touchStates {
      // Long-press a buddy → bring its app forward.
      if case let .buddy(who) = st.target, !st.longFired, !st.moved, now - st.began > 0.6, held.count < 2 {
        touchStates[key]?.longFired = true
        scene.longPress(who)
      }
      // Holding a keyboard-backlight button repeats, like the hardware keys.
      if case let .button(i) = st.target, pressed == i, [.keyboardDown, .keyboardUp].contains(buttons[i].action),
         now - st.began > 0.45, now - st.lastRepeat > 0.11 {
        touchStates[key]?.lastRepeat = now
        fire(buttons[i].action)
      }
    }

    if let p = popover {
      if !p.touching && now - p.lastInteraction > 3.5 { p.close(now: now) }
      if p.isGone(now: now) { popover = nil }
    }
    if now > nextVolumeCheck {
      nextVolumeCheck = now + 0.5
      // CoreAudio can be slow to answer (e.g. while audio devices change), so ask off the main thread.
      volumeQueue.async { [weak self] in
        let icon = Self.icon(forVolume: SystemControls.volume, muted: SystemControls.muted)
        DispatchQueue.main.async {
          guard let self, icon != self.volumeIcon else { return }
          self.volumeIcon = icon
          self.needsDisplay = true
        }
      }
    }

    // Pick the frame rate and redraw area for the next frame (see the note above start()).
    let busy = !touchStates.isEmpty || popover != nil
    switch busy ? .lively : scene.pace {
    case .fast: run(at: 60)
    case .lively: run(at: 30)
    case .calm: run(at: 12)
    case .asleep: run(at: 10)
    }
    let full = busy || scene.drawsOutsidePockets
    if full || lastFrameFull {
      needsDisplay = true
    } else {
      scene.redrawAreas.forEach { setNeedsDisplay($0) }
    }
    lastFrameFull = full
  }

  private static func icon(forVolume v: Float, muted: Bool) -> Icon {
    if muted || v <= 0 { return .volume }
    return v < 0.34 ? .volume1 : v < 0.67 ? .volume2 : .volume3
  }

  // MARK: Drawing

  override func draw(_ dirtyRect: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.setFillColor(CGColor.black)
    ctx.fill(bounds)
    if let p = popover {
      p.draw(ctx, now: CACurrentMediaTime())
      return
    }
    for (i, b) in buttons.enumerated() {
      ctx.setFillColor(pressed == i ? Self.pressedColor : Self.buttonColor)
      ctx.addPath(CGPath(roundedRect: b.rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
      ctx.fillPath()
      ctx.interpolationQuality = .high
      ctx.draw(Icons.image(b.action == .volume ? volumeIcon : b.icon), in: CGRect(x: b.rect.midX - 36, y: 0, width: 72, height: 30))
    }
    scene.draw(ctx)
  }

  // MARK: Touches

  private func key(_ t: NSTouch) -> AnyHashable { AnyHashable(t.identity as! NSObject) }

  private func hit(_ p: CGPoint) -> Target {
    if popover != nil { return .popover }
    if let i = buttons.firstIndex(where: { $0.rect.contains(p) }) { return .button(i) }
    if scene.codex.pocket.contains(p) { return .buddy(.codex) }
    if scene.clawd.pocket.contains(p) { return .buddy(.clawd) }
    return .none
  }

  override func touchesBegan(with event: NSEvent) {
    let now = CACurrentMediaTime()
    for t in event.touches(matching: .began, in: self) {
      let p = t.location(in: self)
      var st = TouchState(target: hit(p), start: p, began: now)
      switch st.target {
      case let .button(i):
        pressed = i
        let a = buttons[i].action
        if a == .keyboardDown || a == .keyboardUp { fire(a); st.lastRepeat = now + 0.3 }
        if a == .brightness { st.startValue = SystemControls.brightness }
        if a == .volume { st.startValue = SystemControls.volume }
      case .popover:
        guard let pop = popover, pop.closedAt == nil else { break }
        if pop.hitsPanel(p) {
          pop.touching = true
          pop.slide(toX: p.x, now: now)
        } else {
          pop.close(now: now)   // the × or anywhere outside the panel
        }
      default: break
      }
      touchStates[key(t)] = st
    }
    needsDisplay = true
  }

  override func touchesMoved(with event: NSEvent) {
    for t in event.touches(matching: .moved, in: self) {
      guard let st = touchStates[key(t)] else { continue }
      let p = t.location(in: self)
      let dx = p.x - st.start.x
      if abs(dx) > 6 { touchStates[key(t)]?.moved = true }
      switch st.target {
      case let .button(i):
        let a = buttons[i].action
        if (a == .brightness || a == .volume) && abs(dx) > 6 {
          // Press and slide: the slider opens under your finger and follows it 1:1.
          if popover == nil { openPopover(a, from: buttons[i].rect, animated: false) }
          popover?.touching = true
          popover?.set(st.startValue + Float(dx / SliderPopover.trackLength), now: CACurrentMediaTime())
          pressed = nil
        } else if pressed == i, !buttons[i].rect.insetBy(dx: -8, dy: -8).contains(p) {
          pressed = nil   // sliding off a button cancels it, like a normal button
        }
      case .popover:
        if let pop = popover, pop.touching { pop.slide(toX: p.x, now: CACurrentMediaTime()) }
      default: break
      }
    }
    needsDisplay = true
  }

  override func touchesEnded(with event: NSEvent) {
    for t in event.touches(matching: .ended, in: self) {
      guard let st = touchStates.removeValue(forKey: key(t)) else { continue }
      switch st.target {
      case let .button(i):
        let a = buttons[i].action
        if pressed == i && a != .keyboardDown && a != .keyboardUp { fire(a) }
        if pressed == i { pressed = nil }
        popover?.touching = false
      case let .buddy(who):
        if !st.longFired && !st.moved { scene.tap(who) }
      case .popover:
        popover?.touching = false
      case .none:
        break
      }
    }
    needsDisplay = true
  }

  override func touchesCancelled(with event: NSEvent) {
    for t in event.touches(matching: .cancelled, in: self) { touchStates.removeValue(forKey: key(t)) }
    pressed = nil
    popover?.touching = false
    needsDisplay = true
  }

  func openPopover(_ a: Action, from button: CGRect, animated: Bool) {
    popover = SliderPopover(a == .brightness ? .brightness : .volume, from: button, barWidth: bounds.width,
                            now: CACurrentMediaTime(), animated: animated)
    needsDisplay = true
  }

  /// For the debug command channel.
  func openPopover(volume: Bool) {
    let a: Action = volume ? .volume : .brightness
    if let b = buttons.first(where: { $0.action == a }) { openPopover(a, from: b.rect, animated: true) }
  }

  private func fire(_ a: Action) {
    switch a {
    case .brightness, .volume:
      if let b = buttons.first(where: { $0.action == a }) { openPopover(a, from: b.rect, animated: true) }
    case .missionControl: SystemControls.missionControl()
    case .launchpad: SystemControls.launchpad()
    case .keyboardDown: SystemControls.stepKeyboard(up: false)
    case .keyboardUp: SystemControls.stepKeyboard(up: true)
    case .rewind: SystemControls.media(.previous)
    case .playPause: SystemControls.media(.playPause); scene.notes()
    case .forward: SystemControls.media(.next)
    case .mute: SystemControls.muted.toggle()
    case .sleep: SystemControls.sleep()
    case .lock: SystemControls.lockScreen()
    }
  }
}
