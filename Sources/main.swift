import AppKit

// The app: puts StripView on the Touch Bar (replacing the Control Strip), feeds it what Claude and Codex
// are doing (ActivityMonitor), and adds the menu bar icon. Command-line modes are at the bottom.
final class AppDelegate: NSObject, NSApplicationDelegate, NSTouchBarDelegate, NSMenuDelegate {
  static let stripID = NSTouchBarItem.Identifier("dev.touchbarbuddies.strip")
  static let trayID = NSTouchBarItem.Identifier("dev.touchbarbuddies.tray")
  /// The LaunchAgent that starts us at login (install.sh writes the same one).
  static let agentLabel = "dev.touchbarbuddies"
  static var agentURL: URL { home("Library/LaunchAgents/\(agentLabel).plist") }
  /// Where the LaunchAgent (and `./tbb run`) sends our output; `./tbb logs` shows it.
  static var logURL: URL { home("Library/Logs/TouchBarBuddies.log") }
  private static func home(_ path: String) -> URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path) }

  private var scene: Scene!
  private var strip: StripView!
  private let monitor = ActivityMonitor()
  private let bar = NSTouchBar()
  private var trayItem: NSCustomTouchBarItem!
  private var statusItem: NSStatusItem!
  private var signalSources: [DispatchSourceSignal] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Nothing to do on a Mac without a Touch Bar. Exiting cleanly (0) also tells launchd not to restart us.
    guard TouchBarPrivate.hardwarePresent else {
      NSLog("Touch Bar Buddies: this Mac has no Touch Bar, so there is nothing to show. Quitting.")
      exit(0)
    }
    scene = Scene(bank: Bank(resources: AssetCache.prepare()))
    scene.onLaunch = { who in AppLauncher.open(who) }
    scene.onFocus = { who in AppLauncher.focus(who) }
    strip = StripView(scene: scene)

    // Our bar covers the whole Touch Bar. macOS wants a tray item for it (tapping it brings the bar back).
    bar.delegate = self
    bar.defaultItemIdentifiers = [Self.stripID]
    trayItem = NSCustomTouchBarItem(identifier: Self.trayID)
    let trayButton = NSButton(image: Self.clawdIcon(), target: self, action: #selector(presentBar))
    trayItem.view = trayButton
    TouchBarPrivate.showCloseBoxWhenFrontmost(false)
    TouchBarPrivate.addSystemTrayItem(trayItem)
    TouchBarPrivate.setControlStripPresence(Self.trayID, true)
    presentBar()
    strip.start()

    // The buddies follow their apps: asleep when closed, typing while busy.
    monitor.onChange = { [weak self] claude, codex in
      guard let self else { return }
      self.scene.setState(self.scene.clawd, claude)
      self.scene.setState(self.scene.codex, codex)
    }
    // macOS drops our bar when the Touch Bar restarts, wakes or unlocks, so show it again then.
    monitor.onTouchBarServerRestart = { [weak self] in
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.presentBar() }
    }
    monitor.start()

    let ws = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
      ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.strip.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.presentBar() }
      }
    }
    ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.strip.stop() }
    DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
      self?.presentBar()
    }

    restoreBarWhenStopped()
    listenForCommands()
    setUpStatusItem()
  }

  func applicationWillTerminate(_ notification: Notification) { restoreNativeBar() }

  func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
    guard identifier == Self.stripID else { return nil }
    let item = NSCustomTouchBarItem(identifier: identifier)
    item.view = strip
    return item
  }

  @objc func presentBar() {
    TouchBarPrivate.present(bar, trayID: Self.trayID)
  }

  private func restoreNativeBar() {
    TouchBarPrivate.dismiss(bar)
    TouchBarPrivate.setControlStripPresence(Self.trayID, false)
    TouchBarPrivate.removeSystemTrayItem(trayItem)
  }

  /// Put the native Control Strip back when launchd, logout or Ctrl-C stops us.
  private func restoreBarWhenStopped() {
    for sig in [SIGTERM, SIGINT, SIGHUP] {
      signal(sig, SIG_IGN)
      let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
      src.setEventHandler { [weak self] in
        self?.restoreNativeBar()
        exit(0)
      }
      src.resume()
      signalSources.append(src)
    }
  }

  // MARK: Debug commands (`./tbb send <command>`)

  /// Other processes can trigger animations by posting a distributed notification whose object is the command.
  private func listenForCommands() {
    DistributedNotificationCenter.default().addObserver(forName: .init("dev.touchbarbuddies.command"), object: nil, queue: .main) { [weak self] n in
      if let command = n.object as? String { self?.handle(command) }
    }
  }

  /// App-level commands live here; everything else is an animation (Scene.command).
  /// Render.swift mirrors these for offline renders.
  private func handle(_ command: String) {
    switch command {
    case "absent-claude": monitor.pretendAbsent[.claude] = !(monitor.pretendAbsent[.claude] ?? false)
    case "absent-codex": monitor.pretendAbsent[.codex] = !(monitor.pretendAbsent[.codex] ?? false)
    case "work-claude": toggleClaudeWork()
    case "work-codex": toggleCodexWork()
    case "slider-volume", "slider-brightness": strip.openPopover(volume: command == "slider-volume")
    default: scene.command(command)
    }
  }

  // MARK: Menu bar

  private func setUpStatusItem() {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.image = Self.clawdIcon()
    statusItem.button?.toolTip = "Touch Bar Buddies"
    let menu = NSMenu()
    menu.delegate = self
    statusItem.menu = menu
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    menu.removeAllItems()
    func describe(_ s: AgentState) -> String { !s.present ? "asleep — tap to open" : s.working ? "working" : "hanging out" }
    let header = { (t: String) in let i = NSMenuItem(title: t, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }
    menu.addItem(header("Clawd: \(describe(monitor.claude))"))
    menu.addItem(header("Codex: \(describe(monitor.codex))"))
    menu.addItem(.separator())
    menu.addItem(item("Play Together", #selector(playTogether)))
    menu.addItem(item("Visits Across the Bar", #selector(toggleRoaming), on: scene.roaming))
    menu.addItem(item("Pretend Claude Is Working", #selector(toggleClaudeWork), on: monitor.pretendWorking[.claude] == true))
    menu.addItem(item("Pretend Codex Is Working", #selector(toggleCodexWork), on: monitor.pretendWorking[.codex] == true))
    menu.addItem(.separator())
    if !SystemControls.hasAccessibility {
      menu.addItem(item("Allow Window Tiling & Media Keys…", #selector(enableMediaKeys)))
    }
    menu.addItem(item("Open at Login", #selector(toggleLogin), on: FileManager.default.fileExists(atPath: Self.agentURL.path)))
    menu.addItem(item("Refresh Touch Bar", #selector(presentBar)))
    menu.addItem(item("Rebuild Sprites", #selector(rebuildSprites)))
    menu.addItem(.separator())
    menu.addItem(item("Quit Touch Bar Buddies", #selector(quit)))
  }

  private func item(_ title: String, _ action: Selector, on: Bool? = nil) -> NSMenuItem {
    let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
    i.target = self
    if let on { i.state = on ? .on : .off }
    return i
  }

  @objc private func playTogether() { scene.playTogether() }
  @objc private func toggleRoaming() { scene.roaming.toggle() }
  @objc private func toggleClaudeWork() { monitor.pretendWorking[.claude] = !(monitor.pretendWorking[.claude] ?? false) }
  @objc private func toggleCodexWork() { monitor.pretendWorking[.codex] = !(monitor.pretendWorking[.codex] ?? false) }
  @objc private func enableMediaKeys() { SystemControls.requestAccessibility() }

  @objc private func toggleLogin() {
    let fm = FileManager.default
    if fm.fileExists(atPath: Self.agentURL.path) {
      try? fm.removeItem(at: Self.agentURL)
    } else {
      let plist: [String: Any] = [
        "Label": Self.agentLabel,
        "ProgramArguments": [Bundle.main.executablePath!],
        "RunAtLoad": true,
        "KeepAlive": ["SuccessfulExit": false],   // restart after a crash, not after Quit
        "LimitLoadToSessionType": "Aqua",
        "ProcessType": "Interactive",
        "StandardOutPath": Self.logURL.path,
        "StandardErrorPath": Self.logURL.path,
      ]
      try? fm.createDirectory(at: Self.agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      (plist as NSDictionary).write(to: Self.agentURL, atomically: true)
    }
  }

  // MARK: Sprites (AssetCache.swift)

  private var rebuilding = false

  /// Re-extracts every sprite in the background, then swaps the new art in.
  @objc private func rebuildSprites() {
    guard !rebuilding else { return }
    rebuilding = true
    DispatchQueue.global(qos: .userInitiated).async {
      AssetCache.build(force: true)
      let bank = Bank(resources: AssetCache.directory)
      DispatchQueue.main.async {
        self.rebuilding = false
        self.scene.bank = bank
        // A buddy that just got his sprites picks up what his app is doing right now.
        self.scene.setState(self.scene.clawd, self.monitor.claude)
        self.scene.setState(self.scene.codex, self.monitor.codex)
      }
    }
  }

  @objc private func quit() {
    restoreNativeBar()
    NSApp.terminate(nil)
  }

  /// Clawd's silhouette as a menu-bar template image (his 2×2 art pixels → 1.5pt squares).
  static func clawdIcon() -> NSImage {
    let rows = [
      "..########..",
      "..#.####.#..",
      "############",
      "############",
      "..########..",
      "..########..",
      "..#.#..#.#..",
      "..#.#..#.#..",
    ]
    let s: CGFloat = 1.5
    let img = NSImage(size: NSSize(width: 12 * s, height: 12 * s), flipped: true) { _ in
      NSColor.black.setFill()
      for (y, row) in rows.enumerated() {
        for (x, ch) in row.enumerated() where ch == "#" {
          NSRect(x: CGFloat(x) * s, y: CGFloat(y) * s + 3, width: s, height: s).fill()
        }
      }
      return true
    }
    img.isTemplate = true
    return img
  }
}

// MARK: - Command line

// `TouchBarBuddies --build-sprites`: rebuild the sprite cache headlessly, report, and exit (see AssetCache.swift).
if CommandLine.arguments.contains("--build-sprites") {
  AssetCache.build(force: true)
  print(AssetCache.summary())
  exit(0)
}

// `TouchBarBuddies --render out.gif …`: draw the Touch Bar offscreen and exit (see Render.swift).
if CommandLine.arguments.contains("--render") {
  exit(Renderer.run(CommandLine.arguments))
}

// Otherwise: run as the menu bar app that owns the Touch Bar.

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
