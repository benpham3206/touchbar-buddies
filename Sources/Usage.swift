import AppKit

/// The four independently-known plan usage percentages. A nil value has no drawable bar.
struct UsageLevels: Equatable {
  var codexFiveHour: Double? = nil
  var codexWeekly: Double? = nil
  var claudeFiveHour: Double? = nil
  var claudeWeekly: Double? = nil

  static let demo = UsageLevels(codexFiveHour: 83, codexWeekly: 50, claudeFiveHour: 40, claudeWeekly: 12)
}

/// Reads local plan limits off the main thread and publishes only values whose windows have not reset.
final class UsageMonitor {
  private struct Window {
    let percent: Double
    let resetsAt: Date
  }

  private struct CodexSample {
    let timestamp: Date
    let primary: Window?
    let secondary: Window?
  }

  private struct CodexLog {
    let tail: LogTail
    var latest: CodexSample? = nil
  }

  private let queue = DispatchQueue(label: "dev.touchbarbuddies.usage", qos: .utility)
  private let sessions = NSHomeDirectory() + "/.codex/sessions"
  private let claudeHistory = NSHomeDirectory() + "/Library/Application Support/Claude/plan-usage-history.json"
  private let finder: RecentLogs
  private var logs: [String: CodexLog] = [:]
  private var timer: DispatchSourceTimer?
  private var latest = UsageLevels()
  private let dayFolder: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy/MM/dd"
    return f
  }()
  private let fractionalDate: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  private let plainDate: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
  }()

  var onChange: ((UsageLevels) -> Void)?

  init() { finder = RecentLogs(root: sessions, depth: 3) }

  func start() {
    guard timer == nil else { return }
    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now(), repeating: 45, leeway: .seconds(5))
    t.setEventHandler { [weak self] in self?.sample() }
    t.resume()
    timer = t
  }

  private func sample() {
    let now = Date()
    let days = [-1.0, 0, 1].map { sessions + "/" + dayFolder.string(from: Date(timeIntervalSinceNow: $0 * 86400)) }
    let paths = finder.find(changedWithin: 7 * 86400, alsoCheck: days)
    for path in paths {
      var log = logs[path] ?? CodexLog(tail: LogTail(path))
      log.tail.readNewLines { line in
        guard let event = codexSample(line), log.latest.map({ event.timestamp >= $0.timestamp }) ?? true else { return }
        log.latest = event
      }
      logs[path] = log
    }
    if logs.count > 100 { logs = logs.filter { paths.contains($0.key) } }

    let codex = logs.values.compactMap(\.latest).max { $0.timestamp < $1.timestamp }
    let claude = claudeSample(now: now)
    let result = UsageLevels(
      codexFiveHour: codex?.primary.flatMap { $0.resetsAt > now ? $0.percent : nil },
      codexWeekly: codex?.secondary.flatMap { $0.resetsAt > now ? $0.percent : nil },
      claudeFiveHour: claude.fiveHour,
      claudeWeekly: claude.weekly
    )
    guard result != latest else { return }
    latest = result
    let show = { (v: Double?) in v.map { "\(Int($0.rounded()))%" } ?? "?" }
    NSLog("[usage] codex 5h %@ wk %@, claude 5h %@ wk %@", show(result.codexFiveHour), show(result.codexWeekly),
          show(result.claudeFiveHour), show(result.claudeWeekly))
    DispatchQueue.main.async { [weak self] in self?.onChange?(result) }
  }

  private func codexSample(_ line: Data) -> CodexSample? {
    guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
          ["event_msg", "response_item"].contains(record["type"] as? String ?? ""),
          let payload = record["payload"] as? [String: Any], payload["type"] as? String == "token_count",
          let timestamp = date(record["timestamp"]) else { return nil }
    let rateLimits = payload["rate_limits"] as? [String: Any] ?? [:]
    let primary = window(rateLimits["primary"], minutes: 300)
    let secondary = window(rateLimits["secondary"], minutes: 10080)
    return CodexSample(timestamp: timestamp, primary: primary, secondary: secondary)
  }

  private func window(_ value: Any?, minutes: Int) -> Window? {
    guard let limits = value as? [String: Any],
          (limits["window_minutes"] as? NSNumber)?.intValue == minutes,
          let percent = number(limits["used_percent"]), (0...100).contains(percent),
          let reset = number(limits["resets_at"]) else { return nil }
    return Window(percent: percent, resetsAt: Date(timeIntervalSince1970: reset))
  }

  private func claudeSample(now: Date) -> (fiveHour: Double?, weekly: Double?) {
    // Live numbers from Claude Code's status line, when it's set up (ClaudeStatusLine). Each one holds until its
    // window resets.
    if let data = try? Data(contentsOf: ClaudeStatusLine.file),
       let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       let limits = root["rate_limits"] as? [String: Any] {
      func live(_ key: String) -> Double? {
        guard let w = limits[key] as? [String: Any], let reset = number(w["resets_at"]),
              Date(timeIntervalSince1970: reset) > now else { return nil }
        return percentage(w["used_percentage"])
      }
      let result = (live("five_hour"), live("seven_day"))
      if result.0 != nil || result.1 != nil { return result }
    }
    // Otherwise the Claude app's own occasional samples.
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: claudeHistory)),
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let samples = root["samples"] as? [Any], let sample = samples.last as? [String: Any],
          let milliseconds = number(sample["t"]), milliseconds > 0 else { return (nil, nil) }
    let timestamp = Date(timeIntervalSince1970: milliseconds / 1000)
    let age = now.timeIntervalSince(timestamp)
    guard age >= 0, let usage = sample["u"] as? [String: Any] else { return (nil, nil) }
    // The Claude app writes this file only now and then (it went a whole day without a sample), and an old
    // reading can be far off, so only a recent one counts.
    guard age < 30 * 60 else { return (nil, nil) }
    return (percentage(usage["fh"]), percentage(usage["sd"]))
  }

  private func percentage(_ value: Any?) -> Double? {
    guard let value = number(value), (0...100).contains(value) else { return nil }
    return value
  }

  private func number(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber else { return nil }
    let result = number.doubleValue
    return result.isFinite ? result : nil
  }

  private func date(_ value: Any?) -> Date? {
    guard let value = value as? String else { return nil }
    return fractionalDate.date(from: value) ?? plainDate.date(from: value)
  }
}

/// `TouchBarBuddies --claude-statusline`: a Claude Code status line command (see tools/claude-statusline.sh).
/// Claude Code pipes it the session's JSON, which for subscribers carries the plan's live usage (`rate_limits`),
/// straight from the API. Save that where UsageMonitor reads it, and print a short line for terminal sessions.
enum ClaudeStatusLine {
  static var file: URL {
    URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/TouchBarBuddies/claude-usage.json")
  }

  static func run() -> Int32 {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
          let limits = json["rate_limits"] as? [String: Any], !limits.isEmpty else { return 0 }
    if let data = try? JSONSerialization.data(withJSONObject: ["rate_limits": limits]) {
      try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? data.write(to: file, options: .atomic)
    }
    func used(_ key: String) -> String? {
      ((limits[key] as? [String: Any])?["used_percentage"] as? NSNumber).map { "\(Int($0.doubleValue.rounded()))%" }
    }
    print([used("five_hour").map { "5h \($0)" }, used("seven_day").map { "wk \($0)" }].compactMap { $0 }.joined(separator: " · "))
    return 0
  }
}
