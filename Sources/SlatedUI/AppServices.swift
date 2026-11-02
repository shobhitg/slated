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

/// Live state of the running engine, shown in the main window and the menu bar icon.
public struct RuntimeStatus: Hashable, Sendable {
  public var accessibilityGranted: Bool
  public var hyperKeyActive: Bool
  /// The user's text-expansion switch (`setHotstringsEnabled`), kept across launches.
  public var hotstringsEnabled: Bool
  /// Hotstrings are matching right now (enabled, not paused, permission granted).
  public var hotstringsActive: Bool
  /// Everything is paused ("Pause Slated", `setPaused`): no hotkeys, Hyper key or hotstrings.
  public var paused: Bool
  /// Keyed by `KeyCombo.string`, prefixed with the modal key's string and a space for modal bindings.
  public var hotkeys: [String: HotkeyStatus]
  /// Last thing Slated did, e.g. "Left half · Safari".
  public var lastAction: String?
  public var lastError: String?
  /// Whether screenshots saved as files reach the clipboard history (`clipboard.screenshots`).
  public var screenshots: ScreenshotFolderStatus
  /// What setting `keyboard.keyRepeat` did; nil while Slated leaves key repeat alone.
  public var keyRepeat: KeyRepeatState?
  /// Where Slated's menu bar icon is.
  public var menuBarIcon: MenuBarIconState
  /// The notice about an icon behind the notch was dismissed (until the icon shows again).
  public var menuBarNoticeDismissed: Bool

  public init(
    accessibilityGranted: Bool = false, hyperKeyActive: Bool = false, hotstringsEnabled: Bool = true,
    hotstringsActive: Bool = false, paused: Bool = false, hotkeys: [String: HotkeyStatus] = [:],
    lastAction: String? = nil, lastError: String? = nil, screenshots: ScreenshotFolderStatus = .off,
    keyRepeat: KeyRepeatState? = nil, menuBarIcon: MenuBarIconState = .shown, menuBarNoticeDismissed: Bool = false
  ) {
    self.accessibilityGranted = accessibilityGranted
    self.hyperKeyActive = hyperKeyActive
    self.hotstringsEnabled = hotstringsEnabled
    self.hotstringsActive = hotstringsActive
    self.paused = paused
    self.hotkeys = hotkeys
    self.lastAction = lastAction
    self.lastError = lastError
    self.screenshots = screenshots
    self.keyRepeat = keyRepeat
    self.menuBarIcon = menuBarIcon
    self.menuBarNoticeDismissed = menuBarNoticeDismissed
  }
}

/// Slated's icon in the menu bar.
public enum MenuBarIconState: Hashable, Sendable {
  case shown
  /// The menu bar is full and macOS put the icon behind the camera notch.
  case behindNotch
  /// Turned off (`general.showStatusIcon`).
  case off
}

/// The screenshot folder clipboard history watches. `folder` is its name ("Desktop").
public enum ScreenshotFolderStatus: Hashable, Sendable {
  /// Not watched: the setting or clipboard history is off (or it's just starting).
  case off
  case watching(folder: String)
  /// macOS doesn't let Slated see the folder: allowed in Privacy & Security → Files and Folders.
  case denied(folder: String)
  /// The folder isn't there (an external disk that isn't connected, say).
  case missing(folder: String)
}

/// Everything the UI can ask of the app. Implemented by the app target (live) and by
/// `PreviewServices` (sample data for previews and UI snapshots).
@MainActor
public protocol AppServices: AnyObject {
  /// config.json: what your keys do (keyboard, bindings, hotstrings, layouts, display defaults).
  var configurationFileURL: URL { get }
  /// settings.json, beside it: how Slated behaves (general, windows, clipboard, automation, island).
  var settingsFileURL: URL { get }
  /// The configuration in config.json and settings.json. Throws when either can't be read or decoded,
  /// even if the app keeps running what it loaded before: the UI then stops saving rather than
  /// overwrite the user's file with that older (or, at launch, empty) configuration.
  func loadConfiguration() throws -> SlatedConfiguration
  /// Persists the configuration (writing only the file whose part changed) and applies it
  /// immediately (re-registers hotkeys, hotstrings, Hyper).
  func saveConfiguration(_ configuration: SlatedConfiguration) throws
  func runtimeStatus() -> RuntimeStatus
  /// The Slate config "Import Slate Config" reads (`~/.slate.js`, else `~/.slate`), as written there;
  /// nil when there's none.
  func slateConfigPath() -> String?
  /// Adds the Slate config's shortcuts, layouts, display defaults and settings to Slated's
  /// configuration, keeping what Slated already has, and saves it. Throws when there's no Slate config
  /// or saving fails.
  func importSlateConfig() throws -> SlateImportReport
  /// What a first run or the migration of a version 1 config imported from the Slate config, until
  /// `dismissSlateImportNotice`.
  func slateImportNotice() -> SlateImportReport?
  func dismissSlateImportNotice()
  func screens() -> [ScreenInfo]
  func runningApplications() -> [AppInfo]
  /// Shows the system Accessibility prompt and adds Slated to the list in System Settings.
  func requestAccessibilityPermission()
  func openAccessibilitySettings()
  /// Opens System Settings → Privacy & Security → Files and Folders (the screenshot folder's access).
  func openFilesAndFoldersSettings()
  /// Reloads config.json and settings.json from disk.
  func reload()
  func revealConfigurationFile()
  /// Shows a file in the Finder, e.g. a Slate config. `path` may start with `~`.
  func revealFile(atPath path: String)
  /// Stops every shortcut and hotstring from firing while the UI records a shortcut, and while the
  /// hotstring "try it" field has focus (so the real engine doesn't expand into it too). The Hyper key
  /// keeps working meanwhile (Caps Lock stays mapped to F18 and the event tap still adds its
  /// modifiers), so holding Caps Lock records ✦; only `setPaused` turns it off.
  func setHotkeysSuspended(_ suspended: Bool)
  /// Pauses or resumes all hotkeys, the Hyper key and hotstrings ("Pause Slated" in the menus).
  /// Runtime only: not saved in the configuration. Reflected in `RuntimeStatus.paused`.
  func setPaused(_ paused: Bool)
  /// Master switch for text expansion that leaves each hotstring's own `enabled` flag alone.
  /// The app keeps it across launches; reflected in `RuntimeStatus.hotstringsEnabled`.
  func setHotstringsEnabled(_ enabled: Bool)
  func setLaunchAtLogin(_ enabled: Bool) throws
  /// This computer's key repeat right now, for "Use this Mac's current setting"; nil when it can't be
  /// read.
  func currentSystemKeyRepeat() -> KeyRepeat?
  /// Hides the notice about the menu bar icon behind the notch until the icon shows again.
  func dismissMenuBarNotice()
  /// Get Started was finished once. The app keeps it across launches; until then the main window
  /// opens on Get Started.
  var setupFinished: Bool { get set }
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
  /// Opens the clipboard picker.
  func showClipboardHistory()
  /// A copied image's file, for thumbnails and previews; nil when it has none (any more).
  func clipboardImageURL(_ image: ClipboardImage) -> URL?
  /// A copied file is gone from where it was copied: moved or deleted.
  func clipboardFileMissing(_ path: String) -> Bool

  // MARK: Automation

  /// Auto-repeats and held inputs that are running right now.
  func activeAutomations() -> [ActiveAutomation]
  /// Stops every automation and releases anything held down.
  func stopAutomations()

  // MARK: The files

  /// Opens one of Slated's files, its folder or a Slate config, from a link or button in the window: a
  /// file in its default app (TextEdit when none), the folder in the Finder. Returns `.missing`, having
  /// opened nothing, when it isn't there, for the window to say so. Logs `ui.config_file_opened`.
  func openFile(_ link: FileLink) -> FileOpenPlan
  /// Puts text on the pasteboard: a setting's key or its value, from the settings' context menus.
  func copyText(_ text: String)
  /// Records what the settings window did with the files. Events name files only, never values.
  func logConfigEvent(_ event: ConfigUIEvent)
}

/// What the settings window did with config.json and settings.json, for the event log.
public enum ConfigUIEvent: Hashable, Sendable {
  /// Copy Key or Copy Value as JSON, on a setting in `file`.
  case keyCopied(ConfigFile, value: Bool)
  /// Hand edits adopted (`source` "disk"), or a conflict settled by reloading the file ("conflict").
  case reloaded([ConfigFile], source: String)
  /// A file changed on disk while the window had unsaved edits in it (`choice` nil), and what the user
  /// chose: "reload" or "keep".
  case conflict([ConfigFile], choice: String?)

  /// The event's name in the log.
  public var name: String {
    switch self {
    case .keyCopied: return "ui.config_key_copied"
    case .reloaded: return "ui.config_reloaded"
    case .conflict: return "ui.config_conflict"
    }
  }

  /// The event's data: file names and what happened, nothing from the files.
  public var data: [String: String] {
    let names = { (files: [ConfigFile]) in files.map(\.rawValue).sorted().joined(separator: ",") }
    switch self {
    case .keyCopied(let file, let value): return ["file": file.rawValue, "copied": value ? "value" : "key"]
    case .reloaded(let files, let source): return ["files": names(files), "source": source]
    case .conflict(let files, let choice): return ["files": names(files), "choice": choice ?? "pending"]
    }
  }
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

extension AppServices {
  /// No images by default (test doubles).
  public func clipboardImageURL(_ image: ClipboardImage) -> URL? { nil }
  /// Every copied file is still there by default (test doubles).
  public func clipboardFileMissing(_ path: String) -> Bool { false }
  public func openFilesAndFoldersSettings() {}
  public func currentSystemKeyRepeat() -> KeyRepeat? { nil }
  public func dismissMenuBarNotice() {}
  /// Test doubles open nothing, copy nothing to the real pasteboard and log nothing.
  public func openFile(_ link: FileLink) -> FileOpenPlan { .defaultApp }
  public func copyText(_ text: String) {}
  public func logConfigEvent(_ event: ConfigUIEvent) {}
}
