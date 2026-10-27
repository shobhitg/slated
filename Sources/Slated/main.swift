import AppKit

let app = NSApplication.shared

if CommandLine.arguments.contains("--smoke") {
  // Start the engine without UI or permission prompts, print what it loaded, and exit.
  let engine = Engine()
  engine.allowsKeyboardChanges = false
  engine.start()
  DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    let status = engine.status
    let config = engine.configuration
    print("config:", engine.store.fileURL.path, engine.store.loadError ?? "ok")
    print("native: \(config.bindings.count) bindings, \(config.hotstrings.count) hotstrings, capsLock: \(config.keyboard.capsLock.rawValue), loadSlateConfigs: \(config.general.loadSlateConfigs)")
    for source in engine.sources.sources {
      print("source:", source.path, source.loaded ? "loaded" : "not loaded", "\(source.bindings.count) bindings")
      for d in source.diagnostics { print("  ", d) }
    }
    print("hotkeys:", status.hotkeys.count, "registered,", status.hotkeys.values.filter { $0 == .active }.count, "active")
    for (key, value) in status.hotkeys.sorted(by: { $0.key < $1.key }) where value != .active {
      switch value {
      case .failed(let reason): print("  ", key, "failed:", reason)
      default: print("  ", key, value)
      }
    }
    for key in engine.hotkeys.duplicates { print("   duplicate:", key) }
    for warning in engine.warnings { print("warning:", warning) }
    print("accessibility:", status.accessibilityGranted, "hyper:", status.hyperKeyActive, "hotstrings:", status.hotstringsActive)
    let island = config.island
    print(
      "island:", island.enabled ? "on" : "off",
      island.cheatSheet ? "cheat sheet after \(island.cheatSheetDelay) s" : "no cheat sheet",
      island.showFailures ? "failures shown" : "failures hidden")
    let sheet = engine.hyperCheatSheet()
    print("cheat sheet: \(sheet.items.count) Hyper shortcuts (\(sheet.sections.map(\.title).joined(separator: ", ")))")
    print("log:", Log.fileURL.path)
    engine.shutdown()
    Diagnostics.markCleanExit()
    Log.flush()
    exit(0)
  }
  app.run()
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
