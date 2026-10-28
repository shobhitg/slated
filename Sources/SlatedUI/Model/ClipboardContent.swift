import Foundation
import SlatedCore

/// What a clipboard item looks like, so the switcher and settings can show it well: links get
/// their host, code a monospaced preview, colors a swatch.
enum ClipboardContentKind: String, CaseIterable, Hashable {
  case link, email, color, path, code, number, text

  var title: String {
    switch self {
    case .link: return "Link"
    case .email: return "Email Address"
    case .color: return "Color"
    case .path: return "File Path"
    case .code: return "Code"
    case .number: return "Number"
    case .text: return "Text"
    }
  }

  var symbol: String {
    switch self {
    case .link: return "link"
    case .email: return "envelope"
    case .color: return "paintpalette"
    case .path: return "folder"
    case .code: return "chevron.left.forwardslash.chevron.right"
    case .number: return "number"
    case .text: return "text.alignleft"
    }
  }

  /// Shown in a monospaced font.
  var isMonospaced: Bool { self == .code || self == .path || self == .color || self == .number }
}

enum ClipboardContent {
  static func kind(of text: String) -> ClipboardContentKind {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .text }
    let singleToken = !trimmed.contains(where: { $0.isWhitespace })
    if singleToken {
      if isColor(trimmed) { return .color }
      if isEmail(trimmed) { return .email }
      if isLink(trimmed) { return .link }
    }
    if isNumber(trimmed) { return .number }
    if trimmed.count > 1, trimmed.hasPrefix("/") || trimmed.hasPrefix("~/"), !trimmed.hasPrefix("//"),
      !trimmed.contains(where: \.isNewline)
    {
      return .path
    }
    return looksLikeCode(trimmed) ? .code : .text
  }

  static func isColor(_ s: String) -> Bool {
    guard s.hasPrefix("#") else { return false }
    let hex = s.dropFirst()
    return [3, 6, 8].contains(hex.count) && hex.allSatisfy(\.isHexDigit)
  }

  /// `#RRGGBB` (or `#RGB`, `#RRGGBBAA`) as sRGB components 0…1.
  static func rgba(_ s: String) -> (red: Double, green: Double, blue: Double, alpha: Double)? {
    guard isColor(s) else { return nil }
    var hex = String(s.dropFirst())
    if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
    guard let value = UInt64(hex, radix: 16) else { return nil }
    if hex.count == 8 {
      return (
        Double((value >> 24) & 0xFF) / 255, Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255,
        Double(value & 0xFF) / 255
      )
    }
    return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255, 1)
  }

  static func isEmail(_ s: String) -> Bool {
    s.range(of: #"^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
  }

  static func isLink(_ s: String) -> Bool {
    if s.lowercased().hasPrefix("www."), s.count > 6 { return true }
    guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return false }
    if ["http", "https", "ftp"].contains(scheme) { return url.host?.isEmpty == false }
    // App links like raycast://extensions or slack://open, but not "note:" or "C:".
    return s.contains("://") && scheme.count > 1
  }

  /// The part of a link worth showing: "github.com".
  static func host(of link: String) -> String? {
    let s = link.lowercased().hasPrefix("www.") ? "https://" + link : link
    return URL(string: s)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
  }

  static func isNumber(_ s: String) -> Bool {
    s.count <= 40 && s.range(of: #"^[+\-−]?[$€£¥]?\d[\d,. _']*%?$"#, options: .regularExpression) != nil
  }

  /// A rough guess good enough for picking a monospaced font: shell commands, JSON, programming
  /// languages and Slate expressions read as code; sentences and addresses don't.
  static func looksLikeCode(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
    guard let first = lines.first else { return false }
    var score = 0

    let shellWords = [
      "git", "swift", "npm", "npx", "yarn", "pnpm", "brew", "cd", "ls", "sudo", "curl", "wget", "make", "python",
      "python3", "pip", "node", "docker", "kubectl", "ssh", "scp", "cat", "echo", "export", "defaults", "open",
      "xcodebuild", "rm", "mv", "cp", "mkdir", "chmod", "grep", "find", "go", "cargo", "./", "$",
    ]
    let firstWord = first.split(separator: " ").first.map(String.init) ?? ""
    if shellWords.contains(firstWord) || first.hasPrefix("./") || first.hasPrefix("$ ") { score += 3 }
    if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
      score += 3
    }
    let operators = ["=>", "->", "::", "==", "!=", "&&", "||", ":=", "+=", "</", "/>"]
    if operators.contains(where: trimmed.contains) { score += 2 }
    if lines.contains(where: { line in
      let end = line.trimmingCharacters(in: .whitespaces).last
      return end == "{" || end == "}" || end == ";"
    }) {
      score += 2
    }
    // Declarations and imports at the start of a line (`let x =`, `func f(`, `import Foundation`).
    let declarations = [
      #"(?m)^\s*(let|var|const|val)\s+[A-Za-z_]\w*\s*[:=]"#, #"(?m)^\s*(func|def|fn|function)\s+[A-Za-z_]\w*\s*\("#,
      #"(?m)^\s*(import|#include|using|package)\s+[\w<."]"#,
      #"(?m)^\s*(class|struct|enum|interface|protocol)\s+[A-Z]\w*"#,
      #"\bSELECT\b.+\bFROM\b\s+\w+"#,
    ]
    if declarations.contains(where: { trimmed.range(of: $0, options: .regularExpression) != nil }) { score += 2 }
    if lines.count > 1, lines.filter({ $0.hasPrefix("  ") || $0.hasPrefix("\t") }).count >= max(1, lines.count / 3) {
      score += 2
    }
    // A call like `foo.bar(…)` or `print(x)`.
    if trimmed.range(of: #"[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*\([^)]*\)"#, options: .regularExpression)
      != nil
    {
      score += 1
    }
    // An expression without spaces mixing identifiers and operators: `screenOriginX+screenSizeX/2`.
    if !trimmed.contains(" "), trimmed.range(of: #"[A-Za-z_]\w*[+\-*/%^<>=]\w"#, options: .regularExpression) != nil {
      score += 2
    }
    // Prose: several words ending like a sentence.
    let words = trimmed.split(whereSeparator: \.isWhitespace).count
    if words >= 6, let last = trimmed.last, ".!?…".contains(last) { score -= 2 }
    return score >= 2
  }

  /// The text on one line, for list rows: line breaks become ⏎, runs of spaces collapse.
  static func singleLine(_ text: String, limit: Int = 240) -> String {
    let collapsed = text.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
      .joined(separator: " ⏎ ")
    return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
  }

  struct Stats: Equatable {
    var characters: Int
    var words: Int
    var lines: Int
  }

  static func stats(_ text: String) -> Stats {
    Stats(
      characters: text.count, words: text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count,
      lines: max(1, text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count))
  }

  /// An image as a row reads: "Image · 1280×720 · Safari".
  static func imageTitle(_ image: ClipboardImage, app: String?) -> String {
    (["Image", "\(image.width)×\(image.height)"] + (app.map { [$0] } ?? [])).joined(separator: " · ")
  }

  /// Under a preview: "1280×720 · 245 KB".
  static func imageDetails(_ image: ClipboardImage) -> String {
    "\(image.width)×\(image.height) · \(Int64(image.bytes).formatted(.byteCount(style: .file)))"
  }

  /// Display names for the password managers Slated excludes by default, which may not be installed.
  static let knownAppNames: [String: String] = [
    "com.1password.1password": "1Password",
    "com.agilebits.onepassword7": "1Password 7",
    "com.bitwarden.desktop": "Bitwarden",
    "com.apple.keychainaccess": "Keychain Access",
    "com.apple.Passwords": "Passwords",
    "com.lastpass.LastPass": "LastPass",
    "com.dashlane.dashlanephonefinal": "Dashlane",
  ]
}

/// Choices for the clipboard settings pickers. A hand-edited value that isn't one of them is kept
/// and shown as its own choice.
enum ClipboardOptions {
  static let maxItems = [50, 100, 200, 500, 1000]
  static let retentionDays = [1, 7, 30, 90, 0]

  static func retentionTitle(_ days: Int) -> String {
    switch days {
    case 0: return "Forever"
    case 1: return "1 day"
    case 7: return "1 week"
    default: return "\(days) days"
    }
  }
}

/// Choices for the automation time limit (minutes; 0 is no limit).
enum AutomationLimits {
  static let timeLimits: [Double] = [0, 1, 5, 15, 30, 60]

  static func timeLimitTitle(_ minutes: Double) -> String {
    switch minutes {
    case 0: return "No limit"
    case 60: return "1 hour"
    default:
      // Not `Int(minutes)`, which traps on what config.json can hold: 1e300, or JSON5 Infinity.
      let value: String
      if let whole = Int(exactly: minutes) {
        value = "\(whole)"
      } else if minutes.isInfinite {
        value = minutes < 0 ? "-∞" : "∞"
      } else if minutes == minutes.rounded() {
        value = String(format: "%g", minutes)  // too big for Int: 1e+300
      } else {
        value = String(format: "%.1f", minutes)
      }
      return "\(value) min"
    }
  }
}
