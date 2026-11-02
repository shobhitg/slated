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
    /// A configured Mac just moved to two config files: Hyper key on, ~25 bindings, hotstrings, and
    /// the notice about the `~/.slate.js` it imported.
    case configured
    /// First launch: no permission yet, Hyper off, the shortcuts of the `~/.slate.js` it imported.
    case firstRun
    /// Permission granted but nothing configured and no Slate config: every empty state.
    case empty
    /// config.json has a syntax error, so the UI must not overwrite it.
    case brokenConfig
  }

  public let configurationFileURL = URL(fileURLWithPath: NSHomeDirectory() + "/.config/slated/config.json")
  public let settingsFileURL = URL(fileURLWithPath: NSHomeDirectory() + "/.config/slated/settings.json")
  public private(set) var configuration: SlatedConfiguration
  public private(set) var status: RuntimeStatus
  public private(set) var hotkeysSuspended = false
  /// Not yet on a first run.
  public var setupFinished: Bool
  /// The Slate config there is to import, if any.
  public var slateConfig: String?
  /// What a first run or the migration imported, until dismissed.
  public var importNotice: SlateImportReport?
  private let scenario: Scenario
  private var handlers: [@MainActor () -> Void] = []

  public init(scenario: Scenario = .configured) {
    self.scenario = scenario
    setupFinished = scenario != .firstRun
    switch scenario {
    case .configured, .brokenConfig:
      var config = SlatedConfiguration()
      config.keyboard.capsLock = .hyper
      config.keyboard.keyRepeat = KeyRepeat(delay: 200, interval: 17)
      config.general.launchAtLogin = true
      config.general.showActionHUD = true
      config.bindings = PreviewData.bindings
      config.hotstrings = PreviewData.hotstrings
      config.layouts = PreviewData.layouts
      slateConfig = "~/.slate.js"
      importNotice = config.merge(PreviewData.slateImport)
      configuration = config
      status = RuntimeStatus(
        accessibilityGranted: true, hyperKeyActive: true, hotstringsActive: true,
        lastAction: "Left Half · Safari", lastError: "Couldn't resize “Calculator”: its window has a fixed size.",
        screenshots: .watching(folder: "Desktop"), keyRepeat: .applied)
      clipboard = ClipboardHistory(items: PreviewData.clipboard())
    case .firstRun:
      // As a first run leaves it: the Slate config, imported.
      var config = SlatedConfiguration()
      slateConfig = "~/.slate.js"
      importNotice = config.merge(PreviewData.slateImport)
      configuration = config
      status = RuntimeStatus(accessibilityGranted: false, hotstringsActive: false)
    case .empty:
      configuration = SlatedConfiguration()
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

  /// The sample Mac's key repeat: the author's.
  public var systemKeyRepeat: KeyRepeat? = KeyRepeat(delay: 200, interval: 17)

  public func currentSystemKeyRepeat() -> KeyRepeat? { systemKeyRepeat }

  public func dismissMenuBarNotice() {
    status.menuBarNoticeDismissed = true
    notify()
  }

  /// What applying key repeat did, as the engine would report it.
  public func setKeyRepeatState(_ state: KeyRepeatState?) {
    status.keyRepeat = state
    notify()
  }

  /// Where the menu bar icon is, as the app would report it.
  public func setMenuBarIcon(_ state: MenuBarIconState) {
    status.menuBarIcon = state
    if state != .behindNotch { status.menuBarNoticeDismissed = false }
    notify()
  }
  public func slateConfigPath() -> String? { slateConfig }

  /// Like the app: adds what the sample ~/.slate.js has that Slated doesn't.
  public func importSlateConfig() throws -> SlateImportReport {
    guard slateConfig != nil else {
      throw NSError(
        domain: "Slated", code: 1,
        userInfo: [
          NSLocalizedDescriptionKey: "There's no Slate config to import: Slated looked for ~/.slate.js and ~/.slate."
        ])
    }
    var config = configuration
    let report = config.merge(PreviewData.slateImport)
    try saveConfiguration(config)
    return report
  }

  public func slateImportNotice() -> SlateImportReport? { importNotice }

  public func dismissSlateImportNotice() {
    importNotice = nil
    notify()
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
    // Like the app: the item moves to the top, keeping its pin. Files that are all gone stay put.
    if let files = item.files, item.isFiles {
      guard files.contains(where: { !clipboardFileMissing($0) }) else { return }
      clipboard.add(files: files, from: item.sourceApp, at: Date(), limit: configuration.clipboard.maxItems)
    } else if let image = item.image {
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
  public func clipboardFileMissing(_ path: String) -> Bool { !FileManager.default.fileExists(atPath: path) }
  public func openFilesAndFoldersSettings() { openedFilesAndFoldersSettings += 1 }

  /// How often the UI opened Privacy & Security → Files and Folders, for tests.
  public private(set) var openedFilesAndFoldersSettings = 0

  /// What the UI opened, copied and logged about the files, for tests.
  public private(set) var openedConfigFiles: [ConfigFile] = []
  public private(set) var copiedTexts: [String] = []
  public private(set) var configEvents: [ConfigUIEvent] = []
  public func openConfigFile(_ file: ConfigFile) { openedConfigFiles.append(file) }
  public func copyText(_ text: String) { copiedTexts.append(text) }
  public func logConfigEvent(_ event: ConfigUIEvent) { configEvents.append(event) }

  /// A hand edit: the files now say `configuration`, and the app reports the change as its file
  /// watcher would.
  public func simulateHandEdit(_ configuration: SlatedConfiguration) {
    self.configuration = configuration
    recomputeStatus()
    notify()
  }

  /// The screenshot folder's state as the app would report it: watching, not allowed or missing.
  public func setScreenshotStatus(_ screenshots: ScreenshotFolderStatus) {
    status.screenshots = screenshots
    notifyChange()
  }

  /// Records copied files and notifies the UI, as the pasteboard watcher would.
  public func simulateCopy(files: [String], from app: String? = "com.apple.finder", at date: Date = Date()) {
    clipboard.add(files: files, from: app, at: date, limit: configuration.clipboard.maxItems)
    notifyChange()
  }
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
