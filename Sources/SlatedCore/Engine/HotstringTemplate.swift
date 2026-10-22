import Foundation

/// Placeholders in hotstring replacements, Keyboard Maestro-style:
/// `{date}`, `{time}`, `{datetime}`, `{clipboard}`, and `{date:FORMAT}` with a Unicode date format
/// such as `{date:yyyy-MM-dd}`. Unknown placeholders are left untouched; `{{` and `}}` are literal braces.
public enum HotstringTemplate {
  public static func expand(_ text: String, now: Date = Date(), clipboard: String? = nil, locale: Locale = .current)
    -> String
  {
    guard text.contains("{") else { return text }
    var output = ""
    var i = text.startIndex
    while i < text.endIndex {
      let c = text[i]
      if c == "{", text[i...].hasPrefix("{{") {
        output.append("{")
        i = text.index(i, offsetBy: 2)
        continue
      }
      if c == "}", text[i...].hasPrefix("}}") {
        output.append("}")
        i = text.index(i, offsetBy: 2)
        continue
      }
      if c == "{", let close = text[i...].firstIndex(of: "}") {
        let token = String(text[text.index(after: i)..<close])
        if let value = value(for: token, now: now, clipboard: clipboard, locale: locale) {
          output += value
          i = text.index(after: close)
          continue
        }
      }
      output.append(c)
      i = text.index(after: i)
    }
    return output
  }

  private static func value(for token: String, now: Date, clipboard: String?, locale: Locale) -> String? {
    let formatter = DateFormatter()
    formatter.locale = locale
    switch token.lowercased() {
    case "date":
      formatter.dateStyle = .medium
      formatter.timeStyle = .none
      return formatter.string(from: now)
    case "time":
      formatter.dateStyle = .none
      formatter.timeStyle = .short
      return formatter.string(from: now)
    case "datetime":
      formatter.dateStyle = .medium
      formatter.timeStyle = .short
      return formatter.string(from: now)
    case "clipboard":
      return clipboard ?? ""
    default:
      guard token.lowercased().hasPrefix("date:") else { return nil }
      formatter.dateFormat = String(token.dropFirst("date:".count))
      return formatter.string(from: now)
    }
  }
}
