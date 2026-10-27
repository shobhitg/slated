import AppKit
import ServiceManagement
import SlatedCore
import SlatedScript
import SlatedSystem
import SlatedUI

/// The running app's brain: loads configuration from every source, registers triggers (hotkeys,
/// hotstrings, Hyper key), runs actions, and publishes status for the UI.
final class Engine {
  let store = ConfigStore()
  let runner = ActionRunner()
  let hotkeys = HotkeyManager()
  let tap = KeyboardTap()
  let sources = SlateSourceLoader()
  let overlays = OverlayController()
  let hud = ActionHUD()
  let automation = AutomationEngine()
  let clipboard = ClipboardService()
  let automationIndicator = AutomationIndicator()
  let island = IslandPresenter()
  /// Modal mode started (with its key) or ended (nil); the menu bar icon reflects it.
  var onModalChange: ((KeyCombo?) -> Void)?

  private(set) var status = RuntimeStatus()
  /// Other software that fights over the same keys, with advice.
  private(set) var warnings: [String] = []
  private var changeHandlers: [() -> Void] = []
  private var permissionTimer: Timer?
  /// "Pause Slated" from the menu bar.
  private var pausedByUser = false
  /// While the settings window records a shortcut or the hotstring "try it" field has focus.
  private var suspendedForRecording = false
  private var suspended: Bool { pausedByUser || suspendedForRecording }
  private var capsLockRemapped = false
  private var observers: [NSObjectProtocol] = []
  /// Last logged keyboard state ("tap on, hyper on …"), so only changes are logged.
  private var loggedKeyboardState = ""
  private var loggedWarnings: [String] = []

  var configuration: SlatedConfiguration { store.configuration }
  /// False in `--smoke` runs and test runs of the app (`SLATED_HOME` set): never install the keyboard
  /// tap or remap Caps Lock on the real system.
  var allowsKeyboardChanges = true
  /// What kind of run this is, for the log: "app", "smoke", or "test" (the app with `SLATED_HOME` set).
  var mode = "app"

  func start() {
    Diagnostics.checkPreviousRun()
    var startInfo = Diagnostics.build.merging(Diagnostics.system) { a, _ in a }
    startInfo["accessibility"] = Permissions.isAccessibilityTrusted
    startInfo["mode"] = mode
    startInfo["keyboardChanges"] = allowsKeyboardChanges
    Log.record("app.start", level: .notice, startInfo)
    Accessibility.configure()
    store.load()
    store.onExternalChange = { [weak self] in self?.apply() }
    store.startWatching()
    sources.onChange = { [weak self] in self?.apply() }
    sources.javascript.onDiagnostics = { [weak self] diagnostics in
      self?.status.lastError = diagnostics.map(\.description).joined(separator: "\n")
      self?.notify()
    }

    runner.onPerformed = { [weak self] report in
      guard let self else { return }
      status.lastAction = report.message
      if store.configuration.general.showActionHUD { showFeedback(report) }
      notify()
    }
    runner.onError = { [weak self] message in
      self?.status.lastError = message
      self?.notify()
    }
    runner.onFailed = { [weak self] message in self?.island.flashFailure(message) }
    runner.onRelaunch = { [weak self] in self?.reload() }
    runner.overlays = overlays
    runner.automation = automation
    runner.clipboard = clipboard
    automation.perform = { [weak self] action in self?.runner.perform(action) }
    automation.onChange = { [weak self] in
      self?.refreshAutomationStatus()
      self?.notify()
    }
    island.model.onStop = { [weak self] in
      Log.record("island.stop_clicked", level: .notice)
      self?.automation.stopAll(reason: "stopped from the island")
    }
    island.currentAutomations = { [weak self] in
      guard let self, store.configuration.automation.showIndicator else { return [] }
      return automation.active
    }
    island.hyperSheet = { [weak self] in self?.hyperCheatSheet() }
    hotkeys.onModalChange = { [weak self] modal in
      guard let self else { return }
      island.modalChanged(modal.map { CheatSheet.modal($0, liveShortcuts()) })
      onModalChange?(modal)
    }
    hotkeys.onFire = { [weak self] entry in self?.island.shortcutFired(id: entry.id) }
    tap.onHyperEvent = { [weak self] event in self?.island.hyperEvent(event) }
    clipboard.onChange = { [weak self] in self?.notify() }
    hotkeys.onRelease = { [weak self] entry in self?.automation.released(id: "hotkey \(entry.id)") }
    overlays.place = { [weak self] window, frame in self?.runner.place(window, at: frame, label: "Grid") }
    tap.onHotstring = { [weak self] match in self?.expand(match) }
    tap.onHyperHotkey = { [weak self] code, down in
      guard let self, let key = KeyCodes.key(for: code) else { return }
      let combo = KeyCombo(key: key, modifiers: store.configuration.keyboard.hyperModifiers)
      let bound = hotkeys.trigger(combo, phase: down ? .pressed : .released)
      if down { Log.record("hyper.combo", level: bound ? .debug : .notice, ["keys": combo.string, "bound": bound]) }
    }
    tap.onEvent = { event in Log.record("tap.\(event)", level: .notice) }
    tap.onMouseHotkey = { [weak self] hotkey, down in
      let combo = KeyCombo(key: "mouse\(hotkey.button)", modifiers: hotkey.modifiers)
      self?.hotkeys.trigger(combo, phase: down ? .pressed : .released)
    }
    hotkeys.setFrontmostApp(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

    observeSystem()
    if allowsKeyboardChanges {
      switch HIDRemapper.capsLockOwner(record: SlatedPaths.capsLockRecordURL) {
      case .slated:
        // Left over from a run that didn't quit cleanly: Caps Lock would stay dead. Adopt it, so
        // `applyKeyboard` removes it when Hyper is off (or keeps it when on).
        capsLockRemapped = true
      case .otherTool:
        // Another tool's (a Hammerspoon setup, say): left as it is, or put back after Slated's Hyper.
        Log.record("keyboard.caps_lock_mapped_elsewhere", level: .notice)
      case .nobody:
        break
      }
    }
    apply()
    // Permission can be granted or revoked at any time in System Settings; react within a second.
    permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkPermission() }
    }
  }

  /// Puts the keyboard back the way it was. Called on quit.
  func shutdown() {
    automation.stopAll(reason: "quit")
    clipboard.stop()
    Log.record("app.quit", level: .notice, ["capsLockRestored": capsLockRemapped])
    tap.stop()
    if capsLockRemapped { HIDRemapper.setCapsLockRemapped(false, record: SlatedPaths.capsLockRecordURL) }
    capsLockRemapped = false
    hotkeys.unregisterAll()
  }

  func reload() {
    Log.record("config.reload")
    store.load()
    apply()
  }

  func save(_ configuration: SlatedConfiguration) throws {
    let before = store.configuration
    do {
      try store.save(configuration)
    } catch {
      Log.error("config.save_failed", LogPrivacy.message(error.localizedDescription), ["path": store.fileURL.path])
      if error is ConfigChangedOnDisk {
        // The store loaded a hand edit instead. Settings ignores changes reported while its own save
        // runs, so tell it again once that save has returned: it then shows the edit.
        DispatchQueue.main.async { [weak self] in self?.notify() }
      }
      throw error
    }
    let changes = ConfigDiff.changes(from: before, to: configuration)
    if !changes.isEmpty { Log.record("config.saved", ["changes": changes]) }
    apply()
  }

  func onChange(_ handler: @escaping () -> Void) { changeHandlers.append(handler) }

  /// Pauses every trigger (used while the UI records a shortcut, and by "Pause Slated").
  func setSuspended(_ value: Bool) {
    guard value != suspendedForRecording else { return }
    suspendedForRecording = value
    Log.record("hotkeys.suspended", level: .debug, ["suspended": value, "reason": "recording"])
    apply()
  }

  /// "Pause Slated": no hotkeys, Hyper key or hotstrings until resumed. Not persisted.
  func setPaused(_ value: Bool) {
    guard value != pausedByUser else { return }
    pausedByUser = value
    if value { automation.stopAll(reason: "paused") }
    Log.record(value ? "app.paused" : "app.resumed", level: .notice)
    apply()
  }

  var isSuspended: Bool { suspended }
  var isPaused: Bool { pausedByUser }

  func setHotstringsEnabled(_ enabled: Bool) throws {
    var config = store.configuration
    guard config.general.hotstringsEnabled != enabled else { return }
    config.general.hotstringsEnabled = enabled
    try save(config)
  }

  // MARK: Applying configuration

  /// Re-registers everything from the current configuration and Slate sources.
  func apply() {
    let config = store.configuration
    sources.load(paths: config.general.loadSlateConfigs ? config.general.slateConfigPaths : [], runner: runner)

    let settings = sources.settings.merging(config.settings)
    runner.settings = settings
    var layouts: [String: Layout] = [:]
    for layout in sources.layouts + config.layouts { layouts[layout.name] = layout }
    runner.layouts = layouts

    if suspended {
      hotkeys.unregisterAll()
    } else {
      // Slated's own bindings come first so they win over Slate-file duplicates.
      var entries: [HotkeyManager.Entry] = config.bindings.filter(\.enabled).map { binding in
        let repeats = binding.repeats ?? settings.repeatOnHoldOps.contains(binding.action.name)
        return HotkeyManager.Entry(
          keys: binding.keys, modal: binding.modal, repeats: repeats, source: "Slated", apps: binding.onlyInApps
        ) {
          [weak self] in
          self?.runner.run(
            binding.action, label: binding.name, chainKey: binding.id.uuidString,
            trigger: "hotkey \((binding.modal.map { $0.keys.string + " " } ?? "") + binding.keys.string)", source: "Slated")
        }
      }
      entries += sources.entries(settings: settings)
      entries += builtInEntries(config)
      let disabled = config.bindings.filter { !$0.enabled }.map { binding in
        (binding.modal.map { $0.keys.string + " " } ?? "") + binding.keys.string
      }
      hotkeys.mouseTriggersAvailable = Permissions.isAccessibilityTrusted && allowsKeyboardChanges
      hotkeys.apply(entries, disabled: disabled, settings: settings)
    }
    automation.settings = config.automation
    clipboard.apply(config.clipboard)
    island.apply(config.island)
    refreshAutomationStatus()
    applyKeyboard()
    warnings = Self.detectConflicts(hyperWanted: config.keyboard.capsLock == .hyper)
    if warnings != loggedWarnings {
      loggedWarnings = warnings
      if !warnings.isEmpty { Log.record("conflict.detected", level: .notice, ["warnings": warnings]) }
    }
    status.hotkeys = hotkeys.statuses
    status.lastError = store.loadError
    notify()
  }

  /// Slated's own shortcuts: the clipboard switcher and the automation stop shortcut. They come after
  /// the user's bindings, so a binding on the same keys wins.
  private func builtInEntries(_ config: SlatedConfiguration) -> [HotkeyManager.Entry] {
    var entries: [HotkeyManager.Entry] = []
    if config.clipboard.enabled, let keys = config.clipboard.shortcut {
      entries.append(
        HotkeyManager.Entry(keys: keys, modal: nil, repeats: false, source: "Slated clipboard") { [weak self] in
          self?.runner.run(.clipboardHistory, trigger: "hotkey \(keys.string)", source: "Slated clipboard")
        })
    }
    if let keys = config.automation.stopShortcut {
      entries.append(
        HotkeyManager.Entry(keys: keys, modal: nil, repeats: false, source: "Slated automation") { [weak self] in
          self?.runner.run(.stopAutomations, trigger: "hotkey \(keys.string)", source: "Slated automation")
        })
    }
    return entries
  }

  /// The original Slate registers the same hotkeys (whoever starts first wins), and Karabiner-Elements
  /// may already be turning Caps Lock into Hyper.
  static func detectConflicts(hyperWanted: Bool) -> [String] {
    var result: [String] = []
    if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.slate.Slate" }) {
      result.append("Slate is running and owns the same shortcuts. Quit Slate so Slated can take over.")
    }
    if hyperWanted && isProcessRunning("karabiner_grabber") {
      result.append("Karabiner-Elements is running. If it also remaps Caps Lock, turn that rule off or quit it.")
    }
    return result
  }

  private static func isProcessRunning(_ name: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-x", name]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return false }
    process.waitUntilExit()
    return process.terminationStatus == 0
  }

  /// Hyper key and hotstrings both need the event tap, which needs Accessibility permission.
  private func applyKeyboard() {
    let config = store.configuration
    let trusted = Permissions.isAccessibilityTrusted
    status.accessibilityGranted = trusted
    let wantsHyper = config.keyboard.capsLock == .hyper && !suspended
    let wantsHotstrings = config.general.hotstringsEnabled && config.hotstrings.contains(where: \.enabled) && !suspended
    let mouseCombos = suspended ? [] : hotkeys.boundMouseCombos

    var tapFailed = false
    if trusted && allowsKeyboardChanges && (wantsHyper || wantsHotstrings || !mouseCombos.isEmpty) {
      if !tap.isRunning && !tap.start() { tapFailed = true }
    } else if tap.isRunning {
      tap.stop()
    }
    let tapRunning = tap.isRunning

    // Only remap Caps Lock while the tap is there to turn F18 into Hyper; otherwise the key
    // would go dead.
    let remap = wantsHyper && tapRunning
    var remapFailed = false
    if remap != capsLockRemapped {
      if HIDRemapper.setCapsLockRemapped(remap, record: SlatedPaths.capsLockRecordURL) {
        capsLockRemapped = remap
      } else {
        remapFailed = true
      }
    }
    let state =
      "tap \(tapRunning ? "on" : "off"), hyper \(remap ? "on" : "off"), hotstrings \(wantsHotstrings && tapRunning ? "on" : "off")"
    if state != loggedKeyboardState || tapFailed || remapFailed {
      loggedKeyboardState = state
      var data: [String: Any] = [
        "tap": tapRunning, "hyper": remap, "hotstrings": wantsHotstrings && tapRunning, "wantsHyper": wantsHyper,
        "wantsHotstrings": wantsHotstrings, "accessibility": trusted,
      ]
      if tapFailed { data["error"] = "Couldn't create the keyboard event tap" }
      if remapFailed { data["error"] = "hidutil couldn't change the Caps Lock mapping" }
      Log.record("keyboard.state", level: tapFailed || remapFailed ? .error : .info, data)
    }

    var options = KeyboardTap.Options()
    options.hyperEnabled = remap
    options.hyperModifiers = config.keyboard.hyperModifiers
    options.capsLockAloneSendsEscape = config.keyboard.capsLockAlone == .escape
    // Holding Caps Lock long enough to see the cheat sheet isn't a tap.
    if config.island.enabled && config.island.cheatSheet { options.aloneTimeout = min(1, island.cheatSheetDelay) }
    options.hotstringsEnabled = wantsHotstrings
    let hyperCodes = Set(
      hotkeys.boundCombos.filter { $0.modifiers == config.keyboard.hyperModifiers }.compactMap { KeyCodes.code(for: $0.key) })
    let mouseHotkeys = Set(
      mouseCombos.compactMap { combo -> KeyboardTap.MouseHotkey? in
        guard let n = Int(combo.key.dropFirst("mouse".count)) else { return nil }
        return KeyboardTap.MouseHotkey(button: n, modifiers: combo.modifiers.subtracting(.function))
      })
    tap.update(
      options: options, hotstrings: config.hotstrings, hyperHotkeys: remap ? hyperCodes : [], mouseHotkeys: mouseHotkeys)
    tap.setFrontmostApp(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

    if !remap { island.hyperUnavailable() }
    status.hyperKeyActive = remap
    status.hotstringsActive = wantsHotstrings && tapRunning
    status.hotstringsEnabled = config.general.hotstringsEnabled
    status.paused = pausedByUser
  }

  private func checkPermission() {
    let trusted = Permissions.isAccessibilityTrusted
    guard trusted != status.accessibilityGranted else { return }
    Log.record("permission.accessibility", level: .notice, ["granted": trusted])
    // Everything, not just the keyboard: mouse button shortcuts' statuses depend on the permission.
    apply()
  }

  // MARK: Hotstrings

  private func expand(_ match: HotstringMatch) {
    let hotstring = match.hotstring
    let text = HotstringTemplate.expand(hotstring.replacement, clipboard: NSPasteboard.general.string(forType: .string))
    TextInjector.shared.replace(deleting: match.deleteCount, with: text, method: hotstring.method, suffix: match.delimiter)
    Log.record(
      "hotstring.expanded",
      [
        "trigger": hotstring.trigger, "app": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
        "method": hotstring.method.rawValue, "fire": hotstring.fire.rawValue, "chars": text.count,
        "deleted": match.deleteCount,
      ])
    if let action = hotstring.action {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.runner.run(action, trigger: "hotstring \(hotstring.trigger)", source: "Slated")
      }
    }
    status.lastAction = "Expanded \(hotstring.trigger)"
    if store.configuration.general.showActionHUD {
      if store.configuration.island.enabled {
        island.flash(IslandFeedback(title: "Expanded \(hotstring.trigger)", symbol: "text.insert"), near: nil)
      } else {
        hud.show(status.lastAction ?? "")
      }
    }
    notify()
  }

  // MARK: Feedback

  /// What a shortcut did: in the island, or the classic pill when the island is off.
  private func showFeedback(_ report: ActionReport) {
    guard store.configuration.island.enabled else {
      hud.show(report.message)
      return
    }
    let frame = report.window?.frame
    var region: CGRect?
    if let frame, Self.showsRegion(report.action), let screen = Screens.current().screen(containing: frame) {
      let v = screen.visibleFrame
      let fraction = CGRect(
        x: (frame.minX - v.minX) / v.width, y: (frame.minY - v.minY) / v.height, width: frame.width / v.width,
        height: frame.height / v.height
      ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
      if !fraction.isNull && !fraction.isEmpty { region = fraction }
    }
    let feedback = IslandFeedback(
      title: report.title, app: report.app, region: region,
      symbol: report.action.map(IslandFeedback.symbol(for:)) ?? "square.grid.3x3")
    island.flash(feedback, near: frame)
  }

  /// Window placements show where the window went; focusing and app actions show their symbol.
  private static func showsRegion(_ action: Action?) -> Bool {
    switch action {
    case .focus, .focusApp, .switchApp, .hint, .show, .hide, .toggle: return false
    default: return true  // nil: a grid placement
    }
  }

  /// Running automations: in the island, or the classic pill when the island is off.
  private func refreshAutomationStatus() {
    let config = store.configuration
    let active = config.automation.showIndicator ? automation.active : []
    if config.island.enabled {
      automationIndicator.update(active: [], stopShortcut: nil, visible: false)
      island.automationsChanged(active, stopShortcut: config.automation.stopShortcut)
    } else {
      island.automationsChanged([], stopShortcut: nil)
      automationIndicator.update(active: active, stopShortcut: config.automation.stopShortcut, visible: !active.isEmpty)
    }
  }

  /// What the island lists while the Hyper key is held.
  func hyperCheatSheet() -> CheatSheet {
    CheatSheet.hyper(liveShortcuts(), hyperModifiers: store.configuration.keyboard.hyperModifiers)
  }

  /// Every shortcut that works right now, from every source, in the order they're registered (the
  /// first for a key wins), for the cheat sheet.
  private func liveShortcuts() -> [CheatSheet.Shortcut] {
    let config = store.configuration
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    var result = config.bindings.filter { $0.enabled && $0.isActive(inApp: front) }.map {
      CheatSheet.Shortcut(keys: $0.keys, modal: $0.modal?.keys, name: $0.name, action: $0.action)
    }
    if config.general.loadSlateConfigs {
      for source in sources.sources where source.loaded {
        result += source.bindings.map {
          CheatSheet.Shortcut(keys: $0.keys, modal: $0.modal?.keys, action: $0.action, summary: $0.summary)
        }
      }
    }
    if config.clipboard.enabled, let keys = config.clipboard.shortcut {
      result.append(CheatSheet.Shortcut(keys: keys, name: "Clipboard history", action: .clipboardHistory))
    }
    if let keys = config.automation.stopShortcut {
      result.append(CheatSheet.Shortcut(keys: keys, name: "Stop automations", action: .stopAutomations))
    }
    // Skip what failed to register (taken by another app, say); app-specific ones count as live.
    return result.filter { shortcut in
      let id = (shortcut.modal.map { $0.string + " " } ?? "") + shortcut.keys.string
      switch hotkeys.statuses[id] {
      case .failed, .disabled: return false
      default: return true
      }
    }
  }

  // MARK: System events

  private func observeSystem() {
    let center = NSWorkspace.shared.notificationCenter
    observers.append(
      center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
        [weak self] note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let bundleID = app?.bundleIdentifier
        MainActor.assumeIsolated {
          guard let self else { return }
          self.tap.setFrontmostApp(bundleID: bundleID)
          self.automation.frontmostAppChanged(to: bundleID)
          // Per-app bindings follow the frontmost app; refresh what the tap catches too.
          if self.hotkeys.setFrontmostApp(bundleID) {
            self.applyKeyboard()
            self.status.hotkeys = self.hotkeys.statuses
          }
        }
      })
    observers.append(
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.automation.stopAll(reason: "sleep") }
      })
    observers.append(
      DistributedNotificationCenter.default().addObserver(
        forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.automation.stopAll(reason: "screen locked") }
      })
    observers.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
        // hidutil mappings and event taps can be reset across sleep; re-assert both.
        MainActor.assumeIsolated {
          Log.record("system.wake")
          self?.capsLockRemapped = false
          self?.applyKeyboard()
        }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.screensChanged() }
      })
    observers.append(
      DistributedNotificationCenter.default().addObserver(
        forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"), object: nil,
        queue: .main
      ) { [weak self] _ in
        // Letter keys may now be on different physical keys; re-register hotkeys.
        MainActor.assumeIsolated {
          Log.record("input_source.changed")
          KeyCodes.invalidateLayout()
          self?.apply()
        }
      })
  }

  /// Slate's `default` directive: apply a layout or snapshot when the display setup matches.
  private func screensChanged() {
    let screens = Screens.current()
    let resolutions = screens.map(\.resolution).sorted()
    Log.record("display.changed", ["screens": screens.count, "resolutions": resolutions])
    for entry in sources.defaults + store.configuration.defaults {
      let matches: Bool
      switch entry.condition {
      case .count(let n): matches = screens.count == n
      case .resolutions(let list): matches = list.sorted() == resolutions
      }
      guard matches else { continue }
      let trigger = "display change (\(screens.count) screens)"
      if runner.layouts[entry.target] != nil {
        runner.run(.layout(name: entry.target), trigger: trigger)
      } else if runner.externalLayout?(entry.target) == true {
        Log.record("action.done", ["trigger": trigger, "action": "layout \(entry.target)", "source": "JavaScript"])
      } else {
        runner.run(.activateSnapshot(name: entry.target, delete: false), trigger: trigger)
      }
      break
    }
    sources.javascript.runCallbackDefaults(screens: screens)
    notify()
  }

  private func notify() {
    status.hotkeys = hotkeys.statuses
    for handler in changeHandlers { handler() }
  }

  // MARK: Importing Slate configs

  struct ImportSummary {
    var imported: Int
    /// What stays in the Slate files, which keep loading for it ("what: why").
    var skipped: [String]
    /// What isn't imported because it never runs in Slated ("what: why").
    var neverRun: [String] = []

    /// The import alert's title and text.
    var title: String { "Imported \(imported) bindings" }
    var message: String {
      var parts = [
        skipped.isEmpty
          ? "Your Slate bindings are now part of Slated's configuration and can be edited in Settings. Your Slate files are left untouched and no longer loaded."
          : "These need JavaScript and still run from your Slate file:\n" + skipped.joined(separator: "\n")
      ]
      if !neverRun.isEmpty { parts.append("Not imported:\n" + neverRun.joined(separator: "\n")) }
      return parts.joined(separator: "\n\n")
    }
  }

  /// Copies the bindings from the Slate config files into Slated's own configuration, so they can be
  /// edited in Settings. When everything converts, Slate files stop loading (they'd only duplicate).
  @discardableResult
  func importSlateConfigs() throws -> ImportSummary {
    var config = store.configuration
    var bound = Set(config.bindings.map { (($0.modal?.keys.string).map { $0 + " " } ?? "") + $0.keys.string })
    var imported = 0
    var skipped: [String] = []
    var neverRun: [String] = []
    func add(_ binding: HotkeyBinding) {
      let id = ((binding.modal?.keys.string).map { $0 + " " } ?? "") + binding.keys.string
      guard bound.insert(id).inserted else { return }
      config.bindings.append(binding)
      imported += 1
    }
    for raw in config.general.slateConfigPaths {
      let path = SlatedPaths.expand(raw)
      guard FileManager.default.fileExists(atPath: path) else { continue }
      if path.hasSuffix(".js") {
        let result = SlateImporter.importJavaScript(path: path)
        result.bindings.forEach(add)
        skipped += result.skipped.map { "\($0.keystroke): \($0.reason)" }
        neverRun += result.neverRun.map { "\($0.keystroke): \($0.reason)" }
        // Settings the script set, without overriding ones already in Slated's config. Those a
        // function computes keep coming from the script (see SlateImporter.Result.functionSettings).
        var settings = sources.javascript.settings
        for name in result.functionSettings { settings[name] = nil }
        config.settings = settings.merging(config.settings)
        config.layouts += sources.javascript.layouts.filter { layout in !config.layouts.contains { $0.name == layout.name } }
      } else if let text = try? String(contentsOfFile: path, encoding: .utf8) {
        let file = SlateConfigParser.parse(text, path: path)
        file.bindings.forEach(add)
        config.settings = file.settings.merging(config.settings)
        config.layouts += file.layouts.filter { layout in !config.layouts.contains { $0.name == layout.name } }
        config.defaults += file.defaults
      }
    }
    if skipped.isEmpty { config.general.loadSlateConfigs = false }
    try save(config)
    Log.record("slate.imported", ["imported": imported, "skipped": skipped, "neverRun": neverRun])
    return ImportSummary(imported: imported, skipped: skipped, neverRun: neverRun)
  }

  // MARK: Launch at login

  func setLaunchAtLogin(_ enabled: Bool) throws {
    do {
      if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      Log.record("settings.launch_at_login", ["enabled": enabled])
    } catch {
      Log.error("settings.launch_at_login_failed", error.localizedDescription, ["enabled": enabled])
      throw error
    }
  }
}
