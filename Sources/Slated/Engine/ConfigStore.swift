import Foundation
import SlatedCore

/// config.json couldn't be read, so Slated won't save over it: that would replace the user's file,
/// which may only need a small fix, with the configuration Slated last loaded.
struct ConfigUnreadable: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// config.json changed on disk since Slated last read it, and the once-a-second check hadn't noticed
/// yet (a hand edit saved in place, say). Slated loaded the edit instead of saving over it.
struct ConfigChangedOnDisk: LocalizedError {
  var errorDescription: String? {
    "config.json changed on disk, so Slated loaded it instead of saving over it. Make your change again."
  }
}

/// Loads, saves and watches `~/.config/slated/config.json`.
final class ConfigStore {
  let fileURL: URL
  private(set) var configuration = SlatedConfiguration()
  /// Why the file on disk couldn't be used, if it couldn't.
  private(set) var loadError: String?
  /// Called when the file changes on disk (e.g. edited by hand).
  var onExternalChange: (() -> Void)?

  private var watcher: DispatchSourceFileSystemObject?
  private var pollTimer: Timer?
  /// The file's contents as last read or written, so each change is handled once.
  private var lastSeen: Data?
  private var lastModified: Date?

  /// Defaults to `SlatedPaths.configURL` (`SLATED_CONFIG` / `SLATED_HOME` override it for tests).
  init(fileURL: URL = SlatedPaths.configURL) {
    self.fileURL = fileURL
  }

  /// Reads the file, creating it with defaults on first run. On a parse error the previous
  /// configuration stays active and `loadError` explains the problem.
  func load() {
    if let missing = missingLinkTarget() {
      // A dotfiles link whose file isn't there: the repo moved or isn't cloned yet, a volume isn't
      // mounted, a branch switch removed it. Writing defaults would replace the link with a file of
      // their own, and the dotfiles copy would never be read again; wait for it to come back.
      lastSeen = nil
      lastModified = nil
      loadError =
        "config.json links to \(missing.standardizedFileURL.path), which doesn't exist. Put the file back, or remove the link to start over."
      Log.error("config.error", loadError ?? "", ["path": fileURL.path])
      return
    }
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      // First run. If the user has a Slate config, it is their default and loads as-is; otherwise
      // start from the built-in bindings (the same setup, in Slated's own format).
      let defaults = GeneralSettings()
      let hasSlateConfig = defaults.slateConfigPaths.contains {
        FileManager.default.fileExists(atPath: SlatedPaths.expand($0))
      }
      configuration = hasSlateConfig ? SlatedConfiguration() : .starter
      loadError = nil
      do {
        try save(configuration)
        Log.record(
          "config.created",
          ["path": fileURL.path, "from": hasSlateConfig ? "empty (Slate config is the default)" : "starter bindings"])
      } catch {
        Log.error("config.save_failed", error.localizedDescription, ["path": fileURL.path])
      }
      return
    }
    do {
      lastModified = modificationDate()
      let data = try Data(contentsOf: fileURL)
      lastSeen = data
      configuration = try SlatedConfiguration.decode(from: data)
      loadError = nil
      Log.record("config.loaded", Self.summary(configuration, path: fileURL.path))
    } catch {
      loadError = "Couldn't read \(fileURL.path): \(Self.describe(error))"
      Log.error("config.error", LogPrivacy.message(loadError ?? ""), ["path": fileURL.path])
    }
  }

  /// Writes `configuration`. Refuses (throws `ConfigUnreadable`) while the file on disk couldn't be
  /// read, until it's fixed or reloaded, and (throws `ConfigChangedOnDisk`) when it changed since it
  /// was last read: that edit is loaded instead of overwritten.
  func save(_ configuration: SlatedConfiguration) throws {
    // The once-a-second check may not have seen a hand edit yet; look now, as it would.
    if modificationDate() != lastModified || (try? Data(contentsOf: fileURL)) != lastSeen, fileMayHaveChanged() {
      if loadError == nil { throw ConfigChangedOnDisk() }
    }
    if let loadError { throw ConfigUnreadable(message: "\(loadError) Slated won't save over it until it's fixed.") }
    let data = try configuration.encoded()
    // Through a symlinked config.json (dotfiles) to its target: an atomic save would replace the link.
    let destination = linkTarget().url
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: destination, options: .atomic)
    lastSeen = data
    lastModified = modificationDate()
    self.configuration = configuration
    loadError = nil
  }

  /// Watches the config directory (atomic saves replace the file, so watch its parent), and polls the
  /// file's modification date: saving in place (nano, Sublime Text, `>` in a shell) or through a
  /// symlink doesn't change the directory, so the watcher never hears of it.
  func startWatching() {
    let directory = fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.modificationDate() != self.lastModified else { return }
        self.fileMayHaveChanged()
      }
    }
    let fd = open(directory.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { _ = self?.fileMayHaveChanged() }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    watcher = source
  }

  /// Reloads config.json if it changed since it was last read or written. Returns whether it did
  /// (or found the file a link to nothing).
  @discardableResult
  private func fileMayHaveChanged() -> Bool {
    lastModified = modificationDate()
    if let data = try? Data(contentsOf: fileURL) {
      guard data != lastSeen else { return false }
    } else {
      // Gone. A config.json deleted by hand is written again on the next save, but a link to a file
      // that's gone mustn't be (that would replace the link); report it, once.
      guard missingLinkTarget() != nil, lastSeen != nil || loadError == nil else { return false }
    }
    Log.record("config.changed_on_disk", ["path": fileURL.path])
    load()
    onExternalChange?()
    return true
  }

  /// The modification date of config.json, or of the file it links to.
  private func modificationDate() -> Date? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: linkTarget().url.path)
    return attributes?[.modificationDate] as? Date
  }

  /// config.json, or for a config.json symlinked from a dotfiles folder, the file it links to (through
  /// any chain of links). Followed by hand: `resolvingSymlinksInPath()` stops at a link to a file
  /// that doesn't exist, and saving there would replace the link.
  private func linkTarget() -> (url: URL, isLink: Bool) {
    var url = fileURL
    var isLink = false
    for _ in 0..<32 {
      guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { break }
      isLink = true
      url =
        destination.hasPrefix("/")
        ? URL(fileURLWithPath: destination)
        : url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(destination)
    }
    return (url, isLink)
  }

  /// Where config.json links to, when that file doesn't exist.
  private func missingLinkTarget() -> URL? {
    let target = linkTarget()
    return target.isLink && !FileManager.default.fileExists(atPath: target.url.path) ? target.url : nil
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
      // A syntax error says where it is only in the underlying error ("Unexpected character '}' in
      // object around line 6, column 1."); its own description is just "not valid JSON".
      let underlying = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
      return (underlying ?? context.debugDescription) + Self.path(context.codingPath)
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
