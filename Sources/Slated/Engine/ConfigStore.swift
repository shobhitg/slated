import Foundation
import SlatedCore
import SlatedScript
import SlatedSystem

/// Slated's files, `~/.config/slated/config.json`, `settings.json` and `secrets.json` (`ConfigFileStore` reads
/// and writes them, and migrates a version 1 config.json), watched for hand edits, with every load logged.
/// secrets.json's content is never logged: counts, and errors that quote nothing from it.
final class ConfigStore {
  let files: ConfigFileStore
  var fileURL: URL { files.configURL }
  var settingsURL: URL { files.settingsURL }
  var configuration: SlatedConfiguration { files.configuration }
  /// Why a file on disk couldn't be used, if one couldn't.
  var loadError: String? { files.loadError }
  /// Called when a file changes on disk (e.g. edited by hand).
  var onExternalChange: (() -> Void)?
  /// Called when a first run or the migration imported the user's Slate config.
  var onSlateImported: ((SlateImportReport) -> Void)?

  private var watcher: DispatchSourceFileSystemObject?
  private var pollTimer: Timer?

  /// Defaults to `SlatedPaths.configURL` (`SLATED_CONFIG` / `SLATED_HOME` override it for tests).
  init(fileURL: URL = SlatedPaths.configURL) {
    files = ConfigFileStore(configURL: fileURL, home: SlatedPaths.home)
    files.importSlate = { paths in SlateConfigImport.importFiles(paths, home: SlatedPaths.home) }
    files.onReload = { [weak self] file, result in
      guard let self else { return }
      Log.record("config.changed_on_disk", ["path": files.url(file).path, "file": file.rawValue])
      record(result)
      onExternalChange?()
    }
  }

  /// Reads both files, creating them on a first run and migrating a version 1 config.json. On a parse
  /// error the previous configuration stays active and `loadError` explains the problem.
  func load() {
    record(files.load())
  }

  /// Writes the files whose content changes. Refuses (throws `ConfigUnreadable`) while a file on disk
  /// couldn't be read, and (throws `ConfigChangedOnDisk`) when one changed since it was last read:
  /// that edit is loaded instead of overwritten.
  func save(_ configuration: SlatedConfiguration) throws {
    try files.save(configuration)
  }

  /// Logs what a load did.
  private func record(_ result: ConfigFileStore.LoadResult) {
    let config = files.configuration
    switch result.kind {
    case .loaded:
      Log.record("config.loaded", Self.summary(config, path: fileURL.path))
    case .failed:
      let path = result.failedFile.map(files.url)?.path ?? fileURL.path
      Log.error("config.error", LogPrivacy.message(loadError ?? ""), ["path": path])
    case .created:
      var data: [String: Any] = [
        "path": fileURL.path, "from": result.slateImport == nil ? "starter bindings" : "Slate config",
        "written": result.written.map(\.rawValue),
      ]
      if let report = result.slateImport { data.merge(Self.counts(report)) { a, _ in a } }
      Log.record("config.created", data)
    case .migrated:
      // Counts only: never the shortcuts' keys, actions or anything typed.
      var data: [String: Any] = [
        "path": fileURL.path, "settingsMoved": result.settingsMoved, "backedUp": result.backedUp,
        "slateImported": result.slateImport != nil, "written": result.written.map(\.rawValue),
      ]
      if let report = result.slateImport { data.merge(Self.counts(report)) { a, _ in a } }
      Log.record("config.migrated", level: .notice, data)
    }
    if let error = result.writeError {
      Log.error("config.save_failed", LogPrivacy.message(error), ["path": fileURL.path])
    }
    if result.secretsPermissionsFixed {
      Log.record("config.secrets_made_private", level: .notice, ["path": files.secretsURL.path, "mode": "600"])
    }
    if let report = result.slateImport { onSlateImported?(report) }
  }

  /// What an import did, for the log: counts, never keys or content.
  static func counts(_ report: SlateImportReport) -> [String: Any] {
    [
      "imported": report.added, "skipped": report.alreadyThere, "notConverted": report.notConverted.count,
      "layouts": report.layoutsAdded, "defaults": report.defaultsAdded, "settings": report.settingsAdded,
      "problems": report.problems.count,
    ]
  }

  /// Watches the config directory (atomic saves replace the files, so watch their parent), and polls
  /// the files' modification dates: saving in place (nano, Sublime Text, `>` in a shell) or through a
  /// symlink doesn't change the directory, so the watcher never hears of it.
  func startWatching() {
    let directory = fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { _ = self?.files.checkForChanges() }
    }
    let fd = open(directory.path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
    source.setEventHandler { [weak self] in
      MainActor.assumeIsolated { _ = self?.files.checkForChanges(comparingContents: true) }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
    watcher = source
  }

  static func summary(_ config: SlatedConfiguration, path: String) -> [String: Any] {
    [
      "path": path, "bindings": config.bindings.count, "hotstrings": config.hotstrings.count,
      "layouts": config.layouts.count, "capsLock": config.keyboard.capsLock.rawValue,
      // Counts only: never a secret's name or text.
      "secrets": config.secrets.count, "missingSecrets": config.hotstringsMissingSecrets.count,
    ]
  }
}
