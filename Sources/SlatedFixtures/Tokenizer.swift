import Foundation

@testable import SlatedCore

private func tokensJ(_ tokens: [SlateToken]) -> J {
  .array(
    tokens.map {
      ["text": .string($0.text), "raw": .string($0.raw), "isQuoted": .bool($0.isQuoted), "column": .int($0.column)]
    })
}

private let tokenizeInputs: [String] = [
  "hi 'tokenize\t\t  \"me\"' path:'~/a b'c ''", "  \t ", "", "a 'b", "a \"b", "plain words here", "'single'",
  "\"double\"", "'it''s'", "a'b c'd", "'say \"hi\"'", "\"it's\"", "x'\"'y", "''", "\"\"", "'' ''", "a''b",
  "tab\tseparated\twords", "new\nline", "cr\r\nlf", "nbsp\u{00A0}space", "ideographic\u{3000}space",
  "zero\u{200B}width", "bom\u{FEFF}inside", "emoji 😀 👍🏽 🇺🇸", "e\u{301} é", "'unclosed \"inner\" text",
  "\"mixed 'quotes' ok\"", "a'''b'", "'a\"b'\"c'd\"", "  leading and trailing  ", "back\\slash 'no\\escape'",
  "'#' # hash", "a|b c>d", "path:'~/My Dir'", "'é' 'x\u{301}'",
]

private let leadingInputs: [(String, Int)] = [
  ("name 'App Name':OPTIONS push left | push right", 2), ("one", 2), ("", 2), ("a b c d", 0), ("a b c d", 1),
  ("a  b   c  d  ", 3), ("'quoted name' app   rest with  spaces  ", 2), ("a 'b", 2), ("a b 'c", 2),
  ("x\ty\nrest\n", 2), ("l BEFORE  shell path:~/ '/opt/local/bin/mvim before'", 2),
]

private let splitInputs: [(String, String)] = [
  ("a | 'b|c' > d", "|>"), ("push up|push down", "|"), ("push up | push down |", "|"), ("| push up", "|"),
  ("", "|"), ("   ", "|"), ("'iTerm','Google Chrome'", ","), ("'Apps, Inc.','Other'", ","), ("a,,b", ","),
  ("a 'b", ","), ("shell wait '/bin/sh -c \"ls | wc > /tmp/x\"' | undo", "|>"), ("a>b|c>d", "|>"),
  ("x \"y|z\" | w", "|"), ("one", "|"), ("trailing,", ","), (",leading", ","), ("a ; b ; c", ";"),
  ("IGNORE_FAIL,TITLE_ORDER='a,b',REPEAT", ","),
]

private let firstIndexInputs: [(String, Character)] = [
  ("'App Name':OPTIONS", ":"), ("App:OPTIONS", ":"), ("'A:B':REPEAT", ":"), ("NoColon", ":"), ("\"x:y\"", ":"),
  ("TITLE_ORDER='a=b'", "="), ("'k=v'=x", "="), ("", ":"), ("é:x", ":"), ("'unclosed:", ":"),
]

private let quoteInputs: [String] = [
  "plain", "with space", "it's", "say \"hi\"", "both ' and \"", "'\"'\"", "", "a|b", "x#y", "screenSizeX/2",
  "a b", "a,b", "a>b", "tab\there", "new\nline", "'", "\"", "''", "it's \"quoted\" and 'more'", "émoji 😀",
  "nbsp\u{00A0}x", "zero\u{200B}width", "Bob's \"Best\" App", "a\"b'c\"d'e", "   ", "'quoted'", "\"dq\"",
]

private let unquoteInputs: [String] = [
  "'Google Chrome'", "Google Chrome", "'a'b", "'unclosed", "  'x'  ", "''", "'a' 'b'", "\"it's\"", "plain",
  "'a''b'", "", "'a\"b'\"c'd\"",
]

private let shellInputs: [String] = [
  "/bin/echo 'with single' \"and double quotes\"", "/usr/bin/say hello world", "/usr/bin/say \"hello world\"",
  "  spaced   out  ", "", "open -a 'Google Chrome'", "/bin/sh -c 'echo $HOME | wc'", "unclosed 'quote", "a''b",
  "tab\tsep", "it'\"'\"'s",
]

private let escapeInputs: [String] = [
  "line 1\nline 2\tend\\", "C:\\dir", "plain", "", "\r\n", "back\\\\slash", "\\n literal", "trailing\\",
  "¯\\_(ツ)_/¯", "tab\there", "\\q unknown", "\\", "\\\\", "a\\nb\\tc\\rd", "😀\\n",
]

/// Code points that some definition or other counts as space, to pin Foundation's CharacterSet
/// trimming and Swift's Character properties.
private let spaceLikeCodePoints: [UInt32] =
  [0x00, 0x01, 0x08] + Array(0x09...0x0D) + Array(0x1C...0x20) + [0x7F, 0x85, 0xA0, 0x1680, 0x180E]
  + Array(0x2000...0x200F) + [0x2028, 0x2029, 0x202F, 0x205F, 0x2060, 0x3000, 0xFEFF, 0x61]

func tokenizerFixtures() -> FixtureFile {
  let trimming: [J] = spaceLikeCodePoints.map { value in
    let c = Character(Unicode.Scalar(value)!)
    let text = "\(c)x\(c)"
    return [
      "codePoint": .int(Int(value)),
      "whitespaces": .bool(text.trimmingCharacters(in: .whitespaces) == "x"),
      "whitespacesAndNewlines": .bool(text.trimmingCharacters(in: .whitespacesAndNewlines) == "x"),
      "isWhitespace": .bool(c.isWhitespace), "isNewline": .bool(c.isNewline),
    ]
  }
  let tokenize: [J] = tokenizeInputs.map { input in
    .object(
      ["input": .string(input)].merging(outcome("tokens") { tokensJ(try SlateTokenizer.tokenize(input)) }) { a, _ in a }
    )
  }
  let leading: [J] = leadingInputs.map { input, count in
    var item: [String: J] = ["input": .string(input), "count": .int(count)]
    do {
      let (tokens, rest) = try SlateTokenizer.leadingTokens(input, count: count)
      item["tokens"] = tokensJ(tokens)
      item["rest"] = .string(rest)
    } catch {
      item["error"] = errorJ(error)
    }
    return .object(item)
  }
  let split: [J] = splitInputs.map { input, separators in
    var item: [String: J] = ["input": .string(input), "separators": .string(separators)]
    item.merge(
      outcome("pieces") {
        .array(
          try SlateTokenizer.split(input, separators: Set(separators)).map {
            ["separator": .optional($0.separator.map(String.init)), "text": .string($0.text)]
          })
      }
    ) { a, _ in a }
    return .object(item)
  }
  let firstIndex: [J] = firstIndexInputs.map { input, character in
    let index = SlateTokenizer.firstIndex(of: character, outsideQuotesIn: input)
    return [
      "input": .string(input), "character": .string(String(character)),
      // Position in characters (grapheme clusters), so it means the same in JavaScript.
      "index": index.map { .int(input.distance(from: input.startIndex, to: $0)) } ?? .null,
    ]
  }
  let quote: [J] = quoteInputs.map { input in
    [
      "input": .string(input), "quoted": .string(SlateTokenizer.quote(input)),
      "quotedIfNeeded": .string(SlateTokenizer.quoteIfNeeded(input)),
    ]
  }
  let unquote: [J] = unquoteInputs.map { ["input": .string($0), "unquoted": .string(SlateTokenizer.unquote($0))] }
  let shell: [J] = shellInputs.map { input in
    .object(
      ["input": .string(input)].merging(
        outcome("arguments") { .array(try SlateSyntax.shellArguments(input).map(J.string)) }
      ) {
        a, _ in a
      })
  }
  let escape: [J] = escapeInputs.map {
    [
      "input": .string($0), "escaped": .string(SlateSyntax.escapeText($0)),
      "unescaped": .string(SlateSyntax.unescapeText($0)),
    ]
  }
  return FixtureFile(
    name: "tokenizer.json",
    description:
      "Slate operation-syntax words: SlateTokenizer.tokenize/leadingTokens/split/firstIndex/quote/quoteIfNeeded/"
      + "unquote, SlateSyntax.shellArguments and the insert-text escapes. Columns and indexes count characters "
      + "(grapheme clusters).",
    sections: [
      "tokenize": tokenize, "leadingTokens": leading, "split": split, "firstIndexOutsideQuotes": firstIndex,
      "quote": quote, "unquote": unquote, "shellArguments": shell, "escapeText": escape, "trimming": trimming,
    ])
}
