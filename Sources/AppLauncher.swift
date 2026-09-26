import AppKit
import ApplicationServices

// Opens each buddy's app on its coding screen and tiles the window: Codex on the left half, Claude on the right.
// An app that's already open is just brought forward.
// Tiling uses the Accessibility API, so it only happens once the user has allowed Accessibility.
enum AppLauncher {
  private struct App {
    let bundleID: String
    let link: String?   // deep link to the app's "new coding session" screen
  }

  private static func apps(_ who: Who) -> [App] {
    switch who {
    // ChatGPT.app (the Codex app) routes codex://threads/new?mode=codex to a new thread in Codex mode.
    // The older ChatGPT app has no Codex screen, so it just opens.
    case .codex: return [App(bundleID: ActivityMonitor.codexBundle, link: "codex://threads/new?mode=codex"),
                         App(bundleID: "com.openai.chat", link: nil)]
    // Claude.app routes claude://code/new to a new Claude Code session (the Code tab).
    case .clawd: return [App(bundleID: ActivityMonitor.claudeBundle, link: "claude://code/new")]
    }
  }

  private static func downloadPage(_ who: Who) -> URL {
    URL(string: who == .codex ? "https://chatgpt.com/codex" : "https://claude.ai/download")!
  }

  /// The first of the buddy's apps that is installed, and where it lives.
  private static func installedApp(_ who: Who) -> (App, URL)? {
    for app in apps(who) {
      if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) { return (app, url) }
    }
    return nil
  }

  /// Tapping a sleeping buddy: open its app on the coding screen, then tile it.
  static func open(_ who: Who) { launch(who, withLink: true) }

  /// Tapping an awake buddy: bring its app forward as it is (no navigation, and its window stays where you put it).
  static func focus(_ who: Who) { launch(who, withLink: false) }

  private static func launch(_ who: Who, withLink: Bool) {
    let ws = NSWorkspace.shared
    guard let (app, appURL) = installedApp(who) else {
      ws.open(downloadPage(who))   // not installed: show where to get it
      return
    }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    let done: (NSRunningApplication?, Error?) -> Void = { running, _ in
      guard withLink, let running else { return }   // only a freshly opened app gets tiled
      DispatchQueue.main.async { tile(running, leftHalf: who == .codex) }
    }
    // A new coding session only when the app is starting up; if it's already open, just bring its window
    // forward as it is. (Opening a running app also "reopens" it, which shows a window if all were closed.)
    let alreadyOpen = !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
    if withLink, !alreadyOpen, let link = app.link.flatMap(URL.init(string:)) {
      ws.open([link], withApplicationAt: appURL, configuration: config, completionHandler: done)
    } else {
      ws.openApplication(at: appURL, configuration: config, completionHandler: done)
    }
  }

  // MARK: Tiling (Accessibility)

  /// Moves the app's main window to one half of the main screen. A just-launched app may take a few seconds
  /// to show its window, so keep looking for up to 10 seconds.
  private static func tile(_ app: NSRunningApplication, leftHalf: Bool, until deadline: Date = Date() + 10) {
    guard AXIsProcessTrusted(), !app.isTerminated else { return }   // never prompt from a tap
    guard let window = mainWindow(of: app) else {
      if Date() < deadline {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { tile(app, leftHalf: leftHalf, until: deadline) }
      }
      return
    }
    guard let frame = halfOfScreen(left: leftHalf) else { return }
    setFrame(window, frame)
    // Some apps restore their saved window size right after they appear; put it back once more.
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { setFrame(window, frame) }
  }

  /// The target rectangle in Accessibility coordinates.
  private static func halfOfScreen(left: Bool) -> CGRect? {
    guard let screen = NSScreen.main, let primary = NSScreen.screens.first else { return nil }
    // AppKit puts (0,0) at the bottom-left of the primary (menu bar) screen, y going up;
    // Accessibility puts it at the top-left of that same screen, y going down.
    let visible = screen.visibleFrame   // excludes the menu bar and Dock
    let width = (visible.width / 2).rounded(.down)
    return CGRect(x: left ? visible.minX : visible.maxX - width,
                  y: primary.frame.maxY - visible.maxY,
                  width: width, height: visible.height)
  }

  private static func mainWindow(of app: NSRunningApplication) -> AXUIElement? {
    let ax = AXUIElementCreateApplication(app.processIdentifier)
    for attribute in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
      var value: CFTypeRef?
      if AXUIElementCopyAttributeValue(ax, attribute as CFString, &value) == .success, let value,
         CFGetTypeID(value) == AXUIElementGetTypeID() {
        return (value as! AXUIElement)
      }
    }
    // Not frontmost yet: fall back to the first normal window.
    var list: CFTypeRef?
    guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &list) == .success,
          let windows = list as? [AXUIElement] else { return nil }
    return windows.first { w in
      var subrole: CFTypeRef?
      AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &subrole)
      return subrole as? String == kAXStandardWindowSubrole as String
    }
  }

  private static func setFrame(_ window: AXUIElement, _ frame: CGRect) {
    var origin = frame.origin, size = frame.size
    guard let position = AXValueCreate(.cgPoint, &origin), let dimensions = AXValueCreate(.cgSize, &size) else { return }
    AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    // Size, move, size again: shrinking first keeps the move from being clamped at the screen edge,
    // and the second resize applies anything the old position didn't allow.
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position)
    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, dimensions)
  }
}
