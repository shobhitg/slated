import CoreGraphics
import Foundation
import SlatedCore

@testable import SlatedSystem

// The keyboard tap's decisions, fed with events that are created but never posted, on a tap that is
// never started: nothing here touches the real keyboard or mouse.

/// What the tap reported to the main actor.
private final class TapRecorder: @unchecked Sendable {
  var events: [String] = []
}

private func key(_ code: CGKeyCode, down: Bool) -> CGEvent {
  let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
  event.flags = []
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

private func recordingTap() -> (KeyboardTap, TapRecorder) {
  let tap = KeyboardTap()
  let recorder = TapRecorder()
  tap.onHyperHotkey = { code, down in recorder.events.append("key \(code) \(down ? "down" : "up")") }
  tap.onMouseHotkey = { hotkey, down in recorder.events.append("mouse\(hotkey.button) \(down ? "down" : "up")") }
  tap.onHyperEvent = { event in recorder.events.append("hyper \(event)") }
  return (tap, recorder)
}

/// Lets the main-actor callbacks the tap dispatched run.
private func deliverCallbacks() {
  RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}

private var hyperOn: KeyboardTap.Options {
  var options = KeyboardTap.Options()
  options.hyperEnabled = true
  return options
}

private let capsLock = CGKeyCode(KeyboardTap.hyperKeyCode)
private let keyA: CGKeyCode = 0

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
        let (tap, recorder) = recordingTap()
        tap.update(options: hyperOn, hotstrings: [])
        _ = tap.handle(type: .keyDown, event: key(capsLock, down: true))
        // macOS turns slow taps off; events that pass meanwhile (Caps Lock's release) go unseen.
        _ = tap.handle(type: .tapDisabledByTimeout, event: key(capsLock, down: false))
        let typed = key(keyA, down: true)
        expect(tap.handle(type: .keyDown, event: typed) != nil)
        expectEqual(typed.flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand]), [])
        deliverCallbacks()
        expectEqual(recorder.events, ["hyper pressed", "hyper released"])
        // Still holding Caps Lock: its key repeat brings Hyper back.
        _ = tap.handle(type: .keyDown, event: key(capsLock, down: true))
        let combo = key(keyA, down: true)
        _ = tap.handle(type: .keyDown, event: combo)
        expect(combo.flags.contains(.maskCommand))
      }
    ),
  ])
