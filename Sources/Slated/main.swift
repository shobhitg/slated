import AppKit

let app = NSApplication.shared

if CommandLine.arguments.contains("--smoke") {
  // Start the engine without UI or permission prompts, print what it loaded, and exit. Tests/Smoke can
  // keep it running longer (SLATED_SMOKE_SECONDS) and drive it half way through (SLATED_SMOKE_STEPS,
  // see SmokeSteps).
  let environment = ProcessInfo.processInfo.environment
  let steps = (environment["SLATED_SMOKE_STEPS"] ?? "").split(separator: " ").map(String.init)
  let engine = Engine()
  engine.allowsKeyboardChanges = false
  engine.mode = "smoke"
  engine.start()
  let seconds = environment["SLATED_SMOKE_SECONDS"].flatMap(Double.init) ?? 1
  DispatchQueue.main.asyncAfter(deadline: .now() + seconds / 2) {
    for step in steps { SmokeSteps.run(step, engine: engine) }
  }
  DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    SmokeSteps.report(steps)
    let status = engine.status
    let config = engine.configuration
    print("config:", engine.store.fileURL.path, engine.store.loadError ?? "ok")
    print("native: \(config.bindings.count) bindings, \(config.hotstrings.count) hotstrings, capsLock: \(config.keyboard.capsLock.rawValue), \(config.layouts.count) layouts, \(config.windows.values.count) window settings")
    // What Overview would say about a Slate config a first run or the migration imported.
    if let notice = SlateImportNotice.load() {
      print(
        "slate notice: \(notice.added) added, \(notice.alreadyThere) already there, \(notice.notConverted.count) not converted, from \(notice.fileNames)"
      )
      for item in notice.notConverted { print("   not converted:", item.description) }
      for problem in notice.problems { print("   problem:", problem) }
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

// A regular app (Dock icon, menus, Cmd-Tab) with one main window; see AppDelegate.
let delegate = AppDelegate()
app.delegate = delegate
app.run()
