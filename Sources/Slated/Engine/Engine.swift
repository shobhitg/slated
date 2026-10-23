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

  private(set) var status = RuntimeStatus()
  /// Other software that fights over the same keys, with advice.
  private(set) var warnings: [String] = []
  private var changeHandlers: [() -> Void] = []
  private var permissionTimer: Timer?
  private var suspended = false
  private var capsLockRemapped = false
  private var observers: [NSObjectProtocol] = []
  /// Last logged keyboard state ("tap on, hyper on …"), so only changes are logged.
  private var loggedKeyboardState = ""
  private var loggedWarnings: [String] = []

  var configuration: SlatedConfiguration { store.configuration }
  /// False in `--smoke` runs: never install the keyboard tap or remap Caps Lock on the real system.
  var allowsKeyboardChanges = true

  func start() {
    Diagnostics.checkPreviousRun()
    var startInfo = Diagnostics.build.merging(Diagnostics.system) { a, _ in a }
    startInfo["accessibility"] = Permissions.isAccessibilityTrusted
    startInfo["mode"] = allowsKeyboardChanges ? "app" : "smoke"
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

    runner.onPerformed = { [weak self] message in
      guard let self else { return }
      status.lastAction = message
      if store.configuration.general.showActionHUD { hud.show(message) }
      notify()
    }
    runner.onError = { [weak self] message in
      self?.status.lastError = message
      self?.notify()
    }
    runner.onRelaunch = { [weak self] in self?.reload() }
    runner.overlays = overlays
    overlays.place = { [weak self] window, frame in self?.runner.place(window, at: frame, label: "Grid") }
    tap.onHotstring = { [weak self] match in self?.expand(match) }
    tap.onHyperHotkey = { [weak self] code, down in
      guard let self, let key = KeyCodes.key(for: code) else { return }
      let combo = KeyCombo(key: key, modifiers: store.configuration.keyboard.hyperModifiers)
      let bound = hotkeys.trigger(combo, phase: down ? .pressed : .released)
      if down { Log.record("hyper.combo", level: bound ? .debug : .notice, ["keys": combo.string, "bound": bound]) }
    }
    tap.onEvent = { event in Log.record("tap.\(event)", level: .notice) }

    observeSystem()
    // A mapping left over from a crash would leave Caps Lock dead; adopt it so `applyKeyboard`
    // removes it when Hyper is off (or keeps it when on).
    capsLockRemapped = allowsKeyboardChanges && HIDRemapper.isCapsLockRemapped
    apply()
    // Permission can be granted or revoked at any time in System Settings; react within a second.
    permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkPermission() }
    }
  }

  /// Puts the keyboard back the way it was. Called on quit.
  func shutdown() {
    Log.record("app.quit", level: .notice, ["capsLockRestored": capsLockRemapped])
    tap.stop()
    if capsLockRemapped { HIDRemapper.setCapsLockRemapped(false) }
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
      Log.error("config.save_failed", error.localizedDescription, ["path": store.fileURL.path])
      throw error
    }
    let changes = ConfigDiff.changes(from: before, to: configuration)
    if !changes.isEmpty { Log.record("config.saved", ["changes": changes]) }
    apply()
  }

  func onChange(_ handler: @escaping () -> Void) { changeHandlers.append(handler) }

  /// Pauses every trigger (used while the UI records a shortcut, and by "Pause Slated").
  func setSuspended(_ value: Bool) {
    guard value != suspended else { return }
    suspended = value
    Log.record("hotkeys.suspended", ["suspended": value])
    apply()
  }

  var isSuspended: Bool { suspended }

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
        return HotkeyManager.Entry(keys: binding.keys, modal: binding.modal, repeats: repeats, source: "Slated") {
          [weak self] in
          self?.runner.run(
            binding.action, label: binding.name, chainKey: binding.id.uuidString,
            trigger: "hotkey \((binding.modal.map { $0.keys.string + " " } ?? "") + binding.keys.string)", source: "Slated")
        }
      }
      entries += sources.entries(settings: settings)
      let disabled = config.bindings.filter { !$0.enabled }.map { binding in
        (binding.modal.map { $0.keys.string + " " } ?? "") + binding.keys.string
      }
      hotkeys.apply(entries, disabled: disabled, settings: settings)
    }
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
    let wantsHotstrings = config.hotstrings.contains(where: \.enabled) && !suspended

    var tapFailed = false
    if trusted && allowsKeyboardChanges && (wantsHyper || wantsHotstrings) {
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
      if HIDRemapper.setCapsLockRemapped(remap) { capsLockRemapped = remap } else { remapFailed = true }
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
    options.hotstringsEnabled = wantsHotstrings
    let hyperCodes = Set(
      hotkeys.boundCombos.filter { $0.modifiers == config.keyboard.hyperModifiers }.compactMap { KeyCodes.code(for: $0.key) })
    tap.update(options: options, hotstrings: config.hotstrings, hyperHotkeys: remap ? hyperCodes : [])
    tap.setFrontmostApp(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

    status.hyperKeyActive = remap
    status.hotstringsActive = wantsHotstrings && tapRunning
  }

  private func checkPermission() {
    let trusted = Permissions.isAccessibilityTrusted
    guard trusted != status.accessibilityGranted else { return }
    Log.record("permission.accessibility", level: .notice, ["granted": trusted])
    applyKeyboard()
    notify()
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
    notify()
  }

  // MARK: System events

  private func observeSystem() {
    let center = NSWorkspace.shared.notificationCenter
    observers.append(
      center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
        [weak self] note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let bundleID = app?.bundleIdentifier
        MainActor.assumeIsolated { self?.tap.setFrontmostApp(bundleID: bundleID) }
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
    var skipped: [String]
  }

  /// Copies the bindings from the Slate config files into Slated's own configuration, so they can be
  /// edited in Settings. When everything converts, Slate files stop loading (they'd only duplicate).
  @discardableResult
  func importSlateConfigs() throws -> ImportSummary {
    var config = store.configuration
    var bound = Set(config.bindings.map { (($0.modal?.keys.string).map { $0 + " " } ?? "") + $0.keys.string })
    var imported = 0
    var skipped: [String] = []
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
        // Settings the script set, without overriding ones already in Slated's config.
        config.settings = sources.javascript.settings.merging(config.settings)
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
    Log.record("slate.imported", ["imported": imported, "skipped": skipped])
    return ImportSummary(imported: imported, skipped: skipped)
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
