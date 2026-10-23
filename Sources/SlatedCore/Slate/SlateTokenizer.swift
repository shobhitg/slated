import Foundation

/// One word of Slate operation syntax.
///
/// Whitespace separates words. `'…'` and `"…"` quote a stretch of text (spaces included) and the quote
/// marks are dropped; the other kind of quote is literal inside, so `'say "hi"'` is `say "hi"` (Slate
/// 1.0.15+). Quoted stretches join the text around them, as in a shell: `path:'~/My Dir'` is one word,
/// `path:~/My Dir`. There are no backslash escapes, matching Slate.
struct SlateToken: Equatable {
  /// The word with quote marks removed.
  var text: String
  /// The word exactly as written.
  var raw: String
  /// True when any part of the word was quoted (so `'left'` is an app name, not a direction).
  var isQuoted: Bool
  /// 1-based column of the word's first character.
  var column: Int
}

enum SlateTokenizer {
  static let quoteCharacters: Set<Character> = ["'", "\""]

  /// Splits `string` into words. Throws when a quote is never closed.
  static func tokenize(_ string: String) throws -> [SlateToken] {
    try leadingTokens(string, count: .max).tokens
  }

  /// The first `count` words of `string`, plus the rest of the string (trimmed) after them, unparsed.
  static func leadingTokens(_ string: String, count: Int) throws -> (tokens: [SlateToken], rest: String) {
    let chars = Array(string)
    var tokens: [SlateToken] = []
    var i = 0
    while i < chars.count, tokens.count < count {
      if chars[i].isWhitespace {
        i += 1
        continue
      }
      let start = i
      var text = ""
      var quoted = false
      var quote: Character?
      var quoteColumn = 0
      while i < chars.count {
        let c = chars[i]
        if let open = quote {
          if c == open { quote = nil } else { text.append(c) }
        } else if c.isWhitespace {
          break
        } else if quoteCharacters.contains(c) {
          quote = c
          quoted = true
          quoteColumn = i + 1
        } else {
          text.append(c)
        }
        i += 1
      }
      if let open = quote {
        throw SlatedError.invalidSyntax(
          "Missing closing \(open) for the quote at column \(quoteColumn) in \"\(string)\"")
      }
      tokens.append(SlateToken(text: text, raw: String(chars[start..<i]), isQuoted: quoted, column: start + 1))
    }
    let rest = String(chars[Swift.min(i, chars.count)...]).trimmingCharacters(in: .whitespacesAndNewlines)
    return (tokens, rest)
  }

  /// One piece of a string split at separator characters.
  struct Piece: Equatable {
    /// The separator before this piece; nil for the first piece.
    var separator: Character?
    /// The piece's text, trimmed, quotes left in place.
    var text: String
  }

  /// Splits `string` at any of `separators` that are outside quotes, e.g. `|` between chained operations
  /// or `,` between app names. Throws when a quote is never closed.
  static func split(_ string: String, separators: Set<Character>) throws -> [Piece] {
    var pieces: [Piece] = []
    var current = ""
    var separator: Character?
    var quote: Character?
    var quoteColumn = 0
    for (index, c) in string.enumerated() {
      if let open = quote {
        if c == open { quote = nil }
        current.append(c)
      } else if separators.contains(c) {
        pieces.append(Piece(separator: separator, text: current.trimmingCharacters(in: .whitespacesAndNewlines)))
        current = ""
        separator = c
      } else {
        if quoteCharacters.contains(c) {
          quote = c
          quoteColumn = index + 1
        }
        current.append(c)
      }
    }
    if let open = quote {
      throw SlatedError.invalidSyntax("Missing closing \(open) for the quote at column \(quoteColumn) in \"\(string)\"")
    }
    pieces.append(Piece(separator: separator, text: current.trimmingCharacters(in: .whitespacesAndNewlines)))
    return pieces
  }

  /// Index of the first `character` outside quotes, if any.
  static func firstIndex(of character: Character, outsideQuotesIn string: String) -> String.Index? {
    var quote: Character?
    var index = string.startIndex
    while index < string.endIndex {
      let c = string[index]
      if let open = quote {
        if c == open { quote = nil }
      } else if c == character {
        return index
      } else if quoteCharacters.contains(c) {
        quote = c
      }
      index = string.index(after: index)
    }
    return nil
  }

  /// Removes quoting from a single word: `'Google Chrome'` → `Google Chrome`. Text that isn't exactly one
  /// word (or has an unclosed quote) is returned trimmed but otherwise unchanged.
  static func unquote(_ string: String) -> String {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let tokens = try? tokenize(trimmed), tokens.count == 1, tokens[0].raw == trimmed else { return trimmed }
    return tokens[0].text
  }

  /// Quotes `string` so `tokenize` reads it back as exactly one word with the same text. Uses `'…'`, or
  /// `"…"` when the text contains `'`, or adjacent quoted pieces when it contains both kinds.
  static func quote(_ string: String) -> String {
    if !string.contains("'") { return "'\(string)'" }
    if !string.contains("\"") { return "\"\(string)\"" }
    var result = ""
    var piece = ""
    var pieceHasSingle = false
    var pieceHasDouble = false
    func flush() {
      guard !piece.isEmpty else { return }
      result += pieceHasSingle ? "\"\(piece)\"" : "'\(piece)'"
      piece = ""
      pieceHasSingle = false
      pieceHasDouble = false
    }
    for c in string {
      if (c == "'" && pieceHasDouble) || (c == "\"" && pieceHasSingle) { flush() }
      if c == "'" { pieceHasSingle = true }
      if c == "\"" { pieceHasDouble = true }
      piece.append(c)
    }
    flush()
    return result
  }

  /// Characters that force quoting in `quoteIfNeeded`: word and operation separators, quotes, and `#`
  /// (a comment in `.slate` files).
  private static let specialCharacters: Set<Character> = ["'", "\"", "|", ">", "#", ","]

  /// `string` as-is when it reads back as one word with the same text, otherwise quoted.
  static func quoteIfNeeded(_ string: String) -> String {
    if string.isEmpty || string.contains(where: { $0.isWhitespace || specialCharacters.contains($0) }) {
      return quote(string)
    }
    return string
  }
}
