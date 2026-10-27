import Foundation

/// Takes private text out of an error message before it's logged (slated.log and the unified log, where
/// it's public). Settings and the menu still show the whole message.
///
/// - The text an `insert-text` action types: a parse error quotes the operation, and its hint repeats
///   the text, so everything from "insert-text" on is left out. A config.json location at the end
///   ("(at bindings[0].action)") stays.
/// - Values JavaScriptCore puts in a TypeError, such as a window title:
///   `w.title() is not a function. (In 'w.title()()', 'w.title()' is "Inbox – a mail subject")`. Its
///   "(In …)" part goes, and so do quoted strings (`"…" is not a constructor`).
nonisolated enum LogPrivacy {
  static func message(_ text: String) -> String {
    var text = text
    if let start = text.range(of: "insert-text", options: .caseInsensitive) {
      let location = text.range(of: #" \(at [A-Za-z0-9_.\[\]]+\)$"#, options: .regularExpression).map {
        String(text[$0])
      }
      text = String(text[..<start.upperBound]) + " …" + (location ?? "")
    }
    if let typeError = text.range(of: "TypeError: ") {
      if let suffix = text.range(of: " (In '", range: typeError.upperBound..<text.endIndex) {
        text.removeSubrange(suffix.lowerBound...)
      }
      if let typeError = text.range(of: "TypeError: "),
        let first = text.range(of: "\"", range: typeError.upperBound..<text.endIndex)
      {
        let last = text.range(of: "\"", options: .backwards, range: first.upperBound..<text.endIndex)
        text.replaceSubrange(first.lowerBound..<(last?.upperBound ?? text.endIndex), with: "\"…\"")
      }
    }
    return text
  }
}
