import CoreGraphics
import SlatedCore

/// Synthesizes mouse and keyboard input for automation (auto-clickers, held keys, macros).
///
/// Events are posted at the HID level with the HID system state, so they look like real hardware
/// input: games that read the button or key state see a held button as held. Every event carries the
/// synthetic marker so Slated's own keyboard tap ignores it.
public enum InputSynth {
  /// Where the pointer is, in top-left global coordinates.
  public static var pointerLocation: CGPoint { CGEvent(source: nil)?.location ?? .zero }

  /// Clicks `button` at the pointer `count` times in a row (2 = double-click).
  public static func click(_ button: MouseButton, count: Int = 1) {
    let location = pointerLocation
    for clickState in 1...max(1, count) {
      post(mouse: button, down: true, at: location, clickState: clickState)
      post(mouse: button, down: false, at: location, clickState: clickState)
    }
  }

  /// Presses or releases `button` at the pointer.
  public static func mouse(_ button: MouseButton, down: Bool) {
    post(mouse: button, down: down, at: pointerLocation, clickState: 1)
  }

  /// Presses or releases a key with modifiers.
  public static func key(_ code: CGKeyCode, modifiers: Modifiers = [], down: Bool) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
    event.flags = KeyboardTap.flags(for: modifiers)
    mark(event)
    event.post(tap: .cghidEventTap)
  }

  /// Presses and releases a key.
  public static func tap(_ code: CGKeyCode, modifiers: Modifiers = []) {
    key(code, modifiers: modifiers, down: true)
    key(code, modifiers: modifiers, down: false)
  }

  // Only used to create events; CGEventSource is thread-safe for that.
  nonisolated(unsafe) private static let source = CGEventSource(stateID: .hidSystemState)

  private static func post(mouse button: MouseButton, down: Bool, at location: CGPoint, clickState: Int) {
    let (type, cgButton): (CGEventType, CGMouseButton)
    switch button {
    case .left: (type, cgButton) = (down ? .leftMouseDown : .leftMouseUp, .left)
    case .right: (type, cgButton) = (down ? .rightMouseDown : .rightMouseUp, .right)
    case .middle: (type, cgButton) = (down ? .otherMouseDown : .otherMouseUp, .center)
    }
    guard
      let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: cgButton)
    else { return }
    event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
    mark(event)
    event.post(tap: .cghidEventTap)
  }

  private static func mark(_ event: CGEvent) {
    event.setIntegerValueField(.eventSourceUserData, value: KeyboardTap.syntheticEventMarker)
  }
}
