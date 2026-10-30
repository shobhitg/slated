import AppKit
import SlatedCore
import SlatedSystem
import SlatedUI

/// What `--smoke` does half way through its run for Tests/Smoke: `SLATED_SMOKE_STEPS` lists steps,
/// separated by spaces, that drive the real engine the way the UI or macOS would. Notifications are
/// posted in this process only; nothing outside it is touched.
enum SmokeSteps {
  static func run(_ step: String, engine: Engine) {
    switch step {
    case "save":
      // Saving as Settings does (through the UI's services) and as the menus' toggles do.
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
    case "pause":
      // "Pause Slated", then another app becomes active.
      engine.setPaused(true)
      print("paused: \(HotKeyCenter.shared.registrationCount) hotkeys registered")
      activateAnotherApp()
    case "record-shortcut":
      // Settings records a shortcut: nothing bound may fire, but the Hyper key keeps working, so Caps
      // Lock + a key reaches the recorder as ✦ + that key. Pause Slated turns the Hyper key off too.
      engine.setSuspended(true)
      print("recording a shortcut: \(keyboard(engine))")
      engine.setPaused(true)
      print("paused while recording: \(keyboard(engine))")
      engine.setPaused(false)
      engine.setSuspended(false)
      print("after recording: \(keyboard(engine))")
    case "reload":
      engine.reload()
    case "toggle-island":
      // Settings → Island → the island switch: a settings.json change only.
      var config = engine.configuration
      config.island.enabled.toggle()
      do { try engine.save(config) } catch { print("save failed:", error.localizedDescription) }
    case "add-binding":
      // Settings → Windows → a new shortcut: a config.json change only.
      var config = engine.configuration
      if let keys = KeyCombo(string: "ctrl+alt+cmd+f19") {
        config.bindings.append(HotkeyBinding(keys: keys, action: .undo))
      }
      do { try engine.save(config) } catch { print("save failed:", error.localizedDescription) }
    case "screens-changed":
      // As when a display is plugged in.
      NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
    case "hand-edit-then-save":
      // Settings saves an edit right after config.json was saved by hand, in place (nano, `>`), before
      // the once-a-second check has seen it. SLATED_SMOKE_EDIT is the hand edit.
      guard let edit = ProcessInfo.processInfo.environment["SLATED_SMOKE_EDIT"],
        let text = FileManager.default.contents(atPath: edit),
        let handle = FileHandle(forWritingAtPath: engine.store.fileURL.path)
      else { return print("hand-edit-then-save needs SLATED_SMOKE_EDIT and a config.json") }
      let model = AppModel(services: LiveServices(engine: engine))
      model.configuration.keyboard.capsLock = model.configuration.keyboard.capsLock == .hyper ? .off : .hyper
      try? handle.truncate(atOffset: 0)
      try? handle.write(contentsOf: text)
      try? handle.close()
      model.saveNow()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        let (bindings, hotstrings) = (model.configuration.bindings.count, model.configuration.hotstrings.count)
        print("after a hand edit, Settings shows \(bindings) bindings, \(hotstrings) hotstrings")
      }
    case "repeat-text":
      // Two auto-repeats of different text of the same length, started with no shortcut (as when a
      // sequence resumes after a wait): both run. Their repetitions do nothing here; nothing is typed.
      engine.automation.perform = { _ in }
      for text in ["first secret", "other secret"] {
        engine.runner.perform(
          .autoRepeat(.insertText(text, method: .type), interval: 60, mode: .toggle, times: nil, jitter: 0))
      }
      print("auto-repeats running: \(engine.automation.active.count)")
      engine.automation.stopAll(reason: "smoke test")
    case "macro-stops":
      // A macro waiting between steps, on a wait or on a shell command with wait, counts as a running
      // automation: each safety stop drops the steps it has left. One stop after another.
      let stops = ["none", "stop-shortcut", "app-switch", "time-limit", "sleep", "pause"]
      macroStops(engine, stops.map { ("wait", $0) } + ["none", "stop-shortcut", "app-switch"].map { ("shell", $0) })
    case "copy-a-day-later":
      // A copy recorded a day after launch: what expired meanwhile goes. Recorded directly; the real
      // clipboard isn't touched.
      let later = Date().addingTimeInterval(86_400)
      engine.clipboard.now = { later }
      engine.clipboard.record(PasteboardWatcher.Copy(text: "a new copy", sourceApp: "com.example.editor"))
      let items = engine.clipboard.history.items
      let expired = items.filter { !$0.pinned && $0.copiedAt < later.addingTimeInterval(-30 * 86_400) }.count
      print("clipboard after a copy a day later: \(expired) expired, \(items.filter(\.pinned).count) pinned")
    case "break-config":
      // config.json stops being readable while Slated runs (a hand edit half done), and is reloaded.
      try? Data("{ \"bindings\": [".utf8).write(to: engine.store.fileURL)
      engine.reload()
    case "switcher":
      // What the clipboard picker says Return does, with the services the app gives it.
      let model = ClipboardPickerModel(services: LiveServices.forClipboardSwitcher(engine))
      print("switcher: Return \(model.pasteAfterSelecting ? "pastes" : "copies")")
    case "clipboard-images":
      clipboardImages(engine)
    case "clipboard-screenshots":
      clipboardScreenshots(engine)
    case "clipboard-files":
      clipboardFiles(engine)
    case "import-slate":
      // "Import Slate Config into Slated…" in the menus; prints what its alert says.
      do {
        let summary = try engine.importSlateConfigs()
        print("import alert:", summary.title)
        print(summary.message)
      } catch {
        print("import failed:", error.localizedDescription)
      }
    case "edit-imported":
      // In Settings: delete the binding on ⌃⌥F16 and move the one on ⌃⌥F18 to ⌃⌥F19.
      var config = engine.configuration
      config.bindings.removeAll { $0.keys.string == "ctrl+alt+f16" }
      if let index = config.bindings.firstIndex(where: { $0.keys.string == "ctrl+alt+f18" }),
        let keys = KeyCombo(string: "ctrl+alt+f19")
      {
        config.bindings[index].keys = keys
      }
      do {
        try LiveServices(engine: engine).saveConfiguration(config)
      } catch {
        print("save failed:", error.localizedDescription)
      }
    case "edit-then-import":
      // In Settings, an edit still waiting for its debounce; then "Import Slate Config into Slated…".
      let model = AppModel(services: LiveServices(engine: engine))
      model.configuration.general.showActionHUD.toggle()
      do {
        let summary = try model.importSlateConfig()
        print("import alert:", summary.title)
      } catch {
        print("import failed:", error.localizedDescription)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
        let config = model.configuration
        let (bindings, hud) = (config.bindings.count, config.general.showActionHUD)
        print("after the debounce, Settings shows \(bindings) bindings, HUD \(hud)")
      }
    case "print-hotkeys":
      // Every shortcut's status, active ones too (the summary at the end lists only the others).
      for (key, value) in engine.status.hotkeys.sorted(by: { $0.key < $1.key }) { print("hotkey \(key): \(value)") }
    case "move-config-away":
      // The file config.json links to goes away while Slated runs (a branch switch, an unmounted volume).
      let target = engine.store.fileURL.resolvingSymlinksInPath()
      try? FileManager.default.moveItem(at: target, to: target.appendingPathExtension("moved"))
    default:
      print("unknown smoke step:", step)
    }
  }

  /// What the keyboard tap and Caps Lock mapping are asked for (smoke runs never set them up), and how
  /// many hotkeys are registered.
  private static func keyboard(_ engine: Engine) -> String {
    let live = engine.liveTriggers
    return "Hyper key \(live.hyperKey ? "on" : "off"), shortcuts \(live.shortcuts ? "on" : "off"), "
      + "hotstrings \(live.hotstrings ? "on" : "off"), \(HotKeyCenter.shared.registrationCount) hotkeys registered"
  }

  /// Runs `scenarios` one after another: a macro whose last step (touching a file) waits 0.2 s, on a
  /// `wait` or on a shell command with `wait`, stopped as a safety stop would. "none" stops nothing.
  private static func macroStops(_ engine: Engine, _ scenarios: [(pause: String, stop: String)]) {
    guard let (pause, stop) = scenarios.first else { return }
    let marker = URL(fileURLWithPath: SlatedPaths.home).appendingPathComponent("macro-\(pause)-\(stop)").path
    let first: Action = pause == "shell" ? .shell(command: "sleep 0.2", wait: true, path: nil) : .wait(0.2)
    let macro = Action.sequence([
      SequenceStep(first), SequenceStep(.shell(command: "touch '\(marker)'", wait: false, path: nil)),
    ])
    if stop == "time-limit" { engine.automation.settings.maxRunMinutes = 0.05 / 60 }
    engine.runner.run(macro, trigger: "smoke macro")
    let running = engine.automation.isBusy
    switch stop {
    case "stop-shortcut": engine.runner.run(.stopAutomations, trigger: "smoke stop shortcut")
    case "app-switch": activateAnotherApp()
    case "sleep": NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
    case "pause":
      engine.setPaused(true)
      engine.setPaused(false)
    default: break
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
      engine.automation.settings = engine.configuration.automation
      let ran = FileManager.default.fileExists(atPath: marker)
      print(
        "macro waiting on \(pause == "shell" ? "a shell command" : "a wait"), stopped by \(stop): "
          + "\(running ? "running" : "not running"), its last step \(ran ? "ran" : "dropped")")
      macroStops(engine, Array(scenarios.dropFirst()))
    }
  }

  /// A screenshot copied twice, put back on the clipboard and deleted, through a clipboard service of
  /// its own on a private pasteboard: the real clipboard isn't touched.
  private static func clipboardImages(_ engine: Engine) {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.slated.smoke.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let service = ClipboardService(pasteboard: pasteboard)
    service.apply(engine.configuration.clipboard)
    let context = CGContext(
      data: nil, width: 64, height: 40, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0.4, green: 0.3, blue: 0.9, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
    let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    let copy = PasteboardWatcher.Copy(text: nil, image: .init(data: png, type: .png), sourceApp: "com.example.browser")
    service.record(copy)
    service.record(copy)
    let directory = service.images.directory.path
    let files = { (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] }
    let mode = files().first.flatMap {
      (try? FileManager.default.attributesOfItem(atPath: "\(directory)/\($0)")[.posixPermissions]) as? NSNumber
    }
    let images = service.history.items.filter(\.isImage)
    print(
      "clipboard images: \(images.count) item, \(files().count) file, mode \(String(mode?.intValue ?? 0, radix: 8)), "
        + "\(images.first.map { "\($0.image!.width)×\($0.image!.height)" } ?? "none")")
    guard let item = images.first else { return }
    service.copy(id: item.id)
    print("clipboard image put back: \(pasteboard.data(forType: .png) == png ? "the same bytes" : "different bytes")")
    // Putting it back moved it to the top, as a new item.
    service.delete(id: service.history.items.first(where: \.isImage)?.id ?? item.id)
    print("clipboard images after deleting it: \(files().count) files")
    service.stop()
  }

  /// A screenshot saved into the test home's Desktop (the only screenshot folder a run with
  /// SLATED_HOME watches) while `clipboard.screenshots` is on, and another after it's turned off,
  /// through the engine's own clipboard service. Saved as screencapture does: hidden, then renamed.
  /// The watcher reports on the main queue, so each check runs later on it (about 4 s in all; give
  /// the run SLATED_SMOKE_SECONDS=12).
  private static func clipboardScreenshots(_ engine: Engine) {
    let desktop = URL(fileURLWithPath: SlatedPaths.home).appendingPathComponent("Desktop")
    let clipboard = engine.clipboard
    let screenshots = { clipboard.history.items.filter { $0.image?.name != nil } }
    print("screenshot folder: \(clipboard.screenshotStatus)")
    let first = saveScreenshot("Screenshot 2026-10-30 at 09.41.12.png", in: desktop, red: 0.2)
    later(2) {
      print(
        "screenshots recorded: \(screenshots().count), named \(screenshots().first?.image?.name ?? "none"), "
          + "file \(FileManager.default.fileExists(atPath: first.path) ? "left in place" : "gone")")
      var config = engine.configuration
      config.clipboard.screenshots = false
      do { try engine.save(config) } catch { print("save failed:", error.localizedDescription) }
      later(0.5) {
        saveScreenshot("Screenshot 2026-10-30 at 09.42.00.png", in: desktop, red: 0.7)
        later(1.5) {
          print("with the setting off: \(screenshots().count) recorded, folder \(clipboard.screenshotStatus)")
        }
      }
    }
  }

  private static func later(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(work) }
  }

  @discardableResult
  private static func saveScreenshot(_ name: String, in folder: URL, red: CGFloat) -> URL {
    let context = CGContext(
      data: nil, width: 48, height: 30, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: red, green: 0.5, blue: 0.9, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: 48, height: 30))
    let png = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
    let temporary = folder.appendingPathComponent(".\(name)")
    FileManager.default.createFile(atPath: temporary.path, contents: png)
    let flag = try! PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
    _ = flag.withUnsafeBytes { setxattr(temporary.path, Screenshots.attribute, $0.baseAddress, $0.count, 0, 0) }
    let final = folder.appendingPathComponent(name)
    try? FileManager.default.moveItem(at: temporary, to: final)
    return final
  }

  /// Files copied (on a private pasteboard), put back, then put back again after one and then both
  /// were deleted.
  private static func clipboardFiles(_ engine: Engine) {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.github.slated.smoke.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let service = ClipboardService(pasteboard: pasteboard)
    var settings = engine.configuration.clipboard
    settings.screenshots = false
    service.apply(settings)
    let folder = URL(fileURLWithPath: SlatedPaths.home).appendingPathComponent("Copied files")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let files = ["SECRET-NAME report.pdf", "SECRET-NAME notes.txt"].map { folder.appendingPathComponent($0) }
    for file in files { FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8)) }
    service.record(PasteboardWatcher.Copy(text: "names", files: files, sourceApp: "com.apple.finder"))
    let items = service.history.items.filter(\.isFiles)
    let named = items.first?.text == "SECRET-NAME report.pdf\nSECRET-NAME notes.txt"
    print("files copied: \(items.count) item, \(items.first?.files?.count ?? 0) files, text \(named ? "their names" : "wrong")")
    // Putting an item back moves it to the top as a new item: look it up each time.
    let copy = { service.history.items.first(where: \.isFiles).map { service.copy(id: $0.id) } }
    let putBack = { PasteboardWatcher.fileURLs(on: pasteboard).count }
    copy()
    print("files put back: \(putBack())")
    try? FileManager.default.removeItem(at: files[1])
    copy()
    print("files put back after one was deleted: \(putBack())")
    try? FileManager.default.removeItem(at: files[0])
    pasteboard.clearContents()
    pasteboard.setString("left alone", forType: .string)
    copy()
    print("with both deleted, the clipboard holds: \(pasteboard.string(forType: .string) ?? "something else")")
    service.stop()
  }

  /// As when another app comes to the front.
  private static func activateAnotherApp() {
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    if let other = NSWorkspace.shared.runningApplications.first(where: {
      $0.bundleIdentifier != nil && $0.bundleIdentifier != front
    }) {
      NSWorkspace.shared.notificationCenter.post(
        name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
        userInfo: [NSWorkspace.applicationUserInfoKey: other])
    }
  }

  /// Printed with the summary at the end of the run.
  static func report(_ steps: [String]) {
    if steps.contains("pause") {
      print("paused, after switching apps: \(HotKeyCenter.shared.registrationCount) hotkeys registered")
    }
  }
}
