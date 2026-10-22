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
  public var diagnostics: [Diagnostic]

  public init(
    path: String, kind: Kind, exists: Bool, loaded: Bool, bindings: [SourceBinding] = [],
    diagnostics: [Diagnostic] = []
  ) {
    self.path = path
    self.kind = kind
    self.exists = exists
    self.loaded = loaded
    self.bindings = bindings
    self.diagnostics = diagnostics
  }
}

/// Whether a hotkey is live.
public enum HotkeyStatus: Hashable, Sendable {
  case active
  case disabled
  /// Another binding in Slated uses the same keys.
  case duplicate
  /// Registration failed, usually because another app owns the shortcut.
  case failed(String)
}

/// Live state of the running engine, shown in the UI and the menu bar.
public struct RuntimeStatus: Hashable, Sendable {
  public var accessibilityGranted: Bool
  public var hyperKeyActive: Bool
  public var hotstringsActive: Bool
  /// Keyed by `KeyCombo.string`, prefixed with the modal key's string and a space for modal bindings.
  public var hotkeys: [String: HotkeyStatus]
  /// Last thing Slated did, e.g. "Left half · Safari".
  public var lastAction: String?
  public var lastError: String?

  public init(
    accessibilityGranted: Bool = false, hyperKeyActive: Bool = false, hotstringsActive: Bool = false,
    hotkeys: [String: HotkeyStatus] = [:], lastAction: String? = nil, lastError: String? = nil
  ) {
    self.accessibilityGranted = accessibilityGranted
    self.hyperKeyActive = hyperKeyActive
    self.hotstringsActive = hotstringsActive
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
  func loadConfiguration() throws -> SlatedConfiguration
  /// Persists the configuration and applies it immediately (re-registers hotkeys, hotstrings, Hyper).
  func saveConfiguration(_ configuration: SlatedConfiguration) throws
  func runtimeStatus() -> RuntimeStatus
  func slateSources() -> [SlateSource]
  func screens() -> [ScreenInfo]
  func runningApplications() -> [AppInfo]
  /// Shows the system Accessibility prompt and adds Slated to the list in System Settings.
  func requestAccessibilityPermission()
  func openAccessibilitySettings()
  /// Reloads the config file and Slate sources from disk.
  func reload()
  func revealConfigurationFile()
  /// Suspends global hotkeys, Hyper and hotstrings while the UI records a shortcut.
  func setHotkeysSuspended(_ suspended: Bool)
  func setLaunchAtLogin(_ enabled: Bool) throws
  /// Called with a closure the app invokes whenever runtime status or sources change.
  func onChange(_ handler: @escaping @MainActor () -> Void)
}
