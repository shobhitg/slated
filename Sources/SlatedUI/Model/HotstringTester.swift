import Foundation
import SlatedCore

/// Simulates one hotstring on a text field's contents, for the editor's "try it" field.
///
/// It follows the same rules the engine documents (fire immediately or after a delimiter, case
/// sensitivity, word boundary) but runs entirely in the UI on the field's own text, so it works
/// without Accessibility permission and never touches other apps.
enum HotstringTester {
  /// Characters that end a word: anything that isn't a letter or digit.
  static func isDelimiter(_ c: Character) -> Bool { !(c.isLetter || c.isNumber) }

  /// The expanded text when typing the last character of `current` (one character appended to
  /// `previous`) fires `hotstring`; otherwise `nil`.
  static func expand(previous: String, current: String, hotstring: Hotstring) -> String? {
    guard !hotstring.trigger.isEmpty, current.count == previous.count + 1, current.hasPrefix(previous),
      let typed = current.last
    else { return nil }
    switch hotstring.fire {
    case .immediately:
      guard let start = triggerStart(in: current, hotstring: hotstring) else { return nil }
      return String(current[..<start]) + hotstring.replacement
    case .afterDelimiter:
      guard isDelimiter(typed) else { return nil }
      let body = String(current.dropLast())
      guard let start = triggerStart(in: body, hotstring: hotstring) else { return nil }
      return String(body[..<start]) + hotstring.replacement + String(typed)
    }
  }

  /// Where the trigger starts if `text` ends with it and the word-boundary rule allows it.
  private static func triggerStart(in text: String, hotstring: Hotstring) -> String.Index? {
    let trigger = hotstring.trigger
    guard text.count >= trigger.count else { return nil }
    let start = text.index(text.endIndex, offsetBy: -trigger.count)
    let tail = text[start...]
    let matches = hotstring.caseSensitive ? tail == trigger : tail.lowercased() == trigger.lowercased()
    guard matches else { return nil }
    if hotstring.wordBoundary, start > text.startIndex, !isDelimiter(text[text.index(before: start)]) {
      return nil
    }
    return start
  }
}
