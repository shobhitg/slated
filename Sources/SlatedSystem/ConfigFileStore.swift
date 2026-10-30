import Foundation
import SlatedCore

/// A file of Slated's couldn't be read, so Slated won't save over either: that would replace the
/// user's file, which may only need a small fix, with the configuration Slated last loaded.
public struct ConfigUnreadable: LocalizedError {
  public let message: String
  public init(message: String) { self.message = message }
  public var errorDescription: String? { message }
}

/// A file changed on disk since Slated last read it, and the once-a-second check hadn't noticed yet
/// (a hand edit saved in place, say). Slated loaded the edit instead of saving over it.
public struct ConfigChangedOnDisk: LocalizedError {
  public let file: ConfigFile
  public init(file: ConfigFile) { self.file = file }
  public var errorDescription: String? {
    "\(file.rawValue) changed on disk, so Slated loaded it instead of saving over it. Make your change again."
  }
}

/// Reads and writes Slated's two files, `config.json` and `settings.json` (`ConfigFile`), as one
/// `SlatedConfiguration`; migrates a version 1 config.json; and on a first run writes both, from the
/// user's Slate config when there is one. Watching the files and logging are the app's (`ConfigStore`).
///
/// Saving writes only the files whose own content changed, atomically, and through a symlink to the
/// file it points at (dotfiles). It never writes over a file it couldn't read, or one edited by hand
/// since it was read (that edit is loaded instead).
@MainActor
public final class ConfigFileStore {
  public let configURL: URL
  public let settingsURL: URL
  /// Where a version 1 config.json is kept when it's migrated: beside config.json, never overwritten.
  public var backupURL: URL { configURL.deletingLastPathComponent().appendingPathComponent("config.v1.json") }
  /// What `~` means in Slate config paths.
  public let home: String
  /// Converts Slate config files (paths as written, `~` allowed) for a first run and the migration.
  /// Nil: nothing is imported.
  public var importSlate: (([String]) -> SlateImport)?

  public private(set) var configuration = SlatedConfiguration()
  /// Why a file on disk couldn't be used, naming it, if one couldn't.
  public private(set) var loadError: String?
  /// Called when the store reloaded on its own because a file changed on disk (found by
  /// `checkForChanges` or by a save), with which file and what loading it did.
  public var onReload: ((ConfigFile, LoadResult) -> Void)?

  /// What a `load` did.
  public struct LoadResult: Sendable {
    public enum Kind: String, Sendable {
      /// Read both files.
      case loaded
      /// There was no config.json: wrote both files, from the Slate config (`slateImport`) or the
      /// starter configuration.
      case created
      /// config.json was version 1: kept it as config.v1.json, moved its settings to settings.json
      /// and imported its Slate config, then wrote both files.
      case migrated
      /// A file couldn't be read (`failedFile`); the configuration is what it was, and `loadError`
      /// says why.
      case failed
    }

    public var kind: Kind
    public var failedFile: ConfigFile?
    /// The Slate config imported by a first run or the migration.
    public var slateImport: SlateImportReport?
    /// The migration moved config.json's settings into settings.json (rather than settings.json,
    /// which was there already, winning).
    public var settingsMoved = false
    /// The migration kept the old config.json as config.v1.json (false: one was there already).
    public var backedUp = false
    /// Files written while loading.
    public var written: [ConfigFile] = []
    /// Why writing the files failed, if it did. The configuration is still the one loaded.
    public var writeError: String?
  }

  /// Each file's contents as last read or written, and its modification date, so each change is
  /// handled once.
  private var lastSeen: [ConfigFile: Data] = [:]
  private var lastModified: [ConfigFile: Date] = [:]

  public init(configURL: URL, settingsURL: URL? = nil, home: String) {
    self.configURL = configURL
    self.settingsURL =
      settingsURL ?? configURL.deletingLastPathComponent().appendingPathComponent(ConfigFile.settings.rawValue)
    self.home = home
  }

  public func url(_ file: ConfigFile) -> URL {
    switch file {
    case .config: return configURL
    case .settings: return settingsURL
    }
  }

  // MARK: Loading

  /// Reads both files: creates them on a first run, migrates a version 1 config.json. On an error the
  /// previous configuration stays active and `loadError` explains the problem.
  @discardableResult
  public func load() -> LoadResult {
    for file in ConfigFile.allCases {
      if let missing = missingLinkTarget(file) {
        // A dotfiles link whose file isn't there: the repo moved or isn't cloned yet, a volume isn't
        // mounted, a branch switch removed it. Writing defaults would replace the link with a file of
        // their own, and the dotfiles copy would never be read again; wait for it to come back.
        lastSeen[file] = nil
        lastModified[file] = nil
        return fail(
          file,
          "\(file.rawValue) links to \(missing.standardizedFileURL.path), which doesn't exist. Put the file back, or remove the link to start over."
        )
      }
    }
    var settingsData: Data?
    if FileManager.default.fileExists(atPath: settingsURL.path) {
      lastModified[.settings] = modificationDate(.settings)
      do {
        settingsData = try Data(contentsOf: settingsURL)
      } catch {
        return fail(.settings, "Couldn't read \(settingsURL.path): \(error.localizedDescription)")
      }
      lastSeen[.settings] = settingsData
    } else {
      lastSeen[.settings] = nil
      lastModified[.settings] = nil
    }
    guard FileManager.default.fileExists(atPath: configURL.path) else {
      return firstRun(settings: settingsData)
    }
    let configData: Data
    lastModified[.config] = modificationDate(.config)
    do {
      configData = try Data(contentsOf: configURL)
    } catch {
      return fail(.config, "Couldn't read \(configURL.path): \(error.localizedDescription)")
    }
    lastSeen[.config] = configData
    let files: SlatedConfiguration.Files
    do {
      files = try SlatedConfiguration.decodeFiles(config: configData, settings: settingsData)
    } catch let error as ConfigFileError {
      return fail(error.file, "Couldn't read \(url(error.file).path): \(Self.describe(error.error))")
    } catch {
      return fail(.config, "Couldn't read \(configURL.path): \(Self.describe(error))")
    }
    guard let legacy = files.legacy else {
      configuration = files.configuration
      loadError = nil
      return LoadResult(kind: .loaded)
    }
    return migrate(files.configuration, legacy: legacy, original: configData, hadSettingsFile: settingsData != nil)
  }

  /// No config.json: the user's Slate config converted, or the starter configuration. A settings.json
  /// that's there already is kept.
  private func firstRun(settings: Data?) -> LoadResult {
    var config = SlatedConfiguration.starter
    if let settings {
      do {
        // Its settings, with config.json's part from the starter.
        let read = try SlatedConfiguration.decodeFiles(config: Data("{}".utf8), settings: settings).configuration
        config.adoptSettings(of: read)
        config.version = read.version
      } catch let error as ConfigFileError {
        return fail(.settings, "Couldn't read \(settingsURL.path): \(Self.describe(error.error))")
      } catch {
        return fail(.settings, "Couldn't read \(settingsURL.path): \(Self.describe(error))")
      }
    }
    var result = LoadResult(kind: .created)
    let asRead = config
    if let importSlate, let found = SlateImport.find(home: home) {
      // Their Slate config is their default, in Slated's own format.
      config = SlatedConfiguration(version: asRead.version)
      config.adoptSettings(of: asRead)
      result.slateImport = config.merge(importSlate([found]))
    }
    configuration = config
    loadError = nil
    result.written = writeAll(config, &result, settingsAsRead: settings == nil ? nil : asRead)
    return result
  }

  /// A version 1 config.json: keep it as config.v1.json, import its Slate config, write both files.
  private func migrate(
    _ migrated: SlatedConfiguration, legacy: LegacyConfig, original: Data, hadSettingsFile: Bool
  ) -> LoadResult {
    var config = migrated
    var result = LoadResult(kind: .migrated)
    result.settingsMoved = legacy.settingsMoved
    if !FileManager.default.fileExists(atPath: backupURL.path) {
      do {
        try FileManager.default.createDirectory(
          at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try original.write(to: backupURL, options: .withoutOverwriting)
        result.backedUp = true
      } catch {
        // Without the copy, nothing is changed: the user's only copy of their old file is config.json.
        configuration = config
        loadError = nil
        result.writeError = "Couldn't keep a copy of config.json at \(backupURL.path): \(error.localizedDescription)"
        return result
      }
    }
    if legacy.loadSlateConfigs, let importSlate {
      let paths: [String] =
        legacy.slateConfigPaths.map { paths in
          paths.filter { FileManager.default.fileExists(atPath: SlateImport.expand($0, home: home)) }
        } ?? SlateImport.find(home: home).map { [$0] } ?? []
      if !paths.isEmpty {
        result.slateImport = config.merge(importSlate(paths), alreadyImported: Set(legacy.importedSlateShortcuts))
      }
    }
    configuration = config
    loadError = nil
    result.written = writeAll(config, &result, settingsAsRead: hadSettingsFile ? migrated : nil)
    return result
  }

  /// settings.json, then config.json (so a run that stops in between still finds config.json version 1,
  /// and migrates again with settings.json winning). A settings.json that was there and says the same
  /// as before (`settingsAsRead`) is left as it is, comments and all.
  private func writeAll(
    _ config: SlatedConfiguration, _ result: inout LoadResult, settingsAsRead: SlatedConfiguration? = nil
  ) -> [ConfigFile] {
    var written: [ConfigFile] = []
    for file in [ConfigFile.settings, .config] {
      if file == .settings, let settingsAsRead,
        (try? settingsAsRead.encodedSettingsFile()) == (try? config.encodedSettingsFile())
      {
        continue
      }
      do {
        try write(config.encoded(file), to: file)
        written.append(file)
      } catch {
        result.writeError = "Couldn't write \(url(file).path): \(error.localizedDescription)"
        break
      }
    }
    return written
  }

  private func fail(_ file: ConfigFile, _ message: String) -> LoadResult {
    loadError = message
    return LoadResult(kind: .failed, failedFile: file)
  }

  // MARK: Saving

  /// Writes the files whose content `configuration` changes; returns them. Refuses (throws
  /// `ConfigUnreadable`) while a file on disk couldn't be read, until it's fixed or reloaded, and
  /// (throws `ConfigChangedOnDisk`) when one changed since it was last read: that edit is loaded
  /// instead of overwritten.
  @discardableResult
  public func save(_ configuration: SlatedConfiguration) throws -> [ConfigFile] {
    // The once-a-second check may not have seen a hand edit yet; look now, as it would.
    for file in ConfigFile.allCases
    where modificationDate(file) != lastModified[file] || (try? Data(contentsOf: url(file))) != lastSeen[file] {
      if fileMayHaveChanged(file), loadError == nil { throw ConfigChangedOnDisk(file: file) }
    }
    if let loadError { throw ConfigUnreadable(message: "\(loadError) Slated won't save over it until it's fixed.") }
    var written: [ConfigFile] = []
    for file in ConfigFile.allCases {
      let data = try configuration.encoded(file)
      let unchanged = (try? self.configuration.encoded(file)) == data
      // config.json is written again when it's gone (deleted by hand): without it, the next launch
      // would be a first run. A missing settings.json just means defaults.
      let missing = file == .config && !FileManager.default.fileExists(atPath: configURL.path)
      guard !unchanged || missing else { continue }
      try write(data, to: file)
      written.append(file)
    }
    self.configuration = configuration
    loadError = nil
    return written
  }

  private func write(_ data: Data, to file: ConfigFile) throws {
    // Through a symlinked file (dotfiles) to its target: an atomic save would replace the link.
    let destination = linkTarget(file).url
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: destination, options: .atomic)
    lastSeen[file] = data
    lastModified[file] = modificationDate(file)
  }

  // MARK: Watching

  /// Reloads if either file changed since it was last read or written. Returns whether it did. The
  /// app calls it every second, looking only at files whose modification date changed, and with
  /// `comparingContents` when the folder changes. (Saving in place, as nano or `>` in a shell do, or
  /// through a symlink doesn't change the folder.)
  @discardableResult
  public func checkForChanges(comparingContents: Bool = false) -> Bool {
    var reloaded = false
    for file in ConfigFile.allCases where comparingContents || modificationDate(file) != lastModified[file] {
      if fileMayHaveChanged(file) { reloaded = true }
    }
    return reloaded
  }

  /// Reloads if `file` changed since it was last read or written. Returns whether it did (or found it
  /// a link to nothing).
  @discardableResult
  private func fileMayHaveChanged(_ file: ConfigFile) -> Bool {
    lastModified[file] = modificationDate(file)
    if let data = try? Data(contentsOf: url(file)) {
      guard data != lastSeen[file] else { return false }
    } else if file == .settings && lastSeen[.settings] != nil && missingLinkTarget(.settings) == nil {
      // settings.json deleted by hand: every setting back to its default.
    } else {
      // Gone. A config.json deleted by hand is written again on the next save, but a link to a file
      // that's gone mustn't be (that would replace the link); report it, once.
      guard missingLinkTarget(file) != nil, lastSeen[file] != nil || loadError == nil else { return false }
    }
    let result = load()
    onReload?(file, result)
    return true
  }

  /// The modification date of `file`, or of the file it links to.
  public func modificationDate(_ file: ConfigFile) -> Date? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: linkTarget(file).url.path)
    return attributes?[.modificationDate] as? Date
  }

  /// `file`, or for one symlinked from a dotfiles folder, the file it links to (through any chain of
  /// links). Followed by hand: `resolvingSymlinksInPath()` stops at a link to a file that doesn't
  /// exist, and saving there would replace the link.
  private func linkTarget(_ file: ConfigFile) -> (url: URL, isLink: Bool) {
    var url = url(file)
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

  /// Where `file` links to, when that file doesn't exist.
  private func missingLinkTarget(_ file: ConfigFile) -> URL? {
    let target = linkTarget(file)
    return target.isLink && !FileManager.default.fileExists(atPath: target.url.path) ? target.url : nil
  }

  // MARK: Messages

  /// Turns decoding errors into something a person can act on.
  public static func describe(_ error: Error) -> String {
    switch error {
    case DecodingError.dataCorrupted(let context):
      // A syntax error says where it is only in the underlying error ("Unexpected character '}' in
      // object around line 6, column 1."); its own description is just "not valid JSON".
      let underlying = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
      return (underlying ?? context.debugDescription) + path(context.codingPath)
    case DecodingError.keyNotFound(let key, let context):
      return "missing \"\(key.stringValue)\"" + path(context.codingPath)
    case DecodingError.typeMismatch(_, let context), DecodingError.valueNotFound(_, let context):
      return context.debugDescription + path(context.codingPath)
    default:
      return error.localizedDescription
    }
  }

  /// ` (at bindings[0].action.op)`
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
