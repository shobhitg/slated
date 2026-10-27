import Foundation

/// The whole of Slated's native configuration, stored as JSON at `~/.config/slated/config.json`.
///
/// Every field has a default, and decoding tolerates missing keys, so hand-edited files only need
/// what they change. Slate files (`~/.slate`, `~/.slate.js`) are loaded alongside this, not into it.
public struct SlatedConfiguration: Hashable, Sendable {
  public static let currentVersion = 1

  public var version: Int
  public var general: GeneralSettings
  /// Slate's global `config` values (e.g. `defaultToCurrentScreen`, `nudgePercentOf`).
  public var settings: SlateSettings
  public var keyboard: KeyboardSettings
  public var bindings: [HotkeyBinding]
  public var layouts: [Layout]
  public var defaults: [ScreenDefault]
  public var hotstrings: [Hotstring]
  public var clipboard: ClipboardSettings
  public var automation: AutomationSettings
  public var island: IslandSettings

  public init(
    version: Int = SlatedConfiguration.currentVersion,
    general: GeneralSettings = .init(),
    settings: SlateSettings = .init(),
    keyboard: KeyboardSettings = .init(),
    bindings: [HotkeyBinding] = [],
    layouts: [Layout] = [],
    defaults: [ScreenDefault] = [],
    hotstrings: [Hotstring] = [],
    clipboard: ClipboardSettings = .init(),
    automation: AutomationSettings = .init(),
    island: IslandSettings = .init()
  ) {
    self.version = version
    self.general = general
    self.settings = settings
    self.keyboard = keyboard
    self.bindings = bindings
    self.layouts = layouts
    self.defaults = defaults
    self.hotstrings = hotstrings
    self.clipboard = clipboard
    self.automation = automation
    self.island = island
  }
}

extension SlatedConfiguration: Codable {
  private enum Key: String, CodingKey {
    case version, general, settings, keyboard, bindings, layouts, defaults, hotstrings, clipboard, automation, island
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    self.init(
      version: try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion,
      general: try c.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? .init(),
      settings: try c.decodeIfPresent(SlateSettings.self, forKey: .settings) ?? .init(),
      keyboard: try c.decodeIfPresent(KeyboardSettings.self, forKey: .keyboard) ?? .init(),
      bindings: try c.decodeIfPresent([HotkeyBinding].self, forKey: .bindings) ?? [],
      layouts: try c.decodeIfPresent([Layout].self, forKey: .layouts) ?? [],
      defaults: try c.decodeIfPresent([ScreenDefault].self, forKey: .defaults) ?? [],
      hotstrings: try c.decodeIfPresent([Hotstring].self, forKey: .hotstrings) ?? [],
      clipboard: try c.decodeIfPresent(ClipboardSettings.self, forKey: .clipboard) ?? .init(),
      automation: try c.decodeIfPresent(AutomationSettings.self, forKey: .automation) ?? .init(),
      island: try c.decodeIfPresent(IslandSettings.self, forKey: .island) ?? .init())
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Key.self)
    try c.encode(version, forKey: .version)
    try c.encode(general, forKey: .general)
    try c.encode(settings, forKey: .settings)
    try c.encode(keyboard, forKey: .keyboard)
    try c.encode(bindings, forKey: .bindings)
    try c.encode(layouts, forKey: .layouts)
    try c.encode(defaults, forKey: .defaults)
    try c.encode(hotstrings, forKey: .hotstrings)
    try c.encode(clipboard, forKey: .clipboard)
    try c.encode(automation, forKey: .automation)
    try c.encode(island, forKey: .island)
  }

  /// Decodes JSON, allowing JSON5 conveniences (comments, trailing commas) in hand-edited files.
  public static func decode(from data: Data) throws -> SlatedConfiguration {
    let decoder = JSONDecoder()
    decoder.allowsJSON5 = true
    return try decoder.decode(SlatedConfiguration.self, from: data)
  }

  /// Stable, human-friendly JSON: pretty-printed with sorted keys so diffs stay small.
  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }
}

// MARK: - General

public struct GeneralSettings: Hashable, Sendable {
  public var launchAtLogin: Bool
  /// Load Slate config files (`~/.slate.js`, `~/.slate`) in addition to Slated's own bindings.
  public var loadSlateConfigs: Bool
  /// Slate config files to load, in order. `~` is expanded.
  public var slateConfigPaths: [String]
  /// Show a small HUD when an operation runs.
  public var showActionHUD: Bool
  /// Master switch for text expansion; each hotstring's own `enabled` flag is kept as is.
  public var hotstringsEnabled: Bool

  public init(
    launchAtLogin: Bool = false,
    loadSlateConfigs: Bool = true,
    slateConfigPaths: [String] = ["~/.slate.js", "~/.slate"],
    showActionHUD: Bool = false,
    hotstringsEnabled: Bool = true
  ) {
    self.launchAtLogin = launchAtLogin
    self.loadSlateConfigs = loadSlateConfigs
    self.slateConfigPaths = slateConfigPaths
    self.showActionHUD = showActionHUD
    self.hotstringsEnabled = hotstringsEnabled
  }
}

extension GeneralSettings: Codable {
  private enum Key: String, CodingKey { case launchAtLogin, loadSlateConfigs, slateConfigPaths, showActionHUD, hotstringsEnabled }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    let d = GeneralSettings()
    self.init(
      launchAtLogin: try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin,
      loadSlateConfigs: try c.decodeIfPresent(Bool.self, forKey: .loadSlateConfigs) ?? d.loadSlateConfigs,
      slateConfigPaths: try c.decodeIfPresent([String].self, forKey: .slateConfigPaths) ?? d.slateConfigPaths,
      showActionHUD: try c.decodeIfPresent(Bool.self, forKey: .showActionHUD) ?? d.showActionHUD,
      hotstringsEnabled: try c.decodeIfPresent(Bool.self, forKey: .hotstringsEnabled) ?? d.hotstringsEnabled)
  }
}

// MARK: - Keyboard (the Karabiner-Elements part)

public struct KeyboardSettings: Hashable, Sendable {
  public enum CapsLockMode: String, Codable, Sendable, CaseIterable, Hashable {
    /// Leave Caps Lock alone.
    case off
    /// Caps Lock acts as the Hyper key (`hyperModifiers`) while held.
    case hyper
  }

  public enum CapsLockAlone: String, Codable, Sendable, CaseIterable, Hashable {
    /// Tapping Caps Lock on its own does nothing.
    case nothing
    /// Tapping Caps Lock on its own sends Escape.
    case escape
  }

  public var capsLock: CapsLockMode
  public var capsLockAlone: CapsLockAlone
  /// What the Hyper key holds down. Defaults to ⌃⌥⇧⌘.
  public var hyperModifiers: Modifiers

  public init(capsLock: CapsLockMode = .off, capsLockAlone: CapsLockAlone = .nothing, hyperModifiers: Modifiers = .hyper) {
    self.capsLock = capsLock
    self.capsLockAlone = capsLockAlone
    self.hyperModifiers = hyperModifiers
  }
}

extension KeyboardSettings: Codable {
  private enum Key: String, CodingKey { case capsLock, capsLockAlone, hyperModifiers }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    let d = KeyboardSettings()
    var mods = d.hyperModifiers
    if let tokens = try c.decodeIfPresent([String].self, forKey: .hyperModifiers) {
      mods = tokens.compactMap(Modifiers.token).reduce(into: Modifiers()) { $0.formUnion($1) }
    }
    self.init(
      capsLock: try c.decodeIfPresent(CapsLockMode.self, forKey: .capsLock) ?? d.capsLock,
      capsLockAlone: try c.decodeIfPresent(CapsLockAlone.self, forKey: .capsLockAlone) ?? d.capsLockAlone,
      hyperModifiers: mods)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Key.self)
    try c.encode(capsLock, forKey: .capsLock)
    try c.encode(capsLockAlone, forKey: .capsLockAlone)
    var tokens: [String] = []
    if hyperModifiers.contains(.function) { tokens.append("fn") }
    if hyperModifiers.contains(.control) { tokens.append("ctrl") }
    if hyperModifiers.contains(.option) { tokens.append("alt") }
    if hyperModifiers.contains(.shift) { tokens.append("shift") }
    if hyperModifiers.contains(.command) { tokens.append("cmd") }
    try c.encode(tokens, forKey: .hyperModifiers)
  }
}

// MARK: - Bindings

/// A hotkey that runs an operation — Slate's `bind`.
public struct HotkeyBinding: Hashable, Sendable, Identifiable {
  public var id: UUID
  /// Optional label shown in the UI, e.g. "Left half".
  public var name: String?
  public var keys: KeyCombo
  /// Slate modal key: press this first, then `keys`.
  public var modal: ModalKey?
  public var action: Action
  /// Repeat while held. `nil` uses Slate's `repeatOnHoldOps` setting.
  public var repeats: Bool?
  public var enabled: Bool
  /// Only active while one of these apps is in front (macOS bundle identifiers or GNOME app ids, e.g.
  /// a game). Empty means everywhere. Lets plain keys like F be shortcuts inside a game without
  /// affecting typing anywhere else.
  public var onlyInApps: [String]

  public init(
    id: UUID = UUID(), name: String? = nil, keys: KeyCombo, modal: ModalKey? = nil,
    action: Action, repeats: Bool? = nil, enabled: Bool = true, onlyInApps: [String] = []
  ) {
    self.id = id
    self.name = name
    self.keys = keys
    self.modal = modal
    self.action = action
    self.repeats = repeats
    self.enabled = enabled
    self.onlyInApps = onlyInApps
  }
}

extension HotkeyBinding: Codable {
  private enum Key: String, CodingKey { case id, name, keys, modal, action, repeats, enabled, onlyInApps }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    self.init(
      id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
      name: try c.decodeIfPresent(String.self, forKey: .name),
      keys: try c.decode(KeyCombo.self, forKey: .keys),
      modal: try c.decodeIfPresent(ModalKey.self, forKey: .modal),
      action: try c.decode(Action.self, forKey: .action),
      repeats: try c.decodeIfPresent(Bool.self, forKey: .repeats),
      enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
      onlyInApps: try c.decodeIfPresent([String].self, forKey: .onlyInApps) ?? [])
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Key.self)
    try c.encode(id, forKey: .id)
    try c.encodeIfPresent(name, forKey: .name)
    try c.encode(keys, forKey: .keys)
    try c.encodeIfPresent(modal, forKey: .modal)
    try c.encode(action, forKey: .action)
    try c.encodeIfPresent(repeats, forKey: .repeats)
    try c.encode(enabled, forKey: .enabled)
    if !onlyInApps.isEmpty { try c.encode(onlyInApps, forKey: .onlyInApps) }
  }

  /// Whether the binding applies while `bundleID` (the frontmost app) is in front.
  public func isActive(inApp bundleID: String?) -> Bool {
    onlyInApps.isEmpty || bundleID.map(onlyInApps.contains) == true
  }
}

/// Slate's modal key: pressing `keys` enters modal mode; the binding's own key then fires.
public struct ModalKey: Hashable, Sendable, Codable {
  public var keys: KeyCombo
  /// Stay in modal mode after the binding fires (Slate's `:toggle`).
  public var toggle: Bool

  public init(keys: KeyCombo, toggle: Bool = false) {
    self.keys = keys
    self.toggle = toggle
  }

  private enum CodingKeys: String, CodingKey { case keys, toggle }

  /// `toggle` may be left out of hand-edited files, like every field with a default.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      keys: try c.decode(KeyCombo.self, forKey: .keys),
      toggle: try c.decodeIfPresent(Bool.self, forKey: .toggle) ?? false)
  }
}

// MARK: - Layouts

/// Slate's `layout`: operations applied to the windows of several apps at once.
public struct Layout: Hashable, Sendable, Codable, Identifiable {
  public var id: String { name }
  public var name: String
  public var apps: [LayoutApp]
  /// Run before any app is arranged (Slate's `BEFORE`).
  public var before: [Action]
  /// Run after all apps are arranged (Slate's `AFTER`).
  public var after: [Action]

  public init(name: String, apps: [LayoutApp] = [], before: [Action] = [], after: [Action] = []) {
    self.name = name
    self.apps = apps
    self.before = before
    self.after = after
  }

  private enum Key: String, CodingKey { case name, apps, before, after }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    self.init(
      name: try c.decode(String.self, forKey: .name),
      apps: try c.decodeIfPresent([LayoutApp].self, forKey: .apps) ?? [],
      before: try c.decodeIfPresent([Action].self, forKey: .before) ?? [],
      after: try c.decodeIfPresent([Action].self, forKey: .after) ?? [])
  }
}

public struct LayoutApp: Hashable, Sendable, Codable {
  public var app: String
  /// Applied to the app's windows in order: first operation → first window, and so on.
  public var operations: [Action]
  public var options: LayoutAppOptions

  public init(app: String, operations: [Action], options: LayoutAppOptions = .init()) {
    self.app = app
    self.operations = operations
    self.options = options
  }

  private enum Key: String, CodingKey { case app, operations, options }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    self.init(
      app: try c.decode(String.self, forKey: .app),
      operations: try c.decodeIfPresent([Action].self, forKey: .operations) ?? [],
      options: try c.decodeIfPresent(LayoutAppOptions.self, forKey: .options) ?? .init())
  }
}

/// Slate's per-app layout options (`IGNORE_FAIL`, `REPEAT`, `MAIN_FIRST`, …).
public struct LayoutAppOptions: Hashable, Sendable, Codable {
  public var ignoreFail: Bool = false
  public var `repeat`: Bool = false
  public var repeatLast: Bool = false
  public var mainFirst: Bool = false
  public var mainLast: Bool = false
  public var sortTitle: Bool = false
  public var titleOrder: [String]? = nil
  public var titleOrderRegex: [String]? = nil

  public init() {}

  private enum Key: String, CodingKey {
    case ignoreFail, `repeat`, repeatLast, mainFirst, mainLast, sortTitle, titleOrder, titleOrderRegex
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    ignoreFail = try c.decodeIfPresent(Bool.self, forKey: .ignoreFail) ?? false
    `repeat` = try c.decodeIfPresent(Bool.self, forKey: .repeat) ?? false
    repeatLast = try c.decodeIfPresent(Bool.self, forKey: .repeatLast) ?? false
    mainFirst = try c.decodeIfPresent(Bool.self, forKey: .mainFirst) ?? false
    mainLast = try c.decodeIfPresent(Bool.self, forKey: .mainLast) ?? false
    sortTitle = try c.decodeIfPresent(Bool.self, forKey: .sortTitle) ?? false
    titleOrder = try c.decodeIfPresent([String].self, forKey: .titleOrder)
    titleOrderRegex = try c.decodeIfPresent([String].self, forKey: .titleOrderRegex)
  }
}

/// Slate's `default`: activate a layout or snapshot when the display setup matches.
public struct ScreenDefault: Hashable, Sendable, Codable {
  public enum Condition: Hashable, Sendable, Codable {
    case count(Int)
    /// Exact set of resolutions, e.g. `["1440x900", "1680x1050"]`.
    case resolutions([String])
  }

  /// Name of a layout or snapshot.
  public var target: String
  public var condition: Condition

  public init(target: String, condition: Condition) {
    self.target = target
    self.condition = condition
  }
}

// MARK: - Hotstrings (the Keyboard Maestro part)

/// Typed-text trigger: when `trigger` is typed, it is replaced by `replacement` (or `operation` runs).
public struct Hotstring: Hashable, Sendable, Identifiable {
  public enum Fire: String, Codable, Sendable, CaseIterable, Hashable {
    /// As soon as the last character of the trigger is typed.
    case immediately
    /// When a delimiter (space, return, tab, punctuation) follows the trigger; the delimiter is kept.
    case afterDelimiter
  }

  public var id: UUID
  public var trigger: String
  public var replacement: String
  /// Run an action instead of (or after) inserting `replacement`.
  public var action: Action?
  public var enabled: Bool
  public var caseSensitive: Bool
  public var fire: Fire
  /// Only fire when the trigger starts a word (preceded by a delimiter or the start of input).
  public var wordBoundary: Bool
  public var method: InsertMethod
  /// Limit to these apps (bundle identifiers). Empty means everywhere.
  public var onlyInApps: [String]
  /// Never fire in these apps (bundle identifiers).
  public var exceptInApps: [String]
  public var notes: String?

  public init(
    id: UUID = UUID(), trigger: String, replacement: String, action: Action? = nil,
    enabled: Bool = true, caseSensitive: Bool = true, fire: Fire = .immediately,
    wordBoundary: Bool = false, method: InsertMethod = .auto, onlyInApps: [String] = [],
    exceptInApps: [String] = [], notes: String? = nil
  ) {
    self.id = id
    self.trigger = trigger
    self.replacement = replacement
    self.action = action
    self.enabled = enabled
    self.caseSensitive = caseSensitive
    self.fire = fire
    self.wordBoundary = wordBoundary
    self.method = method
    self.onlyInApps = onlyInApps
    self.exceptInApps = exceptInApps
    self.notes = notes
  }
}

extension Hotstring: Codable {
  private enum Key: String, CodingKey {
    case id, trigger, replacement, action, enabled, caseSensitive, fire, wordBoundary, method
    case onlyInApps, exceptInApps, notes
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    let d = Hotstring(trigger: "", replacement: "")
    self.init(
      id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
      trigger: try c.decode(String.self, forKey: .trigger),
      replacement: try c.decodeIfPresent(String.self, forKey: .replacement) ?? "",
      action: try c.decodeIfPresent(Action.self, forKey: .action),
      enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled,
      caseSensitive: try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? d.caseSensitive,
      fire: try c.decodeIfPresent(Fire.self, forKey: .fire) ?? d.fire,
      wordBoundary: try c.decodeIfPresent(Bool.self, forKey: .wordBoundary) ?? d.wordBoundary,
      method: try c.decodeIfPresent(InsertMethod.self, forKey: .method) ?? d.method,
      onlyInApps: try c.decodeIfPresent([String].self, forKey: .onlyInApps) ?? [],
      exceptInApps: try c.decodeIfPresent([String].self, forKey: .exceptInApps) ?? [],
      notes: try c.decodeIfPresent(String.self, forKey: .notes))
  }
}
