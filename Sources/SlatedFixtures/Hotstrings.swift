import Foundation

@testable import SlatedCore

private func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

private func hs(
  _ n: Int, _ trigger: String, _ replacement: String = "x", enabled: Bool = true, caseSensitive: Bool = true,
  fire: Hotstring.Fire = .immediately, wordBoundary: Bool = false, only: [String] = [], except: [String] = []
) -> Hotstring {
  Hotstring(
    id: uuid(n), trigger: trigger, replacement: replacement, enabled: enabled, caseSensitive: caseSensitive, fire: fire,
    wordBoundary: wordBoundary, onlyInApps: only, exceptInApps: except)
}

/// One step of a typing session.
private enum Step {
  /// Feed this text as one key event (usually one character).
  case feed(String, app: String? = nil)
  /// Feed each character of the text as its own key event.
  case type(String, app: String? = nil)
  case backspace
  case reset
  case update([Hotstring])
}

private struct Session {
  var name: String
  var hotstrings: [Hotstring]
  var steps: [Step]
}

private let sessions: [Session] = [
  // From HotstringMatcherTests
  Session(
    name: "fires immediately on the last trigger character", hotstrings: [hs(1, ";shrug", "¯\\_(ツ)_/¯")],
    steps: [.type("hello ;shrug")]),
  Session(
    name: "waits for a delimiter and keeps it", hotstrings: [hs(1, "brb", "be right back", fire: .afterDelimiter)],
    steps: [.type("brb"), .feed(" ")]),
  Session(
    name: "respects word boundaries", hotstrings: [hs(1, "teh", "the", fire: .afterDelimiter, wordBoundary: true)],
    steps: [.type("pteh "), .type(" teh ")]),
  Session(name: "case sensitive", hotstrings: [hs(1, "Sig")], steps: [.type("sig"), .type("Sig")]),
  Session(
    name: "case insensitive", hotstrings: [hs(1, "Sig", caseSensitive: false)], steps: [.type("SIG"), .type("sIg")]),
  Session(
    name: "backspace edits the buffer", hotstrings: [hs(1, "abc")], steps: [.type("abx"), .backspace, .type("c")]),
  Session(
    name: "longest trigger wins and app filters apply",
    hotstrings: [
      hs(1, "ab", "short", fire: .afterDelimiter), hs(2, "xab", "long", fire: .afterDelimiter),
      hs(3, "zz", "only mail", only: ["com.apple.mail"]),
    ],
    steps: [.type("xab "), .type("zz", app: "com.apple.Safari"), .type("zz", app: "com.apple.mail")]),
  Session(
    name: "disabled hotstrings and resets", hotstrings: [hs(1, "abc", enabled: false), hs(2, "def")],
    steps: [.type("abc"), .type("de"), .reset, .type("f")]),
  // Delimiters
  Session(
    name: "delimiters that complete afterDelimiter triggers", hotstrings: [hs(1, "brb", fire: .afterDelimiter)],
    steps: [
      .type("brb"), .feed("\n"), .type("brb"), .feed("."), .type("brb"), .feed(","), .type("brb"), .feed("!"),
      .type("brb"), .feed("-"), .type("brb"), .feed("("), .type("brb"), .feed("$"), .type("brb"), .feed("+"),
      .type("brb"), .feed("_"), .reset, .type("brb"), .feed("'"), .type("brb"), .feed("\t"), .type("brb"),
      .feed("\r\n"), .type("brb"), .feed("é"), .reset, .type("brb"), .feed("€"), .type("brb"), .feed("😀"),
      .type("brb"), .feed("\u{00A0}"), .type("brb"), .feed("\u{200B}"), .reset, .type("brb"), .feed("1"), .reset,
      .type("brb"), .feed("\u{2028}"), .type("brb"), .feed("|"), .type("brb"), .feed("~"), .type("brb"), .feed("^"),
      .type("brb"), .feed("`"), .type("brb"), .feed("\u{3000}"), .type("brb"), .feed("¿"), .type("brb"), .feed("«"),
    ]),
  Session(
    name: "word boundary at the start and after delimiters",
    hotstrings: [hs(1, "omw", "on my way", wordBoundary: true)],
    steps: [
      .type("omw"), .type("xomw"), .type(" omw"), .type("(omw"), .type("_omw"), .type("1omw"), .type("éomw"),
      .type("😀omw"),
    ]),
  Session(
    name: "case-insensitive unicode",
    hotstrings: [hs(1, "Éa", caseSensitive: false), hs(2, "straße", caseSensitive: false)],
    steps: [.type("éA"), .type("ÉA"), .type("STRASSE"), .type("STRAßE"), .type("Straße")]),
  Session(
    name: "equal-length triggers: the first one wins",
    hotstrings: [hs(1, "ab", "first"), hs(2, "ab", "second"), hs(3, "b", "short")],
    steps: [.type("ab"), .type("b")]),
  Session(
    name: "exceptInApps and a missing app",
    hotstrings: [
      hs(1, "aa", except: ["com.apple.Terminal"]), hs(2, "bb", only: ["com.apple.mail"]),
      hs(3, "cc", only: ["x"], except: ["x"]),
    ],
    steps: [
      .type("aa", app: "com.apple.Terminal"), .type("aa", app: nil), .type("aa", app: "com.apple.mail"),
      .type("bb", app: nil),
      .type("bb", app: "com.apple.mail"), .type("cc", app: "x"),
    ]),
  Session(
    name: "empty triggers are ignored", hotstrings: [hs(1, ""), hs(2, "q")], steps: [.feed(""), .type("q"), .feed("a")]),
  Session(
    name: "update shrinks the buffer", hotstrings: [hs(1, "abcdef")],
    steps: [.type("xyzab"), .update([hs(2, "ab"), hs(3, "zab")]), .type("c"), .type("zab"), .update([]), .type("ab")]),
  Session(
    name: "backspace on an empty buffer", hotstrings: [hs(1, "ab")], steps: [.backspace, .backspace, .type("ab")]),
  Session(
    name: "several characters in one key event", hotstrings: [hs(1, "abc"), hs(2, "xy", fire: .afterDelimiter)],
    steps: [.feed("zabcxy "), .feed("xy"), .feed(" more"), .feed("xy z")]),
  Session(
    name: "the buffer only keeps what matching needs", hotstrings: [hs(1, "abc", wordBoundary: true)],
    steps: [.type("zzzzzzzabc"), .type(" abc"), .type("qq"), .backspace, .backspace, .backspace, .type("abc")]),
  Session(
    name: "a trigger that ends with a delimiter", hotstrings: [hs(1, "a.", fire: .afterDelimiter), hs(2, "b.")],
    steps: [.type("a."), .feed(" "), .type("b.")]),
  Session(
    name: "afterDelimiter is checked before immediate",
    hotstrings: [hs(1, "x ", "immediate"), hs(2, "x", "delimited", fire: .afterDelimiter)],
    steps: [.type("x "), .type("yx"), .feed(" ")]),
  Session(
    name: "deleteCount counts characters",
    hotstrings: [hs(1, "é😀"), hs(2, "👍🏽!", fire: .afterDelimiter), hs(3, "e\u{301}x")],
    steps: [.type("é😀"), .type("👍🏽!"), .feed(" "), .type("e\u{301}x"), .type("éx")]),
  Session(
    name: "delimiters right after a match", hotstrings: [hs(1, "hi", fire: .afterDelimiter, wordBoundary: true)],
    steps: [.type("hi"), .feed(" "), .feed(" "), .type("hi."), .type("hi"), .feed("?")]),
  Session(
    name: "only afterDelimiter triggers", hotstrings: [hs(1, "ty", fire: .afterDelimiter)],
    steps: [.type("ty"), .reset, .feed(" "), .type("tyty"), .feed(" "), .type("t"), .backspace, .type("ty;")]),
]

private func matchJ(_ match: HotstringMatch?) -> J {
  guard let match else { return .null }
  return [
    "id": .string(match.hotstring.id.uuidString), "trigger": .string(match.hotstring.trigger),
    "deleteCount": .int(match.deleteCount), "delimiter": .optional(match.delimiter),
  ]
}

private let delimiterCharacters: [String] = [
  " ", "\t", "\n", "\r", "\r\n", ".", ",", ";", ":", "!", "?", "'", "\"", "-", "_", "(", ")", "[", "]", "{", "}", "/",
  "\\", "@", "#", "$", "%", "^", "&", "*", "+", "=", "<", ">", "|", "~", "`", "a", "Z", "0", "9", "é", "e\u{301}",
  "€", "£", "😀", "👍🏽", "🇺🇸", "\u{00A0}", "\u{200B}", "\u{2028}", "\u{3000}", "¿", "«", "»", "–", "—", "…", "©", "°",
  "×", "÷", "√", "∞", "中", "١", "²", "½", "\u{0301}", "\u{FEFF}", "\u{85}", "\u{0B}", "\u{0C}", "\u{7F}", "\u{1F}",
]

private let templateDates: [(String, Double)] = [
  ("2026-10-26T07:33:20Z", 1_793_000_000), ("2026-10-22T15:04:05.678Z", 1_792_681_445.678),
  ("2000-02-29T00:00:00Z", 951_782_400), ("2024-12-30T12:00:00Z", 1_735_560_000),
  ("2026-03-01T00:30:00Z", 1_772_325_000),
  ("2026-06-15T12:00:00Z", 1_781_524_800), ("1969-12-31T23:00:00Z", -3600),
  ("2027-01-03T09:05:09.004Z", 1_799_053_509.004),
  // Around 1970, where ICU starts calling UTC "Greenwich Mean Time".
  ("1970-01-01T00:00:00Z", 0), ("1969-12-31T23:59:59.999Z", -0.001), ("1920-01-01T00:00:00Z", -1_577_923_200),
]

private let templates: [String] = [
  "{date}", "{time}", "{datetime}", "{DATE}", "{Time}", "{clipboard}", "paste: {clipboard}", "{CLIPBOARD}",
  "{date:yyyy-MM-dd}", "on {date:yyyy-MM-dd}", "{date:EEEE, MMMM d, y}", "{date:HH:mm:ss.SSS}", "{date:h:mm a}",
  "{date:'week' w 'of' YYYY}", "{date:QQQ QQQQ Q QQ}", "{date:D DD DDD}", "{date:E EE EEE EEEE EEEEE EEEEEE}",
  "{date:M MM MMM MMMM MMMMM}", "{date:L LL LLL LLLL LLLLL}", "{date:d dd}", "{date:k kk K KK h hh H HH}", "{date:a}",
  "{date:G GGGG GGGGG}", "{date:y yy yyy yyyy yyyyy}", "{date:Z ZZ ZZZ ZZZZ ZZZZZ}", "{date:z zz zzz zzzz}",
  "{date:x xx xxx X XX XXX}", "{date:O OOOO}", "{date:'literal' ''}", "{date:o''clock}",
  "{date:e ee eee eeee c ccc cccc}",
  "{date:W F}", "{date:A}", "{date:S SS SSSS}", "{date:u}", "{date:m mm s ss}", "{date:yyyy-MM-dd'T'HH:mm:ssZZZZZ}",
  "{date:dd.MM.yy}", "{date:'It''s' h 'o''clock'}", "{date:Y YY YYYY w ww}", "{date:}", "{date:'}",
  "{date:q qq qqq qqqq}",
  "{unknown} {{braces}}", "no placeholders", "{date", "date}", "{}", "{{}}", "}}{{", "{ date }",
  "{clipboard}{clipboard}",
  "{a{date:yyyy}}", "{{date}}", "only }} closing", "😀{date:yyyy}😀", "{date:yyyy}{time}{{x}}", "{datetime:x}",
  "{date:yyyy}}", "{{{date:yyyy}}}", "text {", "text }", "{date:MMMM}{date:LLLL}", "{date:EEEEE}{date:MMMMM}",
]

func hotstringFixtures() -> FixtureFile {
  var matcher: [J] = []
  for session in sessions {
    var m = HotstringMatcher(hotstrings: session.hotstrings)
    var steps: [J] = []
    for step in session.steps {
      switch step {
      case .feed(let text, let app):
        steps.append(["feed": .string(text), "app": .optional(app), "match": matchJ(m.feed(text, appBundleID: app))])
      case .type(let text, let app):
        for c in text {
          steps.append([
            "feed": .string(String(c)), "app": .optional(app), "match": matchJ(m.feed(String(c), appBundleID: app)),
          ])
        }
      case .backspace:
        m.backspace()
        steps.append(["backspace": true])
      case .reset:
        m.reset()
        steps.append(["reset": true])
      case .update(let hotstrings):
        m.update(hotstrings)
        steps.append(["update": toJ(hotstrings)])
      }
    }
    matcher.append(["name": .string(session.name), "hotstrings": toJ(session.hotstrings), "steps": .array(steps)])
  }

  let delimiters: [J] = delimiterCharacters.map { text in
    precondition(text.count == 1)
    return ["character": .string(text), "delimiter": .bool(HotstringMatcher.isDelimiter(text.first!))]
  }

  let posix = Locale(identifier: "en_US_POSIX")
  var expansions: [J] = []
  for (label, seconds) in templateDates {
    let date = Date(timeIntervalSince1970: seconds)
    for template in templates {
      for clipboard in (template.lowercased().contains("clipboard") ? ["hi {date} there", nil] : [nil]) as [String?] {
        expansions.append([
          "text": .string(template), "date": .string(label), "now": .number(seconds), "clipboard": .optional(clipboard),
          "result": .string(HotstringTemplate.expand(template, now: date, clipboard: clipboard, locale: posix)),
        ])
      }
    }
  }

  return FixtureFile(
    name: "hotstrings.json",
    description:
      "HotstringMatcher typing sessions (the match after every key event, null when none), which characters are "
      + "delimiters, and HotstringTemplate.expand with fixed dates (`now` in seconds since 1970), locale en_US_POSIX "
      + "and time zone UTC.",
    sections: ["matcher": matcher, "isDelimiter": delimiters, "templates": expansions],
    extra: ["locale": "en_US_POSIX", "timeZone": "UTC"],
    depth: ["matcher": 3])
}
