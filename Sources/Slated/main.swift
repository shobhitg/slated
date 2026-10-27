import AppKit

let app = NSApplication.shared

if CommandLine.arguments.contains("--smoke") {
  // Start the engine without UI or permission prompts, print what it loaded, and exit. Tests/Smoke can
  // keep it running longer (SLATED_SMOKE_SECONDS) and have it save the configuration first
  // (SLATED_SMOKE_SAVE).
  let environment = ProcessInfo.processInfo.environment
  let engine = Engine()
  engine.allowsKeyboardChanges = false
  engine.start()
  let seconds = environment["SLATED_SMOKE_SECONDS"].flatMap(Double.init) ?? 1
  DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    if environment["SLATED_SMOKE_SAVE"] != nil {
      // Saving as Settings does (through the UI's services) and as the menu bar's toggles do.
      let services = LiveServices(engine: engine)
      let saves: [(String, () throws -> Void)] = [
        ("settings", { try services.saveConfiguration(try services.loadConfiguration()) }),
        ("menu", { try engine.save(engine.configuration) }),
      ]
      for (name, save) in saves {
        do {
          try save()
          print("\(name) save: saved")
        } catch {
          print("\(name) save: refused:", error.localizedDescription)
        }
      }
    }
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
