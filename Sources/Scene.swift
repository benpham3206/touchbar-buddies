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
  var state = AgentState()             // what the buddy acts out
  var reported = AgentState()          // what the activity monitor says (state = this + the secret ultra boost)
  var greeted = false                 // has made its first entrance since the app started
  var launchUntil: Double = 0          // a tap is opening its app: the entrance plays until then (see Scene.launch)
  var playing = false                  // in a game, whatever its app is doing; Scene.end() sends it back to that
  var carry: Effect? = nil             // something it takes across the bar (a message, a result), held over its head
  var carryOffset: CGVector?           // where it's held, from the buddy's feet (eased between poses)
  var taps: [Double] = []
  var nextIdle: Double = 3
  var nextBlink: Double = 2
  var still: Clip? = nil               // temporary idle expression (blink / glance)
  var stillUntil: Double = 0
  var shakeUntil: Double = 0
  var lastZ: Double = 0
  var ultraStart: Double = -10         // when ultra mode began / ended (for the flash and the fading glow)
  var ultraEnd: Double = -10
  var nextFlourish: Double = 0         // next code symbol / ultra sparkle while working
  var flourishes = 0                   // how many so far (alternates sides, turns Codex's ultra rings)
  var symbol = 0                       // Codex's last code symbol (the next one is always different)

  init(_ who: Who) { self.who = who }

  enum Base { case sleep, idle, work }
  var base: Base { !state.present ? .sleep : state.working ? .work : .idle }
  var busy: Bool { step != nil || !queue.isEmpty }
  /// What it shows with nothing queued: its base pose, but a buddy in a game stands around between its beats
  /// (no typing, no snoozing) until the game sends it back.
  var pose: Base { playing ? .idle : base }
  var home: CGFloat { pocket.midX + (who == .clawd && base == .work ? -5 : 0) }
  var inPocket: Bool { abs(x - pocket.midX) < pocket.width / 2 + 4 }
  /// Where the buddy's current frame was last drawn (a kart or cloud is much wider than the buddy himself).
  var drawnRect = CGRect.zero

  /// Out on the bar, away from its pocket. Hiding behind the button next to it doesn't count: then nothing of it
  /// is drawn outside the pocket.
  var abroad: Bool {
    guard !inPocket else { return false }
    if let r = step?.clipRect, r.minX >= pocket.minX - 1, r.maxX <= pocket.maxX + 1 { return false }
    return true
  }

  func enqueue(_ steps: [Step]) { queue.append(contentsOf: steps) }

  /// Drops everything queued. An entrance or an errand that gets cut short is over too, so nothing is left
  /// waiting on it (a "launching" flag that outlived its entrance used to swallow every later tap).
  func interrupt() {
    queue.removeAll()
    step = nil
    launchUntil = 0
    carry = nil
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
  case ring(CGColor)                   // an expanding ring; the particle's size is its final radius
}

struct Particle {
  var effect: Effect
  var x, y, vx, vy: CGFloat
  var life: Double
  var age: Double = 0
  var gravity: CGFloat = 0
  var size: CGFloat = 1
  var behind = false                   // drawn behind the buddies
}

struct Projectile {
  var effect: Effect
  var from, to: CGPoint
  var start: Double
  var duration: Double
  var arc: CGFloat
  var wobble: CGFloat = 0
  var trail: CGColor? = nil            // leaves a faint sparkle trail
  var onArrive: (() -> Void)?
  var game = 0                         // the game that threw it (a called-off game's things vanish)
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

  /// The games by name: Play Together picks one at random, and the menu bar's Play submenu lists them all.
  static let games: [(title: String, command: String)] = [
    ("Wave", "wave"), ("Catch", "toss"), ("Paper Plane", "plane"), ("Echo Hops", "echo"), ("Packets", "packets"),
    ("Peek-a-boo", "peek"), ("Clawd Visits Codex", "visit-clawd"), ("Codex Visits Clawd", "visit-codex"),
    ("Codex's Victory Sprint", "visit-codex-sprint"), ("Codex Sneaks Up on Clawd", "visit-codex-sneak"),
    ("Codex Runs a Lap", "visit-codex-lap"), ("Codex Trips Over", "visit-codex-trip"),
  ]

  private var particles: [Particle] = []
  private var projectiles: [Projectile] = []
  private var timers: [(at: Double, game: Int, run: () -> Void)] = []
  private var interacting = false
  private var interactionStart: Double = 0
  private var game = 0                           // numbers the games; timers set during one carry its number
  private var nextInteraction: Double = 12
  private var laidOut = false
  private var boostUntil: Double = 0             // the secret two-buddy hold: both work in ultra mode until then
  private var welcomeDue = false                 // welcomeBack() was called: play it on the next frame
  // Errands between two busy buddies (see delegate()).
  private var nextSender: Who = .codex           // they take turns handing work over
  private var delegatedBy: [Who: Who] = [:]      // who handed work to whom: receiver → sender
  private var pendingDelivery: (courier: Who, to: Who)?
  /// Codex's typing symbols. One consistent set, and no angle brackets.
  private let codeBits = ["{", "}", "(", ")", ";"]

  init(bank: Bank) { self.bank = bank }

  /// How often the Touch Bar needs redrawing right now; the render loop picks its frame rate from this.
  enum Pace { case asleep, calm, lively, fast }
  var pace: Pace {
    let both = [clawd, codex]
    if !projectiles.isEmpty || both.contains(where: { $0.abroad }) { return .fast }          // something crosses the bar
    if both.allSatisfy({ $0.pose == .sleep && !$0.busy }) { return .asleep }                 // just Zzz
    if !particles.isEmpty || both.contains(where: { $0.state.ultra || $0.hop > 0 || $0.step?.moveTo != nil }) { return .lively }
    return .calm                                                                              // sprites tick at ~12 fps
  }

  /// Whether anything is drawn outside the two pockets, so the whole bar must be redrawn (not just the pockets).
  var drawsOutsidePockets: Bool {
    if pace == .fast { return true }
    let areas = redrawAreas
    // Judge by what was actually drawn: a parked kart can hang over the next button even with Clawd "home".
    if [clawd, codex].contains(where: { b in !b.drawnRect.isEmpty && !areas.contains { $0.contains(b.drawnRect.insetBy(dx: 0.5, dy: 0.5)) } }) {
      return true
    }
    return particles.contains { p in !areas.contains { $0.contains(CGPoint(x: p.x, y: min(p.y, 29))) } }
  }

  /// The pockets plus a margin for sparkles and symbols that spill a little past their edges.
  var redrawAreas: [CGRect] { [codex.pocket, clawd.pocket].map { $0.insetBy(dx: -14, dy: 0) } }

  func layout(codexPocket: CGRect, clawdPocket: CGRect) {
    codex.pocket = codexPocket
    clawd.pocket = clawdPocket
    if !laidOut || !codex.busy { codex.x = codex.home }
    if !laidOut || !clawd.busy { clawd.x = clawd.home }
    laidOut = true
  }

  /// Runs `run` after `delay` seconds of scene time. Set during a game, it belongs to that game (see cancelGame).
  func after(_ delay: Double, _ run: @escaping () -> Void) { timers.append((now + delay, interacting ? game : 0, run)) }

  private func other(_ b: Buddy) -> Buddy { b === clawd ? codex : clawd }
  private func buddy(_ who: Who) -> Buddy { who == .clawd ? clawd : codex }

  /// A buddy whose sprites couldn't be extracted stays asleep and hidden (never drawn, never tapped).
  func has(_ b: Buddy) -> Bool { b.who == .clawd ? bank.hasClawd : bank.hasCodex }

  /// A tap is opening the buddy's app and its entrance is playing.
  private func launching(_ b: Buddy) -> Bool { now < b.launchUntil }

  // MARK: Agent state

  func setState(_ b: Buddy, _ s: AgentState) {
    b.reported = s
    act(b)
  }

  /// Acts out what the monitor reported, plus the secret boost (hold both buddies → both work in ultra mode).
  private func act(_ b: Buddy) {
    guard has(b) else { return }
    var s = b.reported
    if now < boostUntil && s.present { s.working = true; s.ultra = true }
    let old = b.state
    b.state = s
    if s.present != old.present {
      if s.present { arrive(b) } else { fallAsleep(b) }
    } else if s.present && s.working != old.working {
      s.working ? startWork(b) : finishWork(b)
    }
    if s.ultra != old.ultra { s.ultra ? ultraOn(b) : ultraOff(b) }
  }

  /// The secret gesture: both buddies go ultra for a few seconds (only the ones that are awake).
  func ultraBoost(seconds: Double = 8) {
    boostUntil = now + seconds
    for b in [clawd, codex] where has(b) {
      if b.base == .sleep { puff(at: CGPoint(x: b.x, y: ground + 8), color: Palette.violet) }
      act(b)
    }
  }

  /// The app opened (not from a tap): the buddy makes its entrance.
  private func arrive(_ b: Buddy) {
    guard !launching(b) else { return }       // the tap-to-open entrance is already playing
    b.interrupt()
    b.playing = false
    b.x = b.home
    if !b.greeted {
      // First arrival after login: pop out from behind the outer buttons — Codex from the left, Clawd from the right.
      b.greeted = true
      let side: CGFloat = b.who == .codex ? -1 : 1
      b.x = (side < 0 ? b.pocket.minX : b.pocket.maxX) + side * 14
      let popIn = Step(moveTo: b.home, speed: 45, run: true, clipRect: b.pocket)
      b.enqueue([popIn, b.who == .clawd ? Step(clip: bank.cHappy, hold: 0.45, hopV: 60) : Step(clip: bank.xJump),
                 waveStep(b, toward: b.who == .clawd ? codex.x : clawd.x)])
    } else {
      b.enqueue(b.who == .clawd ? clawdEntrance() : codexEntrance())
    }
    if b.state.working { startWork(b) }
  }

  private func fallAsleep(_ b: Buddy) {
    delegatedBy[b.who] = nil                  // its agent is gone: no result to bring back
    if pendingDelivery?.courier == b.who { pendingDelivery = nil }
    guard !launching(b) else { return }
    b.interrupt()
    b.playing = false
    b.x = b.home
    b.hop = 0
    puff(at: CGPoint(x: b.x, y: ground + 6), color: Palette.white)
  }

  private func startWork(_ b: Buddy) {
    let wasPlaying = b.playing, g = game
    b.playing = false                         // work comes first; a game goes on without it
    if b.abroad {
      // Out on the bar: hurry home. (Behind a button it finishes what it's doing, which ends at home anyway.)
      b.interrupt()
      b.enqueue([Step(moveTo: b.home, speed: 160, run: true, onEnd: {
        if wasPlaying && self.interacting && self.game == g { self.end() }   // its game can't finish without it
      })])
    }
    b.enqueue([Step(moveTo: b.home, speed: 40, run: true)])
    if b.who == .clawd { b.enqueue([Step(clip: bank.cWorkIn, face: b.home + 50)]) }
    else { b.enqueue([Step(clip: bank.xJump)]) }
    // Both at their laptops now: the first errand shouldn't take long.
    if other(b).base == .work && !interacting { nextInteraction = min(nextInteraction, now + .random(in: 8...12)) }
  }

  // MARK: Ultra / ultracode

  private func ultraOn(_ b: Buddy) {
    b.ultraStart = now
    b.nextFlourish = now + 0.5
    ultraBurst(at: CGPoint(x: b.x + (b.who == .clawd ? 3 : 0), y: ground + 11))
  }

  private func ultraOff(_ b: Buddy) {
    b.ultraEnd = now
    puff(at: CGPoint(x: b.x, y: ground + 10), color: Palette.violet)
  }

  /// The purple flash when ultra kicks in: two rings and a starburst.
  private func ultraBurst(at c: CGPoint) {
    particles.append(Particle(effect: .ring(Palette.violetLight), x: c.x, y: c.y, vx: 0, vy: 0, life: 0.45, size: 22))
    particles.append(Particle(effect: .ring(Palette.violet), x: c.x, y: c.y, vx: 0, vy: 0, life: 0.7, size: 38))
    for i in 0..<14 {
      let a = Double(i) / 14 * 2 * .pi, dx = CGFloat(cos(a)), dy = CGFloat(sin(a))
      let big = i % 2 == 0
      emit(.bitmap(big ? Sprite.spark : Sprite.star, big ? Palette.violet : Palette.violetLight),
           at: CGPoint(x: c.x + dx * 8, y: c.y + dy * 4), vx: dx * (big ? 52 : 36), vy: dy * (big ? 22 : 15),
           life: 0.65, size: big ? 0.6 : 1, behind: true)
    }
  }

  /// While a buddy works in ultra mode: Clawd throws off violet sparkles, Codex's code symbols burst out in rings.
  private func ultraAura(_ b: Buddy) {
    guard now > b.nextFlourish else { return }
    if b.who == .clawd {
      b.nextFlourish = now + .random(in: 0.18...0.4)
      emit(.bitmap(Sprite.star, Bool.random() ? Palette.violet : Palette.violetLight),
           at: CGPoint(x: b.x + .random(in: -12...20), y: ground + .random(in: 3...20)), vx: .random(in: -4...4), vy: .random(in: 6...14),
           life: .random(in: 0.4...0.7), size: Bool.random() ? 1 : 0.67)
    } else {
      // A ring made of each symbol once, spread evenly; every other ring is turned half a step, so its symbols
      // fly out through the gaps of the one before.
      b.nextFlourish = now + .random(in: 0.35...0.45)
      b.flourishes += 1
      let from = laptop(b), turn = Double(b.flourishes % 2) / 2 + .random(in: 0...0.15)
      let n = codeBits.count
      for i in 0..<n {
        let a = (Double(i) + turn) / Double(n) * 2 * .pi, dx = CGFloat(cos(a)), dy = CGFloat(sin(a))
        emit(.glyph(codeBits[(i + b.flourishes) % n], i % 2 == 0 ? Palette.violet : Palette.violetLight, 6.5),
             at: CGPoint(x: from.x + dx * 7, y: from.y + dy * 3.5), vx: dx * 32, vy: dy * 13 + 2, life: 0.85, behind: true)
      }
    }
  }

  /// Codex typing: one code symbol drifts up from his laptop. At least ~half a second apart, at irregular gaps,
  /// and alternating between two lanes so neighbours never overlap.
  private func codeSymbol(_ b: Buddy) {
    b.nextFlourish = now + 0.55 + .random(in: 0...0.9)
    b.flourishes += 1
    b.symbol = (b.symbol + .random(in: 1..<codeBits.count)) % codeBits.count   // never the same one twice in a row
    let left = b.flourishes % 2 == 0
    emit(.glyph(codeBits[b.symbol], Palette.codexLight, 6), at: CGPoint(x: b.x + (left ? 8 : 12), y: 12),
         vx: left ? .random(in: 1...3) : .random(in: 5...8), vy: 9, life: 1.4)
  }

  /// Where the laptop sits while a buddy works (both type to their right).
  private func laptop(_ b: Buddy) -> CGPoint {
    CGPoint(x: b.x + (b.who == .clawd ? 16 : 6), y: ground + (b.who == .clawd ? 4 : 7) + b.hop)
  }

  private func finishWork(_ b: Buddy) {
    if b.who == .clawd {
      // (Away from his laptop in a game or on an errand, there's no laptop to close.)
      b.enqueue((b.playing ? [] : [Step(clip: bank.cWorkOut)]) + [happyHop(b), happyHop(b)])
    } else {
      b.enqueue([Step(clip: bank.xReview), Step(clip: bank.xReview)])
    }
    confetti(at: CGPoint(x: b.x, y: 16))
    let o = other(b)
    if o.base == .idle && !o.busy && !interacting {
      after(0.7) { o.enqueue([self.cheer(o, toward: b)]) }
    }
    // It was doing work the other one handed over: it brings back the result in person (see update()).
    if let sender = delegatedBy.removeValue(forKey: b.who) { pendingDelivery = (b.who, sender) }
  }

  // MARK: Entrances

  /// Clawd's "load in" from the Claude app: he hops on his little cloud, rides it (until `ready`, when a tap is
  /// still opening the app) and hops off again, then a happy hop and a wave to Codex.
  private func clawdEntrance(until ready: (() -> Bool)? = nil) -> [Step] {
    let c = clawd
    var wave = waveStep(c, toward: codex.x)
    wave.onStart = { self.greet(c) }
    return [Step(clip: bank.cCloudMount),
            ready.map { Step(clip: bank.cCloudRide, loop: true, hold: 30, until: $0) } ?? Step(clip: bank.cCloudRide),
            Step(clip: bank.cCloudDismount),
            Step(clip: bank.cHappy, hold: 0.6, hopV: 60, onStart: { self.sparkle(at: CGPoint(x: c.x, y: 20)) }),
            wave]
  }

  /// Codex's entrance: up with a start, off behind the brightness button to get ready, and back in at a run; then a
  /// jump, a wave to you and a little celebration. With `ready` (a tap is still opening the app) he waits in the
  /// wings, peeking out, until it's true.
  private func codexEntrance(until ready: (() -> Bool)? = nil) -> [Step] {
    let x = codex, p = x.pocket
    let wings = p.minX - 14, peek = p.minX - 1
    var steps = [
      Step(clip: bank.xJump, onStart: { self.emit(.bitmap(Sprite.bang, Palette.gold), at: CGPoint(x: x.x + 10, y: 23), vy: 8, life: 0.6) }),
      Step(clip: bank.xRunL.still(1), hold: 0.1),
      run(-1, to: wings, speed: 140, clipRect: p, onStart: { self.puff(at: CGPoint(x: x.x + 6, y: self.ground + 3), color: Palette.white) }),
    ]
    if let ready {
      steps += [Step(clip: bank.xIdle, hold: 0.3, clipRect: p),
                Step(clip: bank.codexLook(degrees: 67.5), moveTo: peek, speed: 24, clipRect: p),     // leans out to look
                Step(clip: bank.codexLook(degrees: 67.5), hold: 30, clipRect: p, until: ready)]
      steps += dash(x, from: peek, to: x.home, clipRect: p)
    } else {
      steps += [Step(clip: bank.xIdle, hold: 0.45, clipRect: p)]
      steps += dash(x, from: wings, to: x.home, clipRect: p)
    }
    return steps + [
      Step(clip: bank.xJump, onStart: { self.sparkle(at: CGPoint(x: x.x, y: 22)) }),
      Step(clip: bank.xWave, loop: true, hold: bank.xWave.total * 2, onStart: { self.greet(x) }),
      Step(clip: bank.xReview, onStart: { self.confetti(at: CGPoint(x: x.x, y: 16)) }),
    ]
  }

  /// The other buddy waves back, if it's free.
  private func greet(_ b: Buddy) {
    let o = other(b)
    guard has(o), o.base == .idle, !o.busy, !interacting else { return }
    o.enqueue([waveStep(o, toward: b.x)])
  }

  /// The Mac was just unlocked: the awake buddies make an entrance. Both peek in from behind the buttons next to
  /// their pockets; then Clawd walks in, Codex comes running, and both wave. It plays on the next frame, once the
  /// scene clock has caught up with the time spent locked.
  /// A clean slate (after reloading sprites): both buddies home with nothing queued; setState replays their apps.
  func resetBuddies() {
    projectiles.removeAll()
    particles.removeAll()
    timers.removeAll()
    interacting = false
    for b in [clawd, codex] {
      b.interrupt()
      b.state = AgentState()
      b.hop = 0
      b.hopV = 0
      b.x = b.home
      b.drawnRect = .zero
    }
  }

  func welcomeBack() { welcomeDue = true }

  private func welcome() {
    let c = clawd, x = codex
    let cast = [c, x].filter { has($0) && $0.base != .sleep && !launching($0) }
    guard !cast.isEmpty else { return }
    cancelGame()
    begin(cast)
    var left = cast.count
    let bow = { (b: Buddy) in                  // each goes back to what it was doing as soon as it's done
      b.playing = false
      b.enqueue(self.backToBase(b))
      left -= 1
      if left == 0 { self.end() }
    }
    let heart = { (b: Buddy) in self.emit(.bitmap(Sprite.heart, Palette.heart), at: CGPoint(x: b.x, y: 22), vy: 14) }
    for b in cast { b.interrupt() }
    if cast.contains(where: { $0 === c }) {
      let edge = c.pocket.minX
      c.x = edge - 13
      var wave = waveStep(c, toward: x.x)
      wave.onStart = { heart(c) }
      wave.onEnd = { bow(c) }
      c.enqueue([
        Step(clip: bank.cStand, hold: 0.2, clipRect: CGRect(x: edge, y: 0, width: 0, height: 0)),     // out of sight
        Step(clip: bank.cLurk.slice(5...28), clipRect: c.pocket, leftEdge: edge),                      // peeks in…
        Step(moveTo: c.pocket.midX, speed: 30, run: true, clipRect: c.pocket, onStart: { c.x = edge + 1 }),   // …walks in
        Step(clip: bank.cHappy, hold: 0.45, hopV: 55),
        wave,
      ])
    }
    if cast.contains(where: { $0 === x }) {
      let p = x.pocket, peek = p.minX - 1
      x.x = p.minX - 14
      x.enqueue([Step(clip: bank.xIdle, hold: 0.3, clipRect: p),
                 Step(clip: bank.codexLook(degrees: 67.5), moveTo: peek, speed: 24, clipRect: p),                  // peeks in…
                 Step(clip: bank.codexLook(degrees: 67.5), hold: cast.count == 2 ? 1.9 : 0.6, clipRect: p)]         // (in time with Clawd)
                + dash(x, from: peek, to: p.midX, clipRect: p)                                                   // …runs in
                + [Step(clip: bank.xWave, loop: true, hold: bank.xWave.total * 2),
                   Step(clip: bank.xJump, onStart: { heart(x) }, onEnd: { bow(x) })])
    }
  }

  // MARK: Touch

  func tap(_ who: Who) {
    let b = buddy(who)
    guard has(b) else { return }
    guard b.state.appRunning else { launch(b); return }
    b.taps = b.taps.filter { now - $0 < 1.5 } + [now]
    if b.base == .work || launching(b) {
      // Don't break their focus (or their entrance): a little hop and a heart.
      b.hopV = 45; b.hop = max(b.hop, 0.01)
      emit(.bitmap(Sprite.heart, Palette.heart), at: CGPoint(x: b.x + 6, y: 20), vy: 16)
      return
    }
    if b.taps.count >= 4 {
      b.taps.removeAll()
      recall(b)
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
    recall(b)
    b.enqueue(b.who == .codex ? [Step(clip: bank.xJump)] : [Step(clip: bank.cSquat, hold: 0.08), happyHop(b)])
    emit(.bitmap(Sprite.heart, Palette.heart), at: CGPoint(x: b.x + 8, y: 21), vy: 18)
  }

  func longPress(_ who: Who) {
    let b = buddy(who)
    guard has(b) else { return }
    guard b.state.appRunning else { launch(b); return }
    onFocus?(who)
    guard b.base != .work, !launching(b) else { return }
    recall(b)
    b.enqueue([waveStep(b, toward: b.x - 1)])
  }

  /// Tapping a buddy whose app is closed opens it. Every tap asks again (opening an app that's already on its way
  /// is harmless); the entrance starts once and plays until the app is up.
  private func launch(_ b: Buddy, open: Bool = true) {
    if open { onLaunch?(b.who) }
    guard !launching(b) else { return }       // its entrance is already playing
    b.interrupt()
    b.playing = false
    b.x = b.home
    b.launchUntil = now + 40                  // a time limit, so a lost entrance can never block taps for long
    let t0 = now
    // Codex waits in the wings, peeking out: give him a moment there even when the app is quick.
    let ready = { [unowned self] in b.state.appRunning && self.now - t0 > (b.who == .codex ? 2.6 : 1.4) }
    var steps = b.who == .clawd ? clawdEntrance(until: ready) : codexEntrance(until: ready)
    let last = steps[steps.count - 1].onEnd
    steps[steps.count - 1].onEnd = { last?(); b.launchUntil = 0 }
    b.enqueue(steps)
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
    func go(_ f: @escaping () -> Void) { play(f) }
    switch cmd {
    case "play": playTogether()
    case "wave": go { self.waveHello(a, b) }
    case "toss": go { self.toss(a, b, volleys: 3) }
    case "plane": go { self.paperPlane(b, a) }
    case "echo": go { self.echoHops(a, b, rounds: 2) }
    case "packets": go { self.packets() }
    case "peek": go { self.peekaboo(); self.after(6.5) { self.end() } }
    case "visit-clawd": go { self.clawdVisits() }
    case "visit-clawd-car": go { self.clawdVisits(car: true) }
    case "visit-clawd-cloud": go { self.clawdVisits(car: false) }
    case "visit-codex": go { self.codexVisits() }
    case "visit-codex-sprint": go { self.codexSprints() }
    case "visit-codex-sneak": go { self.codexSneaks() }
    case "visit-codex-lap": go { self.codexLap() }
    case "visit-codex-trip": go { self.codexTrips() }
    case "zoomies": habit(a) { zoomies(a) }
    case "stargaze": habit(a) { stargaze(a) }
    case "dance": habit(a) { dance(a) }
    case "peek-codex": habit(a) { codexPeek(a) }
    case "cheer-visit":   // the idle one visits the busy one
      if a.base != b.base, let w = [a, b].first(where: { $0.base == .work }), other(w).base == .idle {
        cancelGame(); begin([other(w)]); cheerInPerson(other(w), w)
      }
    case "welcome": welcomeBack()
    case "delegate": if a.base == .work && b.base == .work { cancelGame(); delegate() }
    case "deliver":   // the one last handed work brings the result back now
      let courier = buddy(nextSender)
      if a.base != .sleep && b.base != .sleep {
        delegatedBy[courier.who] = nil
        if pendingDelivery?.courier == courier.who { pendingDelivery = nil }
        cancelGame()
        deliver(courier, to: other(courier))
      }
    case "tap-clawd": tap(.clawd)
    case "tap-codex": tap(.codex)
    case "launch-clawd": launch(clawd, open: false)
    case "launch-codex": launch(codex, open: false)
    case "notes": notes()
    case "ultra": ultraBoost()
    default: break
    }
  }

  /// Play Together (menu bar): a game right now, whatever the two are up to. `command` picks one of `games`;
  /// without it, it's a random one (no visits while Visits Across the Bar is off).
  func playTogether(_ command: String? = nil) {
    guard let pick = command ?? Self.games.filter({ roaming || !$0.command.hasPrefix("visit") }).randomElement()?.command else { return }
    self.command(pick)
  }

  /// One of a buddy's idle habits, right now (for commands).
  private func habit(_ b: Buddy, _ steps: () -> [Step]) {
    guard has(b) else { return }
    recall(b)
    b.enqueue(steps())
  }

  // MARK: Update

  func update(_ t: Double, _ dt: Double) {
    now = t
    let due = timers.filter { $0.at <= now }
    timers.removeAll { $0.at <= now }
    due.forEach { $0.run() }
    if welcomeDue { welcomeDue = false; welcome() }
    if boostUntil > 0 && now >= boostUntil {
      boostUntil = 0
      act(clawd)
      act(codex)
    }
    // Safety net: an interaction cut short (a tap, work starting mid-visit) never reaches its end().
    if interacting && now - interactionStart > 30 { end() }

    for b in [clawd, codex] where has(b) {
      b.update(now, dt)
      easeCarry(b, dt)
      if !scripted && !b.busy && b.base == .idle && !interacting { idleHabits(b) }
      if b.pose == .sleep && !b.busy && now - b.lastZ > 1.8 {
        b.lastZ = now
        emit(.bitmap(Sprite.zed, Palette.white), at: CGPoint(x: b.x + 9, y: b.who == .clawd ? 11 : 18), vx: 6, vy: 5, life: 2.2, size: 0.75)
      }
      if b.pose == .work && b.state.ultra && !b.busy {
        ultraAura(b)
      } else if b.who == .codex && b.pose == .work && !b.busy && now > b.nextFlourish {
        codeSymbol(b)
      }
    }
    // A finished job goes back to whoever handed it over, once the courier is done celebrating and nothing else is on.
    if let d = pendingDelivery, !interacting, !buddy(d.courier).busy {
      pendingDelivery = nil
      let a = buddy(d.courier), b = buddy(d.to)
      if a.base != .sleep && b.base != .sleep { deliver(a, to: b) }   // (not if the one who asked has gone to sleep)
    }
    if !scripted && !interacting && now > nextInteraction { direct() }

    for i in particles.indices {
      particles[i].age += dt
      particles[i].vy -= particles[i].gravity * CGFloat(dt)
      particles[i].x += particles[i].vx * CGFloat(dt)
      particles[i].y += particles[i].vy * CGFloat(dt)
    }
    particles.removeAll { $0.age >= $0.life }
    for p in projectiles where p.trail != nil && Double.random(in: 0...1) < dt * 12 {
      emit(.bitmap(Sprite.star, p.trail!), at: position(of: p), vx: .random(in: -3...3), vy: .random(in: -4...2), life: 0.45, size: 0.5)
    }
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
      case ..<0.18:
        let dirs: [CGFloat] = [90, 45, 0, 315, 270, 135]
        let pick = Array(dirs.shuffled().prefix(3))
        b.enqueue(pick.map { Step(clip: bank.codexLook(degrees: $0), hold: .random(in: 0.5...1.1)) })
      case ..<0.32: b.enqueue(stroll(b, to: .random(in: lo...hi)))
      case ..<0.40: b.enqueue([Step(clip: bank.xWaiting, loop: true, hold: .random(in: 2.5...4))])
      case ..<0.46: b.enqueue([Step(clip: bank.xJump)])
      case ..<0.52: b.enqueue([waveStep(b, toward: clawd.x)])
      case ..<0.61: b.enqueue(zoomies(b))
      case ..<0.69: b.enqueue(stargaze(b))
      case ..<0.77: b.enqueue(dance(b))
      case ..<0.84: b.enqueue(codexPeek(b))
      default: break
      }
    }
  }

  // MARK: Director

  private func direct() {
    let c = clawd, x = codex
    let free = { (b: Buddy) in !b.busy && !self.launching(b) }
    if c.base == .idle && x.base == .idle && free(c) && free(x) {
      startInteraction()
    } else if c.base == .work && x.base == .idle && free(x) {
      support(x, worker: c)
    } else if x.base == .work && c.base == .idle && free(c) {
      support(c, worker: x)
    } else if c.base == .work && x.base == .work && free(c) && free(x) {
      delegate()
    } else {
      nextInteraction = now + 5
    }
  }

  // MARK: Games

  /// Starts a game: only one at a time, and it must call `end()` when it's over.
  private func begin(_ players: [Buddy]) {
    game += 1
    interacting = true
    interactionStart = now
    for b in players { b.playing = true }
  }

  /// The game is over: once their last steps have played, the players go back to what their apps are doing
  /// (a working buddy sits back down at its laptop, a sleeping one goes back to sleep).
  private func end() {
    interacting = false
    // Errands between two busy buddies come less often than games.
    let bothWork = clawd.base == .work && codex.base == .work
    nextInteraction = now + (bothWork ? .random(in: 30...60) : .random(in: 14...30))
    for b in [clawd, codex] where b.playing {
      b.playing = false
      b.enqueue(backToBase(b))
    }
  }

  /// Calls off the game in progress, with its pending beats and anything still in the air, and puts its players back.
  private func cancelGame() {
    guard interacting else { return }
    timers.removeAll { $0.game == game }
    projectiles.removeAll { $0.game == game }
    for b in [clawd, codex] where b.playing { recall(b) }
    end()
  }

  /// Stops whatever a buddy is doing. One that was out of its pocket (or behind a button) pops back home.
  private func recall(_ b: Buddy) {
    let hidden = b.step?.clipRect != nil
    b.interrupt()
    if hidden || b.x < b.pocket.minX + 10 || b.x > b.pocket.maxX - 10 {
      b.x = b.home
      puff(at: CGPoint(x: b.x, y: ground + 6), color: Palette.white)
    }
  }

  /// After a game: back to the laptop, or back to sleep.
  private func backToBase(_ b: Buddy) -> [Step] {
    switch b.base {
    case .idle: return [Step(moveTo: b.home, speed: 18, run: true)]    // (a game may have left it off-center)
    case .work:
      return [Step(moveTo: b.home, speed: 40, run: true)] + (b.who == .clawd ? [Step(clip: bank.cWorkIn, face: b.home + 50)] : [])
    case .sleep:
      return [Step(moveTo: b.home, speed: 40, run: true, onEnd: { self.puff(at: CGPoint(x: b.x, y: self.ground + 6), color: Palette.white) })]
    }
  }

  /// Starts a game right now, whatever the two are doing (Play Together, commands). A game in progress is called
  /// off, a sleeping buddy gets up for it and a working one leaves its laptop; `end()` sends them back after.
  private func play(_ start: @escaping () -> Void) {
    guard has(clawd) && has(codex) else { return }
    cancelGame()
    begin([clawd, codex])
    var warmUp = 0.0
    for b in [clawd, codex] {
      recall(b)
      var steps: [Step] = []
      if b.base == .sleep {
        puff(at: CGPoint(x: b.x, y: ground + 8), color: Palette.white)
        steps = b.who == .clawd ? [Step(clip: bank.cSquat, hold: 0.08), happyHop(b)] : [Step(clip: bank.xJump)]
      } else if b.base == .work && b.who == .clawd {
        steps = [Step(clip: bank.cWorkOut)]    // closes his laptop
      }
      b.enqueue(steps)
      warmUp = max(warmUp, steps.reduce(0) { $0 + ($1.hold > 0 ? $1.hold : $1.clip?.total ?? 0) })
    }
    if warmUp > 0 { after(warmUp + 0.1, start) } else { start() }
  }

  private func startInteraction() {
    begin([clawd, codex])
    let (a, b) = Bool.random() ? (clawd, codex) : (codex, clawd)
    var options: [(Double, () -> Void)] = [
      (18, { self.waveHello(a, b) }),
      (22, { self.toss(a, b, volleys: .random(in: 3...5)) }),
      (12, { self.paperPlane(a, b) }),
      (12, { self.echoHops(a, b, rounds: 2) }),
      (12, { self.packets() }),
      (8, { self.peekaboo(); self.after(6.5) { self.end() } }),
    ]
    // Visits: Codex has more ways to come over than Clawd, and comes a bit more often.
    if roaming { options += [(8, { self.clawdVisits() }), (12, { self.codexVisit() })] }
    var r = Double.random(in: 0..<options.map(\.0).reduce(0, +))
    for (w, run) in options {
      if r < w { run(); return }
      r -= w
    }
    options[0].1()
  }

  private func support(_ helper: Buddy, worker: Buddy) {
    begin([helper])
    switch Int.random(in: 0..<(roaming ? 4 : 3)) {
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
    case 2:
      let watch: Step = helper.who == .codex
        ? Step(clip: bank.xWaiting, loop: true, hold: 3.5)
        : Step(clip: worker.x < helper.x ? bank.cLookL : bank.cLookR, hold: 3)
      helper.enqueue([watch])
      after(3.6) { self.end() }
    default:
      cheerInPerson(helper, worker)
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
      self.throwThing(.glyph("{}", Palette.codexLight, 8), from: x, to: c, arc: 5) {
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
    if (codex.playing || codex.base == .idle) && !codex.busy {
      after(1.2) { self.codex.enqueue([Step(clip: self.bank.codexLook(degrees: 90), hold: 3.5), Step(clip: self.bank.xReview)]) }
    }
  }

  /// Clawd's ride across the bar: his racing kart (a dust puff as he gets in and out), or his little cloud.
  private func clawdTrip(to target: CGFloat, car: Bool) -> [Step] {
    let c = clawd
    return car
      ? [Step(clip: bank.cRaceIn, face: target, onEnd: { self.puff(at: CGPoint(x: c.x, y: 6), color: Palette.white) }),
         Step(clip: bank.cRaceDrive, loop: true, moveTo: target, speed: 250),
         Step(clip: bank.cRaceOut, onStart: { self.puff(at: CGPoint(x: c.x, y: 6), color: Palette.white) })]
      : [Step(clip: bank.cCloudMount, face: target),
         Step(clip: bank.cCloudRide, loop: true, moveTo: target, speed: 170),
         Step(clip: bank.cCloudDismount)]
  }

  /// Clawd crosses the bar to visit — in his racing kart or on his cloud.
  private func clawdVisits(car: Bool = .random()) {
    let c = clawd, x = codex
    let spot = x.x + 34
    let meet = Step(clip: bank.cHappy, hold: 0.9, face: x.x, hopV: 60, onStart: {
      self.highFive(between: c, x)
      if x.playing { x.enqueue([Step(clip: self.bank.xReview), Step(clip: self.bank.xWave)]) }
    })
    c.enqueue(clawdTrip(to: spot, car: car) + [meet, waveStep(c, toward: x.x)] + clawdTrip(to: c.home, car: car)
              + [Step(clip: bank.cHappy, hold: 0.4, onEnd: { self.end() })])
  }

  // MARK: Codex's visits

  /// One of Codex's visits, at random.
  private func codexVisit() {
    [codexVisits, codexSprints, codexSneaks, codexLap, codexTrips].randomElement()!()
  }

  /// The other buddy's reaction to a beat of a visit, so the two stay in sync (unless it got called away to work).
  private func cue(_ b: Buddy, _ steps: [Step]) -> () -> Void {
    { if b.playing { b.interrupt(); b.enqueue(steps) } }
  }

  /// Codex runs over on foot to visit: a dusty take-off, a jumping high-five, a wave goodbye, and home again.
  private func codexVisits() {
    let c = clawd, x = codex
    let side: CGFloat = x.x < c.x ? -1 : 1        // which side of Clawd he stops on
    let spot = c.x + side * 23                     // close enough to slap hands, without the two overlapping
    let look = side < 0 ? bank.cLookL : bank.cLookR
    let meet = [
      // Both arms up and a hop; the hands meet at the top of it.
      Step(clip: bank.xReview.still(2), hold: 0.35, hopV: 45, onStart: { self.after(0.1) { self.highFive(between: x, c) } }),
      Step(clip: bank.xReview.slice(3...5), onStart: cue(c, [happyHop(c)])),
      Step(clip: bank.xWave, loop: true, hold: bank.xWave.total * 2, onStart: cue(c, [waveStep(c, toward: spot)])),
    ]
    x.enqueue(dash(x, from: x.x, to: spot,
                   onBrake: cue(c, [Step(clip: look, hold: 3)]),                        // Clawd spots him coming
                   onStop: cue(c, [armsUp(c, toward: x, hold: 3)]))                     // and raises a claw
              + meet
              + dash(x, from: spot, to: x.home,
                     onGo: { if c.playing { c.enqueue([Step(clip: look, hold: 1.5)]) } },   // watches him go
                     onStop: { self.end() }))
  }

  /// Codex races over flat out, dust flying, and celebrates like he won; Clawd cheers him on.
  private func codexSprints() {
    let c = clawd, x = codex
    let side: CGFloat = x.x < c.x ? -1 : 1
    let spot = c.x + side * 23
    let look = side < 0 ? bank.cLookL : bank.cLookR
    let hooray = [Step(clip: bank.cSquat, hold: 0.08), happyHop(c), Step(clip: bank.cSquat, hold: 0.08), happyHop(c), waveStep(c, toward: spot)]
    x.enqueue(dash(x, from: x.x, to: spot, fast: 215,
                   onBrake: cue(c, [Step(clip: look, hold: 3)]),
                   onStop: cue(c, hooray))
              + [Step(clip: bank.xReview.still(2), hold: 0.45, hopV: 60, onStart: {       // arms up: winner!
                   self.confetti(at: CGPoint(x: x.x, y: 18))
                   self.after(0.12) { self.highFive(between: x, c) }
                 }),
                 Step(clip: bank.xReview),
                 Step(clip: bank.xJump, onStart: { self.confetti(at: CGPoint(x: x.x, y: 18)) }),
                 Step(clip: bank.xWave)]
              + dash(x, from: spot, to: x.home,
                     onGo: { if c.playing { c.enqueue([Step(clip: look, hold: 1.5)]) } },
                     onStop: { self.end() }))
  }

  /// Codex sneaks up on Clawd, who is looking the other way: the last stretch on tiptoe, then BOO. Clawd jumps out
  /// of his shell; then they both laugh.
  private func codexSneaks() {
    let c = clawd, x = codex
    let side: CGFloat = x.x < c.x ? -1 : 1
    let spot = c.x + side * 21, creep = c.x + side * 66
    let away = side < 0 ? bank.cLookR : bank.cLookL, toward = side < 0 ? bank.cLookL : bank.cLookR
    let boo = {
      guard c.playing else { return }
      c.interrupt()
      c.shakeUntil = self.now + 0.5
      for i in 0..<3 {
        self.after(Double(i) * 0.08) {
          self.emit(.bitmap(Sprite.bang, Palette.gold), at: CGPoint(x: c.x + CGFloat(i - 1) * 5, y: 22), vx: CGFloat(i - 1) * 10, vy: 12, life: 0.6)
        }
      }
      c.enqueue([Step(clip: toward, hold: 0.8, hopV: 95),                                        // eek!
                 self.happyHop(c), self.happyHop(c),   // …ha
                 self.waveStep(c, toward: x.x)])
    }
    c.enqueue([Step(clip: away, hold: 25)])       // gazing the other way, none the wiser
    x.enqueue(dash(x, from: x.x, to: creep)
              + [run(-side, to: spot, speed: 15),                                                // tiptoe…
                 Step(clip: (side < 0 ? bank.xRunR : bank.xRunL).still(7), hold: 0.4),           // …not a sound…
                 Step(clip: bank.xReview.still(2), hold: 0.5, hopV: 60, onStart: boo),           // BOO!
                 Step(clip: bank.xReview, onStart: { self.sparkle(at: CGPoint(x: (x.x + c.x) / 2, y: 22)) }),   // got you ^^
                 Step(clip: bank.xReview.slice(1...5)),
                 Step(clip: bank.xWave)]
              + dash(x, from: spot, to: x.home, onStop: { self.end() }))
  }

  /// Codex runs a lap of the whole bar: past Clawd (who watches him whizz by), round the back of the last button,
  /// and all the way home, arms up like he won.
  private func codexLap() {
    let c = clawd, x = codex
    let far = c.pocket.maxX + 14
    let track = CGRect(x: 0, y: 0, width: c.pocket.maxX, height: 30)   // he disappears behind the last button
    let speed: CGFloat = 175
    var turned = false
    x.enqueue([Step(clip: bank.xRunR.still(1), hold: 0.12),
               run(1, to: far, speed: speed, clipRect: track, onStart: {
                 self.puff(at: CGPoint(x: x.x - 6, y: self.ground + 3), color: Palette.white)
                 self.kickUpDust(x, speed: speed)
               }),
               Step(clip: bank.xIdle, hold: 0.45, clipRect: track, onStart: { turned = true })]    // round the back
              + dash(x, from: far, to: x.home, fast: speed, clipRect: track)
              + [Step(clip: bank.xReview.still(2), hold: 0.5, hopV: 55, onStart: {
                   self.confetti(at: CGPoint(x: x.x, y: 18))
                   self.sparkle(at: CGPoint(x: x.x, y: 22))
                 }),
                 Step(clip: bank.xReview, onEnd: { self.end() })])
    c.enqueue([Step(clip: bank.cLookL, hold: 15, until: { x.x > c.x - 3 }),                    // here he comes…
               Step(clip: bank.cHappy, hold: 0.45, hopV: 55),                                  // whoosh!
               Step(clip: bank.cLookR, hold: 15, until: { turned && x.x < c.x + 3 }),           // …and back again
               Step(clip: bank.cHappy, hold: 0.45, hopV: 55),
               Step(clip: bank.cLookL, hold: 2)])
  }

  /// Codex runs over a bit too fast, trips right in front of Clawd and sees stars; then he laughs it off.
  private func codexTrips() {
    let c = clawd, x = codex
    let side: CGFloat = x.x < c.x ? -1 : 1
    let spot = c.x + side * 23, stumble = spot + side * 20
    let toward = side < 0 ? bank.cLookL : bank.cLookR
    let bonk = {
      self.puff(at: CGPoint(x: x.x, y: self.ground + 4), color: Palette.white)
      self.dizzy(x, seconds: 1.2)
      self.cue(c, [Step(clip: toward, hold: 0.45, hopV: 70), Step(clip: toward, hold: 1.2)])()   // Clawd: !!
      if c.playing { self.emit(.bitmap(Sprite.bang, Palette.gold), at: CGPoint(x: c.x + 8, y: 22), vy: 10, life: 0.6) }
    }
    x.enqueue([Step(clip: (side < 0 ? bank.xRunR : bank.xRunL).still(1), hold: 0.12),
               run(-side, to: stumble, speed: 150, onStart: { self.puff(at: CGPoint(x: x.x + side * 6, y: self.ground + 3), color: Palette.white) }),
               Step(clip: bank.xFailed.still(1), moveTo: spot, speed: 85, hopV: 50),                // whoops…
               Step(clip: bank.xFailed.pick([1, 2, 3, 5, 6, 7]), onStart: bonk),                                 // …x_x
               Step(clip: bank.xReview, onStart: cue(c, [happyHop(c), happyHop(c)])),              // haha, I'm fine
               Step(clip: bank.xReview.still(2), hold: 0.35, hopV: 45, onStart: { self.after(0.1) { self.highFive(between: x, c) } }),
               Step(clip: bank.xWave, loop: true, hold: bank.xWave.total * 2, onStart: cue(c, [waveStep(c, toward: spot)]))]
              + dash(x, from: spot, to: x.home, onStop: { self.end() }))
  }

  /// A busy buddy gets a visit: the idle one crosses the bar to cheer it on right by its laptop, then heads home.
  private func cheerInPerson(_ h: Buddy, _ w: Buddy) {
    let side: CGFloat = h.home < w.home ? -1 : 1
    let love = {
      self.emit(.bitmap(Sprite.heart, Palette.heart), at: CGPoint(x: w.x + 6, y: 20), vy: 16)
      self.sparkle(at: CGPoint(x: (h.x + w.x) / 2, y: 22))
      w.hopV = 40; w.hop = max(w.hop, 0.01)
    }
    if h.who == .codex {
      let spot = w.home + side * 23
      h.enqueue(dash(h, from: h.x, to: spot)
                + [Step(clip: bank.xReview, onStart: love), Step(clip: bank.xJump)]
                + dash(h, from: spot, to: h.home, onStop: { self.end() }))
    } else {
      let car = Bool.random(), spot = w.home + side * 34
      var wave = waveStep(h, toward: w.x)
      wave.onStart = love
      h.enqueue(clawdTrip(to: spot, car: car) + [wave, Step(clip: bank.cHappy, hold: 0.45, hopV: 55)]
                + clawdTrip(to: h.home, car: car) + [Step(clip: bank.cHappy, hold: 0.3, onEnd: { self.end() })])
    }
  }

  // MARK: Errands (both busy)

  /// Both are working: one gets up and crosses the bar to hand the other part of its work in person (Clawd by kart
  /// or cloud with a ✻ over his head, Codex at a run with an envelope), then goes back to its laptop. The other keeps
  /// typing, with a little hop: got it. They take turns, and remember who asked (see `finishWork`).
  private func delegate() {
    let a = buddy(nextSender), b = other(a)
    nextSender = b.who
    delegatedBy[b.who] = a.who
    let ultra = a.state.ultra
    let note: Effect = a.who == .clawd
      ? .glyph("✻", ultra ? Palette.violet : Palette.clawd, 11)
      : .bitmap(Sprite.envelope, ultra ? Palette.violet : Palette.codexLight)
    errand(a, to: b, carrying: note) {
      b.hopV = 42; b.hop = max(b.hop, 0.01)
      self.sparkle(at: CGPoint(x: b.x, y: 20), color: ultra ? Palette.violetLight : Palette.gold)
    }
  }

  /// The work handed over is done: the one who did it brings back the result (a ✓ from Clawd, a little parcel from
  /// Codex) to the one who asked, with a high-five and confetti.
  private func deliver(_ a: Buddy, to b: Buddy) {
    let result: Effect = a.who == .clawd ? .bitmap(Sprite.check, Palette.green) : .bitmap(Sprite.parcel, Palette.gold)
    errand(a, to: b, carrying: result) {
      self.highFive(between: a, b)
      self.confetti(at: CGPoint(x: b.x, y: 16))
      if b.playing { b.enqueue([self.happyHop(b)]) } else { b.hopV = 45; b.hop = max(b.hop, 0.01) }
    }
  }

  /// `a` crosses the bar with something for `b`, holds it up, hands it over and goes home. An idle `b` comes to take
  /// it; a busy one keeps typing. A working `a` leaves its laptop (and sits back down after: see `end()`).
  private func errand(_ a: Buddy, to b: Buddy, carrying item: Effect, handOver: @escaping () -> Void) {
    let receiving = b.base == .idle
    begin(receiving ? [a, b] : [a])
    recall(a)
    if receiving { recall(b) }
    let side: CGFloat = a.home < b.home ? -1 : 1           // which side of `b` it stops on
    let spot = b.home + side * (a.who == .clawd ? 34 : 23)
    let pickUp = { a.carry = item; self.sparkle(at: self.carryPoint(a)) }
    let give = {
      let from = self.carryPoint(a)
      a.carry = nil
      self.fire(Projectile(effect: item, from: from, to: receiving ? self.hand(b, toward: a) : self.laptop(b),
                           start: self.now, duration: 0.4, arc: 5, onArrive: handOver))
      if receiving { b.enqueue([self.armsUp(b, toward: a, hold: 0.45, catching: true)]) }
    }
    var steps: [Step] = []
    if a.who == .clawd {
      let car = Bool.random()
      if a.base == .work { steps.append(Step(clip: bank.cWorkOut)) }       // closes his laptop first
      var there = clawdTrip(to: spot, car: car)
      there[0].onStart = pickUp
      steps += there
      steps += [Step(clip: bank.cWave.still(6), hold: 0.5, face: b.x, onStart: give),   // claw up: here you go
                Step(clip: bank.cHappy, hold: 0.45, hopV: 50)]
      steps += clawdTrip(to: a.home, car: car)
    } else {
      steps += dash(a, from: a.x, to: spot, onGo: pickUp)
      steps += [Step(clip: bank.xReview.still(2), hold: 0.5, onStart: give),                // both arms up: here
                Step(clip: bank.xWave)]
      steps += dash(a, from: spot, to: a.home)
    }
    steps[steps.count - 1].onEnd = { self.end() }
    a.enqueue(steps)
  }

  /// Where a buddy holds what it carries, from its feet: over its head. In the kart Clawd's head is a little
  /// forward; on the cloud he rides too high for that, so he holds it out in front.
  private func carryTarget(_ b: Buddy) -> CGVector {
    if b.who == .codex { return CGVector(dx: 0, dy: 25 + b.hop) }
    let ahead: CGFloat = b.facingLeft ? -1 : 1
    switch b.step?.clip?.size {
    case bank.cRaceDrive.size?: return CGVector(dx: ahead * 6, dy: 22)
    case bank.cCloudRide.size?: return CGVector(dx: ahead * 15, dy: 18)
    default: return CGVector(dx: 0, dy: 21 + b.hop)
    }
  }

  private func carryPoint(_ b: Buddy) -> CGPoint {
    let o = b.carryOffset ?? carryTarget(b)
    return CGPoint(x: b.x + o.dx, y: ground + o.dy)
  }

  /// Moves what a buddy carries toward where it should be held, so it glides when the buddy changes pose.
  private func easeCarry(_ b: Buddy, _ dt: Double) {
    guard b.carry != nil else { b.carryOffset = nil; return }
    let t = carryTarget(b), k = CGFloat(min(1, dt * 10))
    guard let o = b.carryOffset else { b.carryOffset = t; return }
    b.carryOffset = CGVector(dx: o.dx + (t.dx - o.dx) * k, dy: o.dy + (t.dy - o.dy) * k)
  }

  // MARK: Codex's habits

  /// A stretch of Codex's run to `to`, heading `dir` (+1 right, -1 left): the four stride frames of that direction's
  /// row, one per ~8pt travelled, so his feet keep up with the ground at any speed (the sheet's own timing is for
  /// running in place). Slow enough, it's a tiptoe.
  private func run(_ dir: CGFloat, to: CGFloat, speed: CGFloat, clipRect: CGRect? = nil, onStart: (() -> Void)? = nil) -> Step {
    var legs = (dir > 0 ? bank.xRunR : bank.xRunL).slice(2...5)
    legs.durations = Array(repeating: Double(8 / speed), count: legs.frames.count)
    return Step(clip: legs, loop: true, moveTo: to, speed: speed, clipRect: clipRect, onStart: onStart)
  }

  /// Codex's run from one spot to another: a dust puff as he takes off (a trail of it when he sprints), legs striding
  /// in time with his speed, then slowing steps into a stop exactly on `to`.
  private func dash(_ b: Buddy, from: CGFloat, to: CGFloat, fast: CGFloat = 130, clipRect: CGRect? = nil,
                    onGo: (() -> Void)? = nil, onBrake: (() -> Void)? = nil, onStop: (() -> Void)? = nil) -> [Step] {
    let dir: CGFloat = to >= from ? 1 : -1
    let row = dir > 0 ? bank.xRunR : bank.xRunL
    let slow: CGFloat = 45
    let brakeAt = abs(to - from) > 30 ? to - dir * 14 : from   // too short a hop to bother slowing down
    let dust = { (ahead: CGFloat) in
      let p = CGPoint(x: b.x + dir * ahead, y: self.ground + 3)
      if clipRect?.contains(p) ?? true { self.puff(at: p, color: Palette.white) }   // (none over a button he's behind)
    }
    return [
      Step(clip: row.still(1), hold: 0.12, clipRect: clipRect, onStart: onGo),                            // lean into the first step
      run(dir, to: brakeAt, speed: fast, clipRect: clipRect, onStart: {
        dust(-6)
        if fast > 150 { self.kickUpDust(b, speed: fast) }
      }),
      run(dir, to: to, speed: slow, clipRect: clipRect, onStart: { dust(6); onBrake?() }),
      Step(clip: row.still(7), hold: 0.2, clipRect: clipRect, onStart: onStop),                          // planted, facing where he ran
    ]
  }

  /// Little dust clouds behind a sprinting buddy, for as long as the sprint lasts (none while behind a button).
  private func kickUpDust(_ b: Buddy, speed: CGFloat) {
    guard let s = b.step, s.speed == speed, let target = s.moveTo else { return }
    let back: CGFloat = target > b.x ? -1 : 1
    if s.clipRect?.contains(CGPoint(x: b.x, y: 5)) ?? true {
      emit(.bitmap(Sprite.dust, Palette.white), at: CGPoint(x: b.x + back * 8, y: ground + 2), vx: back * 14, vy: 7, life: 0.35, size: 0.6)
    }
    after(0.07) { self.kickUpDust(b, speed: speed) }
  }

  /// Zoomies: he tears back and forth across his pocket, kicking up dust at every turn, then beams.
  private func zoomies(_ x: Buddy) -> [Step] {
    let lo = x.pocket.minX + 12, hi = x.pocket.maxX - 12
    var steps = [Step(clip: bank.xRunR.still(1), hold: 0.12)]
    var at = x.x, dir: CGFloat = 1
    for to in [hi, lo, hi, lo, x.home] {
      dir = to >= at ? 1 : -1
      let turn = at
      steps.append(run(dir, to: to, speed: 115, onStart: { self.puff(at: CGPoint(x: turn, y: self.ground + 3), color: Palette.white) }))
      at = to
    }
    return steps + [Step(clip: (dir > 0 ? bank.xRunR : bank.xRunL).still(7), hold: 0.2),
                    Step(clip: bank.xReview, onStart: { self.sparkle(at: CGPoint(x: x.x, y: 22)) })]
  }

  /// Stargazing: he tips his head back, stars twinkle over the bar, a shooting star streaks by and he follows it. Wow.
  private func stargaze(_ x: Buddy) -> [Step] {
    let twinkle = {
      for i in 0..<5 {
        self.after(Double(i) * 0.3) {
          self.emit(.bitmap(Sprite.star, Palette.gold), at: CGPoint(x: x.x + .random(in: -26...26), y: .random(in: 24...28)),
                    vx: 0, vy: 0, life: 0.7, size: Bool.random() ? 1 : 0.67)
        }
      }
    }
    let shootingStar = {
      let start = CGPoint(x: x.x + 28, y: 28.5)
      self.emit(.bitmap(Sprite.star, Palette.white), at: start, vx: -80, vy: -10, life: 0.6)
      for i in 1...6 {
        let t = Double(i) * 0.07
        self.after(t) {
          self.emit(.bitmap(Sprite.star, Palette.gold), at: CGPoint(x: start.x - 80 * CGFloat(t), y: start.y - 10 * CGFloat(t)),
                    vx: 0, vy: 0, life: 0.3, size: 0.5)
        }
      }
    }
    return [Step(clip: bank.codexLook(degrees: 0), hold: 1.4, onStart: twinkle),          // looks up
            Step(clip: bank.codexLook(degrees: 22.5), hold: 0.45, onStart: shootingStar),  // there!
            Step(clip: bank.codexLook(degrees: 337.5), hold: 0.9),                        // follows it
            Step(clip: bank.codexLook(degrees: 0), hold: 0.5),
            Step(clip: bank.xReview)]                                                      // ^^
  }

  /// A little dance: a hop, a head bob to each side, arms up, a wave and a jump, with music notes.
  private func dance(_ x: Buddy) -> [Step] {
    let notes = {
      for i in 0..<6 {
        self.after(Double(i) * 0.45) {
          self.emit(.bitmap(Sprite.note, Palette.white), at: CGPoint(x: x.x + .random(in: -12...12), y: 20), vx: .random(in: -8...8), vy: 12, life: 1.1)
        }
      }
    }
    let bob = [292.5, 67.5, 292.5, 67.5].map { Step(clip: bank.codexLook(degrees: CGFloat($0)), hold: 0.26, hopV: 30) }
    return [Step(clip: bank.xJump, onStart: notes)] + bob
      + [Step(clip: bank.xReview.slice(1...3)), Step(clip: bank.xWave), Step(clip: bank.xReview.still(2), hold: 0.4, hopV: 45),
         Step(clip: bank.xJump)]
  }

  /// He ducks behind the Mission Control button, peeks back out at you (twice), then pops out: ta-da.
  private func codexPeek(_ x: Buddy) -> [Step] {
    let p = x.pocket, hide = p.maxX + 12, peek = p.maxX - 1
    let look = bank.codexLook(degrees: 292.5)   // (straight left is a profile: the face hardly shows)
    return [Step(clip: bank.xRunR.still(1), hold: 0.12),
            run(1, to: hide, speed: 50, clipRect: p),
            Step(clip: bank.xIdle, hold: 0.9, clipRect: p),                     // gone…
            Step(clip: look, moveTo: peek, speed: 22, clipRect: p),             // …leans out
            Step(clip: look, hold: 1.1, clipRect: p),
            Step(clip: look, moveTo: hide, speed: 80, clipRect: p),             // ducks back
            Step(clip: bank.xIdle, hold: 0.6, clipRect: p),
            Step(clip: look, moveTo: peek, speed: 45, clipRect: p),             // peeks again
            Step(clip: look, hold: 0.5, clipRect: p)]
      + dash(x, from: peek, to: x.home, clipRect: p)
      + [Step(clip: bank.xJump, onStart: { self.sparkle(at: CGPoint(x: x.x, y: 22)) })]
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

  /// Sends something flying. Thrown during a game, it belongs to that game.
  private func fire(_ p: Projectile) {
    var p = p
    p.game = interacting ? game : 0
    projectiles.append(p)
  }

  /// Throw something from `a` to `b`. The catcher raises its arms just before it lands.
  private func throwThing(_ e: Effect, from a: Buddy, to b: Buddy, arc: CGFloat, slow: Double = 1, wobble: CGFloat = 0,
                          onArrive: @escaping () -> Void) {
    var p = makeProjectile(e, from: a, to: b, arc: arc)
    p.duration *= slow
    p.wobble = wobble
    p.onArrive = onArrive
    fire(p)
    if b.playing {
      after(max(0, p.duration - 0.5)) { b.enqueue([self.armsUp(b, toward: a, hold: 0.5, catching: true)]) }
    }
  }

  private func emit(_ e: Effect, at p: CGPoint, vx: CGFloat = 0, vy: CGFloat = 12, life: Double = 1.1, size: CGFloat = 1,
                    behind: Bool = false) {
    particles.append(Particle(effect: e, x: p.x, y: p.y, vx: vx, vy: vy, life: life, size: size, behind: behind))
  }

  private func sparkle(at p: CGPoint, color: CGColor = Palette.gold) {
    for _ in 0..<4 {
      emit(.bitmap(Sprite.star, color), at: CGPoint(x: p.x + .random(in: -9...9), y: p.y + .random(in: -3...3)),
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

  /// Stars circling a dazed buddy's head.
  private func dizzy(_ b: Buddy, seconds: Double) {
    for i in 0..<Int(seconds / 0.1) {
      after(Double(i) * 0.1) {
        let a = Double(i) * 1.1
        self.emit(.bitmap(Sprite.star, Palette.gold), at: CGPoint(x: b.x + CGFloat(cos(a)) * 8, y: self.ground + 24 + CGFloat(sin(a)) * 1.5),
                  vx: 0, vy: 0, life: 0.3, size: 0.67)
      }
    }
  }

  // MARK: Drawing

  func draw(_ ctx: CGContext) {
    for p in particles where p.behind { drawParticle(p, ctx) }
    let order = [clawd, codex].sorted { ($0.inPocket ? 0 : 1) < ($1.inPocket ? 0 : 1) }
    for b in order where has(b) { drawBuddy(b, ctx) }
    for p in projectiles { drawProjectile(p, ctx) }
    for p in particles where !p.behind { drawParticle(p, ctx) }
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
      switch b.pose {
      case .sleep:
        alpha = 0.8
        if b.who == .clawd {
          clip = Int(now / 1.4) % 2 == 0 ? bank.cLoaf : bank.cLoafBreath
        } else {
          clip = bank.xSleep
          squash = 1 - 0.025 * CGFloat(0.5 + 0.5 * sin(now * 2 * .pi / 2.8))
        }
      case .work:
        // Codex's working row changes his face every frame, so it runs at half speed normally (calm typing);
        // ultra speeds it up (2× that for Codex, 3× for Clawd).
        clip = b.who == .clawd ? bank.cWorkLoop : bank.xWork.speed(0.5)
        if b.state.ultra { clip = clip.speed(b.who == .clawd ? 3 : 2) }   // typing like mad
        frame = clip.index(at: now, loop: true)
      case .idle:
        if let s = b.still, now < b.stillUntil { clip = s }
        else { clip = b.who == .clawd ? bank.cStand : bank.xIdleCalm; frame = clip.index(at: now, loop: true) }
      }
    }
    if now < b.shakeUntil { drawX += Int(now * 20) % 2 == 0 ? -1 : 1 }
    drawUltraGlow(b, ctx)
    if b.who == .clawd && b.state.ultra { clip = bank.violet(clip) }
    clip.draw(frame, in: ctx, x: drawX, y: ground + b.hop, mirror: mirror, alpha: alpha, squashY: squash)
    b.drawnRect = CGRect(x: drawX - clip.anchorX, y: 0, width: clip.size.width, height: 30)
    if let item = b.carry { draw(item, at: carryPoint(b), size: 1, alpha: 1, flip: false, outline: true, ctx) }
    if b.step?.clipRect != nil && (b.step?.run == true || b.step?.clip != nil) { ctx.restoreGState() }

    // Claude Code's spinner above Clawd while he works.
    // In ultracode it turns violet and spins much faster.
    if b.who == .clawd && b.pose == .work && !b.busy {
      let frames = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"]
      let beat = b.state.ultra ? 0.045 : 0.12
      drawGlyph(frames[Int(now / beat) % frames.count], at: CGPoint(x: b.x - 5, y: 22.5),
                color: b.state.ultra ? Palette.violet : Palette.clawd, size: 9)
    }
  }

  /// A soft violet glow behind a buddy in ultra mode: it pulses, flares up as ultra starts and fades out after.
  private func drawUltraGlow(_ b: Buddy, _ ctx: CGContext) {
    let flare = max(0, 1 - (now - b.ultraStart) / 0.6)
    let strength = b.state.ultra ? 1 : max(0, 1 - (now - b.ultraEnd) / 0.6)
    guard strength > 0 else { return }
    let pulse = 0.5 + 0.5 * sin(now * 4)
    let alpha = CGFloat(strength * (0.2 + 0.1 * pulse) + 0.45 * flare)
    let center = CGPoint(x: b.x + (b.who == .clawd ? 4 : 2), y: ground + 10 + b.hop)
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [Palette.violetDeep.copy(alpha: alpha)!, Palette.violetDeep.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    // Squash the circle into a wide oval so it fits the 30pt bar.
    ctx.translateBy(x: center.x, y: center.y)
    ctx.scaleBy(x: 1.3, y: 0.8)
    ctx.drawRadialGradient(glow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: CGFloat(17 + 8 * flare), options: [])
    ctx.restoreGState()
  }

  private func position(of p: Projectile) -> CGPoint {
    let u = CGFloat(min(1, max(0, (now - p.start) / p.duration)))
    let x = p.from.x + (p.to.x - p.from.x) * u
    var y = p.from.y + (p.to.y - p.from.y) * u + p.arc * 4 * u * (1 - u)
    y += p.wobble * CGFloat(sin(Double(u) * 12))
    return CGPoint(x: x, y: min(y, 26))
  }

  private func drawProjectile(_ p: Projectile, _ ctx: CGContext) {
    draw(p.effect, at: position(of: p), size: 1, alpha: 1, flip: p.to.x < p.from.x, outline: true, ctx)
  }

  private func drawParticle(_ p: Particle, _ ctx: CGContext) {
    let fade = CGFloat(max(0, 1 - pow(p.age / p.life, 2)))
    if case let .ring(color) = p.effect {
      let r = p.size * CGFloat(0.35 + 0.65 * sqrt(p.age / p.life))   // starts around the buddy, eases out
      ctx.saveGState()
      ctx.setAlpha(fade)
      ctx.setStrokeColor(color)
      ctx.setLineWidth(1.5)
      ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r * 0.55, width: r * 2, height: r * 1.1))
      ctx.restoreGState()
      return
    }
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
    case .ring:
      break   // only ever a particle (drawParticle)
    }
    ctx.restoreGState()
  }

  /// Text glyphs (the ✻ spinner, code symbols) are laid out once and then reused as images: cheaper every frame.
  private var glyphs: [String: (image: CGImage, size: CGSize)] = [:]

  private func drawGlyph(_ s: String, at p: CGPoint, color: CGColor, size: CGFloat, outline: Bool = false) {
    let key = "\(s)|\(color.components ?? [])|\(size)|\(outline)"
    if glyphs[key] == nil {
      let font = NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
      var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .white]
      if outline { attrs[.strokeColor] = NSColor.black; attrs[.strokeWidth] = -3.0 }
      let str = NSAttributedString(string: s, attributes: attrs)
      let sz = str.size()
      let bitmap = CGContext(data: nil, width: Int(ceil(sz.width * 2)), height: Int(ceil(sz.height * 2)), bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      bitmap.scaleBy(x: 2, y: 2)
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
      str.draw(at: .zero)
      NSGraphicsContext.restoreGraphicsState()
      glyphs[key] = (bitmap.makeImage()!, sz)
    }
    guard let g = glyphs[key], let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.draw(g.image, in: CGRect(x: p.x - g.size.width / 2, y: p.y - g.size.height / 2, width: g.size.width, height: g.size.height))
  }
}
