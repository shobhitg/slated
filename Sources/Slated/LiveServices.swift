import AppKit
import SlatedCore
import SlatedSystem
import SlatedUI

/// The real implementation of the UI's `AppServices`, backed by the engine.
class LiveServices: AppServices {
  let engine: Engine

  init(engine: Engine) { self.engine = engine }

  /// What the clipboard picker is given: `SwitcherServices`.
  static func forClipboardSwitcher(_ engine: Engine) -> any AppServices { SwitcherServices(engine: engine) }

  var configurationFileURL: URL { engine.store.fileURL }

  /// Throws while config.json can't be read, so Settings pauses saving instead of overwriting it.
  func loadConfiguration() throws -> SlatedConfiguration {
    if let error = engine.store.loadError { throw ConfigUnreadable(message: error) }
    return engine.configuration
  }

  func saveConfiguration(_ configuration: SlatedConfiguration) throws { try engine.save(configuration) }

  func runtimeStatus() -> RuntimeStatus { engine.status }

  func slateSources() -> [SlateSource] { engine.sources.sources }

  func screens() -> [ScreenInfo] { Screens.current() }

  func runningApplications() -> [AppInfo] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }
      .map { AppInfo(name: $0.localizedName ?? "Unknown", bundleID: $0.bundleIdentifier, path: $0.bundleURL?.path) }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  func requestAccessibilityPermission() {
    Log.record("ui.request_accessibility")
    Permissions.requestAccessibility()
  }

  func openAccessibilitySettings() {
    Log.record("ui.open_accessibility_settings")
    Permissions.openAccessibilitySettings()
  }

  func reload() {
    Log.record("ui.reload")
    engine.reload()
  }

  func revealConfigurationFile() {
    Log.record("ui.reveal_config")
    NSWorkspace.shared.activateFileViewerSelecting([engine.store.fileURL])
  }

  func revealFile(atPath path: String) {
    Log.record("ui.reveal_file", ["path": path])
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: SlatedPaths.expand(path))])
  }

  func setHotkeysSuspended(_ suspended: Bool) { engine.setSuspended(suspended) }

  func setPaused(_ paused: Bool) {
    Log.record("ui.pause", ["paused": paused])
    engine.setPaused(paused)
  }

  func setHotstringsEnabled(_ enabled: Bool) {
    Log.record("ui.hotstrings_enabled", ["enabled": enabled])
    do { try engine.setHotstringsEnabled(enabled) } catch {
      Log.error("config.save_failed", LogPrivacy.message(error.localizedDescription))
    }
  }

  func setLaunchAtLogin(_ enabled: Bool) throws { try engine.setLaunchAtLogin(enabled) }

  /// Under the key the old onboarding window used, so a Mac that finished it isn't asked again.
  static let setupFinishedKey = "onboardingCompleted"

  var setupFinished: Bool {
    get { UserDefaults.standard.bool(forKey: Self.setupFinishedKey) }
    set {
      UserDefaults.standard.set(newValue, forKey: Self.setupFinishedKey)
      if newValue { Log.record("ui.get_started_finished", ["accessibility": Permissions.isAccessibilityTrusted]) }
    }
  }

  func onChange(_ handler: @escaping @MainActor () -> Void) { engine.onChange(handler) }

  // MARK: Clipboard history

  func clipboardItems() -> [ClipboardItem] { engine.clipboard.history.items }

  func pasteClipboardItem(id: UUID) { engine.clipboard.paste(id: id) }

  func copyClipboardItem(id: UUID) { engine.clipboard.copy(id: id) }

  func deleteClipboardItem(id: UUID) { engine.clipboard.delete(id: id) }

  func togglePinClipboardItem(id: UUID) { engine.clipboard.togglePin(id: id) }

  func clearClipboardHistory() {
    Log.record("ui.clipboard_clear")
    engine.clipboard.clear()
  }

  func showClipboardHistory() {
    Log.record("ui.clipboard_open")
    engine.clipboard.showSwitcher()
  }

  func clipboardImageURL(_ image: ClipboardImage) -> URL? { engine.clipboard.imageURL(image) }

  // MARK: Automation

  func activeAutomations() -> [ActiveAutomation] { engine.automation.active }

  func stopAutomations() {
    Log.record("ui.automation_stop")
    engine.automation.stopAll(reason: "stopped from Slated")
  }
}

/// The clipboard picker's services. It reads the configuration only to say what Return does (paste
/// or copy), so it gets the one Slated is running, as the clipboard does: while config.json can't be
/// read, that's the last one that could, not an error (which made it say "Paste" for a setting of
/// copy only).
final class SwitcherServices: LiveServices {
  override func loadConfiguration() throws -> SlatedConfiguration { engine.configuration }
}
