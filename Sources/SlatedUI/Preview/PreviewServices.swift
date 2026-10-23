import Foundation
import SlatedCore

/// An in-memory `AppServices` with realistic sample data, for SwiftUI previews and UI snapshots.
///
/// It behaves like the real app where that's cheap: saving recomputes hotkey statuses (duplicates
/// included), pausing and the switches update `RuntimeStatus`, and requesting Accessibility
/// permission "grants" it after a moment so the onboarding flow can be clicked through.
@MainActor
public final class PreviewServices: AppServices {
  public enum Scenario: Sendable {
    /// A configured Mac: Hyper key on, ~25 bindings, hotstrings, a loaded `~/.slate.js`.
    case configured
    /// First launch: no permission yet, Hyper off, nothing in Slated, a `~/.slate.js` to import.
    case firstRun
    /// Permission granted but nothing configured and no Slate files: every empty state.
    case empty
    /// config.json has a syntax error, so the UI must not overwrite it.
    case brokenConfig
  }

  public let configurationFileURL = URL(fileURLWithPath: NSHomeDirectory() + "/.config/slated/config.json")
  public private(set) var configuration: SlatedConfiguration
  public private(set) var status: RuntimeStatus
  public private(set) var hotkeysSuspended = false
  private var sources: [SlateSource]
  private let scenario: Scenario
  private var handlers: [@MainActor () -> Void] = []

  public init(scenario: Scenario = .configured) {
    self.scenario = scenario
    let slateJS = NSHomeDirectory() + "/.slate.js"
    let classic = NSHomeDirectory() + "/.slate"
    switch scenario {
    case .configured, .brokenConfig:
      var config = SlatedConfiguration()
      config.keyboard.capsLock = .hyper
      config.general.launchAtLogin = true
      config.general.showActionHUD = true
      config.bindings = PreviewData.bindings
      config.hotstrings = PreviewData.hotstrings
      config.layouts = PreviewData.layouts
      configuration = config
      sources = [
        SlateSource(
          path: slateJS, kind: .javascript, exists: true, loaded: true, bindings: PreviewData.slateJSBindings,
          layouts: PreviewData.sourceLayouts, diagnostics: PreviewData.slateJSDiagnostics),
        SlateSource(path: classic, kind: .classic, exists: false, loaded: false),
      ]
      status = RuntimeStatus(
        accessibilityGranted: true, hyperKeyActive: true, hotstringsActive: true,
        lastAction: "Left Half · Safari", lastError: "Couldn't resize “Calculator”: its window has a fixed size.")
    case .firstRun:
      configuration = SlatedConfiguration()
      sources = [
        SlateSource(
          path: slateJS, kind: .javascript, exists: true, loaded: true, bindings: PreviewData.slateJSBindings,
          layouts: PreviewData.sourceLayouts),
        SlateSource(path: classic, kind: .classic, exists: false, loaded: false),
      ]
      status = RuntimeStatus(accessibilityGranted: false, hotstringsActive: false)
    case .empty:
      configuration = SlatedConfiguration()
      sources = [
        SlateSource(path: slateJS, kind: .javascript, exists: false, loaded: false),
        SlateSource(path: classic, kind: .classic, exists: false, loaded: false),
      ]
      status = RuntimeStatus(accessibilityGranted: true, hotstringsActive: true)
    }
    recomputeStatus()
  }

  // MARK: AppServices

  public func loadConfiguration() throws -> SlatedConfiguration {
    if scenario == .brokenConfig {
      let underlying = NSError(
        domain: NSCocoaErrorDomain, code: 3840,
        userInfo: [NSDebugDescriptionErrorKey: "Unexpected character '}' around line 14, column 3."])
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "The given data was not valid JSON.", underlyingError: underlying))
    }
    return configuration
  }

  public func saveConfiguration(_ configuration: SlatedConfiguration) throws {
    self.configuration = configuration
    recomputeStatus()
    notify()
  }

  public func runtimeStatus() -> RuntimeStatus { status }
  public func slateSources() -> [SlateSource] { sources }
  public func screens() -> [ScreenInfo] { PreviewData.screens }
  public func runningApplications() -> [AppInfo] { PreviewData.runningApps }

  public func requestAccessibilityPermission() {
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.5))
      self?.status.accessibilityGranted = true
      self?.notify()
    }
  }

  public func openAccessibilitySettings() {}
  public func reload() { notify() }
  public func revealConfigurationFile() {}
  public func revealFile(atPath path: String) {}
  public func setHotkeysSuspended(_ suspended: Bool) { hotkeysSuspended = suspended }

  public func setPaused(_ paused: Bool) {
    status.paused = paused
    recomputeStatus()
    notify()
  }

  public func setHotstringsEnabled(_ enabled: Bool) {
    status.hotstringsEnabled = enabled
    recomputeStatus()
    notify()
  }

  public func setLaunchAtLogin(_ enabled: Bool) throws {}

  public func onChange(_ handler: @escaping @MainActor () -> Void) { handlers.append(handler) }

  // MARK: Clipboard and automation sample data

  public var clipboard = ClipboardHistory(items: PreviewServices.sampleClipboard)
  public var automations: [ActiveAutomation] = []

  static let sampleClipboard: [ClipboardItem] = {
    let now = Date(timeIntervalSince1970: 1_793_000_000)
    let samples: [(String, String?, Double, Bool)] = [
      ("https://github.com/shobhit-aida/slated", "com.apple.Safari", 40, false),
      ("Let's sync tomorrow at 10 — I'll bring the layout sketches.", "com.tinyspeck.slackmacgap", 300, false),
      ("git commit -m \"Make the author's Slate config the default\"", "com.apple.Terminal", 900, false),
      ("1 Infinite Loop\nCupertino, CA 95014", "com.apple.Notes", 5_400, true),
      ("screenOriginX+screenSizeX/2", "com.microsoft.VSCode", 86_000, false),
    ]
    return samples.map { text, app, ago, pinned in
      ClipboardItem(text: text, copiedAt: now.addingTimeInterval(-ago), sourceApp: app, pinned: pinned)
    }
  }()

  public func clipboardItems() -> [ClipboardItem] { clipboard.items }
  public func pasteClipboardItem(id: UUID) {}
  public func copyClipboardItem(id: UUID) {}
  public func deleteClipboardItem(id: UUID) {
    clipboard.remove(id: id)
    notifyChange()
  }
  public func togglePinClipboardItem(id: UUID) {
    clipboard.togglePin(id: id)
    notifyChange()
  }
  public func clearClipboardHistory() {
    clipboard.clear()
    notifyChange()
  }
  public func showClipboardHistory() {}
  public func activeAutomations() -> [ActiveAutomation] { automations }
  public func stopAutomations() {
    automations = []
    notifyChange()
  }

  private func notifyChange() { for handler in handlers { handler() } }

  // MARK: Simulation

  private func notify() { handlers.forEach { $0() } }

  /// Registers every enabled binding like the app would: shared keys are duplicates, and one
  /// sample shortcut is "taken by another app".
  private func recomputeStatus() {
    var keys: [String: Int] = [:]
    let slated = configuration.bindings.filter { $0.enabled && KeyNames.isValid($0.keys.key) }
    for binding in slated { keys[BindingStatusKey.key(binding.keys, modal: binding.modal), default: 0] += 1 }
    if configuration.general.loadSlateConfigs {
      for source in sources where source.loaded {
        for binding in source.bindings { keys[binding.id, default: 0] += 1 }
      }
    }
    var hotkeys: [String: HotkeyStatus] = [:]
    for (key, count) in keys {
      if key == PreviewData.failedKey {
        hotkeys[key] = .failed("Another app already uses ✦Space. Quit it or pick another shortcut.")
      } else if key == "alt+tab" {
        hotkeys[key] = .failed("macOS reserves ⌥⇥ for an input source shortcut.")
      } else {
        hotkeys[key] = count > 1 ? .duplicate : .active
      }
    }
    status.hotkeys = hotkeys
    status.hyperKeyActive = configuration.keyboard.capsLock == .hyper && !status.paused
    status.hotstringsActive = status.hotstringsEnabled && !status.paused && !configuration.hotstrings.isEmpty
  }
}
