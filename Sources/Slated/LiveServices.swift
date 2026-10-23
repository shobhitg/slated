import AppKit
import SlatedCore
import SlatedSystem
import SlatedUI

/// The real implementation of the UI's `AppServices`, backed by the engine.
final class LiveServices: AppServices {
  private let engine: Engine

  init(engine: Engine) { self.engine = engine }

  var configurationFileURL: URL { engine.store.fileURL }

  func loadConfiguration() throws -> SlatedConfiguration { engine.configuration }

  func saveConfiguration(_ configuration: SlatedConfiguration) throws { try engine.save(configuration) }

  func runtimeStatus() -> RuntimeStatus { engine.status }

  func slateSources() -> [SlateSource] { engine.sources.sources }

  func screens() -> [ScreenInfo] { Screens.current() }

  func runningApplications() -> [AppInfo] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular }
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

  func setHotkeysSuspended(_ suspended: Bool) { engine.setSuspended(suspended) }

  func setLaunchAtLogin(_ enabled: Bool) throws { try engine.setLaunchAtLogin(enabled) }

  func onChange(_ handler: @escaping @MainActor () -> Void) { engine.onChange(handler) }
}
