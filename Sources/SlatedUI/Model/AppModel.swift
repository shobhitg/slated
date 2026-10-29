import Foundation
import Observation
import SlatedCore

/// Where the draft configuration stands relative to the file on disk.
enum SaveState: Equatable {
  case saved
  /// Edits are waiting for the debounce to pass.
  case pending
  /// Everything was written except `count` items that have errors.
  case partiallySaved(count: Int)
  case failed(String)
  /// config.json couldn't be read, so saving is paused rather than overwriting the user's file.
  case blocked
}

/// The UI's single source of truth: a draft of the configuration plus the engine's live state.
///
/// Views edit `configuration` directly (through bindings); every change is validated and saved
/// after a short pause, so there is no Save button. Items with errors are held back (their last
/// saved version stays on disk) and flagged in the UI. The model refreshes runtime status, the Slate
/// config there is to import, screens, apps, the clipboard history and running automations whenever
/// the app reports a change through `AppServices.onChange`, and picks up hand edits to config.json
/// and settings.json when there are no unsaved edits. Clipboard and automation commands go through `AppServices` too.
@MainActor
@Observable
public final class AppModel {
  @ObservationIgnored public let services: any AppServices

  // MARK: Configuration

  /// The draft the UI edits.
  public var configuration: SlatedConfiguration {
    get { draft }
    set {
      guard newValue != draft else { return }
      // Read-only while config.json or settings.json can't be read: an edit couldn't be saved, and
      // the fixed file replaces the draft when it loads.
      guard loadError == nil else {
        showToast(
          "Fix \(unreadableFileName) first: nothing can be changed here until Slated can read it.",
          symbol: "exclamationmark.triangle", style: .failure)
        return
      }
      draft = newValue
      draftDidChange()
    }
  }
  private var draft: SlatedConfiguration
  /// The configuration as last read from or written to disk.
  private(set) var saved: SlatedConfiguration
  private(set) var issues: [ValidationIssue] = []
  private(set) var saveState: SaveState = .saved
  /// Why config.json couldn't be read, if it couldn't. Saving is paused until a reload succeeds.
  private(set) var loadError: String?

  // MARK: Live state

  public private(set) var runtimeStatus: RuntimeStatus
  /// The Slate config there is to import (`~/.slate.js`, else `~/.slate`); nil when there's none.
  public private(set) var slateConfigPath: String?
  /// What a first run or the migration of a version 1 config imported from the Slate config, until
  /// dismissed in Overview.
  public private(set) var slateImportNotice: SlateImportReport?
  public private(set) var screens: [ScreenInfo]
  public private(set) var runningApps: [AppInfo]
  /// Clipboard history, newest first (pinned items wherever they fall).
  public private(set) var clipboardItems: [ClipboardItem]
  /// Auto-repeats and held inputs running right now.
  public private(set) var activeAutomations: [ActiveAutomation]

  // MARK: Navigation

  /// The pane to show. `prepareToShowMainWindow` picks it as the window opens; set it after that to
  /// open a specific pane.
  public var selectedPane: SettingsPane = .overview
  /// Get Started's current step. The app moves it on when Accessibility is granted.
  public var getStartedStep: GetStartedStep = .welcome
  /// Get Started was finished once (the app keeps this across launches).
  public internal(set) var setupFinished: Bool
  public var selectedBinding: BindingSelection?
  public var selectedHotstringID: UUID?
  public var selectedLayout: LayoutSelection?
  /// A binding whose shortcut recorder should start recording when its editor appears.
  var recordShortcutFor: UUID?
  var toast: Toast?
  /// What the last import from Get Started or Settings did, shown there until the window closes.
  var lastSlateImport: SlateImportReport?

  /// How long to wait after the last edit before saving.
  @ObservationIgnored public var saveDelay: Duration = .milliseconds(450)
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  @ObservationIgnored private var toastTask: Task<Void, Never>?
  @ObservationIgnored private var suspensions = 0
  /// True while `saveConfiguration` or `setHotstringsEnabled` runs. The app may report the change it
  /// causes through `onChange` before the call returns; that's our own write, not a hand edit to adopt.
  @ObservationIgnored private var isSaving = false
  /// Ids given to copied items (see `withUniqueIDs`), by kind, original id and occurrence.
  @ObservationIgnored private var replacementIDs: [String: UUID] = [:]

  public init(services: any AppServices) {
    self.services = services
    var loaded = SlatedConfiguration()
    var error: String?
    do {
      loaded = try services.loadConfiguration()
    } catch let caught {
      error = Self.describe(caught)
    }
    draft = loaded
    saved = loaded
    loadError = error
    saveState = error == nil ? .saved : .blocked
    runtimeStatus = services.runtimeStatus()
    setupFinished = services.setupFinished
    slateConfigPath = services.slateConfigPath()
    slateImportNotice = services.slateImportNotice()
    screens = services.screens()
    runningApps = services.runningApplications()
    clipboardItems = services.clipboardItems()
    activeAutomations = services.activeAutomations()
    draft = withUniqueIDs(loaded)
    saved = draft
    issues = ConfigValidator.validate(draft, knownLayouts: knownLayoutNames)
    services.onChange { [weak self] in self?.servicesDidChange() }
  }

  /// `config` with a fresh id for every binding or hotstring that repeats an earlier one's id: an
  /// item copied in config.json, id and all. Otherwise the two would be one item here, and edits or a
  /// delete meant for the copy would reach the original. A copy gets the same id each time the file
  /// is read, and the next save writes it.
  private func withUniqueIDs(_ config: SlatedConfiguration) -> SlatedConfiguration {
    var config = config
    var seen: [String: Int] = [:]
    // Every id in the file, and every id handed out below. Once a save has written a copy's new id,
    // the file uses it; if the original is then pasted again, that paste needs an id of its own.
    var taken = Set(config.bindings.map { "binding|\($0.id)" } + config.hotstrings.map { "hotstring|\($0.id)" })
    func unique(_ id: UUID, kind: String) -> UUID {
      let occurrence = seen["\(kind)|\(id)", default: 0]
      seen["\(kind)|\(id)"] = occurrence + 1
      guard occurrence > 0 else { return id }
      let key = "\(kind)|\(id)|\(occurrence)"
      if let replacement = replacementIDs[key], taken.insert("\(kind)|\(replacement)").inserted {
        return replacement
      }
      let replacement = UUID()
      replacementIDs[key] = replacement
      taken.insert("\(kind)|\(replacement)")
      return replacement
    }
    for index in config.bindings.indices {
      config.bindings[index].id = unique(config.bindings[index].id, kind: "binding")
    }
    for index in config.hotstrings.indices {
      config.hotstrings[index].id = unique(config.hotstrings[index].id, kind: "hotstring")
    }
    return config
  }

  // MARK: Saving

  private func draftDidChange() {
    issues = ConfigValidator.validate(draft, knownLayouts: knownLayoutNames)
    saveTask?.cancel()
    guard loadError == nil else {
      saveState = .blocked
      return
    }
    saveState = .pending
    let delay = saveDelay
    saveTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      self?.saveNow()
    }
  }

  /// Writes pending edits immediately. The app should call this before quitting.
  public func saveNow() {
    saveTask?.cancel()
    saveTask = nil
    guard loadError == nil else {
      saveState = .blocked
      return
    }
    let output = ConfigValidator.savable(draft, lastSaved: saved, issues: issues)
    if output != saved {
      isSaving = true
      defer { isSaving = false }
      do {
        try services.saveConfiguration(output)
        // Re-read so `saved` matches what the file decodes to (key order, normalized values).
        saved = withUniqueIDs((try? services.loadConfiguration()) ?? output)
      } catch {
        saveState = .failed(Self.describe(error))
        return
      }
    }
    // A brand-new shortcut still waiting for its keys isn't an error worth flagging.
    let waiting = Set(
      draft.bindings.filter { binding in binding.keys.key.isEmpty && !saved.bindings.contains { $0.id == binding.id } }
        .map { ValidationIssue.Target.binding($0.id) })
    let held = Set(issues.filter { $0.severity == .error }.map(\.target)).subtracting(waiting).count
    saveState = held > 0 ? .partiallySaved(count: held) : .saved
    refresh()
  }

  var hasUnsavedChanges: Bool { saveTask != nil }

  // MARK: Refreshing

  /// Re-reads runtime status, the Slate config there is to import, screens, running apps, the
  /// clipboard history and running automations from the app.
  public func refresh() {
    let status = services.runtimeStatus()
    if status != runtimeStatus {
      let granted = status.accessibilityGranted && !runtimeStatus.accessibilityGranted
      runtimeStatus = status
      if granted { accessibilityWasGranted() }
    }
    let slatePath = services.slateConfigPath()
    if slatePath != slateConfigPath { slateConfigPath = slatePath }
    let notice = services.slateImportNotice()
    if notice != slateImportNotice { slateImportNotice = notice }
    let newScreens = services.screens()
    if newScreens != screens { screens = newScreens }
    let apps = services.runningApplications()
    if apps != runningApps { runningApps = apps }
    let clipboard = services.clipboardItems()
    if clipboard != clipboardItems { clipboardItems = clipboard }
    refreshAutomations()
  }

  /// Re-reads only the running automations: cheap enough to poll while they're on screen, so
  /// repetition counts stay current between change notifications.
  public func refreshAutomations() {
    let automations = services.activeAutomations()
    if automations != activeAutomations { activeAutomations = automations }
  }

  private func servicesDidChange() {
    refresh()
    if !isSaving { syncFromDisk() }
  }

  /// Adopts config.json when it changed on disk (hand edits), unless the UI has unsaved edits. A file
  /// that can't be read blocks saving either way.
  private func syncFromDisk() {
    let disk: SlatedConfiguration
    do {
      disk = withUniqueIDs(try services.loadConfiguration())
    } catch {
      // Also with an edit waiting to be saved: it couldn't be, and the banner says why.
      saveTask?.cancel()
      saveTask = nil
      loadError = Self.describe(error)
      saveState = .blocked
      return
    }
    guard saveTask == nil else { return }
    let wasBlocked = loadError != nil
    loadError = nil
    if disk != saved || wasBlocked {
      saved = disk
      draft = disk
      issues = ConfigValidator.validate(disk, knownLayouts: knownLayoutNames)
      saveState = .saved
    }
  }

  /// Shows the configuration as the app just wrote it itself (an import), along with the status. Call
  /// `saveNow()` before such a write: an edit still waiting to be saved keeps Settings on its draft,
  /// and its save would then write over the app's change.
  public func showSavedConfiguration() {
    refresh()
    syncFromDisk()
  }

  /// "Import Slate Config into Slated…" (the menus, Get Started, Settings): adds the Slate config's
  /// shortcuts to Slated's own, keeping what's there. Pending edits are saved first, so the import
  /// builds on them instead of a later save undoing it.
  @discardableResult
  public func importSlateConfig() throws -> SlateImportReport {
    saveNow()
    let report = try services.importSlateConfig()
    showSavedConfiguration()
    return report
  }

  /// Get Started and Settings' Import button: imports, then says what happened in a toast.
  func importSlateConfigFromUI() {
    do {
      let report = try importSlateConfig()
      lastSlateImport = report
      showToast(report.title, symbol: "square.and.arrow.down.fill")
    } catch {
      showToast(error.localizedDescription, symbol: "exclamationmark.triangle", style: .failure)
    }
  }

  func dismissSlateImportNotice() {
    services.dismissSlateImportNotice()
    slateImportNotice = nil
  }

  /// Which file couldn't be read, for messages: "config.json", "settings.json" or "config.json".
  var unreadableFileName: String {
    loadError?.contains(ConfigFile.settings.rawValue) == true ? ConfigFile.settings.rawValue : ConfigFile.config.rawValue
  }

  /// Saves pending edits, then asks the app to reload config.json and settings.json.
  public func reload() {
    if hasUnsavedChanges { saveNow() }
    services.reload()
    refresh()
    syncFromDisk()
    if loadError == nil { showToast("Configuration reloaded", symbol: "arrow.clockwise") }
  }

  // MARK: App actions

  func requestAccessibility() {
    services.requestAccessibilityPermission()
    refresh()
  }

  func openAccessibilitySettings() { services.openAccessibilitySettings() }
  func revealConfigurationFile() { services.revealConfigurationFile() }
  func revealFile(atPath path: String) { services.revealFile(atPath: path) }

  func setPaused(_ paused: Bool) {
    services.setPaused(paused)
    refresh()
  }

  func setHotstringsEnabled(_ enabled: Bool) {
    // The app writes the switch to config.json itself, and may report that before returning. It's our
    // own write, not a hand edit: adopting the file would drop the items held back from saving (a new
    // shortcut still waiting for its keys, a hotstring with no trigger yet). Take only the switch from
    // it, into the saved copy and the draft; without the draft, the save of an edit still waiting for
    // its debounce would write the old value back.
    isSaving = true
    services.setHotstringsEnabled(enabled)
    isSaving = false
    if loadError == nil, let written = try? services.loadConfiguration().general.hotstringsEnabled {
      saved.general.hotstringsEnabled = written
      draft.general.hotstringsEnabled = written
    } else {
      // config.json can't be read, so the app couldn't write the switch either. Show that (it may
      // have just broken), and Settings refuses the change with a toast saying why.
      if loadError == nil { syncFromDisk() }
      configuration.general.hotstringsEnabled = enabled
    }
    refresh()
  }

  var hyperKeyEnabled: Bool {
    get { configuration.keyboard.capsLock == .hyper }
    set { configuration.keyboard.capsLock = newValue ? .hyper : .off }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      try services.setLaunchAtLogin(enabled)
      configuration.general.launchAtLogin = enabled
    } catch {
      showToast(
        "Couldn't change Launch at Login: \(Self.describe(error))", symbol: "exclamationmark.triangle", style: .failure)
    }
  }

  /// Hotkeys, Hyper and hotstrings stay suspended while any recorder or test field needs them to be.
  func beginHotkeySuspension() {
    suspensions += 1
    if suspensions == 1 { services.setHotkeysSuspended(true) }
  }

  func endHotkeySuspension() {
    guard suspensions > 0 else { return }
    suspensions -= 1
    if suspensions == 0 { services.setHotkeysSuspended(false) }
  }

  /// A recorder or the Try It field has the hotkeys, Hyper key and hotstrings suspended right now.
  var isSuspendingHotkeys: Bool { suspensions > 0 }

  func showToast(_ message: String, symbol: String = "checkmark.circle.fill", style: Toast.Style = .success) {
    toast = Toast(message: message, symbol: symbol, style: style)
    toastTask?.cancel()
    toastTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(2.6))
      guard !Task.isCancelled else { return }
      self?.toast = nil
    }
  }

  // MARK: Derived

  /// Layout names from config.json, for validation and the layout picker.
  var knownLayoutNames: Set<String> { Set(draft.layouts.map(\.name)) }

  var mainScreen: ScreenInfo? { screens.first(where: \.isMain) ?? screens.first }

  func issues(for target: ValidationIssue.Target) -> [ValidationIssue] { issues.filter { $0.target == target } }

  /// A user-facing description of an error, with decoding paths spelled out.
  static func describe(_ error: Error) -> String {
    if let decoding = error as? DecodingError {
      func location(_ path: [CodingKey]) -> String {
        let parts = path.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        return parts.isEmpty ? "" : " (at \(parts.drop { $0 == "." }))"
      }
      switch decoding {
      case .dataCorrupted(let context):
        let underlying = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
        return (underlying ?? context.debugDescription) + location(context.codingPath)
      case .keyNotFound(let key, let context):
        return "Missing “\(key.stringValue)”" + location(context.codingPath)
      case .typeMismatch(_, let context), .valueNotFound(_, let context):
        return context.debugDescription + location(context.codingPath)
      @unknown default:
        return String(describing: decoding)
      }
    }
    if let slated = error as? SlatedError { return slated.description }
    return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
  }
}
