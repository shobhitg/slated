import AppKit
import Observation
import SlatedCore
import SlatedSystem
import SlatedUI

/// Slated is a regular app with one main window: Get Started during setup, then Overview and the
/// other panes. Closing the window leaves Slated running in the background; the Dock icon, opening
/// it again from Finder or Spotlight, the menu bar icon and Settings… (⌘,) bring the window back, and
/// ⌘Q quits. Small one-off UI stays separate: alerts, the clipboard switcher and the notch island.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
  let engine = Engine()
  private lazy var services = LiveServices(engine: engine)
  private lazy var model = AppModel(services: services)
  private var statusItem: NSStatusItem?
  private var mainWindow: NSWindow?
  private var signalSources: [DispatchSourceSignal] = []
  private lazy var clipboardPanel = ClipboardPanel(services: LiveServices.forClipboardSwitcher(engine))
  private var modalActive = false
  /// The icon's variant on screen, so it's redrawn only when it changes.
  private var shownGlyph: StatusGlyph?
  private var statusItemObservers: [NSObjectProtocol] = []
  /// Accessibility permission as last reported, to notice the moment it's switched on.
  private var accessibilityGranted = false

  /// Test runs (SLATED_HOME set) never put windows or system dialogs on screen, show no Dock icon, and
  /// never touch the keyboard: no event tap, no Caps Lock mapping.
  private var isTestRun: Bool { ProcessInfo.processInfo.environment["SLATED_HOME"] != nil }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // First, before `engine.start()` remaps Caps Lock: a signal from now on quits through
    // `applicationWillTerminate`, which restores it. Its handler runs on the main queue, so only once
    // launching has finished.
    handleTerminationSignals()
    if isTestRun {
      engine.allowsKeyboardChanges = false
      engine.mode = "test"
      NSApp.setActivationPolicy(.accessory)
    }
    engine.start()
    _ = model  // loads the configuration and subscribes to engine changes
    NSApp.mainMenu = MainMenu.make(for: self)
    setUpStatusItem()
    accessibilityGranted = engine.status.accessibilityGranted
    engine.onChange { [weak self] in
      self?.applyStatusIconVisibility()
      self?.refreshStatusIcon()
      self?.clipboardPanel.refresh()
      self?.noticeAccessibilityGrant()
    }
    engine.clipboard.presentSwitcher = { [weak self] anchor in self?.clipboardPanel.show(at: anchor) }
    clipboardPanel.didClose = { [weak self] intoSlatedWindow in
      self?.engine.clipboard.switcherClosed(intoSlatedWindow: intoSlatedWindow)
    }
    engine.onModalChange = { [weak self] modal in
      self?.modalActive = modal != nil
      self?.refreshStatusIcon()
    }
    observeNavigation()

    guard !isTestRun else { return }
    // At login Slated starts quietly in the background, unless setup isn't finished.
    if model.needsSetup || !Self.launchedAsLoginItem {
      showMainWindow(reason: "launch")
    }
    // Ask right away: macOS shows its own "would like to control this computer" prompt with an Open
    // System Settings button, and Get Started moves on within a second of the switch going on.
    if !Permissions.isAccessibilityTrusted {
      _ = Permissions.requestAccessibility()
      Log.record("permission.prompted")
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    model.saveNow()
    engine.shutdown()
    Diagnostics.markCleanExit()
    Log.flush()
  }

  /// Clicking the Dock icon, or opening Slated again from Finder or Spotlight, shows the main window.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    Log.record("app.reopened")
    showMainWindow(reason: "reopen")
    return false
  }

  /// Closing the window keeps Slated running: its shortcuts work with no window open.
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  /// Launched by macOS at login (General → Launch at Login) rather than opened by the user.
  private static var launchedAsLoginItem: Bool {
    guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
    return event.eventID == AEEventID(kAEOpenApplication)
      && event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        == OSType(keyAELaunchedAsLogInItem)
  }

  /// `install.sh`, `make run` and logout send SIGTERM, and a terminal running Slated sends SIGINT
  /// (Ctrl-C), SIGQUIT (Ctrl-\) or SIGHUP (closed); route them through normal termination so Caps Lock
  /// is restored instead of staying remapped until reboot.
  private func handleTerminationSignals() {
    for (number, name) in [(SIGTERM, "sigterm"), (SIGINT, "sigint"), (SIGQUIT, "sigquit"), (SIGHUP, "sighup")] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler {
        Log.record("app.\(name)")
        NSApp.terminate(nil)
      }
      source.resume()
      signalSources.append(source)
    }
  }

  // MARK: Main window

  /// Brings the main window to the front. Opened from closed it shows Get Started during setup and
  /// Overview otherwise (`AppModel.prepareToShowMainWindow`); `pane` picks one instead.
  func showMainWindow(pane: SettingsPane? = nil, reason: String) {
    let window = mainWindow ?? makeMainWindow()
    let wasOpen = window.isVisible || window.isMiniaturized
    model.prepareToShowMainWindow(wasOpen: wasOpen)
    if let pane { model.selectedPane = pane }
    if window.isMiniaturized { window.deminiaturize(nil) }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    // macOS 14's cooperative activation may keep Slated behind the app in front (the terminal that ran
    // ./install.sh, System Settings after granting access); the window must not hide there.
    window.orderFrontRegardless()
    if !wasOpen {
      Log.record(
        "ui.settings_opened",
        ["pane": model.selectedPane.rawValue, "reason": reason, "accessibility": Permissions.isAccessibilityTrusted])
    }
  }

  private func makeMainWindow() -> NSWindow {
    let window = SlatedUI.makeMainWindow(model: model)
    window.delegate = self
    mainWindow = window
    return window
  }

  func windowWillClose(_ notification: Notification) {
    guard (notification.object as? NSWindow) === mainWindow else { return }
    model.saveNow()
    Log.record("ui.settings_closed", ["pane": model.selectedPane.rawValue])
  }

  /// Accessibility was just switched on (in System Settings, which is in front): bring the main window
  /// back. Get Started has moved past its permission step by now.
  private func noticeAccessibilityGrant() {
    let granted = engine.status.accessibilityGranted
    defer { accessibilityGranted = granted }
    guard granted, !accessibilityGranted, !isTestRun else { return }
    showMainWindow(reason: "accessibility_granted")
  }

  /// Logs pane switches (the window publishes its selection on the model).
  private func observeNavigation() {
    withObservationTracking {
      _ = model.selectedPane
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        if self.mainWindow?.isVisible == true {
          Log.record("ui.pane", ["pane": self.model.selectedPane.rawValue])
        }
        self.observeNavigation()
      }
    }
  }

  // MARK: Status item

  private func setUpStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.target = self
    item.button?.action = #selector(statusItemClicked(_:))
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    item.button?.toolTip = "Slated: click to open, right-click for the menu"
    statusItem = item
    // Where macOS puts the icon changes as other apps add or remove theirs (its window moves), and
    // with the displays.
    let center = NotificationCenter.default
    if let window = item.button?.window {
      for name in [NSWindow.didMoveNotification, NSWindow.didChangeOcclusionStateNotification] {
        statusItemObservers.append(
          center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkMenuBarIcon() }
          })
      }
    }
    statusItemObservers.append(
      center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) {
        [weak self] _ in
        MainActor.assumeIsolated { self?.checkMenuBarIcon() }
      })
    applyStatusIconVisibility()
    refreshStatusIcon()
    // The menu bar lays the icon out after launch; look again once it has.
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.checkMenuBarIcon() }
  }

  /// `general.showStatusIcon`: without the icon, the Dock icon opens Slated.
  private func applyStatusIconVisibility() {
    guard let item = statusItem else { return }
    let show = engine.configuration.general.showStatusIcon
    if item.isVisible != show {
      item.isVisible = show
      Log.record("menubar.icon_visibility", ["shown": show])
    }
    checkMenuBarIcon()
  }

  /// Whether macOS put the icon behind the camera notch (a full menu bar), for the notice in Overview
  /// and General. Public API only: the icon's window frame against the screen's unobscured areas.
  private func checkMenuBarIcon() {
    guard let item = statusItem, item.isVisible else {
      engine.setMenuBarIcon(.off)
      return
    }
    guard let window = item.button?.window else { return }
    let frame = window.frame
    guard let screen = window.screen ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) }) else { return }
    let behind = MenuBarPlacement.isBehindNotch(
      itemFrame: Screens.topLeftRect(fromAppKit: frame), screenFrame: Screens.topLeftRect(fromAppKit: screen.frame),
      topLeftArea: screen.auxiliaryTopLeftArea, topRightArea: screen.auxiliaryTopRightArea)
    var details: [String: Any] = [
      "x": Int(frame.minX - screen.frame.minX), "width": Int(frame.width), "screenWidth": Int(screen.frame.width),
    ]
    if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
      details["notch"] = "\(Int(left.width))-\(Int(screen.frame.width - right.width))"
    }
    engine.setMenuBarIcon(behind ? .behindNotch : .shown, details: details)
  }

  private var statusWarnings: [String] {
    StatusGlyph.warnings(loadError: engine.store.loadError, hotkeys: engine.status.hotkeys, conflicts: engine.warnings)
  }

  private func refreshStatusIcon() {
    let glyph = StatusGlyph.variant(paused: engine.isPaused, modal: modalActive, warnings: statusWarnings)
    guard glyph != shownGlyph else { return }
    shownGlyph = glyph
    statusItem?.button?.image = glyph.image()
  }

  /// Left click: the main window. Right click (or ⌃-click): a small classic menu.
  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      Log.record("menu.opened")
      showStatusMenu()
    } else {
      Log.record("menu.status_item_clicked")
      showMainWindow(reason: "status_item")
    }
  }

  private func showStatusMenu() {
    let status = engine.status
    let menu = NSMenu()
    let title =
      !status.accessibilityGranted
      ? "Slated needs Accessibility access" : status.paused ? "Slated is paused" : "Slated is running"
    let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    for warning in statusWarnings {
      let item = NSMenuItem(title: "⚠︎ \(warning)", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }
    menu.addItem(.separator())
    menu.addItem(withTitle: "Open Slated", action: #selector(openMainWindowFromMenu), keyEquivalent: "").target = self
    if !status.accessibilityGranted {
      menu.addItem(withTitle: "Grant Accessibility Access…", action: #selector(grantAccess), keyEquivalent: "").target =
        self
    }
    menu.addItem(withTitle: "Caps Lock → Hyper Key", action: #selector(toggleHyper), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Pause Slated", action: #selector(togglePause), keyEquivalent: "").target = self
    menu.addItem(.separator())
    if canImportSlate {
      menu.addItem(withTitle: "Import Slate Config into Slated…", action: #selector(importSlate), keyEquivalent: "")
        .target = self
    }
    menu.addItem(withTitle: "Reload Configuration", action: #selector(reload), keyEquivalent: "r").target = self
    menu.addItem(withTitle: "Open Config File", action: #selector(openConfig), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Open Settings File", action: #selector(openSettings), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Show Log", action: #selector(showLog), keyEquivalent: "").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Slated", action: #selector(quitFromMenu), keyEquivalent: "q").target = self
    statusItem?.menu = menu
    statusItem?.button?.performClick(nil)
    statusItem?.menu = nil  // keep left clicks for the main window
  }

  // MARK: Menu commands (the menu bar's menus and the status item's)

  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    switch item.action {
    case #selector(togglePause): item.state = engine.isPaused ? .on : .off
    case #selector(toggleHyper): item.state = engine.configuration.keyboard.capsLock == .hyper ? .on : .off
    case #selector(importSlate): return canImportSlate
    default: break
    }
    return true
  }

  /// There's a ~/.slate.js or ~/.slate to import.
  private var canImportSlate: Bool { engine.slateConfigPath != nil }

  private func quit() {
    Log.record("ui.quit")
    model.saveNow()
    NSApp.terminate(nil)
  }

  @objc func openMainWindowFromMenu() {
    Log.record("menu.settings")
    showMainWindow(reason: "menu")
  }

  @objc func showAbout() {
    Log.record("menu.about")
    showMainWindow(pane: .about, reason: "about")
  }

  @objc func showGetStartedFromMenu() {
    Log.record("menu.get_started")
    showMainWindow(reason: "get_started")
    model.showGetStarted()
  }

  @objc func quitFromMenu() {
    Log.record("menu.quit")
    quit()
  }

  /// Get Started's permission step, and macOS's prompt and System Settings on top of it.
  @objc private func grantAccess() {
    Log.record("menu.grant_access")
    showMainWindow(reason: "grant_access")
    model.showGetStarted()
    Permissions.requestAccessibility()
    Permissions.openAccessibilitySettings()
  }

  @objc private func toggleHyper() {
    Log.record("menu.toggle_hyper", ["enable": engine.configuration.keyboard.capsLock != .hyper])
    var config = engine.configuration
    config.keyboard.capsLock = config.keyboard.capsLock == .hyper ? .off : .hyper
    do {
      try engine.save(config)
    } catch {
      Log.error("config.save_failed", LogPrivacy.message(error.localizedDescription))
    }
  }

  @objc func togglePause() {
    Log.record("menu.toggle_pause", ["pause": !engine.isPaused])
    engine.setPaused(!engine.isPaused)
  }

  @objc func reload() {
    Log.record("menu.reload")
    engine.reload()
  }

  @objc func importSlate() {
    Log.record("menu.import_slate")
    let alert = NSAlert()
    do {
      let summary = try model.importSlateConfig()
      alert.messageText = summary.title
      alert.informativeText = summary.message
    } catch {
      alert.messageText = "Couldn't import your Slate config"
      alert.informativeText = error.localizedDescription
    }
    NSApp.activate()
    alert.runModal()
  }

  @objc func openConfig() {
    Log.record("menu.open_config")
    NSWorkspace.shared.open(engine.store.fileURL)
  }

  /// settings.json; when it isn't there (deleted by hand: every setting at its default), the folder.
  @objc func openSettings() {
    Log.record("menu.open_settings")
    let url = engine.store.settingsURL
    if FileManager.default.fileExists(atPath: url.path) {
      NSWorkspace.shared.open(url)
    } else {
      NSWorkspace.shared.activateFileViewerSelecting([engine.store.fileURL])
    }
  }

  @objc func showLog() {
    Log.record("menu.show_log")
    NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
  }
}
