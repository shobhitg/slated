import Foundation
import SlatedCore

// The contract between the UI (this module) and the app target, which implements `AppServices`
// with the real system integrations. The UI never touches Accessibility, hotkeys, or files directly.

/// A running application, for app pickers (hotstring app filters, layouts, focus).
public struct AppInfo: Identifiable, Hashable, Sendable {
  public var id: String { bundleID ?? name }
  public var name: String
  public var bundleID: String?
  /// Bundle path, for loading the icon with `NSWorkspace.shared.icon(forFile:)`.
  public var path: String?

  public init(name: String, bundleID: String?, path: String?) {
    self.name = name
    self.bundleID = bundleID
    self.path = path
  }
}

/// A binding defined in a Slate config file (read-only in the UI).
public struct SourceBinding: Identifiable, Hashable, Sendable {
  public var id: String { (modal.map { $0.keys.string + " " } ?? "") + keys.string }
  public var keys: KeyCombo
  public var modal: ModalKey?
  /// Short description, e.g. "corner top-left" or "JavaScript function".
  public var summary: String
  /// The operation when it is static (JavaScript callbacks have none).
  public var action: Action?

  public init(keys: KeyCombo, modal: ModalKey? = nil, summary: String, action: Action? = nil) {
    self.keys = keys
    self.modal = modal
    self.summary = summary
    self.action = action
  }
}

/// A Slate config file Slated loads alongside its own configuration.
public struct SlateSource: Identifiable, Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable {
    /// `~/.slate.js`
    case javascript
    /// `~/.slate`
    case classic
  }

  public var id: String { path }
  public var path: String
  public var kind: Kind
  public var exists: Bool
  public var loaded: Bool
  public var bindings: [SourceBinding]
  /// Layouts the file defines (`slate.layout(...)` / `layout` lines), shown read-only in Settings.
  public var layouts: [Layout]
  public var diagnostics: [Diagnostic]

  public init(
    path: String, kind: Kind, exists: Bool, loaded: Bool, bindings: [SourceBinding] = [],
    layouts: [Layout] = [], diagnostics: [Diagnostic] = []
  ) {
    self.path = path
    self.kind = kind
    self.exists = exists
    self.loaded = loaded
    self.bindings = bindings
    self.layouts = layouts
    self.diagnostics = diagnostics
  }
}

/// Whether a hotkey is live.
public enum HotkeyStatus: Hashable, Sendable {
  case active
  case disabled
  /// Another binding in Slated uses the same keys. Report it for every key bound more than once
  /// (where the bindings can be live at once): statuses are per key, so this is the only way the UI
  /// learns that one of them never runs.
  case duplicate
  /// Registration failed, usually because another app owns the shortcut.
  case failed(String)
}

/// Live state of the running engine, shown in the UI and the menu bar.
public struct RuntimeStatus: Hashable, Sendable {
  public var accessibilityGranted: Bool
  public var hyperKeyActive: Bool
  /// The user's text-expansion switch (`setHotstringsEnabled`), kept across launches.
  public var hotstringsEnabled: Bool
  /// Hotstrings are matching right now (enabled, not paused, permission granted).
  public var hotstringsActive: Bool
  /// Everything is paused from the menu bar (`setPaused`): no hotkeys, Hyper key or hotstrings.
  public var paused: Bool
  /// Keyed by `KeyCombo.string`, prefixed with the modal key's string and a space for modal bindings.
  public var hotkeys: [String: HotkeyStatus]
  /// Last thing Slated did, e.g. "Left half · Safari".
  public var lastAction: String?
  public var lastError: String?

  public init(
    accessibilityGranted: Bool = false, hyperKeyActive: Bool = false, hotstringsEnabled: Bool = true,
    hotstringsActive: Bool = false, paused: Bool = false, hotkeys: [String: HotkeyStatus] = [:],
    lastAction: String? = nil, lastError: String? = nil
  ) {
    self.accessibilityGranted = accessibilityGranted
    self.hyperKeyActive = hyperKeyActive
    self.hotstringsEnabled = hotstringsEnabled
    self.hotstringsActive = hotstringsActive
    self.paused = paused
    self.hotkeys = hotkeys
    self.lastAction = lastAction
    self.lastError = lastError
  }
}

/// Everything the UI can ask of the app. Implemented by the app target (live) and by
/// `PreviewServices` (sample data for previews and UI snapshots).
@MainActor
public protocol AppServices: AnyObject {
  var configurationFileURL: URL { get }
  /// The configuration in config.json. Throws when the file can't be read or decoded, even if the
  /// app keeps running what it loaded before: the UI then stops saving rather than overwrite the
  /// user's file with that older (or, at launch, empty) configuration.
  func loadConfiguration() throws -> SlatedConfiguration
  /// Persists the configuration and applies it immediately (re-registers hotkeys, hotstrings, Hyper).
  func saveConfiguration(_ configuration: SlatedConfiguration) throws
  func runtimeStatus() -> RuntimeStatus
  /// Every configured Slate file, also while `general.loadSlateConfigs` is off (then `loaded` is
  /// false), so Settings can show them as off rather than missing.
  func slateSources() -> [SlateSource]
  func screens() -> [ScreenInfo]
  func runningApplications() -> [AppInfo]
  /// Shows the system Accessibility prompt and adds Slated to the list in System Settings.
  func requestAccessibilityPermission()
  func openAccessibilitySettings()
  /// Reloads the config file and Slate sources from disk.
  func reload()
  func revealConfigurationFile()
  /// Shows a file in the Finder, e.g. a Slate config. `path` may start with `~`.
  func revealFile(atPath path: String)
  /// Stops every shortcut and hotstring from firing while the UI records a shortcut, and while the
  /// hotstring "try it" field has focus (so the real engine doesn't expand into it too). The Hyper key
  /// keeps working meanwhile (Caps Lock stays mapped to F18 and the event tap still adds its
  /// modifiers), so holding Caps Lock records ✦; only `setPaused` turns it off.
  func setHotkeysSuspended(_ suspended: Bool)
  /// Pauses or resumes all hotkeys, the Hyper key and hotstrings (menu bar "Pause Slated").
  /// Runtime only: not saved in the configuration. Reflected in `RuntimeStatus.paused`.
  func setPaused(_ paused: Bool)
  /// Master switch for text expansion that leaves each hotstring's own `enabled` flag alone.
  /// The app keeps it across launches; reflected in `RuntimeStatus.hotstringsEnabled`.
  func setHotstringsEnabled(_ enabled: Bool)
  func setLaunchAtLogin(_ enabled: Bool) throws
  /// Called with a closure the app invokes whenever runtime status or sources change.
  func onChange(_ handler: @escaping @MainActor () -> Void)

  // MARK: Clipboard history

  /// Newest first; pinned items are included wherever they fall.
  func clipboardItems() -> [ClipboardItem]
  /// Puts the item on the clipboard and, if `clipboard.pasteAfterSelecting`, pastes it into the app
  /// that was frontmost before Slated's switcher opened.
  func pasteClipboardItem(id: UUID)
  /// Puts the item on the clipboard without pasting.
  func copyClipboardItem(id: UUID)
  func deleteClipboardItem(id: UUID)
  func togglePinClipboardItem(id: UUID)
  /// Removes everything except pinned items.
  func clearClipboardHistory()
  /// Opens the clipboard switcher panel.
  func showClipboardHistory()

  // MARK: Automation

  /// Auto-repeats and held inputs that are running right now.
  func activeAutomations() -> [ActiveAutomation]
  /// Stops every automation and releases anything held down.
  func stopAutomations()
}

/// A running automation, for the UI: an auto-repeat or a held mouse button or key.
public struct ActiveAutomation: Identifiable, Hashable, Sendable {
  public var id: String
  /// E.g. "Repeat Click Left every 100 ms" or "Hold Right Button".
  public var title: String
  /// What started it, e.g. "hotkey hyper+r".
  public var trigger: String?
  public var startedAt: Date
  public var repetitions: Int

  public init(id: String, title: String, trigger: String?, startedAt: Date, repetitions: Int) {
    self.id = id
    self.title = title
    self.trigger = trigger
    self.startedAt = startedAt
    self.repetitions = repetitions
  }
}
