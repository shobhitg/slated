import AppKit
import SlatedSystem
import SlatedUI

/// What `--smoke` does half way through its run for Tests/Smoke: `SLATED_SMOKE_STEPS` lists steps,
/// separated by spaces, that drive the real engine the way the UI or macOS would. Notifications are
/// posted in this process only; nothing outside it is touched.
enum SmokeSteps {
  static func run(_ step: String, engine: Engine) {
    switch step {
    case "save":
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
    case "pause":
      // "Pause Slated", then another app becomes active.
      engine.setPaused(true)
      print("paused: \(HotKeyCenter.shared.registrationCount) hotkeys registered")
      let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
      if let other = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier != nil && $0.bundleIdentifier != front
      }) {
        NSWorkspace.shared.notificationCenter.post(
          name: NSWorkspace.didActivateApplicationNotification, object: NSWorkspace.shared,
          userInfo: [NSWorkspace.applicationUserInfoKey: other])
      }
    case "reload":
      engine.reload()
    case "stop-loading-slate":
      // Settings → General → "Load Slate configs" turned off.
      var config = engine.configuration
      config.general.loadSlateConfigs = false
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
    case "move-config-away":
      // The file config.json links to goes away while Slated runs (a branch switch, an unmounted volume).
      let target = engine.store.fileURL.resolvingSymlinksInPath()
      try? FileManager.default.moveItem(at: target, to: target.appendingPathExtension("moved"))
    default:
      print("unknown smoke step:", step)
    }
  }

  /// Printed with the summary at the end of the run.
  static func report(_ steps: [String]) {
    if steps.contains("pause") {
      print("paused, after switching apps: \(HotKeyCenter.shared.registrationCount) hotkeys registered")
    }
  }
}
