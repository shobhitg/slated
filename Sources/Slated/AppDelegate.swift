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
    if !Permissions.isAccessibilityTrusted {
      // First run (or permission revoked): explain and ask.
      Permissions.requestAccessibility()
    }
    log.info("Slated started")
  }

  func applicationWillTerminate(_ notification: Notification) {
    engine.shutdown()
  }

  /// `make run` and logout send SIGTERM; route it through normal termination so Caps Lock is
  /// restored instead of staying remapped until reboot.
  private func handleTerminationSignals() {
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
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
    menu.addItem(withTitle: "Reload Configuration", action: #selector(reload), keyEquivalent: "r").target = self
    menu.addItem(withTitle: "Open Config File", action: #selector(openConfig), keyEquivalent: "").target = self
    menu.addItem(.separator())
    menu.addItem(withTitle: "Quit Slated", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    statusItem?.menu = menu
  }

  @objc private func grantAccess() {
    Permissions.requestAccessibility()
    Permissions.openAccessibilitySettings()
  }

  @objc private func toggleHyper() {
    var config = engine.configuration
    config.keyboard.capsLock = config.keyboard.capsLock == .hyper ? .off : .hyper
    try? engine.save(config)
  }

  @objc private func togglePause() { engine.setSuspended(!engine.isSuspended) }

  @objc private func reload() { engine.reload() }

  @objc private func openConfig() { NSWorkspace.shared.open(engine.store.fileURL) }
}
