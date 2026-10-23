import Foundation
import os

/// Slated's event log: one JSON object per line in `~/Library/Logs/Slated/slated.log`, mirrored to
/// the unified log (Console.app, `log stream`).
///
/// Every interaction and its outcome is recorded — hotkeys, Hyper combos, hotstring expansions, menu
/// and settings actions, errors — so problems can be diagnosed after the fact. Read it with
/// `make logs` (`scripts/logs.py`).
///
/// Privacy: events never contain typed text, hotstring replacements or window titles. They do contain
/// shortcut names, hotstring triggers, app names and error messages. The file stays on this Mac.
nonisolated final class EventLog: @unchecked Sendable {
  enum Level: String, Sendable {
    case debug, info, notice, error, fault
  }

  static let shared = EventLog()
  static let subsystem = Bundle.main.bundleIdentifier ?? "slated"

  let fileURL: URL
  /// Identifies one run of the app, so a log spanning several launches can be split by session.
  let session = String(UUID().uuidString.prefix(8)).lowercased()

  private let queue = DispatchQueue(label: "Slated.EventLog", qos: .utility)
  private var handle: FileHandle?
  private var bytesWritten: UInt64 = 0
  private static let maxBytes: UInt64 = 5_000_000
  private static let keptFiles = 3
  private let formatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
  private var loggers: [String: Logger] = [:]

  init(directory: URL = URL(fileURLWithPath: SlatedPaths.home).appendingPathComponent("Library/Logs/Slated")) {
    fileURL = directory.appendingPathComponent("slated.log")
  }

  /// Records `event` (dotted name, e.g. `binding.run`) with structured `data`. Thread-safe; returns
  /// immediately and writes in the background.
  func record(_ event: String, level: Level = .info, _ data: [String: Any] = [:]) {
    // Encode on the calling thread so only Sendable values cross to the writer queue.
    var entry: [String: Any] = [
      "ts": formatter.string(from: Date()), "level": level.rawValue, "event": event, "session": session,
    ]
    if !data.isEmpty { entry["data"] = Self.sanitize(data) }
    guard
      var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return }
    line.append(0x0A)
    let category = String(event.prefix { $0 != "." })
    let details = data.keys.sorted().map { "\($0)=\(data[$0].map { "\($0)" } ?? "")" }.joined(separator: " ")
    let message = details.isEmpty ? event : "\(event) \(details)"
    let payload = line
    queue.async { [self] in
      write(payload)
      mirror(category: category, level: level, message: message)
    }
  }

  func error(_ event: String, _ message: String, _ data: [String: Any] = [:]) {
    var data = data
    data["message"] = message
    record(event, level: .error, data)
  }

  /// Blocks until queued events are on disk (call before exiting).
  func flush() {
    queue.sync { try? handle?.synchronize() }
  }

  // MARK: Writing

  private func write(_ line: Data) {
    if handle == nil { open() }
    guard let handle else { return }
    handle.write(line)
    bytesWritten += UInt64(line.count)
    if bytesWritten > Self.maxBytes { rotate() }
  }

  private func open() {
    let fm = FileManager.default
    try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
    handle = try? FileHandle(forWritingTo: fileURL)
    bytesWritten = (try? handle?.seekToEnd()) ?? 0
  }

  /// slated.log → slated.1.log → slated.2.log …, keeping `keptFiles` old files.
  private func rotate() {
    try? handle?.close()
    handle = nil
    let fm = FileManager.default
    let dir = fileURL.deletingLastPathComponent()
    func rotated(_ n: Int) -> URL { dir.appendingPathComponent("slated.\(n).log") }
    try? fm.removeItem(at: rotated(Self.keptFiles))
    for n in stride(from: Self.keptFiles - 1, through: 1, by: -1) {
      try? fm.moveItem(at: rotated(n), to: rotated(n + 1))
    }
    try? fm.moveItem(at: fileURL, to: rotated(1))
    open()
  }

  private func mirror(category: String, level: Level, message: String) {
    let logger = loggers[category] ?? Logger(subsystem: EventLog.subsystem, category: category)
    loggers[category] = logger
    switch level {
    case .debug: logger.debug("\(message, privacy: .public)")
    case .info: logger.info("\(message, privacy: .public)")
    case .notice: logger.notice("\(message, privacy: .public)")
    case .error: logger.error("\(message, privacy: .public)")
    case .fault: logger.fault("\(message, privacy: .public)")
    }
  }

  /// JSON-safe copy: nested dictionaries and arrays are kept, anything else becomes a string.
  private static func sanitize(_ value: Any) -> Any {
    switch value {
    case let dict as [String: Any]: return dict.mapValues(sanitize)
    case let array as [Any]: return array.map(sanitize)
    case let string as String: return string
    case let bool as Bool: return bool
    case let int as Int: return int
    case let double as Double: return double.isFinite ? (double * 10).rounded() / 10 : String(double)
    case let number as NSNumber: return number
    case Optional<Any>.none: return NSNull()
    default: return String(describing: value)
    }
  }
}

/// Shorthand: `Log.record("binding.run", ["keys": "hyper+a"])`.
let Log = EventLog.shared
