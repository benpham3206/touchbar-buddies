import AppKit
import ApplicationServices
import AudioToolbox
import CoreAudio

// The actions behind the recreated Control Strip buttons.
// Brightness, volume, mute and keyboard backlight are driven directly (no permissions needed).
// Media keys are posted as real key events when Accessibility is granted, else sent via MediaRemote.
enum SystemControls {
  // MARK: Display brightness (DisplayServices)

  private static let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)

  private static var builtinDisplay: CGDirectDisplayID {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &count)
    return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
  }

  static var brightness: Float {
    get {
      guard let f = dlsym(displayServices, "DisplayServicesGetBrightness") else { return 0.5 }
      typealias F = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
      var value: Float = 0.5
      _ = unsafeBitCast(f, to: F.self)(builtinDisplay, &value)
      return value
    }
    set {
      guard let f = dlsym(displayServices, "DisplayServicesSetBrightness") else { return }
      typealias F = @convention(c) (CGDirectDisplayID, Float) -> Int32
      _ = unsafeBitCast(f, to: F.self)(builtinDisplay, min(1, max(0, newValue)))
    }
  }

  // MARK: Output volume (CoreAudio)

  private static func defaultOutputDevice() -> AudioDeviceID {
    var device = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
    return device
  }

  static var volume: Float {
    get {
      var value: Float32 = 0
      var size = UInt32(MemoryLayout<Float32>.size)
      var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
      AudioObjectGetPropertyData(defaultOutputDevice(), &address, 0, nil, &size, &value)
      return value
    }
    set {
      var value = Float32(min(1, max(0, newValue)))
      var address = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
      AudioObjectSetPropertyData(defaultOutputDevice(), &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
      if muted && value > 0 { muted = false }   // like the hardware keys: changing volume unmutes
    }
  }

  static var muted: Bool {
    get {
      var value: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
      AudioObjectGetPropertyData(defaultOutputDevice(), &address, 0, nil, &size, &value)
      return value != 0
    }
    set {
      var value: UInt32 = newValue ? 1 : 0
      var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
      AudioObjectSetPropertyData(defaultOutputDevice(), &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }
  }

  // MARK: Keyboard backlight (CoreBrightness)

  private static let keyboardClient: NSObject? = {
    _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
    return (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
  }()

  private static let keyboardID: UInt64 = {
    let sel = NSSelectorFromString("copyKeyboardBacklightIDs")
    guard let client = keyboardClient, client.responds(to: sel),
          let ids = client.perform(sel)?.takeRetainedValue() as? [NSNumber], let first = ids.first else { return 1 }
    return first.uint64Value
  }()

  static var keyboardBrightness: Float {
    get {
      let sel = NSSelectorFromString("brightnessForKeyboard:")
      guard let client = keyboardClient, let m = class_getInstanceMethod(type(of: client), sel) else { return 0 }
      typealias F = @convention(c) (AnyObject, Selector, UInt64) -> Float
      return unsafeBitCast(method_getImplementation(m), to: F.self)(client, sel, keyboardID)
    }
    set {
      let sel = NSSelectorFromString("setBrightness:forKeyboard:")
      guard let client = keyboardClient, let m = class_getInstanceMethod(type(of: client), sel) else { return }
      typealias F = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
      _ = unsafeBitCast(method_getImplementation(m), to: F.self)(client, sel, min(1, max(0, newValue)), keyboardID)
    }
  }

  static func stepKeyboard(up: Bool) {
    let step: Float = 1.0 / 16
    let current = (keyboardBrightness / step).rounded() * step
    keyboardBrightness = current + (up ? step : -step)
  }

  // MARK: Media keys

  enum Media { case previous, playPause, next }

  private static let mediaRemote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
  private static var askedForAccessibility: Bool {
    get { UserDefaults.standard.bool(forKey: "askedForAccessibility") }
    set { UserDefaults.standard.set(newValue, forKey: "askedForAccessibility") }
  }

  static var hasAccessibility: Bool { AXIsProcessTrusted() }

  static func requestAccessibility() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
  }

  static func media(_ m: Media) {
    if hasAccessibility {
      // NX_KEYTYPE_PLAY = 16, NEXT = 17, PREVIOUS = 18 — identical to pressing the hardware keys.
      postAuxKey(m == .playPause ? 16 : m == .next ? 17 : 18)
      return
    }
    if let f = dlsym(mediaRemote, "MRMediaRemoteSendCommand") {
      typealias F = @convention(c) (UInt32, CFDictionary?) -> Bool
      _ = unsafeBitCast(f, to: F.self)(m == .playPause ? 2 : m == .next ? 4 : 5, nil)
    }
    if !askedForAccessibility {
      askedForAccessibility = true
      requestAccessibility()
    }
  }

  private static func postAuxKey(_ key: Int) {
    for down in [true, false] {
      let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
      let data1 = (key << 16) | ((down ? 0xA : 0xB) << 8)
      let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
      event?.cgEvent?.post(tap: .cghidEventTap)
    }
  }

  // MARK: Apps & power

  static func openApp(path: String) {
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init())
  }

  static func missionControl() { openApp(path: "/System/Applications/Mission Control.app") }

  static func launchpad() {
    let fm = FileManager.default
    for p in ["/System/Applications/Apps.app", "/System/Applications/Launchpad.app"] where fm.fileExists(atPath: p) {
      openApp(path: p)
      return
    }
  }

  static func sleep() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["sleepnow"]
    try? p.run()
  }

  static func lockScreen() {
    let login = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW)
    if let f = dlsym(login, "SACLockScreenImmediate") {
      typealias F = @convention(c) () -> Int32
      _ = unsafeBitCast(f, to: F.self)()
    }
  }
}
