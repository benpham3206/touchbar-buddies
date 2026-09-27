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
