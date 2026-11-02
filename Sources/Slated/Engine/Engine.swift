import AppKit
import ServiceManagement
import SlatedCore
import SlatedScript
import SlatedSystem
import SlatedUI

/// The running app's brain: loads Slated's configuration, registers triggers (hotkeys, hotstrings,
/// Hyper key), runs actions, and publishes status for the UI.
final class Engine {
  let store = ConfigStore()
  let runner = ActionRunner()
  let hotkeys = HotkeyManager()
  let tap = KeyboardTap()
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
  /// "Pause Slated" from the menus.
  private var pausedByUser = false
  /// While the settings window records a shortcut or the hotstring "try it" field has focus.
  private var suspendedForRecording = false
  private var suspended: Bool { pausedByUser || suspendedForRecording }
  /// What runs right now: recording keeps the Hyper key but no shortcut or hotstring fires; pausing
  /// turns everything off.
  var liveTriggers: LiveTriggers {
    LiveTriggers(store.configuration, paused: pausedByUser, recording: suspendedForRecording)
  }
  private var capsLockRemapped = false
  /// The Caps Lock lock was checked since the Hyper key came on (it's turned off then: see
  /// `CapsLockLock`).
  private var capsLockCheckedForHyper = false
  /// The real lock; a stand-in never touches the keyboard.
  var capsLock = CapsLockLock.system
  private var flagsMonitors: [Any] = []
  /// Turning the lock off failed and was logged; not again until it works (every modifier key would).
  private var capsLockClearFailed = false
  /// The Mac's key repeat (`keyboard.keyRepeat`).
  let keyRepeat = MacKeyRepeat()
  /// The setting last applied, so only changes are applied; nil while Slated leaves it alone.
  private var appliedKeyRepeat: KeyRepeat?
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
    status.menuBarNoticeDismissed = UserDefaults.standard.bool(forKey: Self.menuBarNoticeDismissedKey)
    Diagnostics.checkPreviousRun()
    var startInfo = Diagnostics.build.merging(Diagnostics.system) { a, _ in a }
    startInfo["accessibility"] = Permissions.isAccessibilityTrusted
    startInfo["mode"] = mode
    startInfo["keyboardChanges"] = allowsKeyboardChanges
    Log.record("app.start", level: .notice, startInfo)
    Accessibility.configure()
    // A first run or the migration of a version 1 config.json imported the Slate config: say so once,
    // in Overview and Get Started.
    store.onSlateImported = { [weak self] report in
      SlateImportNotice.save(report)
      self?.slateImportNotice = report
    }
    slateImportNotice = SlateImportNotice.load()
    store.load()
    store.onExternalChange = { [weak self] in self?.apply() }
    store.startWatching()

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
    captureKeyRepeat()
    watchCapsLock()
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

  /// While the UI records a shortcut (or the hotstring Try It field has focus): no shortcut or hotstring
  /// fires, so the keys reach the field. The Hyper key keeps working, so Caps Lock + a key records as
  /// ✦ + that key; only "Pause Slated" gives Caps Lock back.
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

  /// Re-registers everything from the current configuration.
  func apply() {
    let config = store.configuration
    let settings = config.windows
    runner.settings = settings
    var layouts: [String: Layout] = [:]
    for layout in config.layouts { layouts[layout.name] = layout }
    runner.layouts = layouts

    if !liveTriggers.shortcuts {
      hotkeys.unregisterAll()
    } else {
      var entries: [HotkeyManager.Entry] = config.bindings.filter(\.enabled).map { binding in
        let repeats = binding.repeats ?? settings.repeatOnHoldOps.contains(binding.action.name)
        return HotkeyManager.Entry(
          keys: binding.keys, modal: binding.modal, repeats: repeats, source: "Slated", apps: binding.onlyInApps,
          action: binding.action
        ) {
          [weak self] in
          self?.runner.run(
            binding.action, label: binding.name, chainKey: binding.id.uuidString,
            trigger: "hotkey \((binding.modal.map { $0.keys.string + " " } ?? "") + binding.keys.string)",
            source: "Slated")
        }
      }
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
    applyKeyRepeat()
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
        HotkeyManager.Entry(
          keys: keys, modal: nil, repeats: false, source: "Slated clipboard", action: .clipboardHistory, builtIn: true
        ) { [weak self] in
          self?.runner.run(.clipboardHistory, trigger: "hotkey \(keys.string)", source: "Slated clipboard")
        })
    }
    if let keys = config.automation.stopShortcut {
      entries.append(
        HotkeyManager.Entry(
          keys: keys, modal: nil, repeats: false, source: "Slated automation", action: .stopAutomations, builtIn: true
        ) { [weak self] in
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
    // While a shortcut is recorded the Hyper key stays (Caps Lock must reach the recorder as ✦), but
    // the tap catches no shortcut and expands no hotstring.
    let live = liveTriggers
    let wantsHyper = live.hyperKey
    let wantsHotstrings = live.hotstrings
    let mouseCombos = live.shortcuts ? hotkeys.boundMouseCombos : []

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
    // A Caps Lock lock that's on would stay on once the key is F18: turn it off first.
    if remap && !capsLockCheckedForHyper {
      capsLockCheckedForHyper = true
      clearCapsLock(reason: capsLockRemapped ? "hyper already on" : "hyper turned on")
    } else if !remap {
      capsLockCheckedForHyper = false
    }
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
      hotkeys.boundCombos.filter { $0.modifiers == config.keyboard.hyperModifiers }.compactMap {
        KeyCodes.code(for: $0.key)
      })
    let mouseHotkeys = Set(
      mouseCombos.compactMap { combo -> KeyboardTap.MouseHotkey? in
        guard let n = Int(combo.key.dropFirst("mouse".count)) else { return nil }
        return KeyboardTap.MouseHotkey(button: n, modifiers: combo.modifiers.subtracting(.function))
      })
    tap.update(
      options: options, hotstrings: config.hotstrings, hyperHotkeys: remap && live.shortcuts ? hyperCodes : [],
      mouseHotkeys: mouseHotkeys)
    tap.setFrontmostApp(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

    if !remap { island.hyperUnavailable() }
    status.hyperKeyActive = remap
    status.hotstringsActive = wantsHotstrings && tapRunning
    status.hotstringsEnabled = config.general.hotstringsEnabled
    status.paused = pausedByUser
  }

  // MARK: Caps Lock under the Hyper key

  /// Turns the Caps Lock lock off if it's on (see `CapsLockLock`).
  private func clearCapsLock(reason: String) {
    guard allowsKeyboardChanges else { return }
    let outcome = capsLock.clearIfOn()
    defer { capsLockClearFailed = outcome == .failed }
    switch outcome {
    case .wasOff: break
    case .cleared: Log.record("hyper.caps_lock_cleared", level: .notice, ["reason": reason])
    case .failed:
      guard !capsLockClearFailed else { return }
      Log.error(
        "hyper.caps_lock_clear_failed", "Couldn't turn Caps Lock off",
        ["reason": reason, "advice": "Turn the Hyper key off, press Caps Lock, then turn it on again"])
    }
  }

  /// The lock coming on while the Hyper key is active: nothing physical can do that then (an app
  /// might, or a keyboard reconnecting), and no key could turn it off again.
  private func watchCapsLock() {
    guard allowsKeyboardChanges, flagsMonitors.isEmpty else { return }
    let handle: (NSEvent) -> Void = { [weak self] event in
      guard event.modifierFlags.contains(.capsLock) else { return }
      MainActor.assumeIsolated {
        guard let self, self.capsLockRemapped else { return }
        self.clearCapsLock(reason: "caps lock turned on")
      }
    }
    if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: handle) {
      flagsMonitors.append(global)
    }
    if let local = NSEvent.addLocalMonitorForEvents(
      matching: .flagsChanged,
      handler: { event in
        handle(event)
        return event
      })
    {
      flagsMonitors.append(local)
    }
  }

  // MARK: Key repeat

  /// Under Slated's own defaults: the Mac's key repeat was copied into config.json once.
  static let keyRepeatCapturedKey = "keyRepeatCaptured"

  /// The first launch of this version on this Mac: copies the Mac's key repeat into config.json when
  /// it has none, so the setting travels with the file. Once per Mac, whether or not config.json had
  /// one (copied from another computer), so turning the setting off later sticks. Never while
  /// config.json can't be read: that would write over the user's file.
  private func captureKeyRepeat() {
    let defaults = UserDefaults.standard
    guard allowsKeyboardChanges, store.loadError == nil, !defaults.bool(forKey: Self.keyRepeatCapturedKey) else {
      return
    }
    var config = store.configuration
    guard KeyRepeat.shouldCapture(configured: config.keyboard.keyRepeat, capturedBefore: false) else {
      defaults.set(true, forKey: Self.keyRepeatCapturedKey)
      return
    }
    guard let current = keyRepeat.current() else {
      Log.record("keyboard.key_repeat_not_captured", level: .notice, ["reason": "couldn't read this Mac's setting"])
      return
    }
    config.keyboard.keyRepeat = current
    do {
      try save(config)
    } catch {
      return  // logged by save; tried again next launch
    }
    defaults.set(true, forKey: Self.keyRepeatCapturedKey)
    Log.record("keyboard.key_repeat_captured", level: .notice, ["delay": current.delay, "interval": current.interval])
  }

  /// Sets `keyboard.keyRepeat` on the Mac when it changed (`recheck`: also when it didn't, after
  /// waking up). Absent, the Mac's setting is left alone, and nothing is undone.
  private func applyKeyRepeat(recheck: Bool = false) {
    guard allowsKeyboardChanges else { return }
    guard let wanted = store.configuration.keyboard.keyRepeat else {
      appliedKeyRepeat = nil
      status.keyRepeat = nil
      return
    }
    guard recheck || wanted != appliedKeyRepeat else { return }
    let before = (appliedKeyRepeat, status.keyRepeat)
    let result = keyRepeat.apply(wanted)
    appliedKeyRepeat = wanted
    status.keyRepeat = result.state
    guard before.0 != wanted || before.1 != result.state else { return }
    let data: [String: Any] = [
      "delay": wanted.delay, "interval": wanted.interval, "live": result.state == .applied,
      "changed": result.wroteDefaults || result.wroteLive,
    ]
    if case .failed(let message) = result.state {
      Log.error("keyboard.key_repeat_failed", message, data)
    } else {
      Log.record("keyboard.key_repeat_applied", level: .notice, data)
    }
  }

  /// This Mac's key repeat now (Settings' "Use this Mac's current setting").
  func currentKeyRepeat() -> KeyRepeat? { keyRepeat.current() }

  // MARK: Menu bar icon

  static let menuBarNoticeDismissedKey = "menuBarNoticeDismissed"

  /// Where the menu bar icon is (AppDelegate works it out). Logged once per change.
  func setMenuBarIcon(_ state: MenuBarIconState, details: [String: Any] = [:]) {
    guard state != status.menuBarIcon else { return }
    let before = status.menuBarIcon
    status.menuBarIcon = state
    switch state {
    case .behindNotch:
      Log.record("menubar.icon_hidden", level: .notice, details)
    case .shown:
      if before == .behindNotch { Log.record("menubar.icon_visible", details) }
      // Shown again: a later move behind the notch says so again.
      UserDefaults.standard.removeObject(forKey: Self.menuBarNoticeDismissedKey)
    case .off:
      break
    }
    status.menuBarNoticeDismissed = UserDefaults.standard.bool(forKey: Self.menuBarNoticeDismissedKey)
    notify()
  }

  func dismissMenuBarNotice() {
    UserDefaults.standard.set(true, forKey: Self.menuBarNoticeDismissedKey)
    status.menuBarNoticeDismissed = true
    notify()
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
    TextInjector.shared.replace(
      deleting: match.deleteCount, with: text, method: hotstring.method, suffix: match.delimiter)
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

  /// Every shortcut that works right now, in the order they're registered (the first for a key wins),
  /// for the cheat sheet.
  private func liveShortcuts() -> [CheatSheet.Shortcut] {
    let config = store.configuration
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    var result = config.bindings.filter { $0.enabled && $0.isActive(inApp: front) }.map {
      CheatSheet.Shortcut(keys: $0.keys, modal: $0.modal?.keys, name: $0.name, action: $0.action)
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
          self?.capsLockCheckedForHyper = false
          self?.applyKeyboard()
          self?.applyKeyRepeat(recheck: true)
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
    for entry in store.configuration.defaults {
      let matches: Bool
      switch entry.condition {
      case .count(let n): matches = screens.count == n
      case .resolutions(let list): matches = list.sorted() == resolutions
      }
      guard matches else { continue }
      let trigger = "display change (\(screens.count) screens)"
      if runner.layouts[entry.target] != nil {
        runner.run(.layout(name: entry.target), trigger: trigger)
      } else {
        runner.run(.activateSnapshot(name: entry.target, delete: false), trigger: trigger)
      }
      break
    }
    notify()
  }

  private func notify() {
    status.hotkeys = hotkeys.statuses
    status.screenshots = clipboard.screenshotStatus
    for handler in changeHandlers { handler() }
  }

  // MARK: Importing Slate configs

  /// The user's Slate config (`~/.slate.js`, else `~/.slate`) as written there; nil when there's none.
  var slateConfigPath: String? { SlateImport.find(home: SlatedPaths.home) }

  /// What a first run or the migration imported, until dismissed in Overview (`SlateImportNotice`
  /// keeps it across launches; this keeps it from being read on every refresh).
  private(set) var slateImportNotice: SlateImportReport?

  func dismissSlateImportNotice() {
    SlateImportNotice.dismiss()
    slateImportNotice = nil
  }

  /// Copies the user's Slate config into Slated's own configuration: its shortcuts, layouts, display
  /// defaults and settings, leaving out what Slated already has (`SlatedConfiguration.merge`), so it
  /// can be run again any time. Slated doesn't read Slate files otherwise.
  @discardableResult
  func importSlateConfigs() throws -> SlateImportReport {
    guard let path = slateConfigPath else {
      Log.record("slate.import_nothing_found")
      throw SlateConfigNotFound()
    }
    var config = store.configuration
    let report = config.merge(SlateConfigImport.importFiles([path], home: SlatedPaths.home))
    try save(config)
    // Counts only: never the shortcuts' keys or what they run.
    Log.record("slate.imported", ConfigStore.counts(report))
    return report
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
