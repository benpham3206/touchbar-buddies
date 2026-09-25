import AppKit
import Darwin

// Decides whether Claude / Codex are open and whether they're busy.
// "Busy" = CPU used by the agent process tree (the `claude` / `codex` binaries plus every tool they spawn),
// including time from children that already exited, so short shell commands still count.
struct AgentState: Equatable {
  var appRunning = false   // the desktop app (Claude.app / Codex's ChatGPT.app) is open
  var present = false      // app open, or a CLI session is alive
  var working = false
  var ultra = false        // working in Codex's "ultra" reasoning effort / Claude Code's "ultracode" (see UltraDetector)
}

enum AgentKind: String { case claude, codex }

final class ActivityMonitor {
  static let claudeBundle = "com.anthropic.claudefordesktop"
  static let codexBundle = "com.openai.codex"

  var onChange: ((AgentState, AgentState) -> Void)?
  var onTouchBarServerRestart: (() -> Void)?
  var pretendWorking: [AgentKind: Bool] = [:] { didSet { publish() } }
  var pretendAbsent: [AgentKind: Bool] = [:] { didSet { publish() } }
  var pretendUltra: [AgentKind: Bool] = [:] { didSet { publish() } }   // also makes that buddy work

  private(set) var claude = AgentState()
  private(set) var codex = AgentState()

  private let queue = DispatchQueue(label: "dev.touchbarbuddies.activity", qos: .utility)
  private var timer: DispatchSourceTimer?
  private var lastSample: [AgentKind: (cpu: UInt64, wall: UInt64)] = [:]
  private var smoothed: [AgentKind: Double] = [:]
  private var lastBusy: [AgentKind: UInt64] = [:]
  private var cliAlive: [AgentKind: Bool] = [:]
  private var busy: [AgentKind: Bool] = [:]
  private var ultra: [AgentKind: Bool] = [:]
  private var turnOpen: [AgentKind: Bool] = [:]   // the session logs say a turn is in progress
  private let ultraDetectors: [AgentKind: UltraDetector] = [.claude: ClaudeUltra(), .codex: CodexUltra()]
  private var samples = 0
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
    t.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(500))   // every 2 s: plenty, and easy on the battery
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
    // Session logs, every other second (only the new bytes): is a turn in progress, and is it ultra?
    // A model thinking hard uses almost no local CPU, so an open turn counts as working too.
    samples += 1
    if samples % 1 == 0 {
      for kind in [AgentKind.claude, .codex] {
        let detector = ultraDetectors[kind]!
        let isUltra = detector.check()
        turnOpen[kind] = detector.active
        ultra[kind] = isUltra
        if debug { FileHandle.standardError.write("[logs] \(detector.report) active=\(detector.active)\n".data(using: .utf8)!) }
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
      let isBusy = queue.sync { busy[kind] == true || turnOpen[kind] == true }
      let isUltra = queue.sync { ultra[kind] ?? false }
      if pretendAbsent[kind] == true { return AgentState() }
      let fakeUltra = pretendUltra[kind] == true
      let pretending = pretendWorking[kind] == true || fakeUltra
      // Pretending also wakes the buddy, so the menu switches work even while the app is closed.
      let present = app || cli || pretending
      let working = pretending || (present && isBusy)
      return AgentState(appRunning: app, present: present, working: working, ultra: working && (isUltra || fakeUltra))
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

// MARK: - Ultra / ultracode

// Both agents have a "max power" mode, and both leave a trace of it in their session logs. We only ever read the
// newest bytes of those logs (they grow to many MB). An open turn also counts as "working": a model thinking hard
// uses almost no local CPU.
//
//  • Codex "ultra" reasoning effort. Every Codex session, CLI or desktop app, appends to
//    ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl. Each turn logs a task_started event, then
//    {"type":"turn_context","payload":{"effort":"ultra",…}}, and ends with task_complete (or turn_aborted).
//    Ultra = a rollout touched in the last 10 minutes whose latest turn is still open and has effort "ultra".
//  • Claude Code "ultracode". A prompt containing the keyword gets an attachment right after it in the transcript
//    (~/.claude/projects/<cwd>/<session>.jsonl): {"type":"attachment","attachment":{"type":"workflow_keyword_request"}}.
//    `/effort ultracode` logs "ultra_effort_enter" (and "ultra_effort_exit" when it's switched off again).
//    Ultracode = a busy session whose latest human prompt had that attachment, or that is inside enter…exit.
//    Busy sessions come from Claude Code's own list (~/.claude/sessions/<pid>.json, "status":"busy"); if that
//    list isn't there, any transcript written in the last 90 seconds counts.

protocol UltraDetector: AnyObject {
  func check() -> Bool
  var active: Bool { get }     // the last check saw a turn in progress
  var report: String { get }   // what the last check saw (TBB_DEBUG logging)
}

/// Codex's "ultra" reasoning effort (see above).
final class CodexUltra: UltraDetector {
  private let sessions: String
  private let finder: RecentLogs
  private var logs: [String: (tail: LogTail, effort: String?, open: Bool)] = [:]
  private let dayFolder: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy/MM/dd"
    return f
  }()
  private(set) var report = "codex: not checked yet"
  private(set) var active = false

  /// ~/.codex, or $CODEX_HOME (TBB_CODEX_HOME overrides both, for testing).
  init(home: String = ProcessInfo.processInfo.environment["TBB_CODEX_HOME"] ?? ProcessInfo.processInfo.environment["CODEX_HOME"]
         ?? NSHomeDirectory() + "/.codex") {
    sessions = home + "/sessions"
    finder = RecentLogs(root: sessions, depth: 3)
  }

  func check() -> Bool {
    // Day folders around today (UTC and local dates can differ) are looked at every time; an older session that
    // was picked back up is found by the finder's once-a-minute sweep.
    let days = [-1.0, 0, 1].map { sessions + "/" + dayFolder.string(from: Date(timeIntervalSinceNow: $0 * 86400)) }
    let paths = finder.find(changedWithin: 600, alsoCheck: days)
    if logs.count > 50 { logs = logs.filter { paths.contains($0.key) } }   // keep read positions, within reason
    var found = false
    var anyOpen = false
    var notes: [String] = []
    for path in paths {
      var log = logs[path] ?? (LogTail(path), nil, false)
      log.tail.readNewLines { line in
        // A record's own type sits in its first few hundred bytes; anything later may quote any text at all.
        let head = line.prefix(300)
        if head.has("\"type\":\"turn_context\"") {
          let payload = line.json?["payload"] as? [String: Any]
          let settings = (payload?["collaboration_mode"] as? [String: Any])?["settings"] as? [String: Any]
          log.effort = (payload?["effort"] ?? settings?["reasoning_effort"]) as? String
          log.open = true
        } else if head.has("\"type\":\"event_msg\"") {
          if head.has("\"type\":\"task_started\"") { log.open = true }
          if head.has("\"type\":\"task_complete\"") || head.has("\"type\":\"turn_aborted\"") { log.open = false }
        }
      }
      logs[path] = log
      if log.open { anyOpen = true }
      if log.open && log.effort?.lowercased() == "ultra" { found = true }
      notes.append("\((path as NSString).lastPathComponent) effort=\(log.effort ?? "?") \(log.open ? "open" : "done")")
    }
    report = "codex ultra=\(found) [\(notes.joined(separator: "; "))]"
    active = anyOpen
    return found
  }
}

/// Claude Code's "ultracode" (see above).
final class ClaudeUltra: UltraDetector {
  private let home: String
  private let finder: RecentLogs
  private var logs: [String: (tail: LogTail, prompt: Bool, session: Bool)] = [:]
  private var transcriptFor: [String: String] = [:]   // session id → transcript path
  private(set) var report = "claude: not checked yet"
  private(set) var active = false

  /// ~/.claude, or $CLAUDE_CONFIG_DIR (TBB_CLAUDE_HOME overrides both, for testing).
  init(home: String = ProcessInfo.processInfo.environment["TBB_CLAUDE_HOME"] ?? ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
         ?? NSHomeDirectory() + "/.claude") {
    self.home = home
    finder = RecentLogs(root: home + "/projects", depth: 1)
  }

  func check() -> Bool {
    let busy = busySessions()
    active = !(busy ?? []).isEmpty
    let paths = busy ?? finder.find(changedWithin: 90, alsoCheck: [])
    if logs.count > 50 { logs = logs.filter { paths.contains($0.key) } }   // keep read positions, within reason
    var found = false
    var notes: [String] = []
    for path in paths {
      var log = logs[path] ?? (LogTail(path), false, false)
      log.tail.readNewLines { line in
        let head = line.prefix(600)
        if head.has("\"workflow_keyword_request\"") || head.has("\"ultra_effort_") {
          guard let d = line.json, d["type"] as? String == "attachment" else { return }
          switch (d["attachment"] as? [String: Any])?["type"] as? String {
          case "workflow_keyword_request": log.prompt = true
          case "ultra_effort_enter": log.session = true
          case "ultra_effort_exit": log.session = false
          default: break
          }
        } else if head.has("\"type\":\"user\"") && !head.has("\"tool_result\"") {
          // A new prompt typed by the user starts a new turn (task notifications and tool results don't).
          if let d = line.json, Self.isHumanPrompt(d) { log.prompt = false }
        }
      }
      logs[path] = log
      if log.prompt || log.session { found = true }
      notes.append("\((path as NSString).lastPathComponent) prompt=\(log.prompt) session=\(log.session)")
    }
    report = "claude ultracode=\(found) [\(notes.joined(separator: "; "))]"
    return found
  }

  private static func isHumanPrompt(_ d: [String: Any]) -> Bool {
    guard d["type"] as? String == "user", d["isMeta"] as? Bool != true, d["isCompactSummary"] as? Bool != true else { return false }
    if let origin = d["turnOrigin"] as? String { return origin == "human" }
    if let origin = d["origin"] as? [String: Any], let kind = origin["kind"] as? String { return kind == "human" }
    // Older transcripts: a plain prompt is a string, or text blocks without tool results.
    let content = (d["message"] as? [String: Any])?["content"]
    if content is String { return true }
    return (content as? [[String: Any]])?.allSatisfy { $0["type"] as? String != "tool_result" } ?? false
  }

  /// Transcripts of the sessions Claude Code itself lists as busy, or nil if it keeps no such list.
  private func busySessions() -> [String]? {
    let dir = home + "/sessions"
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
    var listed = false
    var paths: [String] = []
    for name in names where name.hasSuffix(".json") {
      guard let data = FileManager.default.contents(atPath: dir + "/" + name),
            let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let pid = d["pid"] as? Int, let id = d["sessionId"] as? String, let status = d["status"] as? String else { continue }
      listed = true
      guard status == "busy", kill(pid_t(pid), 0) == 0 || errno == EPERM else { continue }   // stale files outlive crashes
      if let path = transcript(id, cwd: d["cwd"] as? String ?? "") { paths.append(path) }
    }
    return listed ? paths : nil
  }

  /// ~/.claude/projects/<cwd with every non-alphanumeric character turned into "-">/<session id>.jsonl,
  /// or (very long folder names get shortened) whichever project folder holds that file.
  private func transcript(_ id: String, cwd: String) -> String? {
    if let known = transcriptFor[id] { return known }
    let projects = home + "/projects"
    let escaped = String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    var dirs = [escaped]
    if let all = try? FileManager.default.contentsOfDirectory(atPath: projects) { dirs += all }
    for dir in dirs {
      let path = "\(projects)/\(dir)/\(id).jsonl"
      if FileManager.default.fileExists(atPath: path) { transcriptFor[id] = path; return path }
    }
    return nil
  }
}

/// Finds the .jsonl logs under a folder that changed recently, without statting the whole tree every time:
/// `alsoCheck` folders are listed on every call, the whole tree at most once a minute.
final class RecentLogs {
  private let root: String
  private let depth: Int
  private var lastSweep = -Double.infinity
  private var swept: [String] = []       // logs the last sweep saw changing

  init(root: String, depth: Int) { self.root = root; self.depth = depth }

  func find(changedWithin seconds: Double, alsoCheck dirs: [String]) -> [String] {
    let now = Date().timeIntervalSince1970
    var found = Set<String>()
    if now - lastSweep > 60 {
      lastSweep = now
      swept = []
      Self.list(root, depth: depth) { path, mtime in if now - mtime < seconds { swept.append(path) } }
    }
    for path in swept where now - Self.mtime(path) < seconds { found.insert(path) }
    for dir in dirs { Self.list(dir, depth: 0) { path, mtime in if now - mtime < seconds { found.insert(path) } } }
    return found.sorted()
  }

  private static func mtime(_ path: String) -> Double {
    var st = stat()
    return stat(path, &st) == 0 ? Double(st.st_mtimespec.tv_sec) : 0
  }

  /// Every *.jsonl file in `dir`, and in its subfolders `depth` levels down.
  private static func list(_ dir: String, depth: Int, _ visit: (String, Double) -> Void) {
    guard let d = opendir(dir) else { return }
    defer { closedir(d) }
    while let e = readdir(d) {
      let name = withUnsafeBytes(of: e.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
      if name.hasPrefix(".") { continue }
      let path = dir + "/" + name
      if e.pointee.d_type == UInt8(DT_DIR) {
        if depth > 0 { list(path, depth: depth - 1, visit) }
      } else if name.hasSuffix(".jsonl") {
        visit(path, mtime(path))
      }
    }
  }
}

/// Follows a growing JSONL log. The first read looks at the last 8 MB only; after that each read returns just the
/// complete lines appended since the previous one.
final class LogTail {
  let path: String
  private var offset: UInt64?
  private let window: UInt64 = 8 << 20

  init(_ path: String) { self.path = path }

  func readNewLines(_ body: (Data) -> Void) {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0 else { return }
    let size = UInt64(st.st_size)
    var start = offset ?? 0
    if start > size { start = 0 }                                       // the file was replaced
    if offset == nil || size - start > window { start = size > window ? size - window : 0 }
    guard size > start else { return }
    var data = Data(count: Int(size - start))
    let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(start)) }
    guard n > 0 else { return }
    data = data.prefix(n)
    guard let end = data.lastIndex(of: 0x0A) else { return }           // the last line is still being written
    var from = data.startIndex
    if start > 0 && start != offset {                                   // we started mid-line: skip to the next one
      guard let newline = data.firstIndex(of: 0x0A) else { return }
      from = newline + 1
    }
    offset = start + UInt64(end - data.startIndex) + 1
    if from < end { data[from..<end].split(separator: 0x0A).forEach(body) }
  }
}

private extension Data {
  func has(_ s: String) -> Bool {
    let needle = Array(s.utf8)
    return withUnsafeBytes { hay in needle.withUnsafeBytes { memmem(hay.baseAddress, hay.count, $0.baseAddress, $0.count) != nil } }
  }

  var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(self))) as? [String: Any] }
}
