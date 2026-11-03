import CoreGraphics
import Foundation
import SlatedCore

@testable import SlatedSystem

// The keyboard tap's decisions, fed with events that are created but never posted, on a tap that is
// never started: nothing here touches the real keyboard or mouse.

/// What the tap reported to the main actor, and the Escape key presses it would have posted.
private final class TapRecorder: @unchecked Sendable {
  var events: [String] = []
}

/// What the HID system says is physically down, as each test sets it (nothing, unless it says so).
private final class FakeHID: @unchecked Sendable {
  var keys: Set<CGKeyCode> = []
  var buttons: Set<Int> = []
}

private func key(_ code: CGKeyCode, down: Bool, autorepeat: Bool = false) -> CGEvent {
  let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
  event.flags = []
  if autorepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
  return event
}

private func otherMouse(button number: Int64, down: Bool) -> CGEvent {
  let event = CGEvent(
    mouseEventSource: nil, mouseType: down ? .otherMouseDown : .otherMouseUp, mouseCursorPosition: .zero,
    mouseButton: .center)!
  event.setIntegerValueField(.mouseEventButtonNumber, value: number)
  event.flags = []
  return event
}

private func recordingTap(hid: FakeHID = FakeHID()) -> (KeyboardTap, TapRecorder) {
  let tap = KeyboardTap()
  let recorder = TapRecorder()
  tap.onHyperHotkey = { code, down in recorder.events.append("key \(code) \(down ? "down" : "up")") }
  tap.onMouseHotkey = { hotkey, down in recorder.events.append("mouse\(hotkey.button) \(down ? "down" : "up")") }
  tap.onHyperEvent = { event in recorder.events.append("hyper \(event)") }
  tap.physicalState = KeyboardTap.PhysicalState(
    isKeyDown: { hid.keys.contains($0) }, isMouseButtonDown: { hid.buttons.contains($0) })
  // Recorded, never posted.
  tap.postEscape = { recorder.events.append("escape posted") }
  return (tap, recorder)
}

private let hyperFlags: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]

/// Lets the main-actor callbacks the tap dispatched run: waits for a block queued after them (the main queue
/// runs in order), at least 50 ms and at most 5 s. A fixed 50 ms wasn't always enough on a loaded CI machine.
private func deliverCallbacks() {
  final class Flag: @unchecked Sendable { var raised = false }
  let drained = Flag()
  DispatchQueue.main.async { drained.raised = true }
  let start = Date()
  while (!drained.raised || Date().timeIntervalSince(start) < 0.05) && Date().timeIntervalSince(start) < 5 {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
  }
}

private var hyperOn: KeyboardTap.Options {
  var options = KeyboardTap.Options()
  options.hyperEnabled = true
  return options
}

private let capsLock = CGKeyCode(KeyboardTap.hyperKeyCode)
private let keyA: CGKeyCode = 0
private let keyH: CGKeyCode = 4
private let keyJ: CGKeyCode = 38

let keyboardTapTests = Suite(
  "KeyboardTap",
  [
    (
      "Caps Lock adds the Hyper modifiers; Slated's own Hyper combos are swallowed",
      {
        let (tap, _) = recordingTap()
        tap.update(options: hyperOn, hotstrings: [], hyperHotkeys: [keyA])
        expect(tap.handle(type: .keyDown, event: key(capsLock, down: true)) == nil)
        expect(tap.handle(type: .keyDown, event: key(keyA, down: true)) == nil)
        expect(tap.handle(type: .keyUp, event: key(keyA, down: false)) == nil)
        let other = key(1, down: true)
        expect(tap.handle(type: .keyDown, event: other) != nil)
        expect(other.flags.isSuperset(of: [.maskControl, .maskAlternate, .maskShift, .maskCommand]))
        expect(tap.handle(type: .keyUp, event: key(capsLock, down: false)) == nil)
        let plain = key(1, down: true)
        expect(tap.handle(type: .keyDown, event: plain) != nil)
        expectEqual(plain.flags.intersection(.maskCommand), [])
      }
    ),
    (
      "a Hyper combo held when the tap stops is released, and later presses of its key go through whole",
      {
        let (tap, recorder) = recordingTap()
        tap.update(options: hyperOn, hotstrings: [], hyperHotkeys: [keyA])
        _ = tap.handle(type: .keyDown, event: key(capsLock, down: true))
        expect(tap.handle(type: .keyDown, event: key(keyA, down: true)) == nil)
        tap.stop()  // e.g. Slated paused, or Accessibility turned off, while Hyper+A is down
        deliverCallbacks()
        expectEqual(recorder.events, ["hyper pressed", "hyper used", "key 0 down", "hyper released", "key 0 up"])
        tap.update(options: hyperOn, hotstrings: [], hyperHotkeys: [keyA])
        // A plain A afterwards: its release used to be swallowed, leaving A down in the app.
        expect(tap.handle(type: .keyDown, event: key(keyA, down: true)) != nil)
        expect(tap.handle(type: .keyUp, event: key(keyA, down: false)) != nil)
      }
    ),
    (
      "a mouse button shortcut held when the tap stops is released, and the button works afterwards",
      {
        let (tap, recorder) = recordingTap()
        // Mouse 4 is button number 3 (left is 0).
        tap.update(options: hyperOn, hotstrings: [], mouseHotkeys: [.init(button: 4, modifiers: [])])
        expect(tap.handle(type: .otherMouseDown, event: otherMouse(button: 3, down: true)) == nil)
        tap.stop()
        deliverCallbacks()
        expectEqual(recorder.events, ["mouse4 down", "mouse4 up"])
        tap.update(options: hyperOn, hotstrings: [], mouseHotkeys: [])  // no longer a shortcut
        expect(tap.handle(type: .otherMouseDown, event: otherMouse(button: 3, down: true)) != nil)
        expect(tap.handle(type: .otherMouseUp, event: otherMouse(button: 3, down: false)) != nil)
      }
    ),
    (
      "Caps Lock's release, missed while macOS had the tap off, doesn't leave Hyper on every key",
      {
        let (tap, recorder) = recordingTap()  // the HID system says nothing is down
        tap.update(options: hyperOn, hotstrings: [])
        _ = tap.handle(type: .keyDown, event: key(capsLock, down: true))
        // macOS turns slow taps off; events that pass meanwhile (Caps Lock's release) go unseen.
        _ = tap.handle(type: .tapDisabledByTimeout, event: key(capsLock, down: false))
        let typed = key(keyA, down: true)
        expect(tap.handle(type: .keyDown, event: typed) != nil)
        expectEqual(typed.flags.intersection(hyperFlags), [])
        deliverCallbacks()
        expectEqual(recorder.events, ["hyper pressed", "hyper released"])
        // Pressed again: Hyper is back.
        _ = tap.handle(type: .keyDown, event: key(capsLock, down: true))
        let combo = key(keyA, down: true)
        _ = tap.handle(type: .keyDown, event: combo)
        expect(combo.flags.contains(.maskCommand))
      }
    ),
    (
      "a Hyper combo still held when macOS turns the tap back on keeps its repeats and release out of the app",
      {
        let hid = FakeHID()
        let (tap, recorder) = recordingTap(hid: hid)
        tap.update(options: hyperOn, hotstrings: [], hyperHotkeys: [keyJ])
        _ = tap.handle(type: .keyDown, event: key(capsLock, down: true))
        expect(tap.handle(type: .keyDown, event: key(keyJ, down: true)) == nil)  // e.g. a while-held repeat
        hid.keys = [capsLock, keyJ]  // both still held while the tap is off and on again
        _ = tap.handle(type: .tapDisabledByTimeout, event: key(keyJ, down: true))
        for _ in 0..<5 {
          let repeated = key(keyJ, down: true, autorepeat: true)
          expect(tap.handle(type: .keyDown, event: repeated) == nil, "J's auto-repeat reached the app")
        }
        expect(tap.handle(type: .keyUp, event: key(keyJ, down: false)) == nil, "J's release reached the app")
        deliverCallbacks()
        expectEqual(recorder.events, ["hyper pressed", "hyper used", "key 38 down", "key 38 up"])
        _ = tap.handle(type: .keyUp, event: key(capsLock, down: false))
        deliverCallbacks()
        expectEqual(recorder.events.last, "hyper released")
      }
    ),
    (
      "Caps Lock still held when the tap comes back on: the next keys get Hyper, and bound ones fire",
      {
        let hid = FakeHID()
        let (tap, recorder) = recordingTap(hid: hid)
        tap.update(options: hyperOn, hotstrings: [], hyperHotkeys: [keyJ])
        _ = tap.handle(type: .keyDown, event: key(capsLock, down: true))
        _ = tap.handle(type: .keyDown, event: key(keyA, down: true))  // an unbound Hyper combo, released
        _ = tap.handle(type: .keyUp, event: key(keyA, down: false))
        // Another key was pressed, so Caps Lock doesn't auto-repeat: nothing would turn Hyper back on.
        hid.keys = [capsLock]
        _ = tap.handle(type: .tapDisabledByUserInput, event: key(keyA, down: false))
        let unbound = key(keyH, down: true)
        expect(tap.handle(type: .keyDown, event: unbound) != nil)
        expect(unbound.flags.isSuperset(of: hyperFlags), "Caps Lock+H lost the Hyper modifiers")
        expect(tap.handle(type: .keyDown, event: key(keyJ, down: true)) == nil, "Caps Lock+J typed a plain j")
        deliverCallbacks()
        expectEqual(recorder.events, ["hyper pressed", "hyper used", "key 38 down"])
      }
    ),
    (
      "Caps Lock held past the alone timeout across a tap re-enable sends no Escape when released",
      {
        let hid = FakeHID()
        let (tap, recorder) = recordingTap(hid: hid)
        var options = hyperOn
        options.capsLockAloneSendsEscape = true
        options.aloneTimeout = 0.2
        tap.update(options: options, hotstrings: [])
        // A quick tap sends Escape (through the stand-in, never posted).
        _ = tap.handle(type: .keyDown, event: key(capsLock, down: true))
        _ = tap.handle(type: .keyUp, event: key(capsLock, down: false))
        expectEqual(recorder.events.filter { $0 == "escape posted" }.count, 1)
        // A long hold (reading the cheat sheet) with the tap off and on again meanwhile doesn't.
        _ = tap.handle(type: .keyDown, event: key(capsLock, down: true))
        Thread.sleep(forTimeInterval: 0.3)
        hid.keys = [capsLock]
        _ = tap.handle(type: .tapDisabledByTimeout, event: key(capsLock, down: true))
        _ = tap.handle(type: .keyDown, event: key(capsLock, down: true, autorepeat: true))
        _ = tap.handle(type: .keyUp, event: key(capsLock, down: false))
        expectEqual(recorder.events.filter { $0 == "escape posted" }.count, 1)
      }
    ),
    (
      "a mouse button shortcut still held when the tap comes back on keeps its release from the app",
      {
        let hid = FakeHID()
        let (tap, recorder) = recordingTap(hid: hid)
        tap.update(options: hyperOn, hotstrings: [], mouseHotkeys: [.init(button: 4, modifiers: [])])
        expect(tap.handle(type: .otherMouseDown, event: otherMouse(button: 3, down: true)) == nil)
        hid.buttons = [4]
        _ = tap.handle(type: .tapDisabledByTimeout, event: otherMouse(button: 3, down: true))
        expect(tap.handle(type: .otherMouseUp, event: otherMouse(button: 3, down: false)) == nil)
        deliverCallbacks()
        expectEqual(recorder.events, ["mouse4 down", "mouse4 up"])
      }
    ),
    (
      "only what was let go while the tap was off is released: Caps Lock up, J still held",
      {
        let hid = FakeHID()
        let (tap, recorder) = recordingTap(hid: hid)
        tap.update(options: hyperOn, hotstrings: [], hyperHotkeys: [keyJ])
        _ = tap.handle(type: .keyDown, event: key(capsLock, down: true))
        _ = tap.handle(type: .keyDown, event: key(keyJ, down: true))
        hid.keys = [keyJ]
        _ = tap.handle(type: .tapDisabledByTimeout, event: key(capsLock, down: false))
        deliverCallbacks()
        expectEqual(recorder.events, ["hyper pressed", "hyper used", "key 38 down", "hyper released"])
        let plain = key(keyA, down: true)
        _ = tap.handle(type: .keyDown, event: plain)
        expectEqual(plain.flags.intersection(hyperFlags), [])
        expect(tap.handle(type: .keyUp, event: key(keyJ, down: false)) == nil)
        deliverCallbacks()
        expectEqual(recorder.events.last, "key 38 up")
      }
    ),
    (
      "recording a shortcut keeps the Hyper key but no shortcut or hotstring; Pause Slated turns all off",
      {
        var config = SlatedConfiguration()
        config.keyboard.capsLock = .hyper
        config.hotstrings = [Hotstring(trigger: ";sig", replacement: "Best")]
        func live(paused: Bool, recording: Bool) -> String {
          let live = LiveTriggers(config, paused: paused, recording: recording)
          return "hyper \(live.hyperKey), shortcuts \(live.shortcuts), hotstrings \(live.hotstrings)"
        }
        expectEqual(live(paused: false, recording: false), "hyper true, shortcuts true, hotstrings true")
        // Caps Lock must still reach the recorder as ✦, not as a plain Caps Lock.
        expectEqual(live(paused: false, recording: true), "hyper true, shortcuts false, hotstrings false")
        expectEqual(live(paused: true, recording: false), "hyper false, shortcuts false, hotstrings false")
        expectEqual(live(paused: true, recording: true), "hyper false, shortcuts false, hotstrings false")
        config.keyboard.capsLock = .off
        expect(!LiveTriggers(config, paused: false, recording: true).hyperKey)
      }
    ),
    (
      "while a shortcut is recorded, Caps Lock + a key or click reaches it with the Hyper modifiers, Meh too",
      {
        // The options the engine gives the tap while recording: Hyper on; no Hyper combos, mouse
        // buttons or hotstrings to catch.
        for (modifiers, flags) in [(Modifiers.hyper, hyperFlags), (.meh, [.maskControl, .maskAlternate, .maskShift])] {
          let (tap, recorder) = recordingTap()
          var options = hyperOn
          options.hyperModifiers = modifiers
          tap.update(options: options, hotstrings: [Hotstring(trigger: "a", replacement: "Best")])
          expect(tap.handle(type: .keyDown, event: key(capsLock, down: true)) == nil)
          let combo = key(keyA, down: true)
          expect(tap.handle(type: .keyDown, event: combo) != nil, "the key reaches the recorder")
          expectEqual(combo.flags.intersection(hyperFlags), flags)
          let click = otherMouse(button: 3, down: true)
          expect(tap.handle(type: .otherMouseDown, event: click) != nil, "the click reaches the recorder")
          expectEqual(click.flags.intersection(hyperFlags), flags)
          _ = tap.handle(type: .keyUp, event: key(capsLock, down: false))
          let plain = key(keyA, down: true)
          expect(tap.handle(type: .keyDown, event: plain) != nil, "no hotstring expands")
          deliverCallbacks()
          expectEqual(recorder.events, ["hyper pressed", "hyper used", "hyper released"])
        }
      }
    ),
    (
      "contract: the HID system answers for any mouse button, including 4 and 5",
      {
        // Read-only. CGMouseButton is a C enum with three named cases; the tap asks about buttons 4
        // and 5 by number, so the type must take numbers beyond them.
        expectEqual(CGMouseButton(rawValue: 3)?.rawValue, 3)
        expectEqual(CGMouseButton(rawValue: 4)?.rawValue, 4)
        _ = KeyboardTap.PhysicalState.hidSystem.isMouseButtonDown(5)
        _ = KeyboardTap.PhysicalState.hidSystem.isKeyDown(CGKeyCode(KeyboardTap.hyperKeyCode))
      }
    ),
  ])
