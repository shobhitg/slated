import Foundation

/// A mouse button Slated can click, press or hold.
public enum MouseButton: String, Codable, Sendable, CaseIterable, Hashable {
  case left, right, middle
}

/// Something Slated can press, hold down or repeat for game-style automation: a mouse button or a key.
///
/// Config text: `"mouse:right"`, `"key:w"`, `"key:shift+w"`.
public enum SyntheticInput: Hashable, Sendable {
  case mouse(MouseButton)
  case key(KeyCombo)

  public init?(string raw: String) {
    let s = raw.trimmingCharacters(in: .whitespaces)
    let lower = s.lowercased()
    if lower.hasPrefix("mouse:") {
      guard let button = MouseButton(rawValue: String(lower.dropFirst("mouse:".count))) else { return nil }
      self = .mouse(button)
    } else if lower.hasPrefix("key:") {
      guard let combo = KeyCombo(string: String(s.dropFirst("key:".count))), KeyNames.isValid(combo.key) else {
        return nil
      }
      self = .key(combo)
    } else {
      return nil
    }
  }

  public var string: String {
    switch self {
    case .mouse(let button): return "mouse:\(button.rawValue)"
    case .key(let combo): return "key:\(combo.string)"
    }
  }
}

extension SyntheticInput: Codable {
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    let raw = try c.decode(String.self)
    guard let input = SyntheticInput(string: raw) else {
      throw DecodingError.dataCorruptedError(
        in: c, debugDescription: "Invalid input \"\(raw)\". Expected e.g. \"mouse:right\" or \"key:w\".")
    }
    self = input
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    try c.encode(string)
  }
}

/// How an auto-repeat runs.
public enum RepeatMode: String, Codable, Sendable, CaseIterable, Hashable {
  /// The trigger starts it; the next trigger stops it.
  case toggle
  /// Runs while the trigger's key is held down (hotkeys only; elsewhere it behaves like `toggle`).
  case whileHeld = "while-held"
}

/// Press or release, for building macros out of individual steps.
public enum PressPhase: String, Codable, Sendable, CaseIterable, Hashable {
  case down, up
}

// MARK: - Settings

/// Clipboard history (the Keyboard Maestro clipboard switcher).
public struct ClipboardSettings: Hashable, Sendable {
  public var enabled: Bool
  /// Opens the switcher. ⇧⌘V is the usual clipboard-manager shortcut.
  public var shortcut: KeyCombo?
  public var maxItems: Int
  /// Keep history across restarts (stored only on this Mac, readable only by you).
  public var persist: Bool
  /// Unpinned items older than this are forgotten. 0 keeps them until `maxItems` pushes them out.
  public var retentionDays: Int
  /// What happens to a copy that's a secret (`ClipboardSecrets`): kept masked, in memory only, or not
  /// recorded at all.
  public var secrets: ClipboardSecretHandling
  /// Secrets are forgotten this many minutes after they were copied (and whenever Slated quits). 0
  /// keeps them until Slated quits.
  public var secretMinutes: Int
  /// Text that looks like a secret (an API token, a private key, a card number, a random password)
  /// counts as one, not only what apps mark secret and what password managers copy.
  public var secretPatterns: Bool
  /// Never record copies made in these apps (bundle identifiers).
  public var excludedApps: [String]
  /// After picking an item, paste it into the app you were in (otherwise just put it on the clipboard).
  public var pasteAfterSelecting: Bool
  /// Add screenshots saved as files to the history (macOS: the screenshot folder is watched; GNOME
  /// copies screenshots to the clipboard itself).
  public var screenshots: Bool

  /// None: password managers' copies are kept, masked, like every secret.
  public static let defaultExcludedApps: [String] = []

  /// What `excludedApps` was by default while secrets were skipped (`ignoreConcealed`, before 2026-11):
  /// password managers. A file from then has them taken out, so their copies are kept, masked.
  public static let legacyExcludedApps = [
    "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
    "com.apple.keychainaccess", "com.apple.Passwords", "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
  ]

  public init(
    enabled: Bool = true, shortcut: KeyCombo? = KeyCombo(string: "cmd+shift+v"), maxItems: Int = 200,
    persist: Bool = true, retentionDays: Int = 30, secrets: ClipboardSecretHandling = .masked,
    secretMinutes: Int = 60, secretPatterns: Bool = true,
    excludedApps: [String] = ClipboardSettings.defaultExcludedApps, pasteAfterSelecting: Bool = true,
    screenshots: Bool = true
  ) {
    self.enabled = enabled
    self.shortcut = shortcut
    self.maxItems = maxItems
    self.persist = persist
    self.retentionDays = retentionDays
    self.secrets = secrets
    self.secretMinutes = secretMinutes
    self.secretPatterns = secretPatterns
    self.excludedApps = excludedApps
    self.pasteAfterSelecting = pasteAfterSelecting
    self.screenshots = screenshots
  }
}

extension ClipboardSettings: Codable {
  private enum Key: String, CodingKey {
    case enabled, shortcut, maxItems, persist, retentionDays, secrets, secretMinutes, secretPatterns, excludedApps
    case pasteAfterSelecting, screenshots
    /// Before `secrets`: true skipped what apps marked secret. Read only to update the file.
    case ignoreConcealed
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    let d = ClipboardSettings()
    // `"shortcut": null` turns the shortcut off; a missing key keeps the default.
    let shortcut: KeyCombo? =
      c.contains(.shortcut) ? try c.decodeIfPresent(KeyCombo.self, forKey: .shortcut) : d.shortcut
    var excludedApps = try c.decodeIfPresent([String].self, forKey: .excludedApps) ?? d.excludedApps
    // A file from before secrets were kept: `ignoreConcealed` either way becomes masked (false kept
    // everything already; true was the default, and the default is masked now), and the password
    // managers excluded by default then are taken out, so their copies are kept, masked.
    if c.contains(.ignoreConcealed), !c.contains(.secrets) {
      excludedApps.removeAll(where: Self.legacyExcludedApps.contains)
    }
    self.init(
      enabled: try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled,
      shortcut: shortcut,
      maxItems: try c.decodeIfPresent(Int.self, forKey: .maxItems) ?? d.maxItems,
      persist: try c.decodeIfPresent(Bool.self, forKey: .persist) ?? d.persist,
      retentionDays: try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? d.retentionDays,
      secrets: try c.decodeIfPresent(ClipboardSecretHandling.self, forKey: .secrets) ?? d.secrets,
      secretMinutes: try c.decodeIfPresent(Int.self, forKey: .secretMinutes) ?? d.secretMinutes,
      secretPatterns: try c.decodeIfPresent(Bool.self, forKey: .secretPatterns) ?? d.secretPatterns,
      excludedApps: excludedApps,
      pasteAfterSelecting: try c.decodeIfPresent(Bool.self, forKey: .pasteAfterSelecting) ?? d.pasteAfterSelecting,
      screenshots: try c.decodeIfPresent(Bool.self, forKey: .screenshots) ?? d.screenshots)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Key.self)
    try c.encode(enabled, forKey: .enabled)
    if let shortcut { try c.encode(shortcut, forKey: .shortcut) } else { try c.encodeNil(forKey: .shortcut) }
    try c.encode(maxItems, forKey: .maxItems)
    try c.encode(persist, forKey: .persist)
    try c.encode(retentionDays, forKey: .retentionDays)
    try c.encode(secrets, forKey: .secrets)
    try c.encode(secretMinutes, forKey: .secretMinutes)
    try c.encode(secretPatterns, forKey: .secretPatterns)
    try c.encode(excludedApps, forKey: .excludedApps)
    try c.encode(pasteAfterSelecting, forKey: .pasteAfterSelecting)
    try c.encode(screenshots, forKey: .screenshots)
  }
}

/// Game-style automation (auto-clickers, held keys, macros) and its safety rails.
public struct AutomationSettings: Hashable, Sendable {
  /// Stops every automation and releases anything held.
  public var stopShortcut: KeyCombo?
  /// Stop when you switch away from the app the automation started in.
  public var stopOnAppSwitch: Bool
  /// Stop after this many minutes; 0 means no limit.
  public var maxRunMinutes: Double
  /// Show a small indicator while anything is running.
  public var showIndicator: Bool

  public init(
    stopShortcut: KeyCombo? = KeyCombo(string: "hyper+esc"), stopOnAppSwitch: Bool = true, maxRunMinutes: Double = 0,
    showIndicator: Bool = true
  ) {
    self.stopShortcut = stopShortcut
    self.stopOnAppSwitch = stopOnAppSwitch
    self.maxRunMinutes = maxRunMinutes
    self.showIndicator = showIndicator
  }
}

extension AutomationSettings: Codable {
  private enum Key: String, CodingKey { case stopShortcut, stopOnAppSwitch, maxRunMinutes, showIndicator }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    let d = AutomationSettings()
    let stop: KeyCombo? =
      c.contains(.stopShortcut) ? try c.decodeIfPresent(KeyCombo.self, forKey: .stopShortcut) : d.stopShortcut
    self.init(
      stopShortcut: stop,
      stopOnAppSwitch: try c.decodeIfPresent(Bool.self, forKey: .stopOnAppSwitch) ?? d.stopOnAppSwitch,
      maxRunMinutes: try c.decodeIfPresent(Double.self, forKey: .maxRunMinutes) ?? d.maxRunMinutes,
      showIndicator: try c.decodeIfPresent(Bool.self, forKey: .showIndicator) ?? d.showIndicator)
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Key.self)
    if let stopShortcut {
      try c.encode(stopShortcut, forKey: .stopShortcut)
    } else {
      try c.encodeNil(forKey: .stopShortcut)
    }
    try c.encode(stopOnAppSwitch, forKey: .stopOnAppSwitch)
    try c.encode(maxRunMinutes, forKey: .maxRunMinutes)
    try c.encode(showIndicator, forKey: .showIndicator)
  }
}
