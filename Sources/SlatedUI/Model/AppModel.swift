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
/// saved version stays on disk) and flagged in the UI. The model refreshes runtime status, Slate
/// sources, screens, apps, the clipboard history and running automations whenever the app reports
/// a change through `AppServices.onChange`, and picks up hand edits to config.json when there are
/// no unsaved edits. Clipboard and automation commands go through `AppServices` too.
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
      // Read-only while config.json can't be read: an edit couldn't be saved, and the fixed file
      // replaces the draft when it loads.
      guard loadError == nil else {
        showToast(
          "Fix config.json first: nothing can be changed here until Slated can read it.",
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
  public private(set) var sources: [SlateSource]
  public private(set) var screens: [ScreenInfo]
  public private(set) var runningApps: [AppInfo]
  /// Clipboard history, newest first (pinned items wherever they fall).
  public private(set) var clipboardItems: [ClipboardItem]
  /// Auto-repeats and held inputs running right now.
  public private(set) var activeAutomations: [ActiveAutomation]

  // MARK: Navigation

  /// The settings pane to show. Set it before showing the window to open a specific pane.
  public var selectedPane: SettingsPane = .overview
  public var selectedBinding: BindingSelection?
  public var selectedHotstringID: UUID?
  public var selectedLayout: LayoutSelection?
  /// A binding whose shortcut recorder should start recording when its editor appears.
  var recordShortcutFor: UUID?
  var toast: Toast?

  /// How long to wait after the last edit before saving.
  @ObservationIgnored public var saveDelay: Duration = .milliseconds(450)
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  @ObservationIgnored private var toastTask: Task<Void, Never>?
  @ObservationIgnored private var suspensions = 0
  /// True while `saveConfiguration` runs. The app may report the change it causes through
  /// `onChange` before the call returns; that's our own write, not a hand edit to adopt.
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
    sources = services.slateSources()
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
    func unique(_ id: UUID, kind: String) -> UUID {
      let occurrence = seen["\(kind)|\(id)", default: 0]
      seen["\(kind)|\(id)"] = occurrence + 1
      guard occurrence > 0 else { return id }
      let key = "\(kind)|\(id)|\(occurrence)"
      if let replacement = replacementIDs[key] { return replacement }
      let replacement = UUID()
      replacementIDs[key] = replacement
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

  /// Re-reads runtime status, Slate sources, screens, running apps, the clipboard history and
  /// running automations from the app.
  public func refresh() {
    let status = services.runtimeStatus()
    if status != runtimeStatus { runtimeStatus = status }
    let newSources = services.slateSources()
    if newSources != sources {
      sources = newSources
      issues = ConfigValidator.validate(draft, knownLayouts: knownLayoutNames)
    }
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

  /// Saves pending edits, then asks the app to reload config.json and the Slate files.
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
    services.setHotstringsEnabled(enabled)
    // The app writes the switch to config.json itself. Keep the draft in step, or the save of an
    // edit still waiting for its debounce would write the old value back.
    configuration.general.hotstringsEnabled = enabled
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

  /// Layout names from config.json and the Slate files, for validation and the layout picker.
  var knownLayoutNames: Set<String> {
    Set(draft.layouts.map(\.name) + sources.flatMap { $0.layouts.map(\.name) })
  }

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
