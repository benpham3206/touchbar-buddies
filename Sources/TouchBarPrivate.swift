import AppKit
import ObjectiveC

// Private DFRFoundation / NSTouchBar API used by every "always-on" Touch Bar tool.
// Verified on macOS 27: placement 1 covers the whole bar, including the Expanded Control Strip.
enum TouchBarPrivate {
  private static let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)

  /// True on Macs with a Touch Bar: macOS only runs the processes that drive it (TouchBarServer, which
  /// starts at boot, and ControlStrip) when one is built in.
  static var hardwarePresent: Bool {
    var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    return pids.prefix(Int(max(0, count))).contains { pid in
      var name = [CChar](repeating: 0, count: 64)
      proc_name(pid, &name, UInt32(name.count))
      let s = String(cString: name)
      return s == "TouchBarServer" || s == "ControlStrip"
    }
  }

  static func setControlStripPresence(_ id: NSTouchBarItem.Identifier, _ present: Bool) {
    guard let f = dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier") else { return }
    typealias F = @convention(c) (NSString, Bool) -> Void
    unsafeBitCast(f, to: F.self)(id.rawValue as NSString, present)
  }

  static func showCloseBoxWhenFrontmost(_ show: Bool) {
    guard let f = dlsym(dfr, "DFRSystemModalShowsCloseBoxWhenFrontMost") else { return }
    typealias F = @convention(c) (Bool) -> Void
    unsafeBitCast(f, to: F.self)(show)
  }

  static func addSystemTrayItem(_ item: NSTouchBarItem) { callItem("addSystemTrayItem:", item) }
  static func removeSystemTrayItem(_ item: NSTouchBarItem) { callItem("removeSystemTrayItem:", item) }

  /// Shows `bar` over the whole Touch Bar (placement 1), with our item standing in for the Control Strip.
  static func present(_ bar: NSTouchBar, trayID: NSTouchBarItem.Identifier) {
    let cls: AnyClass = NSTouchBar.self
    let sel = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
    if let m = class_getClassMethod(cls, sel) {
      typealias F = @convention(c) (AnyClass, Selector, NSTouchBar, Int64, NSString) -> Void
      unsafeBitCast(method_getImplementation(m), to: F.self)(cls, sel, bar, 1, trayID.rawValue as NSString)
      return
    }
    // Older systems: no placement argument.
    let legacy = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
    if let m = class_getClassMethod(cls, legacy) {
      typealias F = @convention(c) (AnyClass, Selector, NSTouchBar, NSString) -> Void
      unsafeBitCast(method_getImplementation(m), to: F.self)(cls, legacy, bar, trayID.rawValue as NSString)
    }
  }

  static func dismiss(_ bar: NSTouchBar) { callBar("dismissSystemModalTouchBar:", bar) }

  private static func callItem(_ name: String, _ item: NSTouchBarItem) {
    let cls: AnyClass = NSTouchBarItem.self
    let sel = NSSelectorFromString(name)
    guard let m = class_getClassMethod(cls, sel) else { return }
    typealias F = @convention(c) (AnyClass, Selector, NSTouchBarItem) -> Void
    unsafeBitCast(method_getImplementation(m), to: F.self)(cls, sel, item)
  }

  private static func callBar(_ name: String, _ bar: NSTouchBar) {
    let cls: AnyClass = NSTouchBar.self
    let sel = NSSelectorFromString(name)
    guard let m = class_getClassMethod(cls, sel) else { return }
    typealias F = @convention(c) (AnyClass, Selector, NSTouchBar) -> Void
    unsafeBitCast(method_getImplementation(m), to: F.self)(cls, sel, bar)
  }
}
