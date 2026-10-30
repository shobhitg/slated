import Foundation

/// Slated's two files in `~/.config/slated`.
public enum ConfigFile: String, Sendable, CaseIterable, Hashable {
  /// What your keys do: keyboard (the Hyper key), bindings, hotstrings, layouts, display defaults.
  case config = "config.json"
  /// How Slated behaves: general, windows, clipboard, automation, island.
  case settings = "settings.json"
}

/// A file that couldn't be read, and why. `error` is usually a `DecodingError`.
public struct ConfigFileError: Error {
  public var file: ConfigFile
  public var error: Error

  public init(file: ConfigFile, error: Error) {
    self.file = file
    self.error = error
  }
}

/// What a version 1 config.json (everything in one file, with Slate files loaded alongside it) said
/// that version 2 moved or dropped. Read only to migrate it.
public struct LegacyConfig: Hashable, Sendable {
  /// `general.loadSlateConfigs`: whether Slated loaded the Slate files alongside it.
  public var loadSlateConfigs: Bool
  /// `general.slateConfigPaths`, when the file named them.
  public var slateConfigPaths: [String]?
  /// `general.importedSlateShortcuts`: shortcuts imported from those files earlier, as
  /// `"ctrl+alt+f16"` or, behind a modal key, `"ctrl+alt+f6 x"`.
  public var importedSlateShortcuts: [String]
  /// Its settings sections became settings.json, which wasn't there. When it was, it won and they
  /// were dropped.
  public var settingsMoved: Bool
  /// It had settings sections at all.
  public var hadSettings: Bool

  public init(
    loadSlateConfigs: Bool = true, slateConfigPaths: [String]? = nil, importedSlateShortcuts: [String] = [],
    settingsMoved: Bool = false, hadSettings: Bool = false
  ) {
    self.loadSlateConfigs = loadSlateConfigs
    self.slateConfigPaths = slateConfigPaths
    self.importedSlateShortcuts = importedSlateShortcuts
    self.settingsMoved = settingsMoved
    self.hadSettings = hadSettings
  }
}

extension SlatedConfiguration {
  /// config.json's top-level keys.
  public static let configSections: Set<String> = [
    "version", "keyboard", "bindings", "hotstrings", "layouts", "defaults",
  ]
  /// settings.json's top-level keys.
  public static let settingsSections: Set<String> = [
    "version", "general", "windows", "clipboard", "automation", "island",
  ]
  /// The sections a version 1 config.json had that are settings.json's now (`settings` is `windows`).
  public static let legacySettingsSections: Set<String> = ["general", "settings", "clipboard", "automation", "island"]

  /// What `decodeFiles` read.
  public struct Files: Sendable {
    public var configuration: SlatedConfiguration
    /// Set when config.json is version 1 (or has no version) or has settings sections: it needs
    /// migrating, and this is what it said about Slate files.
    public var legacy: LegacyConfig?
  }

  /// Reads Slated's files: config.json's text, and settings.json's (nil when there's none, which
  /// means every setting at its default). JSON5 conveniences (comments, trailing commas) are allowed.
  ///
  /// A legacy config.json (`Files.legacy`) gives its settings sections when settings.json is missing;
  /// when settings.json is there it wins, and they're dropped. Either way the result is version 2 (or
  /// later, when a newer Slated wrote it), as saving it writes both files.
  ///
  /// Throws `ConfigFileError`, which names the file.
  public static func decodeFiles(config: Data, settings: Data?) throws -> Files {
    let configFile = try decode(ConfigFileCoding.self, from: config, file: .config)
    var result = configFile.configuration
    var legacy = configFile.legacy
    if let settings {
      let settingsFile = try decode(SettingsFileCoding.self, from: settings, file: .settings)
      result.adoptSettings(of: settingsFile.configuration)
      result.version = max(result.version, settingsFile.version ?? 0)
    } else if legacy?.hadSettings == true {
      // The version 1 sections, with `settings` for `windows`.
      let moved = try decode(LegacySettingsCoding.self, from: config, file: .config)
      result.adoptSettings(of: moved.configuration)
      legacy?.settingsMoved = true
    }
    return Files(configuration: result, legacy: legacy)
  }

  /// One document with every section, as a version 1 config.json: `decodeFiles(config: data,
  /// settings: nil)`. For tests and tools; the app reads both files.
  public static func decode(from data: Data) throws -> SlatedConfiguration {
    do {
      return try decodeFiles(config: data, settings: nil).configuration
    } catch let error as ConfigFileError {
      throw error.error
    }
  }

  /// config.json's text: stable, human-friendly JSON, pretty-printed with sorted keys so diffs stay
  /// small.
  public func encodedConfigFile() throws -> Data {
    try Self.encoder.encode(ConfigFileCoding(configuration: self))
  }

  /// settings.json's text, written the same way.
  public func encodedSettingsFile() throws -> Data {
    try Self.encoder.encode(SettingsFileCoding(configuration: self))
  }

  /// The text of `file`.
  public func encoded(_ file: ConfigFile) throws -> Data {
    switch file {
    case .config: return try encodedConfigFile()
    case .settings: return try encodedSettingsFile()
    }
  }

  /// Takes settings.json's sections from `other`, keeping config.json's.
  public mutating func adoptSettings(of other: SlatedConfiguration) {
    general = other.general
    windows = other.windows
    clipboard = other.clipboard
    automation = other.automation
    island = other.island
    unknownSettings = other.unknownSettings
  }

  private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private static func decode<T: Decodable>(_ type: T.Type, from data: Data, file: ConfigFile) throws -> T {
    let decoder = JSONDecoder()
    decoder.allowsJSON5 = true
    do {
      return try decoder.decode(type, from: data)
    } catch {
      throw ConfigFileError(file: file, error: error)
    }
  }
}

// MARK: - The files' shapes

/// config.json: `{ "version": 2, "keyboard": …, "bindings": […], "hotstrings": […], "layouts": […],
/// "defaults": […] }` plus any keys this version doesn't know.
private struct ConfigFileCoding: Codable {
  var configuration: SlatedConfiguration
  var legacy: LegacyConfig?

  init(configuration: SlatedConfiguration) {
    self.configuration = configuration
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: AnyKey.self)
    let version = try c.decodeIfPresent(Int.self, forKey: AnyKey("version"))
    var config = SlatedConfiguration(
      version: max(version ?? 1, SlatedConfiguration.currentVersion),
      keyboard: try c.decodeIfPresent(KeyboardSettings.self, forKey: AnyKey("keyboard")) ?? .init(),
      bindings: try c.decodeIfPresent([HotkeyBinding].self, forKey: AnyKey("bindings")) ?? [],
      layouts: try c.decodeIfPresent([Layout].self, forKey: AnyKey("layouts")) ?? [],
      defaults: try c.decodeIfPresent([ScreenDefault].self, forKey: AnyKey("defaults")) ?? [],
      hotstrings: try c.decodeIfPresent([Hotstring].self, forKey: AnyKey("hotstrings")) ?? [])
    let keys = Set(c.allKeys.map(\.stringValue))
    for key in c.allKeys
    where !SlatedConfiguration.configSections.contains(key.stringValue)
      && !SlatedConfiguration.legacySettingsSections.contains(key.stringValue)
    {
      config.unknownSections[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
    }
    configuration = config
    let hadSettings = !keys.isDisjoint(with: SlatedConfiguration.legacySettingsSections)
    if (version ?? 1) < 2 || hadSettings {
      // Only to migrate: a field of the wrong type here is ignored, not an error, since nothing reads
      // these fields any more.
      let general = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("general"))
      legacy = LegacyConfig(
        loadSlateConfigs: (try? general?.decodeIfPresent(Bool.self, forKey: AnyKey("loadSlateConfigs"))) ?? true,
        slateConfigPaths: try? general?.decodeIfPresent([String].self, forKey: AnyKey("slateConfigPaths")),
        importedSlateShortcuts: (try? general?.decodeIfPresent([String].self, forKey: AnyKey("importedSlateShortcuts")))
          ?? [],
        hadSettings: hadSettings)
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: AnyKey.self)
    try c.encode(configuration.version, forKey: AnyKey("version"))
    try c.encode(configuration.keyboard, forKey: AnyKey("keyboard"))
    try c.encode(configuration.bindings, forKey: AnyKey("bindings"))
    try c.encode(configuration.layouts, forKey: AnyKey("layouts"))
    try c.encode(configuration.defaults, forKey: AnyKey("defaults"))
    try c.encode(configuration.hotstrings, forKey: AnyKey("hotstrings"))
    // The encoder sorts them in with the rest. A known section wins over an unknown one of its name,
    // and settings.json's sections never go here (the file would read as version 1 again).
    for (key, value) in configuration.unknownSections
    where !SlatedConfiguration.configSections.contains(key) && !SlatedConfiguration.legacySettingsSections.contains(key)
    {
      try c.encode(value, forKey: AnyKey(key))
    }
  }
}

/// settings.json: `{ "version": 2, "general": …, "windows": …, "clipboard": …, "automation": …,
/// "island": … }` plus any keys this version doesn't know.
private struct SettingsFileCoding: Codable {
  var configuration: SlatedConfiguration
  var version: Int?

  init(configuration: SlatedConfiguration) {
    self.configuration = configuration
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: AnyKey.self)
    version = try c.decodeIfPresent(Int.self, forKey: AnyKey("version"))
    configuration = try decodeSettings(c, windowsKey: "windows")
    for key in c.allKeys where !SlatedConfiguration.settingsSections.contains(key.stringValue) {
      configuration.unknownSettings[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
    }
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: AnyKey.self)
    try c.encode(configuration.version, forKey: AnyKey("version"))
    try c.encode(configuration.general, forKey: AnyKey("general"))
    try c.encode(configuration.windows, forKey: AnyKey("windows"))
    try c.encode(configuration.clipboard, forKey: AnyKey("clipboard"))
    try c.encode(configuration.automation, forKey: AnyKey("automation"))
    try c.encode(configuration.island, forKey: AnyKey("island"))
    for (key, value) in configuration.unknownSettings where !SlatedConfiguration.settingsSections.contains(key) {
      try c.encode(value, forKey: AnyKey(key))
    }
  }
}

/// A version 1 config.json's settings sections, with `settings` for `windows`. Its other keys are
/// config.json's (or unknown), so none of them is kept here.
private struct LegacySettingsCoding: Decodable {
  var configuration: SlatedConfiguration

  init(from decoder: Decoder) throws {
    configuration = try decodeSettings(decoder.container(keyedBy: AnyKey.self), windowsKey: "settings")
  }
}

private func decodeSettings(_ c: KeyedDecodingContainer<AnyKey>, windowsKey: String) throws -> SlatedConfiguration {
  SlatedConfiguration(
    general: try c.decodeIfPresent(GeneralSettings.self, forKey: AnyKey("general")) ?? .init(),
    windows: try c.decodeIfPresent(SlateSettings.self, forKey: AnyKey(windowsKey)) ?? .init(),
    clipboard: try c.decodeIfPresent(ClipboardSettings.self, forKey: AnyKey("clipboard")) ?? .init(),
    automation: try c.decodeIfPresent(AutomationSettings.self, forKey: AnyKey("automation")) ?? .init(),
    island: try c.decodeIfPresent(IslandSettings.self, forKey: AnyKey("island")) ?? .init())
}
