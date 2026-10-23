import AppKit
import Observation
import SlatedCore
import SlatedSystem
import SlatedUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let engine = Engine()
  private lazy var services = LiveServices(engine: engine)
  private lazy var model = AppModel(services: services)
  private var statusItem: NSStatusItem?
  private let popover = NSPopover()
  private var settingsWindow: NSWindow?
  private var onboardingWindow: NSWindow?
  private var signalSource: DispatchSourceSignal?
  private lazy var clipboardPanel = ClipboardPanel(services: services)
  private var modalActive = false
  private static let onboardingDoneKey = "onboardingCompleted"

  /// Test runs (SLATED_HOME set) never put windows or system dialogs on screen.
  private var isTestRun: Bool { ProcessInfo.processInfo.environment["SLATED_HOME"] != nil }

  func applicationDidFinishLaunching(_ notification: Notification) {
    engine.start()
    _ = model  // loads the configuration and subscribes to engine changes
    setUpStatusItem()
    engine.onChange { [weak self] in
      self?.refreshStatusIcon()
      self?.clipboardPanel.refresh()
    }
    engine.clipboard.presentSwitcher = { [weak self] in self?.clipboardPanel.show() }
    engine.hotkeys.onModalChange = { [weak self] modal in
      self?.modalActive = modal != nil
      self?.refreshStatusIcon()
    }
    handleTerminationSignals()
    observeSettingsNavigation()

    let onboarded = UserDefaults.standard.bool(forKey: Self.onboardingDoneKey)
    if !isTestRun && (!onboarded || !Permissions.isAccessibilityTrusted) {
      showOnboarding()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    model.saveNow()
    engine.shutdown()
    Diagnostics.markCleanExit()
    Log.flush()
  }

  /// Opening Slated again from Finder or Spotlight shows its settings.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    Log.record("app.reopened")
    showSettings()
    return false
  }

  /// `install.sh`, `make run` and logout send SIGTERM; route it through normal termination so Caps
  /// Lock is restored instead of staying remapped until reboot.
  private func handleTerminationSignals() {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler {
      Log.record("app.sigterm")
      NSApp.terminate(nil)
    }
    source.resume()
    signalSource = source
  }

  // MARK: Windows

  func showSettings(pane: SettingsPane? = nil) {
    popover.performClose(nil)
    if let pane { model.selectedPane = pane }
    let window = settingsWindow ?? SlatedUI.makeSettingsWindow(model: model)
    window.delegate = self
    settingsWindow = window
    // A menu-bar-only app can't hold keyboard focus well; act like a regular app while the
    // settings window is open.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    Log.record("ui.settings_opened", ["pane": model.selectedPane.rawValue])
  }

  private func showOnboarding() {
    popover.performClose(nil)
    let window =
      onboardingWindow
      ?? SlatedUI.makeOnboardingWindow(
        model: model,
        openSettings: { [weak self] in self?.showSettings() },
        onFinish: { [weak self] in self?.finishOnboarding() })
    window.delegate = self
    onboardingWindow = window
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    Log.record("ui.onboarding_shown", ["accessibility": Permissions.isAccessibilityTrusted])
  }

  private func finishOnboarding() {
    UserDefaults.standard.set(true, forKey: Self.onboardingDoneKey)
    Log.record("ui.onboarding_finished", ["accessibility": Permissions.isAccessibilityTrusted])
    onboardingWindow?.close()
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    if window === settingsWindow {
      model.saveNow()
      Log.record("ui.settings_closed")
    }
    if window === onboardingWindow && !UserDefaults.standard.bool(forKey: Self.onboardingDoneKey) {
      Log.record("ui.onboarding_dismissed")
    }
    // Back to menu-bar-only once no Slated window is showing.
    DispatchQueue.main.async { [weak self] in
      let visible = [self?.settingsWindow, self?.onboardingWindow].contains { $0?.isVisible == true }
      if !visible { NSApp.setActivationPolicy(.accessory) }
    }
  }

  /// Logs settings-pane switches (the settings UI publishes its selection on the model).
  private func observeSettingsNavigation() {
    withObservationTracking {
      _ = model.selectedPane
    } onChange: { [weak self] in
      DispatchQueue.main.async {
        guard let self else { return }
        if self.settingsWindow?.isVisible == true {
          Log.record("ui.pane", ["pane": self.model.selectedPane.rawValue])
        }
        self.observeSettingsNavigation()
      }
    }
  }

  // MARK: Status item

  private func setUpStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.target = self
    item.button?.action = #selector(statusItemClicked(_:))
    item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    statusItem = item

    popover.behavior = .transient
    popover.animates = true
    popover.contentViewController = SlatedUI.makeMenuBarViewController(
      model: model,
      actions: MenuBarActions(
        openSettings: { [weak self] in self?.showSettings() },
        quit: { [weak self] in self?.quit() },
        showOnboarding: { [weak self] in self?.showOnboarding() }))
    refreshStatusIcon()
  }

  private func refreshStatusIcon() {
    let symbol: String
    if engine.isPaused {
      symbol = "pause.rectangle"
    } else if modalActive {
      symbol = "rectangle.split.2x2.fill"  // Slate showed modal mode in the menu bar; so do we.
    } else {
      symbol = "rectangle.split.2x2"
    }
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Slated")
    image?.isTemplate = true
    statusItem?.button?.image = image
  }

  /// Left click: the popover. Right click (or ⌃-click): a classic menu with power-user actions.
  @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
    let event = NSApp.currentEvent
    if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
      Log.record("menu.opened")
      showClassicMenu()
    } else if popover.isShown {
      popover.performClose(nil)
    } else {
      Log.record("ui.popover_opened")
      popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
      popover.contentViewController?.view.window?.makeKey()
    }
  }

  private func showClassicMenu() {
    let status = engine.status
    let menu = NSMenu()
    let header = NSMenuItem(
      title: status.accessibilityGranted ? "Slated is running" : "Slated needs Accessibility access", action: nil,
      keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    for warning in engine.warnings {
      let item = NSMenuItem(title: "⚠︎ \(warning)", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }
    menu.addItem(.separator())
    menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
    if !status.accessibilityGranted {
      menu.addItem(withTitle: "Grant Accessibility Access…", action: #selector(grantAccess), keyEquivalent: "").target =
        self
    }
    let hyper = menu.addItem(withTitle: "Caps Lock → Hyper Key", action: #selector(toggleHyper), keyEquivalent: "")
    hyper.target = self
    hyper.state = engine.configuration.keyboard.capsLock == .hyper ? .on : .off
    let pause = menu.addItem(withTitle: "Pause Slated", action: #selector(togglePause), keyEquivalent: "")
    pause.target = self
    pause.state = engine.isPaused ? .on : .off
    menu.addItem(.separator())
    if engine.configuration.general.loadSlateConfigs && engine.sources.sources.contains(where: { $0.loaded }) {
      menu.addItem(withTitle: "Import Slate Config into Slated…", action: #selector(importSlate), keyEquivalent: "")
        .target = self
    }
    menu.addItem(withTitle: "Reload Configuration", action: #selector(reload), keyEquivalent: "r").target = self
    menu.addItem(withTitle: "Open Config File", action: #selector(openConfig), keyEquivalent: "").target = self
    menu.addItem(withTitle: "Show Log", action: #selector(showLog), keyEquivalent: "").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Slated", action: #selector(quitFromMenu), keyEquivalent: "q").target = self
    statusItem?.menu = menu
    statusItem?.button?.performClick(nil)
    statusItem?.menu = nil  // keep left clicks for the popover
  }

  private func quit() {
    Log.record("ui.quit")
    model.saveNow()
    NSApp.terminate(nil)
  }

  @objc private func openSettingsFromMenu() {
    Log.record("menu.settings")
    showSettings()
  }

  @objc private func quitFromMenu() {
    Log.record("menu.quit")
    quit()
  }

  @objc private func grantAccess() {
    Log.record("menu.grant_access")
    Permissions.requestAccessibility()
    Permissions.openAccessibilitySettings()
  }

  @objc private func toggleHyper() {
    Log.record("menu.toggle_hyper", ["enable": engine.configuration.keyboard.capsLock != .hyper])
    var config = engine.configuration
    config.keyboard.capsLock = config.keyboard.capsLock == .hyper ? .off : .hyper
    do { try engine.save(config) } catch { Log.error("config.save_failed", error.localizedDescription) }
  }

  @objc private func togglePause() {
    Log.record("menu.toggle_pause", ["pause": !engine.isPaused])
    engine.setPaused(!engine.isPaused)
  }

  @objc private func reload() {
    Log.record("menu.reload")
    engine.reload()
  }

  @objc private func importSlate() {
    Log.record("menu.import_slate")
    let alert = NSAlert()
    do {
      let summary = try engine.importSlateConfigs()
      alert.messageText = "Imported \(summary.imported) bindings"
      alert.informativeText =
        summary.skipped.isEmpty
        ? "Your Slate bindings are now part of Slated's configuration and can be edited in Settings. Your Slate files are left untouched and no longer loaded."
        : "These need JavaScript and still run from your Slate file:\n" + summary.skipped.joined(separator: "\n")
    } catch {
      Log.error("slate.import_failed", error.localizedDescription)
      alert.messageText = "Couldn't import"
      alert.informativeText = error.localizedDescription
    }
    NSApp.activate()
    alert.runModal()
  }

  @objc private func openConfig() {
    Log.record("menu.open_config")
    NSWorkspace.shared.open(engine.store.fileURL)
  }

  @objc private func showLog() {
    Log.record("menu.show_log")
    NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
  }
}
