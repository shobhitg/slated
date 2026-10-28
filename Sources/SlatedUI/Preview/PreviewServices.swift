import Foundation
import SlatedCore

/// An in-memory `AppServices` with realistic sample data, for SwiftUI previews and UI snapshots.
///
/// It behaves like the real app where that's cheap: saving recomputes hotkey statuses (duplicates
/// included), pausing and the switches update `RuntimeStatus`, and requesting Accessibility
/// permission "grants" it after a moment so Get Started can be clicked through.
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
  /// Not yet on a first run.
  public var setupFinished: Bool
  private var sources: [SlateSource]
  private let scenario: Scenario
  private var handlers: [@MainActor () -> Void] = []

  public init(scenario: Scenario = .configured) {
    self.scenario = scenario
    setupFinished = scenario != .firstRun
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
      clipboard = ClipboardHistory(items: PreviewData.clipboard())
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
  public func slateSources() -> [SlateSource] {
    // Like the app: with loading off, the files are listed but not loaded.
    guard !configuration.general.loadSlateConfigs else { return sources }
    return sources.map { SlateSource(path: $0.path, kind: $0.kind, exists: $0.exists, loaded: false) }
  }
  public func screens() -> [ScreenInfo] { PreviewData.screens }
  public func runningApplications() -> [AppInfo] { PreviewData.runningApps }

  public func requestAccessibilityPermission() {
    Task { [weak self] in
      try? await Task.sleep(for: .seconds(1.5))
      self?.setAccessibilityGranted(true)
    }
  }

  /// Turns Accessibility permission on or off, as the app reports it when the user flips the switch
  /// in System Settings.
  public func setAccessibilityGranted(_ granted: Bool) {
    status.accessibilityGranted = granted
    recomputeStatus()
    notify()
  }

  public func openAccessibilitySettings() {}
  public func reload() { notify() }
  public func revealConfigurationFile() {}
  public func revealFile(atPath path: String) {}
  public func setHotkeysSuspended(_ suspended: Bool) {
    // Like the app: while suspended, no shortcut or hotstring is live, but the Hyper key is.
    hotkeysSuspended = suspended
    recomputeStatus()
    notify()
  }

  public func setPaused(_ paused: Bool) {
    status.paused = paused
    recomputeStatus()
    notify()
  }

  public func setHotstringsEnabled(_ enabled: Bool) {
    // Like the app: the switch is written to config.json (`general.hotstringsEnabled`) right away.
    configuration.general.hotstringsEnabled = enabled
    recomputeStatus()
    notify()
  }

  public func setLaunchAtLogin(_ enabled: Bool) throws {}

  public func onChange(_ handler: @escaping @MainActor () -> Void) { handlers.append(handler) }

  // MARK: Clipboard and automation sample data

  /// The clipboard history the UI sees. Empty in the `.empty` and `.firstRun` scenarios.
  public var clipboard = ClipboardHistory()
  /// Running automations the UI sees; none until a test or snapshot sets some.
  public var automations: [ActiveAutomation] = []
  /// Items "pasted" or "copied" from the UI, newest last, for tests.
  public private(set) var pastedClipboardItems: [UUID] = []

  /// Sample running automations (an auto-clicker and a held key), for snapshots and tests.
  public static func sampleAutomations(now: Date = Date()) -> [ActiveAutomation] {
    PreviewData.activeAutomations(now: now)
  }

  /// Replaces the running automations and notifies the UI, as the engine would.
  public func setActiveAutomations(_ automations: [ActiveAutomation]) {
    self.automations = automations
    notifyChange()
  }

  /// Records a copy and notifies the UI, as the pasteboard watcher would.
  public func simulateCopy(_ text: String, from app: String? = nil, at date: Date = Date()) {
    clipboard.add(text, from: app, at: date, limit: configuration.clipboard.maxItems)
    notifyChange()
  }

  public func clipboardItems() -> [ClipboardItem] { clipboard.items }

  public func pasteClipboardItem(id: UUID) { copyClipboardItem(id: id) }

  public func copyClipboardItem(id: UUID) {
    guard let item = clipboard.items.first(where: { $0.id == id }) else { return }
    pastedClipboardItems.append(id)
    // Like the app: the item moves to the top, keeping its pin.
    if let image = item.image {
      clipboard.add(image: image, from: item.sourceApp, at: Date(), limit: configuration.clipboard.maxItems)
    } else {
      clipboard.add(item.text, from: item.sourceApp, at: Date(), limit: configuration.clipboard.maxItems)
    }
    notifyChange()
  }
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
  public func clipboardImageURL(_ image: ClipboardImage) -> URL? { PreviewImages.url(for: image) }
  public func activeAutomations() -> [ActiveAutomation] { automations }
  public func stopAutomations() {
    automations = []
    notifyChange()
  }

  private func notifyChange() { for handler in handlers { handler() } }

  // MARK: Simulation

  private func notify() { handlers.forEach { $0() } }

  /// Registers every enabled binding like the app would: shared keys are duplicates (bindings
  /// limited to different apps don't clash), mouse buttons need Accessibility permission, Slated's
  /// built-in shortcuts register after the bindings, and one sample shortcut is "taken by another app".
  private func recomputeStatus() {
    var keys: [String: Int] = [:]
    var apps: [String: [[String]]] = [:]
    let slated = configuration.bindings.filter { $0.enabled && KeyNames.isValid($0.keys.key) }
    for binding in slated {
      let key = BindingStatusKey.key(binding.keys, modal: binding.modal)
      keys[key, default: 0] += 1
      apps[key, default: []].append(binding.onlyInApps)
    }
    if configuration.general.loadSlateConfigs {
      for source in sources where source.loaded {
        for binding in source.bindings {
          keys[binding.id, default: 0] += 1
          apps[binding.id, default: []].append([])
        }
      }
    }
    if configuration.clipboard.enabled, let shortcut = configuration.clipboard.shortcut {
      keys[shortcut.string, default: 0] += 1
      apps[shortcut.string, default: []].append([])
    }
    if let stop = configuration.automation.stopShortcut {
      keys[stop.string, default: 0] += 1
      apps[stop.string, default: []].append([])
    }
    var hotkeys: [String: HotkeyStatus] = [:]
    for (key, count) in keys {
      let scopes = apps[key] ?? []
      let everywhere = scopes.filter(\.isEmpty).count
      let perApp = scopes.filter { !$0.isEmpty }
      let overlapping =
        everywhere > 1 || (everywhere == 1 && !perApp.isEmpty)
        || Set(perApp.flatMap { $0 }).count < perApp.reduce(0) { $0 + $1.count }
      if key == PreviewData.failedKey {
        hotkeys[key] = .failed("Another app already uses ✦Space. Quit it or pick another shortcut.")
      } else if key == "alt+tab" {
        hotkeys[key] = .failed("macOS reserves ⌥⇥ for an input source shortcut.")
      } else if KeyNames.isMouseButton(KeyCombo(string: key)?.key ?? ""), !status.accessibilityGranted {
        hotkeys[key] = .failed("Mouse button shortcuts need Accessibility permission")
      } else {
        hotkeys[key] = count > 1 && overlapping ? .duplicate : .active
      }
    }
    status.hotkeys = hotkeys
    status.hotstringsEnabled = configuration.general.hotstringsEnabled
    status.hyperKeyActive = configuration.keyboard.capsLock == .hyper && !status.paused
    status.hotstringsActive =
      status.hotstringsEnabled && !status.paused && !hotkeysSuspended && !configuration.hotstrings.isEmpty
  }
}
