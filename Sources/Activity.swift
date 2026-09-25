import AppKit
import Darwin

// Decides whether Claude / Codex are open and whether they're busy.
// "Busy" = CPU used by the agent process tree (the `claude` / `codex` binaries plus every tool they spawn),
// including time from children that already exited, so short shell commands still count.
struct AgentState: Equatable {
  var appRunning = false   // the desktop app (Claude.app / Codex's ChatGPT.app) is open
  var present = false      // app open, or a CLI session is alive
  var working = false
}

enum AgentKind: String { case claude, codex }

final class ActivityMonitor {
  static let claudeBundle = "com.anthropic.claudefordesktop"
  static let codexBundle = "com.openai.codex"

  var onChange: ((AgentState, AgentState) -> Void)?
  var onTouchBarServerRestart: (() -> Void)?
  var pretendWorking: [AgentKind: Bool] = [:] { didSet { publish() } }
  var pretendAbsent: [AgentKind: Bool] = [:] { didSet { publish() } }

  private(set) var claude = AgentState()
  private(set) var codex = AgentState()

  private let queue = DispatchQueue(label: "dev.touchbarbuddies.activity", qos: .utility)
  private var timer: DispatchSourceTimer?
  private var lastSample: [AgentKind: (cpu: UInt64, wall: UInt64)] = [:]
  private var smoothed: [AgentKind: Double] = [:]
  private var lastBusy: [AgentKind: UInt64] = [:]
  private var cliAlive: [AgentKind: Bool] = [:]
  private var busy: [AgentKind: Bool] = [:]
  private var touchBarServerPID: pid_t = 0
  private let debug = ProcessInfo.processInfo.environment["TBB_DEBUG"] != nil
  private let timebase: (numer: UInt64, denom: UInt64) = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return (UInt64(info.numer), UInt64(info.denom))
  }()

  // Tunables: a tree using more than ~2.5% of a core counts as busy; stay "working" through brief lulls
  // (waiting on the model uses little CPU).
  private let busyThreshold = 0.025
  private let holdSeconds: Double = 8

  func start() {
    let ws = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
      ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.publish() }
    }
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now(), repeating: 1.0, leeway: .milliseconds(200))
    t.setEventHandler { [weak self] in self?.sample() }
    t.resume()
    timer = t
  }

  // MARK: Sampling (background queue)

  private func sample() {
    var ppid: [pid_t: pid_t] = [:]
    var comm: [pid_t: String] = [:]
    for pid in Self.allPIDs() {
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { continue }
      ppid[pid] = pid_t(info.pbi_ppid)
      comm[pid] = withUnsafeBytes(of: info.pbi_comm) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
      }
    }
    var children: [pid_t: [pid_t]] = [:]
    for (child, parent) in ppid { children[parent, default: []].append(child) }

    if let tbs = comm.first(where: { $0.value == "TouchBarServer" })?.key, tbs != touchBarServerPID {
      let restarted = touchBarServerPID != 0
      touchBarServerPID = tbs
      if restarted { DispatchQueue.main.async { self.onTouchBarServerRestart?() } }
    }

    let now = mach_absolute_time()
    for kind in [AgentKind.claude, .codex] {
      var roots = comm.filter { $0.value == kind.rawValue }.map(\.key)
      if kind == .codex { roots.removeAll { Self.path(of: $0).contains("/.codex/plugins/") } }
      // Skip roots nested inside another root so nothing is counted twice.
      let rootSet = Set(roots)
      roots.removeAll { pid in
        var p = ppid[pid] ?? 0
        while p > 1 { if rootSet.contains(p) { return true }; p = ppid[p] ?? 0 }
        return false
      }
      cliAlive[kind] = !roots.isEmpty

      var total: UInt64 = 0
      var stack = roots
      var seen = Set<pid_t>()
      while let pid = stack.popLast() {
        guard seen.insert(pid).inserted else { continue }
        total &+= Self.cpuTicks(pid)
        stack.append(contentsOf: children[pid] ?? [])
      }
      var fraction = 0.0
      if let last = lastSample[kind], now > last.wall, total >= last.cpu {
        fraction = Double((total - last.cpu) * timebase.numer / timebase.denom) / Double((now - last.wall) * timebase.numer / timebase.denom)
      }
      lastSample[kind] = (total, now)
      let ema = 0.5 * (smoothed[kind] ?? 0) + 0.5 * fraction
      smoothed[kind] = ema
      if ema > busyThreshold { lastBusy[kind] = now }
      let sinceBusy = Double((now &- (lastBusy[kind] ?? 0)) * timebase.numer / timebase.denom) / 1e9
      busy[kind] = lastBusy[kind] != nil && sinceBusy < holdSeconds
      if debug {
        FileHandle.standardError.write(String(format: "[activity] %@ roots=%d cpu=%.3f ema=%.3f busy=%@\n", kind.rawValue, roots.count, fraction, ema, busy[kind]! ? "Y" : "n").data(using: .utf8)!)
      }
    }
    DispatchQueue.main.async { self.publish() }
  }

  // MARK: Publishing (main thread)

  private func publish() {
    let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    func state(_ kind: AgentKind, bundle: String) -> AgentState {
      let app = running.contains(bundle)
      let cli = queue.sync { cliAlive[kind] ?? false }
      let isBusy = queue.sync { busy[kind] ?? false }
      if pretendAbsent[kind] == true { return AgentState() }
      let present = app || cli
      return AgentState(appRunning: app, present: present, working: present && (isBusy || pretendWorking[kind] == true))
    }
    let c = state(.claude, bundle: Self.claudeBundle)
    let x = state(.codex, bundle: Self.codexBundle)
    guard c != claude || x != codex else { return }
    claude = c
    codex = x
    onChange?(c, x)
  }

  // MARK: libproc helpers

  private static func allPIDs() -> [pid_t] {
    let capacity = Int(proc_listallpids(nil, 0)) + 64
    var pids = [pid_t](repeating: 0, count: capacity)
    let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    return Array(pids.prefix(Int(max(0, count))))
  }

  private static func path(of pid: pid_t) -> String {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    let n = proc_pidpath(pid, &buf, UInt32(buf.count))
    return n > 0 ? String(cString: buf) : ""
  }

  /// Own CPU + CPU of already-exited children, in mach ticks.
  private static func cpuTicks(_ pid: pid_t) -> UInt64 {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    guard ok == 0 else { return 0 }
    return info.ri_user_time &+ info.ri_system_time &+ info.ri_child_user_time &+ info.ri_child_system_time
  }
}
