import Foundation

@testable import SlatedCore
@testable import SlatedUI

// Settings while config.json can't be read (a hand edit half done): read-only, so nothing made there is
// thrown away when the fixed file loads, and the banner shows even when an edit was waiting to save.

private struct Unreadable: LocalizedError {
  var errorDescription: String? { "Couldn't read config.json: Unexpected end of file" }
}

/// The sample services, with a config.json that can break and be fixed. Like the app, it refuses saves
/// meanwhile and tells the UI when the file changes.
@MainActor final class BreakableServices: AppServices {
  let base = PreviewServices()
  var broken = false
  private var handlers: [@MainActor () -> Void] = []

  /// config.json changed on disk (broken, fixed or edited by hand).
  func fileChanged() { handlers.forEach { $0() } }

  var configurationFileURL: URL { base.configurationFileURL }
  func loadConfiguration() throws -> SlatedConfiguration {
    if broken { throw Unreadable() }
    return try base.loadConfiguration()
  }
  func saveConfiguration(_ configuration: SlatedConfiguration) throws {
    if broken { throw Unreadable() }
    try base.saveConfiguration(configuration)
  }
  func runtimeStatus() -> RuntimeStatus { base.runtimeStatus() }
  func slateSources() -> [SlateSource] { base.slateSources() }
  func screens() -> [ScreenInfo] { base.screens() }
  func runningApplications() -> [AppInfo] { base.runningApplications() }
  func requestAccessibilityPermission() {}
  func openAccessibilitySettings() {}
  func reload() {}
  func revealConfigurationFile() {}
  func revealFile(atPath path: String) {}
  func setHotkeysSuspended(_ suspended: Bool) {}
  func setPaused(_ paused: Bool) {}
  func setHotstringsEnabled(_ enabled: Bool) {}
  func setLaunchAtLogin(_ enabled: Bool) throws {}
  func onChange(_ handler: @escaping @MainActor () -> Void) {
    handlers.append(handler)
    base.onChange(handler)
  }
  func clipboardItems() -> [ClipboardItem] { [] }
  func pasteClipboardItem(id: UUID) {}
  func copyClipboardItem(id: UUID) {}
  func deleteClipboardItem(id: UUID) {}
  func togglePinClipboardItem(id: UUID) {}
  func clearClipboardHistory() {}
  func showClipboardHistory() {}
  func activeAutomations() -> [ActiveAutomation] { [] }
  func stopAutomations() {}
}

private func onMain(_ body: @MainActor () throws -> Void) throws {
  try MainActor.assumeIsolated(body)
}

@MainActor private func hotstring(_ trigger: String) -> Hotstring {
  Hotstring(trigger: trigger, replacement: "typed while config.json was broken")
}

let blockedSettingsTests = Suite(
  "BlockedSettings",
  [
    (
      "Settings is read-only while config.json can't be read, so nothing made there is lost",
      {
        try onMain {
          let services = BreakableServices()
          let model = AppModel(services: services)
          let count = model.configuration.hotstrings.count
          services.broken = true
          services.fileChanged()
          expect(model.loadError != nil)
          expect(model.saveState == .blocked)
          model.configuration.hotstrings.append(hotstring(";lost"))
          expectEqual(model.configuration.hotstrings.count, count)  // refused, and said so
          expect(model.toast?.message.contains("Fix config.json first") ?? false)
          // Fixed, with a hand edit of its own: that's what Settings shows, and edits save again.
          services.broken = false
          var fixed = services.base.configuration
          fixed.hotstrings.append(hotstring(";fixed"))
          try services.base.saveConfiguration(fixed)
          services.fileChanged()
          expect(model.loadError == nil)
          expectEqual(model.configuration.hotstrings.count, count + 1)
          model.configuration.hotstrings.append(hotstring(";after"))
          model.saveNow()
          expectEqual(services.base.configuration.hotstrings.count, count + 2)
        }
      }
    ),
    (
      "config.json breaking while an edit waits to be saved shows that it can't be read",
      {
        try onMain {
          let services = BreakableServices()
          let model = AppModel(services: services)
          model.configuration.hotstrings.append(hotstring(";pending"))
          expect(model.saveState == .pending)
          services.broken = true
          services.fileChanged()
          expect(model.loadError != nil, "the banner needs the error")
          expect(model.saveState == .blocked)
        }
      }
    ),
    (
      "a layout can't be renamed, added or deleted meanwhile, and its editor stays open",
      {
        try onMain {
          let services = BreakableServices()
          let model = AppModel(services: services)  // the preview's one Slated layout, “Coding”
          model.selectedLayout = .slated(name: "Coding", index: 0)
          services.broken = true
          services.fileChanged()
          var arrivals: [String: Set<LayoutReference>] = [:]
          expectEqual(model.typeLayoutName("Deep Work", renaming: "Coding", at: 0, arrivals: &arrivals), "Coding")
          expect(arrivals.isEmpty)
          model.addLayout()
          model.deleteLayout("Coding", at: 0)
          expectEqual(model.configuration.layouts.map(\.name), ["Coding"])
          expect(model.selectedLayout == .slated(name: "Coding", index: 0), "the editor would close")
          expect(model.toast?.message.contains("Fix config.json first") ?? false, "not “Deleted layout”")
        }
      }
    ),
    (
      "the hotstrings switch changes nothing while config.json can't be read, and says why",
      {
        try onMain {
          // Like the app, these services don't write the switch while the file can't be read.
          let services = BreakableServices()
          let model = AppModel(services: services)
          // Broken before the app has reported it: flipping the switch finds out.
          services.broken = true
          model.setHotstringsEnabled(false)
          expect(model.loadError != nil, "the banner needs the error")
          expect(model.saveState == .blocked)
          expect(model.toast?.message.contains("Fix config.json first") ?? false)
          expect(model.configuration.general.hotstringsEnabled)
          // Already read-only: the same.
          model.toast = nil
          model.setHotstringsEnabled(false)
          expect(model.toast?.message.contains("Fix config.json first") ?? false)
          expect(model.configuration.general.hotstringsEnabled)
        }
      }
    ),
  ])
