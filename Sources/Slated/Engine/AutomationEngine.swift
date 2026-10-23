import AppKit
import SlatedCore
import SlatedSystem
import SlatedUI

/// Runs AutoHotkey-style automation (auto-repeats and held mouse buttons or keys), with safety rails:
/// a stop shortcut, stopping when you switch apps or after a time limit, and never leaving a button
/// or key stuck down: pausing, sleeping, locking the screen or quitting releases everything.
final class AutomationEngine {
  var settings = AutomationSettings()
  /// Performs one repetition (wired to the action runner).
  var perform: ((Action) -> Void)?
  /// Something started or stopped (the indicator and UI refresh).
  var onChange: (() -> Void)?

  private struct Repeater {
    var timer: Timer
    var info: ActiveAutomation
    var mode: RepeatMode
  }

  private var repeaters: [String: Repeater] = [:]
  private var held: [SyntheticInput: ActiveAutomation] = [:]
  /// The app that was frontmost when the first automation started (for `stopOnAppSwitch`).
  private var startedInApp: String?
  private var limitTimer: Timer?

  var isRunning: Bool { !repeaters.isEmpty || !held.isEmpty }

  var active: [ActiveAutomation] {
    (repeaters.values.map(\.info) + held.values).sorted { $0.startedAt < $1.startedAt }
  }

  // MARK: Auto-repeat

  /// Starts an auto-repeat identified by `id` (its trigger), or stops it if it's already running
  /// (toggle mode, or a second press in while-held mode).
  func toggleRepeat(_ action: Action, interval: Double, mode: RepeatMode, id: String, trigger: String?) {
    if repeaters[id] != nil {
      stopRepeat(id: id, reason: "toggled off")
      return
    }
    let interval = max(interval, 0.01)
    let info = ActiveAutomation(
      id: id, title: "Repeat \(SlateSyntax.format(action)) every \(Self.describe(seconds: interval))",
      trigger: trigger, startedAt: Date(), repetitions: 1)
    perform?(action)  // the first repetition happens right away
    let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick(id: id, action: action) }
    }
    RunLoop.main.add(timer, forMode: .common)
    repeaters[id] = Repeater(timer: timer, info: info, mode: mode)
    began(info, extra: ["interval": interval, "mode": mode.rawValue])
  }

  /// The trigger's key was released: stops the while-held repeat it started.
  func released(id: String) {
    guard let repeater = repeaters[id], repeater.mode == .whileHeld else { return }
    stopRepeat(id: id, reason: "released")
  }

  private func tick(id: String, action: Action) {
    guard repeaters[id] != nil else { return }
    repeaters[id]?.info.repetitions += 1
    perform?(action)
  }

  private func stopRepeat(id: String, reason: String, notify: Bool = true) {
    guard let repeater = repeaters.removeValue(forKey: id) else { return }
    repeater.timer.invalidate()
    ended(repeater.info, reason: reason, notify: notify)
  }

  // MARK: Holding inputs

  /// Holds `input` down, or releases it if it's already held.
  func toggleHold(_ input: SyntheticInput, trigger: String?) {
    if held[input] != nil {
      release(input, reason: "toggled off")
    } else {
      press(input, phase: .down, trigger: trigger)
    }
  }

  /// Presses or releases `input` (macro steps). Everything pressed is tracked so it can always be
  /// released again.
  func press(_ input: SyntheticInput, phase: PressPhase, trigger: String? = nil) {
    switch phase {
    case .down:
      guard send(input, down: true) else { return }
      if held[input] == nil {
        let info = ActiveAutomation(
          id: "hold:\(input.string)", title: "Hold \(Self.describe(input))", trigger: trigger, startedAt: Date(),
          repetitions: 1)
        held[input] = info
        began(info, extra: [:])
      }
    case .up:
      release(input, reason: "released by macro")
    }
  }

  private func release(_ input: SyntheticInput, reason: String, notify: Bool = true) {
    send(input, down: false)
    if let info = held.removeValue(forKey: input) { ended(info, reason: reason, notify: notify) }
  }

  @discardableResult
  private func send(_ input: SyntheticInput, down: Bool) -> Bool {
    switch input {
    case .mouse(let button):
      InputSynth.mouse(button, down: down)
      return true
    case .key(let combo):
      guard let code = KeyCodes.code(for: combo.key) else {
        Log.error("automation.unknown_key", "\(combo.key) isn't a key on this keyboard layout")
        return false
      }
      InputSynth.key(code, modifiers: combo.modifiers, down: down)
      return true
    }
  }

  // MARK: Stopping

  /// Stops every repeat and releases everything held.
  func stopAll(reason: String) {
    guard isRunning else { return }
    for id in Array(repeaters.keys) { stopRepeat(id: id, reason: reason, notify: false) }
    for input in Array(held.keys) { release(input, reason: reason, notify: false) }
    Log.record("automation.stopped_all", level: .notice, ["reason": reason])
    onChange?()
  }

  /// Called when the frontmost app changes.
  func frontmostAppChanged(to bundleID: String?) {
    guard settings.stopOnAppSwitch, isRunning, let startedInApp, bundleID != startedInApp else { return }
    // Our own windows (the switcher, settings) don't count as leaving the game.
    if bundleID == Bundle.main.bundleIdentifier { return }
    stopAll(reason: "switched to another app")
  }

  private func began(_ info: ActiveAutomation, extra: [String: Any]) {
    if startedInApp == nil { startedInApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    if settings.maxRunMinutes > 0 && limitTimer == nil {
      let timer = Timer(timeInterval: settings.maxRunMinutes * 60, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated { self?.stopAll(reason: "time limit reached") }
      }
      RunLoop.main.add(timer, forMode: .common)
      limitTimer = timer
    }
    var data: [String: Any] = ["id": info.id, "title": info.title, "app": startedInApp ?? "unknown"]
    data["trigger"] = info.trigger
    Log.record("automation.started", data.merging(extra) { a, _ in a })
    onChange?()
  }

  private func ended(_ info: ActiveAutomation, reason: String, notify: Bool) {
    Log.record(
      "automation.stopped",
      [
        "id": info.id, "title": info.title, "reason": reason, "repetitions": info.repetitions,
        "seconds": Date().timeIntervalSince(info.startedAt),
      ])
    if !isRunning {
      startedInApp = nil
      limitTimer?.invalidate()
      limitTimer = nil
    }
    if notify { onChange?() }
  }

  // MARK: Descriptions

  static func describe(seconds: Double) -> String {
    seconds < 1 ? "\(Int((seconds * 1000).rounded())) ms" : String(format: seconds == seconds.rounded() ? "%.0f s" : "%.1f s", seconds)
  }

  static func describe(_ input: SyntheticInput) -> String {
    switch input {
    case .mouse(let button): return "\(button.rawValue.capitalized) Mouse Button"
    case .key(let combo): return combo.display()
    }
  }
}
