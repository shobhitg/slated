import Foundation
import SlatedCore
import os

let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "slated", category: "app")

/// Loads, saves and watches `~/.config/slated/config.json`.
final class ConfigStore {
  let fileURL: URL
  private(set) var configuration = SlatedConfiguration()
  /// Why the file on disk couldn't be used, if it couldn't.
  private(set) var loadError: String?
  /// Called when the file changes on disk (e.g. edited by hand).
  var onExternalChange: (() -> Void)?

  private var watcher: DispatchSourceFileSystemObject?
  private var lastWritten: Data?

  /// `SLATED_CONFIG` overrides the location (used by tests and `--smoke`).
  init(fileURL: URL? = nil) {
    if let fileURL {
      self.fileURL = fileURL
    } else if let override = ProcessInfo.processInfo.environment["SLATED_CONFIG"] {
      self.fileURL = URL(fileURLWithPath: override)
    } else {
      self.fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/slated/config.json")
    }
  }

  /// Reads the file, creating it with defaults on first run. On a parse error the previous
  /// configuration stays active and `loadError` explains the problem.
  func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      configuration = SlatedConfiguration()
      loadError = nil
      try? save(configuration)
      return
    }
    do {
      let data = try Data(contentsOf: fileURL)
      configuration = try SlatedConfiguration.decode(from: data)
      lastWritten = data
      loadError = nil
    } catch {
      loadError = "Couldn't read \(fileURL.path): \(Self.describe(error))"
      log.error("\(self.loadError ?? "", privacy: .public)")
    }
  }

  func save(_ configuration: SlatedConfiguration) throws {
    let data = try configuration.encoded()
    try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: fileURL, options: .atomic)
    lastWritten = data
    self.configuration = configuration
    loadError = nil
  }

  /// Watches the config directory (atomic saves replace the file, so watch its parent).
  func startWatching() {
    let directory = fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fd = open(directory.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { self?.fileMayHaveChanged() }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    watcher = source
  }

  private func fileMayHaveChanged() {
    guard let data = try? Data(contentsOf: fileURL), data != lastWritten else { return }
    load()
    onExternalChange?()
  }

  /// Turns decoding errors into something a person can act on.
  static func describe(_ error: Error) -> String {
    switch error {
    case DecodingError.dataCorrupted(let context):
      return context.debugDescription + Self.path(context.codingPath)
    case DecodingError.keyNotFound(let key, let context):
      return "missing \"\(key.stringValue)\"" + Self.path(context.codingPath)
    case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
      return context.debugDescription + Self.path(context.codingPath)
    default:
      return error.localizedDescription
    }
  }

  private static func path(_ codingPath: [CodingKey]) -> String {
    guard !codingPath.isEmpty else { return "" }
    return " (at " + codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".") + ")"
  }
}
