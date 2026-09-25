import AppKit

enum Who { case clawd, codex }

/// One scripted beat of a buddy's life: play a clip, optionally walk somewhere, hop, wait for a condition.
struct Step {
  var clip: Clip? = nil
  var loop = false
  var hold: Double = 0                 // seconds (0 = play the clip once / until arrival)
  var moveTo: CGFloat? = nil
  var speed: CGFloat = 0
  var run = false                      // use the walk/run clip that matches the direction
  var face: CGFloat? = nil             // turn toward this x when the step starts
  var hopV: CGFloat = 0
  var clipRect: CGRect? = nil          // hide anything outside (used to peek from behind a button)
  var leftEdge: CGFloat? = nil         // draw with the frame's left edge here (Clawd's peek)
  var until: (() -> Bool)? = nil
  var onStart: (() -> Void)? = nil
  var onEnd: (() -> Void)? = nil
}

final class Buddy {
  let who: Who
  var pocket = CGRect.zero
  var x: CGFloat = 0
  var hop: CGFloat = 0
  var hopV: CGFloat = 0
  var facingLeft = false
  var queue: [Step] = []
  var step: Step?
  var stepStart: Double = 0
  var state = AgentState()
  var launching = false
  var taps: [Double] = []
  var nextIdle: Double = 3
  var nextBlink: Double = 2
  var still: Clip? = nil               // temporary idle expression (blink / glance)
  var stillUntil: Double = 0
  var shakeUntil: Double = 0
  var lastZ: Double = 0

  init(_ who: Who) { self.who = who }

  enum Base { case sleep, idle, work }
  var base: Base { !state.present ? .sleep : state.working ? .work : .idle }
  var busy: Bool { step != nil || !queue.isEmpty }
  var home: CGFloat { pocket.midX + (who == .clawd && base == .work ? -5 : 0) }
  var inPocket: Bool { abs(x - pocket.midX) < pocket.width / 2 + 4 }

  func enqueue(_ steps: [Step]) { queue.append(contentsOf: steps) }

  func interrupt() {
    queue.removeAll()
    step = nil
  }

  func update(_ now: Double, _ dt: Double) {
    if hop > 0 || hopV > 0 {
      hopV -= 520 * CGFloat(dt)
      hop += hopV * CGFloat(dt)
      if hop <= 0 { hop = 0; hopV = 0 }
    }
    if step == nil { advance(now) }
    guard let s = step else { return }
    if let tx = s.moveTo {
      let dx = tx - x
      let stride = s.speed * CGFloat(dt)
      x = abs(dx) <= stride ? tx : x + (dx > 0 ? stride : -stride)
      if abs(dx) > 0.5 { facingLeft = dx < 0 }
    }
    let t = now - stepStart
    let done: Bool
    if let until = s.until { done = until() || (s.hold > 0 && t >= s.hold) }
    else if let tx = s.moveTo, s.hold == 0 { done = abs(x - tx) < 0.01 }
    else if s.hold > 0 { done = t >= s.hold }
    else { done = t >= (s.clip?.total ?? 0) }
    if done {
      step = nil
      s.onEnd?()
      advance(now)
    }
  }

  private func advance(_ now: Double) {
    guard step == nil, !queue.isEmpty else { return }
    let s = queue.removeFirst()
    step = s
    stepStart = now
    if let f = s.face, abs(f - x) > 1 { facingLeft = f < x }
    if s.hopV > 0 { hopV = s.hopV; hop = max(hop, 0.01) }
    s.onStart?()
  }
}

// MARK: - Effects

enum Effect {
  case bitmap([String], CGColor)
  case glyph(String, CGColor, CGFloat)
}

struct Particle {
  var effect: Effect
  var x, y, vx, vy: CGFloat
  var life: Double
  var age: Double = 0
  var gravity: CGFloat = 0
  var size: CGFloat = 1
}

struct Projectile {
  var effect: Effect
  var from, to: CGPoint
  var start: Double
  var duration: Double
  var arc: CGFloat
  var wobble: CGFloat = 0
  var onArrive: (() -> Void)?
}

// MARK: - Scene

final class Scene {
  var bank: Bank                       // swapped by "Rebuild Sprites"
  let clawd = Buddy(.clawd)
  let codex = Buddy(.codex)
  let ground: CGFloat = 1
  var now: Double = 0
  var roaming = true
  /// Offline renders (Render.swift): no random idle habits or games, so only the commands you ask for play.
  var scripted = false
  var onLaunch: ((Who) -> Void)?
  var onFocus: ((Who) -> Void)?

  private var particles: [Particle] = []
  private var projectiles: [Projectile] = []
  private var timers: [(at: Double, run: () -> Void)] = []
  private var interacting = false
  private var nextInteraction: Double = 12
  private var laidOut = false

  init(bank: Bank) { self.bank = bank }

  var animating: Bool {
    !projectiles.isEmpty || !particles.isEmpty || !clawd.inPocket || !codex.inPocket
  }

  func layout(codexPocket: CGRect, clawdPocket: CGRect) {
    codex.pocket = codexPocket
    clawd.pocket = clawdPocket
    if !laidOut || !codex.busy { codex.x = codex.home }
    if !laidOut || !clawd.busy { clawd.x = clawd.home }
    laidOut = true
  }

  func after(_ delay: Double, _ run: @escaping () -> Void) { timers.append((now + delay, run)) }

  private func other(_ b: Buddy) -> Buddy { b === clawd ? codex : clawd }

  /// A buddy whose sprites couldn't be extracted stays asleep and hidden (never drawn, never tapped).
  func has(_ b: Buddy) -> Bool { b.who == .clawd ? bank.hasClawd : bank.hasCodex }

  // MARK: Agent state

  func setState(_ b: Buddy, _ s: AgentState) {
    guard has(b) else { return }
    let old = b.state
    b.state = s
    if s.present != old.present {
      if s.present { arrive(b) } else { fallAsleep(b) }
      return
    }
    if s.present && s.working != old.working {
      s.working ? startWork(b) : finishWork(b)
    }
  }

  private func arrive(_ b: Buddy) {
    guard !b.launching else { return }       // the launch script is already playing the entrance
    b.interrupt()
    b.x = b.home
    if b.who == .clawd {
      // Clawd's "load in" animation from the Claude app: hops on a little cloud, then off again.
      b.enqueue([Step(clip: bank.cCloudIntro)])
    } else {
      b.enqueue([Step(clip: bank.xJump), Step(clip: bank.xWave, loop: true, hold: bank.xWave.total * 2)])
    }
    if b.state.working { startWork(b) }
  }

  private func fallAsleep(_ b: Buddy) {
    guard !b.launching else { return }
    b.interrupt()
    b.x = b.home
    b.hop = 0
    puff(at: CGPoint(x: b.x, y: ground + 6), color: Palette.white)
  }

  private func startWork(_ b: Buddy) {
    if !b.inPocket {
      b.interrupt()
      b.enqueue([Step(moveTo: b.home, speed: 160, run: true)])
    }
    b.enqueue([Step(moveTo: b.home, speed: 40, run: true)])
    if b.who == .clawd { b.enqueue([Step(clip: bank.cWorkIn, face: b.home + 50)]) }
    else { b.enqueue([Step(clip: bank.xJump)]) }
  }

  private func finishWork(_ b: Buddy) {
    if b.who == .clawd {
      b.enqueue([Step(clip: bank.cWorkOut), happyHop(b), happyHop(b)])
    } else {
      b.enqueue([Step(clip: bank.xReview), Step(clip: bank.xReview)])
    }
    confetti(at: CGPoint(x: b.x, y: 16))
    let o = other(b)
    if o.base == .idle && !o.busy && !interacting {
      after(0.7) { o.enqueue([self.cheer(o, toward: b)]) }
    }
  }

  // MARK: Touch

  func tap(_ who: Who) {
    let b = who == .clawd ? clawd : codex
    guard has(b) else { return }
    guard b.state.appRunning else { launch(b); return }
    b.taps = b.taps.filter { now - $0 < 1.5 } + [now]
    if b.base == .work {
      // Don't break their focus — a little hop and a heart.
      b.hopV = 45; b.hop = max(b.hop, 0.01)
      emit(.bitmap(Sprite.heart, Palette.heart), at: CGPoint(x: b.x + 6, y: 20), vy: 16)
      return
    }
    if b.taps.count >= 4 {
      b.taps.removeAll()
      b.interrupt()
      if b.who == .codex {
        b.enqueue([Step(clip: bank.xFailed)])
      } else {
        b.shakeUntil = now + 1.0
        var dizzy = bank.cLookL
        dizzy.frames = [bank.cLookL.frames[0], bank.cLookR.frames[0]]
        dizzy.durations = [0.07, 0.07]
        b.enqueue([Step(clip: dizzy, loop: true, hold: 1.0)])
      }
      for i in 0..<5 {
        after(Double(i) * 0.15) { self.emit(.bitmap(Sprite.star, Palette.gold), at: CGPoint(x: b.x + .random(in: -8...8), y: 22), vx: .random(in: -12...12), vy: 10) }
      }
      return
    }
    b.interrupt()
    b.enqueue(b.who == .codex ? [Step(clip: bank.xJump)] : [Step(clip: bank.cSquat, hold: 0.08), happyHop(b)])
    emit(.bitmap(Sprite.heart, Palette.heart), at: CGPoint(x: b.x + 8, y: 21), vy: 18)
  }

  func longPress(_ who: Who) {
    let b = who == .clawd ? clawd : codex
    guard has(b) else { return }
    guard b.state.appRunning else { launch(b); return }
    onFocus?(who)
    guard b.base != .work else { return }
    b.interrupt()
    b.enqueue([waveStep(b, toward: b.x - 1)])
  }

  /// Tapping a sleeping buddy opens its app; the buddy plays its entrance until the app is up.
  private func launch(_ b: Buddy, open: Bool = true) {
    guard !b.launching else { return }
    b.launching = true
    b.interrupt()
    b.x = b.home
    if open { onLaunch?(b.who) }
    let t0 = now
    let ready = { [unowned self] in b.state.appRunning && self.now - t0 > 1.4 }
    if b.who == .codex {
      // Same hop the Codex pet does when you hover it.
      b.enqueue([Step(clip: bank.xJump, loop: true, hold: 30, until: ready),
                 Step(clip: bank.xWave, loop: true, hold: bank.xWave.total * 2, onEnd: { b.launching = false })])
    } else {
      b.enqueue([Step(clip: bank.cCloudMount),
                 Step(clip: bank.cCloudRide, loop: true, hold: 30, until: ready),
                 Step(clip: bank.cCloudDismount),
                 Step(clip: bank.cHappy, hold: 0.6, hopV: 60, onEnd: { b.launching = false })])
    }
    sparkle(at: CGPoint(x: b.x, y: 20))
  }

  /// Play/pause pressed: a little burst of music notes and a bop.
  func notes() {
    for b in [clawd, codex] where b.base != .sleep {
      for i in 0..<3 {
        after(Double(i) * 0.25) {
          self.emit(.bitmap(Sprite.note, Palette.white), at: CGPoint(x: b.x + .random(in: -8...8), y: 18), vx: .random(in: -6...6), vy: 12, life: 1.2)
        }
      }
      if !b.busy && b.base == .idle { b.enqueue(hopSteps(b)) }
    }
  }

  /// Named triggers for testing / scripting:
  /// `swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("dev.touchbarbuddies.command"), object: "toss", userInfo: nil, deliverImmediately: true)'`
  func command(_ cmd: String) {
    let (a, b) = (codex, clawd)
    func go(_ f: () -> Void) { guard has(a) && has(b) else { return }; a.interrupt(); b.interrupt(); begin(); f() }
    switch cmd {
    case "play": playTogether()
    case "wave": go { waveHello(a, b) }
    case "toss": go { toss(a, b, volleys: 3) }
    case "plane": go { paperPlane(b, a) }
    case "echo": go { echoHops(a, b, rounds: 2) }
    case "packets": go { packets() }
    case "peek": go { peekaboo(); after(6.5) { self.end() } }
    case "visit-clawd": go { clawdVisits() }
    case "visit-codex": go { codexVisits() }
    case "visit-clawd-car": go { clawdVisits(car: true) }
    case "visit-clawd-cloud": go { clawdVisits(car: false) }
    case "tap-clawd": tap(.clawd)
    case "tap-codex": tap(.codex)
    case "launch-clawd": launch(clawd, open: false)
    case "launch-codex": launch(codex, open: false)
    case "notes": notes()
    default: break
    }
  }

  func playTogether() {
    nextInteraction = now
    if interacting { return }
    if clawd.base == .idle && codex.base == .idle { startInteraction() }
  }

  // MARK: Update

  func update(_ t: Double, _ dt: Double) {
    now = t
    let due = timers.filter { $0.at <= now }
    timers.removeAll { $0.at <= now }
    due.forEach { $0.run() }

    for b in [clawd, codex] where has(b) {
      b.update(now, dt)
      if !scripted && !b.busy && b.base == .idle && !interacting { idleHabits(b) }
      if b.base == .sleep && !b.busy && now - b.lastZ > 1.8 {
        b.lastZ = now
        emit(.bitmap(Sprite.zed, Palette.white), at: CGPoint(x: b.x + 9, y: b.who == .clawd ? 11 : 18), vx: 6, vy: 5, life: 2.2, size: 0.75)
      }
      if b.who == .codex && b.base == .work && !b.busy && Int(now * 10) % 9 == 0 && Double.random(in: 0...1) < 0.2 {
        let bits = ["{", "}", "(", ")", ";"]   // one consistent set of code-ish symbols
        emit(.glyph(bits.randomElement()!, Palette.codexLight, 6), at: CGPoint(x: b.x + 10, y: 12), vx: .random(in: 2...8), vy: 9, life: 1.4)
      }
    }
    if !scripted && !interacting && now > nextInteraction { direct() }

    for i in particles.indices {
      particles[i].age += dt
      particles[i].vy -= particles[i].gravity * CGFloat(dt)
      particles[i].x += particles[i].vx * CGFloat(dt)
      particles[i].y += particles[i].vy * CGFloat(dt)
    }
    particles.removeAll { $0.age >= $0.life }
    let landed = projectiles.filter { now - $0.start >= $0.duration }
    projectiles.removeAll { now - $0.start >= $0.duration }
    landed.forEach { $0.onArrive?() }
  }

  private func idleHabits(_ b: Buddy) {
    if b.who == .clawd && now > b.nextBlink {
      b.still = bank.cBlink
      b.stillUntil = now + 0.13
      b.nextBlink = now + (Double.random(in: 0...1) < 0.2 ? 0.3 : .random(in: 2.2...5.5))
    }
    guard now > b.nextIdle else { return }
    b.nextIdle = now + .random(in: 4...10)
    let r = Double.random(in: 0...1)
    let lo = b.pocket.minX + 13, hi = max(lo, b.pocket.maxX - 13)
    if b.who == .clawd {
      switch r {
      case ..<0.30:
        b.still = Bool.random() ? bank.cLookL : bank.cLookR
        b.stillUntil = now + .random(in: 0.8...1.8)
      case ..<0.55: b.enqueue(stroll(b, to: .random(in: lo...hi)))
      case ..<0.67: b.enqueue([Step(clip: bank.cSquat, hold: 0.08), happyHop(b)])
      case ..<0.77: b.enqueue([waveStep(b, toward: codex.x)])
      case ..<0.84: peekaboo()
      default: break
      }
    } else {
      switch r {
      case ..<0.30:
        let dirs: [CGFloat] = [90, 45, 0, 315, 270, 135]
        let pick = Array(dirs.shuffled().prefix(3))
        b.enqueue(pick.map { Step(clip: bank.codexLook(degrees: $0), hold: .random(in: 0.5...1.1)) })
      case ..<0.55: b.enqueue(stroll(b, to: .random(in: lo...hi)))
      case ..<0.68: b.enqueue([Step(clip: bank.xWaiting, loop: true, hold: .random(in: 2.5...4))])
      case ..<0.78: b.enqueue([Step(clip: bank.xJump)])
      case ..<0.86: b.enqueue([waveStep(b, toward: clawd.x)])
      default: break
      }
    }
  }

  // MARK: Director

  private func direct() {
    let c = clawd, x = codex
    let free = { (b: Buddy) in !b.busy && !b.launching }
    if c.base == .idle && x.base == .idle && free(c) && free(x) {
      startInteraction()
    } else if c.base == .work && x.base == .idle && free(x) {
      support(x, worker: c)
    } else if x.base == .work && c.base == .idle && free(c) {
      support(c, worker: x)
    } else {
      nextInteraction = now + 5
    }
  }

  private func begin() { interacting = true }
  private func end() {
    interacting = false
    nextInteraction = now + .random(in: 14...30)
  }

  private func startInteraction() {
    begin()
    let (a, b) = Bool.random() ? (clawd, codex) : (codex, clawd)
    var options: [(Double, () -> Void)] = [
      (18, { self.waveHello(a, b) }),
      (22, { self.toss(a, b, volleys: .random(in: 3...5)) }),
      (12, { self.paperPlane(a, b) }),
      (12, { self.echoHops(a, b, rounds: 2) }),
      (12, { self.packets() }),
      (8, { self.peekaboo(); self.after(6.5) { self.end() } }),
    ]
    // Visits: Codex's run comes up as often as Clawd's kart/cloud trips.
    if roaming { options += [(8, { self.clawdVisits() }), (8, { self.codexVisits() })] }
    var r = Double.random(in: 0..<options.map(\.0).reduce(0, +))
    for (w, run) in options {
      if r < w { run(); return }
      r -= w
    }
    options[0].1()
  }

  private func support(_ helper: Buddy, worker: Buddy) {
    begin()
    switch Int.random(in: 0..<3) {
    case 0:
      helper.enqueue([cheer(helper, toward: worker)])
      after(1.2) { self.end() }
    case 1:
      helper.enqueue(throwSteps(helper, toward: worker))
      after(0.3) {
        self.throwThing(.bitmap(Sprite.heart, Palette.heart), from: helper, to: worker, arc: 8) {
          worker.hopV = 40; worker.hop = max(worker.hop, 0.01)
          self.sparkle(at: CGPoint(x: worker.x, y: 20))
          self.end()
        }
      }
    default:
      let watch: Step = helper.who == .codex
        ? Step(clip: bank.xWaiting, loop: true, hold: 3.5)
        : Step(clip: worker.x < helper.x ? bank.cLookL : bank.cLookR, hold: 3)
      helper.enqueue([watch])
      after(3.6) { self.end() }
    }
  }

  // MARK: Interactions

  private func waveHello(_ a: Buddy, _ b: Buddy) {
    a.enqueue([waveStep(a, toward: b.x)])
    after(0.8) {
      b.enqueue([self.waveStep(b, toward: a.x)])
      self.emit(.bitmap(Sprite.heart, Palette.heart), at: CGPoint(x: b.x, y: 22), vy: 14)
      self.after(1.6) { self.end() }
    }
  }

  private func toss(_ a: Buddy, _ b: Buddy, volleys: Int) {
    a.enqueue(throwSteps(a, toward: b))
    after(windup) {
      self.throwThing(.bitmap(Sprite.ball, a.who == .clawd ? Palette.clawd : Palette.codex), from: a, to: b, arc: 9) {
        b.enqueue(self.catchSteps(b))
        self.emit(.bitmap(Sprite.star, Palette.gold), at: self.hand(b, toward: a), vy: 12, life: 0.5)
        if volleys > 1 {
          self.after(0.5) { self.toss(b, a, volleys: volleys - 1) }
        } else {
          self.after(0.6) {
            a.enqueue([self.happyHop(a)])
            b.enqueue([self.happyHop(b)])
            self.end()
          }
        }
      }
    }
  }

  private func paperPlane(_ a: Buddy, _ b: Buddy) {
    a.enqueue(throwSteps(a, toward: b))
    after(windup) {
      self.throwThing(.bitmap(Sprite.plane, Palette.white), from: a, to: b, arc: 6, slow: 1.7, wobble: 3) {
        b.enqueue(self.catchSteps(b))
        for i in 0..<3 { self.after(Double(i) * 0.2) { self.emit(.bitmap(Sprite.heart, Palette.heart), at: CGPoint(x: b.x + .random(in: -6...6), y: 20), vy: 14) } }
        self.after(1.2) { self.end() }
      }
    }
  }

  private func echoHops(_ a: Buddy, _ b: Buddy, rounds: Int) {
    var t = 0.0
    for r in 1...rounds {
      for (who, delay) in [(a, 0.0), (b, 0.7)] {
        after(t + delay) {
          who.enqueue(Array(repeating: self.hopSteps(who), count: r).flatMap { $0 })
          self.emit(.bitmap(Sprite.bang, Palette.gold), at: CGPoint(x: who.x + 9, y: 22), vy: 8, life: 0.6)
        }
      }
      t += 1.6 + 0.4 * Double(r)
    }
    after(t + 0.6) { self.end() }
  }

  private func packets() {
    let (x, c) = (codex, clawd)
    x.enqueue(throwSteps(x, toward: c))
    after(windup) {
      self.throwThing(.glyph(">_", Palette.codexLight, 8), from: x, to: c, arc: 5) {
        c.enqueue(self.catchSteps(c))
        self.after(0.6) {
          c.enqueue(self.throwSteps(c, toward: x))
          self.after(self.windup) {
            self.throwThing(.glyph("✻", Palette.clawd, 10), from: c, to: x, arc: 5) {
              x.enqueue([Step(clip: self.bank.xReview)])
              self.after(1.0) { self.end() }
            }
          }
        }
      }
    }
  }

  /// Clawd ducks behind the button on his left, then peeks back out (Claude's "lurking" animation).
  private func peekaboo() {
    let c = clawd, edge = c.pocket.minX
    c.enqueue([
      Step(moveTo: edge - 13, speed: 30, run: true, clipRect: c.pocket),
      Step(clip: bank.cLurk, clipRect: c.pocket, leftEdge: edge),
      Step(clip: bank.cStand, hold: 0.4, clipRect: CGRect(x: edge, y: 0, width: 0, height: 0)),
      Step(moveTo: c.pocket.midX, speed: 30, run: true, clipRect: c.pocket),
    ])
    if codex.base == .idle && !codex.busy {
      after(1.2) { self.codex.enqueue([Step(clip: self.bank.codexLook(degrees: 90), hold: 3.5), Step(clip: self.bank.xReview)]) }
    }
  }

  /// Clawd crosses the bar to visit — in his racing kart or on his cloud.
  private func clawdVisits(car: Bool = .random()) {
    let c = clawd, x = codex
    let spot = x.x + 34
    func trip(to target: CGFloat) -> [Step] {
      car ? [Step(clip: bank.cRaceIn, face: target, onEnd: { self.puff(at: CGPoint(x: c.x, y: 6), color: Palette.white) }),
             Step(clip: bank.cRaceDrive, loop: true, moveTo: target, speed: 250),
             Step(clip: bank.cRaceOut, onStart: { self.puff(at: CGPoint(x: c.x, y: 6), color: Palette.white) })]
          : [Step(clip: bank.cCloudMount, face: target),
             Step(clip: bank.cCloudRide, loop: true, moveTo: target, speed: 170),
             Step(clip: bank.cCloudDismount)]
    }
    let meet = Step(clip: bank.cHappy, hold: 0.9, face: x.x, hopV: 60, onStart: {
      self.highFive(between: c, x)
      x.enqueue([Step(clip: self.bank.xReview), Step(clip: self.bank.xWave)])
    })
    c.enqueue(trip(to: spot) + [meet, waveStep(c, toward: x.x)] + trip(to: c.pocket.midX) + [Step(clip: bank.cHappy, hold: 0.4, onEnd: { self.end() })])
  }

  /// Codex runs over on foot to visit: a dusty take-off, a jumping high-five, a wave goodbye, and home again.
  private func codexVisits() {
    let c = clawd, x = codex
    let side: CGFloat = x.x < c.x ? -1 : 1        // which side of Clawd he stops on
    let spot = c.x + side * 23                     // close enough to slap hands, without the two overlapping
    let look = side < 0 ? bank.cLookL : bank.cLookR
    // Clawd's reactions are cued by Codex's beats so they stay in sync (unless Clawd got called away to work).
    func cue(_ steps: [Step]) -> () -> Void {
      { if c.base == .idle { c.interrupt(); c.enqueue(steps) } }
    }
    let meet = [
      // Both arms up and a hop; the hands meet at the top of it.
      Step(clip: bank.xReview.still(2), hold: 0.35, hopV: 45, onStart: { self.after(0.1) { self.highFive(between: x, c) } }),
      Step(clip: bank.xReview.slice(3...5), onStart: cue([happyHop(c)])),
      Step(clip: bank.xWave, loop: true, hold: bank.xWave.total * 2, onStart: cue([waveStep(c, toward: spot)])),
    ]
    x.enqueue(dash(x, from: x.x, to: spot,
                   onBrake: cue([Step(clip: look, hold: 3)]),                        // Clawd spots him coming
                   onStop: cue([armsUp(c, toward: x, hold: 3)]))                     // and raises a claw
              + meet
              + dash(x, from: spot, to: x.pocket.midX,
                     onGo: { if c.base == .idle { c.enqueue([Step(clip: look, hold: 1.5)]) } },   // watches him go
                     onStop: { self.end() }))
  }

  /// Codex's run from one spot to another: a dust puff as he takes off, legs striding in time with his speed,
  /// then slowing steps into a stop exactly on `to`.
  private func dash(_ b: Buddy, from: CGFloat, to: CGFloat, onGo: (() -> Void)? = nil,
                    onBrake: (() -> Void)? = nil, onStop: (() -> Void)? = nil) -> [Step] {
    let dir: CGFloat = to >= from ? 1 : -1
    let row = dir > 0 ? bank.xRunR : bank.xRunL
    let fast: CGFloat = 130, slow: CGFloat = 45
    let brakeAt = abs(to - from) > 30 ? to - dir * 14 : from   // too short a hop to bother slowing down
    // The four stride frames (leg forward, pass, other leg, pass), one per ~8pt travelled so the feet keep up
    // with the ground instead of skating. The sheet's own timing is for running in place.
    func legs(_ speed: CGFloat) -> Clip {
      var c = row.slice(2...5)
      c.durations = Array(repeating: Double(8 / speed), count: c.frames.count)
      return c
    }
    let feet = { (ahead: CGFloat) in CGPoint(x: b.x + dir * ahead, y: self.ground + 3) }
    return [
      Step(clip: row.still(1), hold: 0.12, onStart: onGo),                               // lean into the first step
      Step(clip: legs(fast), loop: true, moveTo: brakeAt, speed: fast,
           onStart: { self.puff(at: feet(-6), color: Palette.white) }),
      Step(clip: legs(slow), loop: true, moveTo: to, speed: slow,
           onStart: { self.puff(at: feet(6), color: Palette.white); onBrake?() }),
      Step(clip: row.still(7), hold: 0.2, onStart: onStop),                             // planted, facing where he ran
    ]
  }

  // MARK: Step builders

  private func happyHop(_ b: Buddy) -> Step {
    b.who == .clawd ? Step(clip: bank.cHappy, hold: 0.45, hopV: 62) : Step(clip: bank.xJump)
  }

  /// Wander to a spot, hang out for a moment, then walk back to the middle of the pocket.
  private func stroll(_ b: Buddy, to x: CGFloat) -> [Step] {
    [Step(moveTo: x, speed: 18, run: true), Step(hold: .random(in: 1...2.5)), Step(moveTo: b.home, speed: 18, run: true)]
  }

  private func hopSteps(_ b: Buddy) -> [Step] {
    b.who == .clawd ? [Step(clip: bank.cSquat, hold: 0.08), happyHop(b)] : [Step(clip: bank.xJump)]
  }

  private func waveStep(_ b: Buddy, toward x: CGFloat) -> Step {
    b.who == .clawd ? Step(clip: bank.cWave, face: x) : Step(clip: bank.xWave, loop: true, hold: bank.xWave.total * 2)
  }

  private func cheer(_ b: Buddy, toward w: Buddy) -> Step {
    sparkle(at: CGPoint(x: b.x, y: 22))
    return b.who == .clawd ? waveStep(b, toward: w.x) : Step(clip: bank.xJump)
  }

  /// Seconds between the start of a throw and the moment the thing leaves the thrower's hands.
  private let windup = 0.35

  /// Arms up (wind-up), then the throw.
  private func throwSteps(_ b: Buddy, toward o: Buddy) -> [Step] {
    [armsUp(b, toward: o, hold: windup),
     b.who == .clawd ? Step(clip: bank.cSquat, hold: 0.14, face: o.x) : Step(clip: bank.xWave.slice(3...3))]
  }

  /// Arms raised — one arm for the wind-up, both arms (Codex) to get ready to catch.
  private func armsUp(_ b: Buddy, toward o: Buddy, hold: Double, catching: Bool = false) -> Step {
    if b.who == .clawd { return Step(clip: bank.cWave.still(6), hold: hold, face: o.x) }
    return Step(clip: catching ? bank.xReview.still(2) : bank.xWave.still(2), hold: hold)
  }

  private func catchSteps(_ b: Buddy) -> [Step] {
    b.who == .clawd ? [Step(clip: bank.cHappy, hold: 0.45, hopV: 55)] : [Step(clip: bank.xJump)]
  }

  // MARK: Effects

  private func hand(_ b: Buddy, toward o: Buddy) -> CGPoint {
    CGPoint(x: b.x + (o.x < b.x ? -10 : 10), y: ground + (b.who == .clawd ? 11 : 13))
  }

  private func makeProjectile(_ e: Effect, from a: Buddy, to b: Buddy, arc: CGFloat) -> Projectile {
    let p0 = hand(a, toward: b), p1 = hand(b, toward: a)
    return Projectile(effect: e, from: p0, to: p1, start: now, duration: Double(max(0.6, abs(p1.x - p0.x) / 430)), arc: arc)
  }

  /// Throw something from `a` to `b`. The catcher raises its arms just before it lands.
  private func throwThing(_ e: Effect, from a: Buddy, to b: Buddy, arc: CGFloat, slow: Double = 1, wobble: CGFloat = 0,
                          onArrive: @escaping () -> Void) {
    var p = makeProjectile(e, from: a, to: b, arc: arc)
    p.duration *= slow
    p.wobble = wobble
    p.onArrive = onArrive
    projectiles.append(p)
    if b.base == .idle {
      after(max(0, p.duration - 0.5)) { b.enqueue([self.armsUp(b, toward: a, hold: 0.5, catching: true)]) }
    }
  }

  private func emit(_ e: Effect, at p: CGPoint, vx: CGFloat = 0, vy: CGFloat = 12, life: Double = 1.1, size: CGFloat = 1) {
    particles.append(Particle(effect: e, x: p.x, y: p.y, vx: vx, vy: vy, life: life, size: size))
  }

  private func sparkle(at p: CGPoint) {
    for _ in 0..<4 {
      emit(.bitmap(Sprite.star, Palette.gold), at: CGPoint(x: p.x + .random(in: -9...9), y: p.y + .random(in: -3...3)),
           vx: .random(in: -10...10), vy: .random(in: 4...14), life: 0.7)
    }
  }

  private func puff(at p: CGPoint, color: CGColor) {
    for i in 0..<5 {
      let a = Double(i) / 5 * 2 * .pi
      emit(.bitmap(Sprite.dust, color), at: p, vx: CGFloat(cos(a)) * 18, vy: CGFloat(sin(a)) * 10 + 4, life: 0.45, size: 0.75)
    }
  }

  private func confetti(at p: CGPoint) {
    for _ in 0..<18 {
      var q = Particle(effect: .bitmap(["#"], Palette.confetti.randomElement()!), x: p.x, y: p.y,
                       vx: .random(in: -38...38), vy: .random(in: 30...75), life: .random(in: 0.9...1.5))
      q.gravity = 110
      particles.append(q)
    }
  }

  private func highFive(between a: Buddy, _ b: Buddy) {
    let mid = CGPoint(x: (a.x + b.x) / 2, y: 20)
    emit(.bitmap(Sprite.spark, Palette.gold), at: mid, vy: 4, life: 0.6)
    sparkle(at: mid)
  }

  // MARK: Drawing

  func draw(_ ctx: CGContext) {
    let order = [clawd, codex].sorted { ($0.inPocket ? 0 : 1) < ($1.inPocket ? 0 : 1) }
    for b in order where has(b) { drawBuddy(b, ctx) }
    for p in projectiles { drawProjectile(p, ctx) }
    for p in particles { drawParticle(p, ctx) }
  }

  private func drawBuddy(_ b: Buddy, _ ctx: CGContext) {
    let t = now - b.stepStart
    var clip: Clip
    var frame = 0
    var drawX = b.x
    var alpha: CGFloat = 1
    var squash: CGFloat = 1
    var mirror = false

    if let s = b.step, s.run || s.clip != nil {
      if s.run {
        let speedUp = Double(max(1, s.speed / 60))
        clip = b.who == .clawd ? bank.cScuttle.speed(speedUp) : (b.facingLeft ? bank.xRunL : bank.xRunR).speed(speedUp)
        frame = clip.index(at: t, loop: true)
      } else {
        clip = s.clip!
        frame = clip.index(at: t, loop: s.loop)
      }
      mirror = b.who == .clawd && b.facingLeft && clip.facesRight
      if let edge = s.leftEdge { drawX = edge + clip.anchorX }
      if let r = s.clipRect { ctx.saveGState(); ctx.clip(to: r) }
    } else {
      switch b.base {
      case .sleep:
        alpha = 0.8
        if b.who == .clawd {
          clip = Int(now / 1.4) % 2 == 0 ? bank.cLoaf : bank.cLoafBreath
        } else {
          clip = bank.xSleep
          squash = 1 - 0.025 * CGFloat(0.5 + 0.5 * sin(now * 2 * .pi / 2.8))
        }
      case .work:
        clip = b.who == .clawd ? bank.cWorkLoop : bank.xWork
        frame = clip.index(at: now, loop: true)
      case .idle:
        if let s = b.still, now < b.stillUntil { clip = s }
        else { clip = b.who == .clawd ? bank.cStand : bank.xIdleCalm; frame = clip.index(at: now, loop: true) }
      }
    }
    if now < b.shakeUntil { drawX += Int(now * 20) % 2 == 0 ? -1 : 1 }
    clip.draw(frame, in: ctx, x: drawX, y: ground + b.hop, mirror: mirror, alpha: alpha, squashY: squash)
    if b.step?.clipRect != nil && (b.step?.run == true || b.step?.clip != nil) { ctx.restoreGState() }

    // Claude Code's spinner above Clawd while he works.
    if b.who == .clawd && b.base == .work && !b.busy {
      let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
      drawGlyph(frames[Int(now / 0.12) % frames.count], at: CGPoint(x: b.x - 5, y: 22.5), color: Palette.clawd, size: 9)
    }
  }

  private func drawProjectile(_ p: Projectile, _ ctx: CGContext) {
    let u = CGFloat(min(1, max(0, (now - p.start) / p.duration)))
    let x = p.from.x + (p.to.x - p.from.x) * u
    var y = p.from.y + (p.to.y - p.from.y) * u + p.arc * 4 * u * (1 - u)
    y += p.wobble * CGFloat(sin(Double(u) * 12))
    y = min(y, 26)
    draw(p.effect, at: CGPoint(x: x, y: y), size: 1, alpha: 1, flip: p.to.x < p.from.x, outline: true, ctx)
  }

  private func drawParticle(_ p: Particle, _ ctx: CGContext) {
    let fade = CGFloat(max(0, 1 - pow(p.age / p.life, 2)))
    draw(p.effect, at: CGPoint(x: p.x, y: p.y), size: p.size, alpha: fade, flip: false, outline: false, ctx)
  }

  private func draw(_ e: Effect, at p: CGPoint, size: CGFloat, alpha: CGFloat, flip: Bool, outline: Bool, _ ctx: CGContext) {
    ctx.saveGState()
    ctx.setAlpha(alpha)
    switch e {
    case let .bitmap(rows, color):
      let (w, h) = Sprite.size(rows)
      let ox = ((p.x - CGFloat(w) * size / 2) * 2).rounded() / 2, oy = ((p.y - CGFloat(h) * size / 2) * 2).rounded() / 2
      if outline {
        // A dark halo keeps thrown things readable as they fly over the gray buttons.
        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] as [(CGFloat, CGFloat)] {
          Pen(ctx: ctx, ox: ox + dx * size, oy: oy + dy * size, s: size).bitmap(rows, 0, 0, CGColor(gray: 0, alpha: 0.85), flip: flip)
        }
      }
      Pen(ctx: ctx, ox: ox, oy: oy, s: size).bitmap(rows, 0, 0, color, flip: flip)
    case let .glyph(s, color, fontSize):
      drawGlyph(s, at: p, color: color, size: fontSize, outline: outline)
    }
    ctx.restoreGState()
  }

  private func drawGlyph(_ s: String, at p: CGPoint, color: CGColor, size: CGFloat, outline: Bool = false) {
    let font = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .white]
    if outline { attrs[.strokeColor] = NSColor.black; attrs[.strokeWidth] = -3.0 }
    let str = NSAttributedString(string: s, attributes: attrs)
    let sz = str.size()
    str.draw(at: NSPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2))
  }
}
