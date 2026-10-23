import Foundation
import SlatedCore


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

  /// Defaults to `SlatedPaths.configURL` (`SLATED_CONFIG` / `SLATED_HOME` override it for tests).
  init(fileURL: URL = SlatedPaths.configURL) {
    self.fileURL = fileURL
  }

  /// Reads the file, creating it with defaults on first run. On a parse error the previous
  /// configuration stays active and `loadError` explains the problem.
  func load() {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      // First run. If the user has a Slate config, it is their default and loads as-is; otherwise
      // start from the built-in bindings (the same setup, in Slated's own format).
      let defaults = GeneralSettings()
      let hasSlateConfig = defaults.slateConfigPaths.contains {
        FileManager.default.fileExists(atPath: SlatedPaths.expand($0))
      }
      configuration = hasSlateConfig ? SlatedConfiguration() : .starter
      loadError = nil
      try? save(configuration)
      Log.record(
        "config.created",
        ["path": fileURL.path, "from": hasSlateConfig ? "empty (Slate config is the default)" : "starter bindings"])
      return
    }
    do {
      let data = try Data(contentsOf: fileURL)
      configuration = try SlatedConfiguration.decode(from: data)
      lastWritten = data
      loadError = nil
      Log.record("config.loaded", Self.summary(configuration, path: fileURL.path))
    } catch {
      loadError = "Couldn't read \(fileURL.path): \(Self.describe(error))"
      Log.error("config.error", loadError ?? "", ["path": fileURL.path])
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
    Log.record("config.changed_on_disk", ["path": fileURL.path])
    load()
    onExternalChange?()
  }

  static func summary(_ config: SlatedConfiguration, path: String) -> [String: Any] {
    [
      "path": path, "bindings": config.bindings.count, "hotstrings": config.hotstrings.count,
      "layouts": config.layouts.count, "capsLock": config.keyboard.capsLock.rawValue,
      "loadSlateConfigs": config.general.loadSlateConfigs,
    ]
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

  /// `bindings[0].action.op`
  static func path(_ codingPath: [CodingKey]) -> String {
    guard !codingPath.isEmpty else { return "" }
    var text = ""
    for key in codingPath {
      if let index = key.intValue {
        text += "[\(index)]"
      } else {
        text += (text.isEmpty ? "" : ".") + key.stringValue
      }
    }
    return " (at \(text))"
  }
}
