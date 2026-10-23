import AppKit
import SlatedCore
import SlatedSystem
import SlatedUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  let engine = Engine()
  private lazy var services = LiveServices(engine: engine)
  private var statusItem: NSStatusItem?
  private var signalSource: DispatchSourceSignal?

  func applicationDidFinishLaunching(_ notification: Notification) {
    engine.start()
    setUpStatusItem()
    engine.onChange { [weak self] in self?.refreshStatusItem() }
    engine.hotkeys.onModalChange = { [weak self] modal in
      // Slate showed modal mode in the menu bar; so do we.
      let symbol = modal == nil ? "rectangle.split.2x2" : "rectangle.split.2x2.fill"
      self?.statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Slated")
      self?.statusItem?.button?.image?.isTemplate = true
    }
    handleTerminationSignals()
    // First run (or permission revoked): ask. Not in test runs (SLATED_HOME set), which mustn't put
    // system dialogs on screen.
    if !Permissions.isAccessibilityTrusted && ProcessInfo.processInfo.environment["SLATED_HOME"] == nil {
      Log.record("permission.prompt_shown")
      Permissions.requestAccessibility()
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    engine.shutdown()
    Diagnostics.markCleanExit()
    Log.flush()
  }

  /// `make run` and logout send SIGTERM; route it through normal termination so Caps Lock is
  /// restored instead of staying remapped until reboot.
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

  // MARK: Status item

  private func setUpStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: "Slated")
    item.button?.image?.isTemplate = true
    statusItem = item
    refreshStatusItem()
  }

  private func refreshStatusItem() {
    let status = engine.status
    let menu = NSMenu()
    let header = NSMenuItem(title: status.accessibilityGranted ? "Slated is running" : "Slated needs Accessibility access", action: nil, keyEquivalent: "")
    header.isEnabled = false
    menu.addItem(header)
    if let last = status.lastAction {
      let item = NSMenuItem(title: "Last: \(last)", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }
    if let error = status.lastError {
      let item = NSMenuItem(title: "⚠︎ \(error)", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }
    for warning in engine.warnings {
      let item = NSMenuItem(title: "⚠︎ \(warning)", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }
    menu.addItem(.separator())
    if !status.accessibilityGranted {
      menu.addItem(withTitle: "Grant Accessibility Access…", action: #selector(grantAccess), keyEquivalent: "").target = self
    }
    let hyper = menu.addItem(withTitle: "Caps Lock → Hyper Key", action: #selector(toggleHyper), keyEquivalent: "")
    hyper.target = self
    hyper.state = engine.configuration.keyboard.capsLock == .hyper ? .on : .off
    let pause = menu.addItem(withTitle: "Pause Slated", action: #selector(togglePause), keyEquivalent: "")
    pause.target = self
    pause.state = engine.isSuspended ? .on : .off
    menu.addItem(.separator())
    let active = status.hotkeys.values.filter { $0 == .active }.count
    let summary = NSMenuItem(title: "\(active) hotkeys active", action: nil, keyEquivalent: "")
    summary.isEnabled = false
    menu.addItem(summary)
    if engine.configuration.general.loadSlateConfigs && engine.sources.sources.contains(where: { $0.loaded }) {
      menu.addItem(withTitle: "Import Slate Config into Slated…", action: #selector(importSlate), keyEquivalent: "").target = self
    }
    menu.addItem(withTitle: "Reload Configuration", action: #selector(reload), keyEquivalent: "r").target = self
    menu.addItem(withTitle: "Open Config File", action: #selector(openConfig), keyEquivalent: "").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Slated", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    statusItem?.menu = menu
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
    try? engine.save(config)
  }

  @objc private func togglePause() {
    Log.record("menu.toggle_pause", ["pause": !engine.isSuspended])
    engine.setSuspended(!engine.isSuspended)
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
}
