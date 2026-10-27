import AppKit
import SlatedCore

/// Maps `NSEvent`s to Slate key names and modifiers, for the shortcut recorder.
enum KeyEventMapping {
  /// F18: what Caps Lock sends once `hidutil` remaps it for the Hyper key.
  static let hyperKeyCode: UInt16 = 79
  static let escapeKeyCode: UInt16 = 53

  /// Physical keys whose names don't come from the keyboard layout.
  static let namedKeys: [UInt16: String] = [
    123: "left", 124: "right", 125: "down", 126: "up", 36: "return", 76: "padEnter", 48: "tab", 49: "space",
    51: "delete", 117: "forwardDelete", 53: "esc", 115: "home", 119: "end", 116: "pageUp", 121: "pageDown",
    114: "help", 122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9",
    109: "f10", 103: "f11", 111: "f12", 105: "f13", 107: "f14", 113: "f15", 106: "f16", 64: "f17", 79: "f18",
    80: "f19", 90: "f20", 82: "pad0", 83: "pad1", 84: "pad2", 85: "pad3", 86: "pad4", 87: "pad5", 88: "pad6",
    89: "pad7", 91: "pad8", 92: "pad9", 65: "pad.", 67: "pad*", 69: "pad+", 75: "pad/", 78: "pad-", 81: "pad=",
    71: "padClear", 74: "mute", 72: "volumeUp", 73: "volumeDown",
  ]

  /// The Slate key name for a key-down event: named keys by key code, everything else by the
  /// character the active layout produces without modifiers (so ⇧1 records as `1`, not `!`).
  static func keyName(for event: NSEvent) -> String? {
    if let named = namedKeys[event.keyCode] { return named }
    guard let characters = event.characters(byApplyingModifiers: []), characters.count == 1,
      let character = characters.first, !character.isWhitespace, !character.isNewline
    else { return nil }
    if character == "\\" { return "backslash" }
    let key = KeyNames.canonical(String(character))
    return KeyNames.isValid(key) ? key : nil
  }

  /// Slate key names for the extra mouse buttons: AppKit numbers the middle button 2 and the side
  /// buttons 3 and 4; users (and `KeyNames.mouseButtons`) call them Mouse 3, 4 and 5.
  static func mouseButtonName(for buttonNumber: Int) -> String? {
    switch buttonNumber {
    case 2: return "mouse3"
    case 3: return "mouse4"
    case 4: return "mouse5"
    default: return nil
    }
  }

  /// ⌃⌥⇧⌘ from AppKit flags. `fn` is left out: macOS sets it on every arrow and function key.
  static func modifiers(_ flags: NSEvent.ModifierFlags) -> Modifiers {
    var modifiers: Modifiers = []
    if flags.contains(.control) { modifiers.insert(.control) }
    if flags.contains(.option) { modifiers.insert(.option) }
    if flags.contains(.shift) { modifiers.insert(.shift) }
    if flags.contains(.command) { modifiers.insert(.command) }
    return modifiers
  }

  /// The modifiers to record: the event's own, plus what Caps Lock adds while it's held as the Hyper
  /// key (`keyboard.hyperModifiers`: ⌃⌥⇧⌘, or ⌃⌥⇧ for Meh), so the shortcut matches what the
  /// Hyper key will send.
  static func modifiers(_ flags: NSEvent.ModifierFlags, hyperHeld: Bool, hyperModifiers: Modifiers) -> Modifiers {
    hyperHeld ? modifiers(flags).union(hyperModifiers) : modifiers(flags)
  }
}

/// Owns an `NSEvent` local monitor so SwiftUI state can hold it.
@MainActor
final class KeyEventMonitor {
  private var token: Any?

  var isRunning: Bool { token != nil }

  func start(_ handler: @escaping @MainActor (NSEvent) -> NSEvent?) {
    stop()
    // Local monitors run on the main thread, before the event reaches any view. Middle and side
    // mouse buttons (`otherMouseDown`) can be recorded as Mouse 3–5 shortcuts.
    let events: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .otherMouseDown]
    token = NSEvent.addLocalMonitorForEvents(matching: events) { event in
      handler(event)
    }
  }

  func stop() {
    if let token { NSEvent.removeMonitor(token) }
    token = nil
  }
}
