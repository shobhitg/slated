import Foundation

@testable import SlatedCore

// Game automation (Automation.swift, RepeatSchedule.swift) and clipboard history (ClipboardHistory.swift):
// the parts of SlatedCore the GNOME extension's automation engine and clipboard switcher run on.

private func uuid(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))! }

/// `SyntheticInput(string:)`: the `input` of `press` and `hold`.
private let syntheticInputs: [String] = [
  "mouse:left", "mouse:right", "mouse:middle", "MOUSE:LEFT", "Mouse:Right", " mouse:left ", "\tmouse:middle\t",
  "mouse:", "mouse:back", "mouse:4", "mouse: left", "mouse:left:right", "mouse", "key:w", "key:W", "KEY:w", "Key:Shift",
  "key:shift", "key:ctrl", "key:alt", "key:cmd", "key:rightShift", "key:rightshift", "key:RIGHTCTRL", "key:rightAlt",
  "key:rightCmd", "key:shift+w", "key:ctrl+shift+w", "key:hyper+a", "key:meh+x", "key:fn+f1", "key:space", "key:f13",
  "key:f24", "key:esc", "key:escape", "key:'", "key:,", "key:+", "key:cmd++", "key:pad+", "key:mouse4", "key:",
  "key: w",
  "key:w ", "key:ab", "key:bogus", "key:hyper", "key:é", "key:É", "key:👍🏽", "key:+w", "key:shift+", "key:ctrl+bogus",
  "key:bogus+w", "key:return", "key:Enter", "key:#", "key:|", "w", "", "  ", "key", "keyboard:w", "button:left",
  "key:w,a",
]

/// `RepeatSchedule(interval:times:jitter:)` inputs, including the clamps and non-finite values.
private let schedules: [(interval: Double, times: Int?, jitter: Double)] = [
  (0.1, nil, 0), (0.1, 50, 0), (0.05, nil, 0.1), (1, 3, 0.5), (2.5, 1, 0.25), (0.3, 7, 0.1), (0.01, nil, 0.5),
  (0.005, nil, 0), (0, nil, 0), (-1, nil, 0), (.nan, nil, 0), (.infinity, nil, 0), (-.infinity, 2, 0.2), (0.1, 0, 0),
  (0.1, -5, 0), (0.1, nil, 0.7), (0.1, nil, -0.2), (0.1, nil, .nan), (0.1, nil, .infinity), (1e-9, 2, 0.5),
  (1000, nil, 0.5), (0.1, nil, 0.123456789), (0.07, 100, 0.33),
]
private let randoms: [Double] = [0, 0.25, 0.5, 0.75, 1, -0.5, 1.5, .nan, 0.123456789, 0.999999]
private let runCounts: [Int] = [0, 1, 2, 3, 6, 7, 49, 50, 51, 99, 100, 101]

/// Actions for `Action.isAutomation`, in Slate syntax.
private let automationActions: [String] = [
  "click", "click right 2", "press key:w down", "hold mouse:right", "repeat 0.1 'click left'", "wait 1",
  "stop-automations", "clipboard-history", "keystroke e", "insert-text 'x'", "push left", "undo",
  "sequence press key:w down | wait 2 | press key:w up", "chain hold key:w | stop-automations",
]

func automationFixtures() -> FixtureFile {
  let inputs: [J] = syntheticInputs.map { raw in
    ["input": .string(raw), "string": SyntheticInput(string: raw).map { .string($0.string) } ?? .null]
  }
  let repeatSchedule: [J] = schedules.map { input in
    let schedule = RepeatSchedule(interval: input.interval, times: input.times, jitter: input.jitter)
    return [
      "interval": .number(input.interval), "times": input.times.map(J.int) ?? .null, "jitter": .number(input.jitter),
      "normalized": [
        "interval": .number(schedule.interval), "times": schedule.times.map(J.int) ?? .null,
        "jitter": .number(schedule.jitter),
      ],
      "shouldRunAgain": .array(
        runCounts.map { ["runs": .int($0), "again": .bool(schedule.shouldRunAgain(afterRuns: $0))] }),
      "nextInterval": .array(
        randoms.map { ["random": .number($0), "wait": .number(schedule.nextInterval(random: $0))] }),
    ]
  }
  let isAutomation: [J] = automationActions.map { text in
    let action = try! SlateSyntax.parseOperation(text)
    return ["action": actionJ(action), "isAutomation": .bool(action.isAutomation), "name": .string(action.name)]
  }
  return FixtureFile(
    name: "automation.json",
    description:
      "Game automation: SyntheticInput(string:) (the input of press and hold, as its canonical string or null), "
      + "RepeatSchedule (clamped interval/times/jitter, shouldRunAgain(afterRuns:), nextInterval(random:) for fixed "
      + "random values), and Action.isAutomation.",
    sections: ["syntheticInputs": inputs, "repeatSchedule": repeatSchedule, "isAutomation": isAutomation],
    depth: ["repeatSchedule": 2])
}

// MARK: - Clipboard history

/// A date as Swift stores it: seconds since 2001-01-01 (`timeIntervalSinceReferenceDate`).
private func at(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

private let day: Double = 86_400
private let t0: Double = 800_000_000

/// One step of a clipboard session. Items are named by text (images by file); ids Swift generates are
/// random.
private enum ClipStep {
  case add(String, app: String? = nil, at: Double, limit: Int = 200)
  case addImage(
    String, width: Int = 64, height: Int = 32, bytes: Int = 900, app: String? = nil, at: Double, limit: Int = 200)
  case enforce(Int)
  case prune(days: Int, now: Double)
  /// Removes or pins the item with this text, or the image with this file (by its current id).
  case remove(String)
  case togglePin(String)
  /// An id that isn't in the history.
  case removeUnknown
  case togglePinUnknown
  case clear(keepPinned: Bool?)
  case search(String)
}

private struct ClipSession {
  var name: String
  var start: [ClipboardItem] = []
  var steps: [ClipStep]
}

private func item(_ n: Int, _ text: String, at seconds: Double, app: String? = nil, pinned: Bool = false)
  -> ClipboardItem
{
  ClipboardItem(id: uuid(n), text: text, copiedAt: at(seconds), sourceApp: app, pinned: pinned)
}

private let clipSessions: [ClipSession] = [
  ClipSession(
    name: "newest first, with the source app",
    steps: [
      .add("first", app: "org.gnome.TextEditor", at: t0), .add("second", at: t0 + 1),
      .add("third", app: "firefox", at: t0 + 2),
    ]),
  ClipSession(
    name: "empty and whitespace-only copies aren't kept",
    steps: [
      .add("", at: t0), .add("   ", at: t0), .add("\n\t \r\n", at: t0), .add("\u{00A0}\u{2028}\u{3000}", at: t0),
      .add("\u{200B}", at: t0), .add(" x ", at: t0 + 1), .add("\u{FEFF}", at: t0 + 2),
    ]),
  ClipSession(
    name: "copying something again moves it to the top with a new date",
    steps: [
      .add("a", app: "one", at: t0), .add("b", at: t0 + 1), .add("c", at: t0 + 2), .add("a", app: "two", at: t0 + 3),
      .add("b", at: t0 + 4),
    ]),
  ClipSession(
    name: "a re-copied pinned item stays pinned",
    steps: [.add("keep", at: t0), .add("other", at: t0 + 1), .togglePin("keep"), .add("keep", at: t0 + 2)]),
  ClipSession(
    name: "duplicates compare as Swift strings (canonical equivalence)",
    steps: [
      .add("caf\u{E9}", at: t0), .add("cafe\u{301}", at: t0 + 1), .add("Café", at: t0 + 2), .add("CAFÉ", at: t0 + 3),
      .add("x ", at: t0 + 4), .add("x", at: t0 + 5),
    ]),
  ClipSession(
    name: "the limit drops the oldest unpinned items",
    steps: [
      .add("1", at: t0, limit: 3), .add("2", at: t0 + 1, limit: 3), .add("3", at: t0 + 2, limit: 3),
      .add("4", at: t0 + 3, limit: 3), .togglePin("2"), .add("5", at: t0 + 4, limit: 3),
      .add("6", at: t0 + 5, limit: 3),
      .enforce(1), .enforce(0), .enforce(-4), .add("7", at: t0 + 6, limit: 0),
    ]),
  ClipSession(
    name: "pinned items survive every limit",
    start: [
      item(1, "p1", at: t0, pinned: true), item(2, "u1", at: t0 + 1), item(3, "p2", at: t0 + 2, pinned: true),
      item(4, "u2", at: t0 + 3),
    ],
    steps: [.enforce(1), .add("u3", at: t0 + 4, limit: 1), .enforce(5)]),
  ClipSession(
    name: "retention forgets old unpinned items",
    start: [
      item(1, "fresh", at: t0 + 29 * day), item(2, "edge", at: t0), item(3, "old", at: t0 - 1),
      item(4, "old pinned", at: t0 - 100 * day, pinned: true), item(5, "ancient", at: t0 - 365 * day),
    ],
    steps: [
      .prune(days: 0, now: t0 + 30 * day), .prune(days: -3, now: t0 + 30 * day), .prune(days: 30, now: t0 + 30 * day),
    ]),
  ClipSession(
    name: "retention with a cutoff between items",
    start: [item(1, "a", at: t0 + 0.5), item(2, "b", at: t0 - 0.5), item(3, "c", at: t0 - day)],
    steps: [.prune(days: 1, now: t0 + day), .prune(days: 1, now: t0 + day + 0.25)]),
  ClipSession(
    name: "remove, pin and clear",
    steps: [
      .add("one", at: t0), .add("two", at: t0 + 1), .add("three", at: t0 + 2), .togglePin("two"), .togglePin("three"),
      .togglePin("three"), .remove("one"), .removeUnknown, .togglePinUnknown, .add("four", at: t0 + 3),
      .clear(keepPinned: nil),
      .add("five", at: t0 + 4), .clear(keepPinned: true), .clear(keepPinned: false),
    ]),
  ClipSession(
    name: "search puts pinned matches first and keeps their order",
    start: [
      item(1, "alpha beta", at: t0 + 5), item(2, "beta gamma", at: t0 + 4, pinned: true), item(3, "gamma", at: t0 + 3),
      item(4, "Beta delta", at: t0 + 2, pinned: true), item(5, "epsilon", at: t0 + 1),
    ],
    steps: [.search("beta"), .search(""), .search("  "), .search("gamma beta"), .search("zzz"), .search("e")]),
  ClipSession(
    name: "images: copied again moves to the top with its pin; a query never matches one",
    steps: [
      .addImage("a.png", width: 1280, height: 720, bytes: 245_000, app: "com.apple.Safari", at: t0),
      .add("png text", at: t0 + 1), .addImage("b.tiff", at: t0 + 2),
      .addImage("a.png", width: 1280, height: 720, bytes: 245_000, at: t0 + 3), .togglePin("a.png"),
      .addImage("a.png", width: 1280, height: 720, bytes: 245_000, app: "com.apple.Preview", at: t0 + 4),
      .search(""), .search("png"), .search("a"), .search("image"),
    ]),
  ClipSession(
    name: "images without a file or pixels aren't kept; text and images never merge",
    steps: [
      .addImage("", at: t0), .addImage("w.png", width: 0, at: t0), .addImage("h.png", height: -1, at: t0),
      .add("", at: t0), .addImage("x.png", at: t0 + 1), .add("x.png", at: t0 + 2), .addImage("x.png", at: t0 + 3),
    ]),
  ClipSession(
    name: "images count toward the limit and retention, and go with remove and clear",
    steps: [
      .addImage("1.png", at: t0, limit: 2), .add("two", at: t0 + 1, limit: 2),
      .addImage("3.png", at: t0 + 2, limit: 2), .togglePin("3.png"), .addImage("4.tiff", at: t0 + day, limit: 2),
      .add("five", at: t0 + day + 1, limit: 2), .prune(days: 1, now: t0 + 2 * day + 0.5), .remove("five"),
      .clear(keepPinned: true), .addImage("6.png", at: t0 + 3 * day), .clear(keepPinned: false),
    ]),
]

/// A fixed history for `search`, with texts that test case and diacritic folding.
private let searchItems: [ClipboardItem] = [
  "Hello World", "héllo wörld", "Crème brûlée recipe", "STRASSE", "Straße 5", "naïve café", "ﬁle", "file", "İstanbul",
  "istanbul", "Ωmega", "ωmega", "日本語のテキスト", "emoji 👍🏽 here", "tab\there", "line1\nline2", "  spaced  ",
  "ÅNGSTRÖM", "angstrom", "Æsir", "aesir", "Œuvre", "ǆ", "Ǆ", "e\u{301}clair", "\u{E9}clair", "Ⅻ", "ｆｕｌｌ", "Zürich",
  "ZURICH", "ﬀ", "ø", "o", "ı", "I", "ǅ", "Ä", "a\u{308}", "x\u{301}y", "Ελληνικά", "ελληνικα", "Ёлка", "елка",
  "dot.com", "a-b_c", "$100", "100%", "C:\\Users", "it's", "\"quoted\"",
  // Foundation compares only the first letter a query character folds to (ß → s, ﬁ → f) and lets each further
  // letter match any one character; these pin that down.
  "sax", "ssx", "sx", "as", "asb", "ass", "fab", "fa", "fix", "f", "s", "xs", "ʼnx", "ʼx", "sss", "Ss", "ßa",
  "s\u{301}x",
  "s x", "s\u{301}", "sa\u{301}", "\u{915}", "👍", "q\u{20DD}", "q", "ß", "ﬆ", "ﬃ", "ŉ",
  // A combining mark with nothing to attach to (at the start, or after a line break) is compared as
  // it is, without case folding.
  "\u{308}ﬁ", "x\n\u{308}y", "\u{345}x",
  // The letters a query character skips unchecked are whole characters: an emoji, a ZWJ sequence or
  // CR LF counts as one. A skipped character that folds to several letters must match them entirely.
  "ſ😀x", "ſ👨‍👩‍👧x", "ſ\r\nx", "fß", "fﬁx", "fﬀ", "sﬁ", "ﬀß",
  // Foundation ignores every Grapheme_Extend character (ZWNJ, halfwidth voicing marks, Bengali AA)
  // but folds a precomposed character only when its base is below U+0510: "é" is "e", "が" isn't "か".
  // A canonically equivalent spelling still matches ("か" + U+3099 is "が").
  "میخواهم", "می\u{200C}خواهم", "کتابها", "a\u{200C}b", "a\u{200D}b", "ﾊﾟｿｺﾝ", "ｶﾞｯｺｳ", "がっこう",
  "か\u{3099}っこう", "パソコン", "ハ\u{309A}ソコン", "ヴ", "\u{3099}", "কা", "कि", "آب", "ا\u{653}ب", "\u{FB2A}",
  "ש\u{5C1}", "≠", "∉", "각", "\u{1100}\u{1161}\u{11A8}", "\u{F900}", "\u{1FCD}",
].enumerated().map { index, text in item(100 + index, text, at: t0 - Double(index)) }

private let searchQueries: [String] = [
  "hello", "HELLO", "héllo", "hello world", "world hello", "wörld", "WORLD", "creme", "CRÈME brulee", "brûlée",
  "strasse",
  "STRASSE", "straße", "STRAẞE", "ss", "ß", "naive", "NAÏVE", "cafe", "file", "ﬁ", "fi", "ﬁle", "istanbul", "İstanbul",
  "İ", "i", "ı", "omega", "Ω", "ω", "ΩMEGA", "日本", "テキスト", "👍", "👍🏽", "tab", "\t", "line2", "", "   ", "\n",
  "angstrom", "Ångström", "aesir", "æ", "Æ", "oeuvre", "œ", "ǆ", "Ǆ", "dž", "eclair", "\u{E9}clair", "e\u{301}clair",
  "É", "12", "Ⅻ", "xii", "full", "ｆｕｌｌ", "zurich", "zürich", "ZÜRICH", "ff", "ø", "o", "Ä", "ä", "a", "x", "xy",
  "ελληνικα", "ΕΛΛΗΝΙΚΆ", "ёлка", "Елка", ".com", "a-b", "_c", "$", "%", "\\", "'", "\"", "hello zzz", "e", "  hello  ",
  "hel lo", "ßx", "aß", "ﬃ", "ß", "ßß", "xß", "ŉ", "ﬁx", "ßa", "sß", "SS", "ẞ", "ẞx", "ſ", "ﬆ", "ǰ", "ΐ", "ᾳ", "ς", "σ",
  "Σ", "\u{212A}", "\u{212B}", "k", "å", "\u{915}\u{93F}", "q\u{20DD}", "\u{301}", "sa", "se", "ssa", "ss5",
  "a\u{20DD}",
  "s", "st", "t", "fi", "ffi", "ʼn", "ʼ", "n",
  "\u{308}", "\u{308}fi", "\u{301}e", "\u{301}", "\u{345}", "ι", "ßx", "ßi", "ﬃs", "ﬆi", "ﬃx", "\u{308}y",
  "می\u{200C}", "کتاب\u{200C}", "\u{200C}", "ab", "a\u{200C}b", "a\u{200D}b", "ﾊ", "ﾊｿ", "ﾊﾟ", "ｶ", "ﾟ", "か", "が",
  "か\u{3099}", "かっ", "がっ", "か\u{3099}っ", "ハソコン", "パソコン", "ハ\u{309A}", "ウ", "ゔ", "\u{3099}", "ক",
  "কা", "क", "ا", "آ", "ا\u{653}", "ש", "\u{FB2A}", "ש\u{5C1}", "=", "≠", "∈", "∉", "가", "각",
  "\u{1100}\u{1161}\u{11A8}", "\u{F900}", "\u{8C48}", "\u{1FBF}",
]

/// Whether a session step's `key` names this item: its text, or its image's file.
private func named(_ item: ClipboardItem, _ key: String) -> Bool {
  item.image.map { $0.file == key } ?? (item.text == key)
}

/// Items without their ids; `image` only for images, so text items list as they always have.
private func historyItemsJ(_ history: ClipboardHistory) -> J {
  .array(
    history.items.map { item in
      var entry: [String: J] = [
        "text": .string(item.text), "app": .optional(item.sourceApp),
        "copiedAt": .number(item.copiedAt.timeIntervalSinceReferenceDate), "pinned": .bool(item.pinned),
      ]
      if let image = item.image { entry["image"] = toJ(image) }
      return .object(entry)
    })
}

/// Persisted histories (`ClipboardHistory`'s Codable form, as the Mac app writes clipboard.json).
private let codingInputs: [String] = [
  #"{"items":[]}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"hi","copiedAt":800000000.5,"sourceApp":"org.gnome.Terminal","pinned":true}]}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"no app","copiedAt":800000000,"pinned":false}]}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"null app","copiedAt":-5,"sourceApp":null,"pinned":false}]}"#,
  #"{"items":[{"id":"abcdef01-2345-4678-9abc-def012345678","text":"lowercase id","copiedAt":1,"pinned":false}]}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"extra","copiedAt":1,"pinned":false,"color":"red"}],"version":2}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"a","copiedAt":1,"pinned":false},{"id":"00000000-0000-4000-8000-000000000002","text":"b","copiedAt":2,"pinned":true}]}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"missing pinned","copiedAt":1}]}"#,
  #"{"items":[{"id":"not-a-uuid","text":"x","copiedAt":1,"pinned":false}]}"#,
  #"{"items":[{"text":"no id","copiedAt":1,"pinned":false}]}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"string date","copiedAt":"2026-01-01","pinned":false}]}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":5,"copiedAt":1,"pinned":false}]}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"x","copiedAt":1,"pinned":"yes"}]}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"x","copiedAt":1,"pinned":false,"sourceApp":7}]}"#,
  #"{"items":{}}"#, #"{}"#, #"[]"#, #"{"items":[null]}"#, #"{"items":null}"#,
  // Images. Files written before images were kept have no `image` key and read as before (above).
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"","copiedAt":1,"sourceApp":"com.apple.Safari","pinned":true,"image":{"file":"ab.png","width":1280,"height":720,"bytes":245000}}]}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"t","copiedAt":1,"pinned":false,"image":null},{"id":"00000000-0000-4000-8000-000000000002","text":"","copiedAt":2,"pinned":false,"image":{"file":"c.tiff","width":1,"height":2,"bytes":3,"hash":"x"}}]}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"","copiedAt":1,"pinned":false,"image":{"file":"ab.png","width":1280,"height":720}}]}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"","copiedAt":1,"pinned":false,"image":{"width":1,"height":1,"bytes":1}}]}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"","copiedAt":1,"pinned":false,"image":{"file":"a.png","width":"1280","height":720,"bytes":1}}]}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"","copiedAt":1,"pinned":false,"image":{"file":"a.png","width":12.5,"height":720,"bytes":1}}]}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"","copiedAt":1,"pinned":false,"image":{"file":7,"width":1,"height":1,"bytes":1}}]}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"","copiedAt":1,"pinned":false,"image":"a.png"}]}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"","copiedAt":1,"pinned":false,"image":[]}]}"#,
  #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","copiedAt":1,"pinned":false,"image":{"file":"a.png","width":1,"height":1,"bytes":1}}]}"#,
]

func clipboardFixtures() -> FixtureFile {
  let sessions: [J] = clipSessions.map { session in
    var history = ClipboardHistory(items: session.start)
    let steps: [J] = session.steps.map { step in
      var result: [String: J] = [:]
      switch step {
      case .add(let text, let app, let seconds, let limit):
        result["add"] = ["text": .string(text), "app": .optional(app), "at": .number(seconds), "limit": .int(limit)]
        result["added"] = .bool(history.add(text, from: app, at: at(seconds), limit: limit))
      case .addImage(let file, let width, let height, let bytes, let app, let seconds, let limit):
        let image = ClipboardImage(file: file, width: width, height: height, bytes: bytes)
        result["addImage"] = [
          "image": toJ(image), "app": .optional(app), "at": .number(seconds), "limit": .int(limit),
        ]
        result["added"] = .bool(history.add(image: image, from: app, at: at(seconds), limit: limit))
      case .enforce(let limit):
        result["enforce"] = .int(limit)
        history.enforce(limit: limit)
      case .prune(let days, let now):
        result["prune"] = ["days": .int(days), "now": .number(now)]
        history.prune(olderThanDays: days, now: at(now))
      case .remove(let key):
        result["remove"] = .string(key)
        history.remove(id: history.items.first { named($0, key) }!.id)
      case .togglePin(let key):
        result["togglePin"] = .string(key)
        history.togglePin(id: history.items.first { named($0, key) }!.id)
      case .removeUnknown:
        result["removeUnknown"] = true
        history.remove(id: uuid(999))
      case .togglePinUnknown:
        result["togglePinUnknown"] = true
        history.togglePin(id: uuid(999))
      case .clear(let keepPinned):
        result["clear"] = keepPinned.map(J.bool) ?? "default"
        if let keepPinned { history.clear(keepPinned: keepPinned) } else { history.clear() }
      case .search(let query):
        result["search"] = .string(query)
        result["results"] = .array(history.search(query).map { .string($0.text) })
      }
      result["items"] = historyItemsJ(history)
      return .object(result)
    }
    return [
      "name": .string(session.name), "start": historyItemsJ(ClipboardHistory(items: session.start)),
      "steps": .array(steps),
    ]
  }

  let searchHistory = ClipboardHistory(items: searchItems)
  let search: [J] = searchQueries.map { query in
    ["query": .string(query), "results": .array(searchHistory.search(query).map { .string($0.text) })]
  }

  let coding: [J] = codingInputs.map { json in
    var entry: [String: J] = ["json": .string(json)]
    entry.merge(outcome("history") { toJ(try JSONDecoder().decode(ClipboardHistory.self, from: Data(json.utf8))) }) {
      a, _ in a
    }
    return .object(entry)
  }

  return FixtureFile(
    name: "clipboard.json",
    description:
      "ClipboardHistory: sessions of add (dedupe, limit), enforce, prune (retention), remove, togglePin, clear and "
      + "search with fixed dates (seconds since 2001-01-01, as Swift's Date encodes them); search over a fixed history "
      + "(case- and diacritic-insensitive, pinned first); and the Codable form the Mac app writes to clipboard.json "
      + "(`history`, or `error` for files it can't read). Items are listed without their ids, which Swift generates "
      + "at random.",
    sections: ["sessions": sessions, "search": search, "coding": coding],
    extra: ["searchItems": historyItemsJ(searchHistory)],
    depth: ["sessions": 3, "searchItems": 1])
}
