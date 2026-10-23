import Carbon.HIToolbox
import SlatedCore

/// Maps Slate key names to macOS virtual key codes.
///
/// Named keys (arrows, F-keys, keypad) have fixed codes. Characters depend on the keyboard layout:
/// on AZERTY, "a" is a different physical key than on QWERTY. Slate shipped hardcoded tables per
/// layout; Slated asks the active layout instead and falls back to the US ANSI positions.
@MainActor
public enum KeyCodes {
  /// Virtual key code for a Slate key name, or nil if it isn't on this keyboard layout.
  public static func code(for key: String) -> UInt16? {
    let key = KeyNames.canonical(key)
    if let code = named[key] { return code }
    if layoutMap == nil { layoutMap = buildLayoutMap() }
    return layoutMap?[key] ?? ansi[key]
  }

  /// Forget the cached layout map (call when the input source changes).
  public static func invalidateLayout() { layoutMap = nil }

  /// Reverse lookup for display and recording: the Slate key name for a virtual key code.
  public static func key(for code: UInt16) -> String? {
    if let named = named.first(where: { $0.value == code })?.key { return named }
    if layoutMap == nil { layoutMap = buildLayoutMap() }
    return layoutMap?.first(where: { $0.value == code })?.key ?? ansi.first(where: { $0.value == code })?.key
  }

  private static var layoutMap: [String: UInt16]?

  /// Characters produced by each key with no modifiers on the current ASCII-capable layout.
  private static func buildLayoutMap() -> [String: UInt16]? {
    guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
      let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
    return data.withUnsafeBytes { bytes -> [String: UInt16] in
      guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return [:] }
      var map: [String: UInt16] = [:]
      for code in UInt16(0)..<128 where !keypadCodes.contains(code) && !named.values.contains(code) {
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(
          layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
          OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { continue }
        let character = String(utf16CodeUnits: chars, count: length).lowercased()
        if map[character] == nil { map[character] = code }
      }
      return map
    }
  }

  private static let keypadCodes: Set<UInt16> = Set([65, 67, 69, 71, 75, 76, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92])

  static let named: [String: UInt16] = [
    "return": 36, "tab": 48, "space": 49, "delete": 51, "esc": 53, "forwardDelete": 117,
    "home": 115, "end": 119, "pageUp": 116, "pageDown": 121, "help": 114,
    "left": 123, "right": 124, "down": 125, "up": 126, "caps": 57,
    "mute": 74, "volumeUp": 72, "volumeDown": 73, "backslash": 42,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
    "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
    "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
    "padClear": 71, "padEnter": 76, "pad=": 81, "pad*": 67, "pad+": 69, "pad-": 78, "pad.": 65,
    "pad/": 75, "pad0": 82, "pad1": 83, "pad2": 84, "pad3": 85, "pad4": 86, "pad5": 87,
    "pad6": 88, "pad7": 89, "pad8": 91, "pad9": 92,
    "shift": 56, "rightShift": 60, "ctrl": 59, "rightCtrl": 62, "alt": 58, "rightAlt": 61, "cmd": 55,
    "rightCmd": 54,
  ]

  /// US ANSI positions, the fallback when the layout doesn't produce a character.
  static let ansi: [String: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
    "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
    "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
    "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
    ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
  ]
}
