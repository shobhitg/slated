import AppKit
import SlatedSystem

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
