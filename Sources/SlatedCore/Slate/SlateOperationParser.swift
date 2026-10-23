import Foundation

/// Parses one Slate operation string (`SlateSyntax.parseOperation`).
///
/// Follows Slate's grammar, with these deliberate differences:
/// - Any amount of whitespace separates parameters, and `|`/`>` between chained operations need no
///   surrounding spaces (Slate required exactly `" | "`). Separators inside quotes don't count.
/// - Expressions are checked when parsing, so a typo like `screenSizeZ` fails at load time.
/// - Unknown options and extra parameters are errors instead of being silently ignored.
/// - Operation names are case-insensitive.
struct SlateOperationParser {
  /// The whole operation, trimmed, for error messages.
  let operation: String
  /// The operation name as written.
  let name: String
  /// Everything after the name, trimmed.
  let arguments: String

  init(_ string: String) throws {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw SlatedError.invalidSyntax("The operation is empty") }
    operation = trimmed
    let end = trimmed.firstIndex(where: \.isWhitespace) ?? trimmed.endIndex
    name = String(trimmed[..<end])
    arguments = trimmed[end...].trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // MARK: Dispatch

  func parse() throws -> Action {
    switch name.lowercased() {
    case "move": return try parseMove()
    case "resize": return try parseResize()
    case "push": return try parsePush()
    case "nudge": return try parseNudge()
    case "throw": return try parseThrow()
    case "corner": return try parseCorner()
    case "chain": return try parseChain()
    case "sequence": return try parseSequence()
    case "layout": return try parseLayout()
    case "focus": return try parseFocus()
    case "snapshot", "delete-snapshot", "activate-snapshot": return try parseSnapshot()
    case "hint": return parseHint()
    case "grid": return try parseGrid()
    case "hide", "show", "toggle": return try parseVisibility()
    case "shell": return try parseShell()
    case "undo": return try parseBare(.undo)
    case "relaunch": return try parseBare(.relaunch)
    case "switch":
      // Slate's switcher took key options (back:, quit:, …). Slated doesn't implement the switcher yet,
      // so options are accepted and dropped.
      return .switchApp
    case "by-orientation": return try parseByOrientation()
    case "insert-text": return try parseInsertText()
    case "open-url": return try parseOpenURL()
    case "keystroke": return try parseKeystrokeAction()
    default:
      throw SlatedError.unknownOperation(name)
    }
  }

  // MARK: Window geometry

  private func parseMove() throws -> Action {
    let words = try tokens()
    try expect(words, count: 2...3)
    let (x, y) = try pair(words[0], what: "position")
    let (width, height) = try pair(words[1], what: "size")
    let screen = words.count == 3 ? try screenRef(words[2]) : nil
    for expression in [x, y, width, height] { try SlateExpression.validate(expression) }
    return .move(x: x, y: y, width: width, height: height, screen: screen)
  }

  private func parseResize() throws -> Action {
    let words = try tokens()
    try expect(words, count: 2...3)
    let anchor: Corner
    if words.count == 3 {
      guard let corner = Corner(rawValue: words[2].text.lowercased()) else {
        throw fail(
          "Unknown anchor \"\(words[2].text)\"", hint: "use top-left, top-right, bottom-left or bottom-right")
      }
      anchor = corner
    } else {
      anchor = .topLeft
    }
    try Self.validateResizeAmount(words[0].text)
    try Self.validateResizeAmount(words[1].text)
    return .resize(width: words[0].text, height: words[1].text, anchor: anchor)
  }

  private func parsePush() throws -> Action {
    let words = try tokens()
    try expect(words, count: 1...3)
    let direction = try self.direction(words[0])
    var style = PushStyle.none
    var screen: ScreenRef?
    if words.count >= 2 {
      if let parsed = PushStyle(slate: words[1].text) {
        style = parsed
      } else if words.count == 2, let ref = ScreenRef(slate: words[1].text) {
        screen = ref  // `push up 1`: Slated lets the screen follow the direction directly.
      } else {
        throw fail("Unknown push style \"\(words[1].text)\"", hint: "use none, center, bar or bar-resize:expression")
      }
    }
    if words.count == 3 { screen = try screenRef(words[2]) }
    if case .barResize(let expression) = style {
      guard !expression.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw fail("bar-resize needs an expression", hint: "like bar-resize:screenSizeX/2")
      }
      try SlateExpression.validate(expression)
    }
    return .push(direction: direction, style: style, screen: screen)
  }

  private func parseNudge() throws -> Action {
    let words = try tokens()
    try expect(words, count: 2...2)
    try Self.validateNudgeAmount(words[0].text)
    try Self.validateNudgeAmount(words[1].text)
    return .nudge(x: words[0].text, y: words[1].text)
  }

  private func parseThrow() throws -> Action {
    let words = try tokens()
    try expect(words, count: 1...2)
    let screen = try screenRef(words[0])
    var width: String?
    var height: String?
    if words.count == 2 {
      let style = words[1].text
      switch style.lowercased() {
      case "resize":
        (width, height) = ("screenSizeX", "screenSizeY")
      case "noresize":
        break
      default:
        guard style.lowercased().hasPrefix("resize:") else {
          throw fail("Unknown throw style \"\(style)\"", hint: "use resize, resize:width;height or noresize")
        }
        (width, height) = try pair(String(style.dropFirst("resize:".count)), what: "size")
      }
    }
    for expression in [width, height].compactMap({ $0 }) { try SlateExpression.validate(expression) }
    return .throwWindow(screen: screen, width: width, height: height)
  }

  private func parseCorner() throws -> Action {
    let words = try tokens()
    try expect(words, count: 1...3)
    guard let corner = Corner(rawValue: words[0].text.lowercased()) else {
      throw fail("Unknown corner \"\(words[0].text)\"", hint: "use top-left, top-right, bottom-left or bottom-right")
    }
    var width: String?
    var height: String?
    var screen: ScreenRef?
    if words.count >= 2 {
      let style = words[1].text
      if style.lowercased().hasPrefix("resize:") {
        (width, height) = try pair(String(style.dropFirst("resize:".count)), what: "size")
      } else if style.lowercased() == "noresize" || style.lowercased() == "resize" {
        // Slate ignores anything but resize:… here; `noresize` keeps a screen in the fourth position.
      } else if words.count == 2, let ref = ScreenRef(slate: style) {
        screen = ref  // `corner top-left 1`: the screen can follow the corner directly.
      } else {
        throw fail("Unknown corner style \"\(style)\"", hint: "use resize:width;height")
      }
    }
    if words.count == 3 { screen = try screenRef(words[2]) }
    for expression in [width, height].compactMap({ $0 }) { try SlateExpression.validate(expression) }
    return .corner(corner, width: width, height: height, screen: screen)
  }

  // MARK: Composition

  private func parseChain() throws -> Action {
    let pieces = try operationPieces(separators: ["|"])
    return .chain(try pieces.map { try SlateSyntax.parseOperation($0.text) })
  }

  private func parseSequence() throws -> Action {
    let pieces = try operationPieces(separators: ["|", ">"])
    return .sequence(
      try pieces.map { SequenceStep(try SlateSyntax.parseOperation($0.text), keepWindow: $0.separator == ">") })
  }

  private func operationPieces(separators: Set<Character>) throws -> [SlateTokenizer.Piece] {
    guard !arguments.isEmpty else { throw fail("Missing operations") }
    let pieces = try SlateTokenizer.split(arguments, separators: separators)
    for (index, piece) in pieces.enumerated() where piece.text.isEmpty {
      let separator = index == 0 ? pieces[1].separator! : piece.separator!
      throw fail("Missing an operation \(index == 0 ? "before" : "after") \"\(separator)\"")
    }
    return pieces
  }

  private func parseLayout() throws -> Action {
    let layoutName = SlateTokenizer.unquote(arguments)
    guard !layoutName.isEmpty else { throw fail("Missing the layout name") }
    return .layout(name: layoutName)
  }

  // MARK: Focus, snapshots, overlays

  private func parseFocus() throws -> Action {
    let words = try tokens()
    guard words.count == 1 else {
      if words.isEmpty { throw fail("Missing a direction or app") }
      throw fail("App names need quotes", hint: "write focus '\(arguments)'")
    }
    if words[0].isQuoted {
      guard !words[0].text.isEmpty else { throw fail("The app name is empty") }
      return .focusApp(words[0].text)
    }
    guard let direction = FocusDirection(slate: words[0].text) else {
      throw fail(
        "Unknown focus direction \"\(words[0].text)\"",
        hint: "use left, right, up, down, behind or a quoted app name like 'Safari'")
    }
    return .focus(direction)
  }

  private func parseSnapshot() throws -> Action {
    let words = try tokens()
    guard let first = words.first, !first.text.isEmpty else { throw fail("Missing the snapshot name") }
    let options = words.dropFirst().flatMap { word in
      word.text.split(whereSeparator: { $0 == ";" || $0 == "," }).map { $0.trimmingCharacters(in: .whitespaces) }
    }.filter { !$0.isEmpty }
    let kind = name.lowercased()
    let allowed: [String] =
      switch kind {
      case "snapshot": ["save-to-disk", "stack"]
      case "delete-snapshot": ["all"]
      default: ["delete"]
      }
    for option in options where !allowed.contains(option.lowercased()) {
      throw fail("Unknown \(kind) option \"\(option)\"", hint: "use \(allowed.joined(separator: " or "))")
    }
    let set = Set(options.map { $0.lowercased() })
    switch kind {
    case "snapshot":
      return .snapshot(name: first.text, save: set.contains("save-to-disk"), stack: set.contains("stack"))
    case "delete-snapshot":
      return .deleteSnapshot(name: first.text, all: set.contains("all"))
    default:
      return .activateSnapshot(name: first.text, delete: set.contains("delete"))
    }
  }

  private func parseHint() -> Action {
    arguments.isEmpty ? .hint(characters: nil) : .hint(characters: SlateTokenizer.unquote(arguments))
  }

  private func parseGrid() throws -> Action {
    var padding: Int?
    var grids: [GridScreen] = []
    for word in try tokens() {
      guard let colon = word.text.firstIndex(of: ":") else {
        throw fail("Unknown grid option \"\(word.text)\"", hint: "use padding:n or screen:width,height")
      }
      let key = String(word.text[..<colon])
      let value = String(word.text[word.text.index(after: colon)...])
      if key.lowercased() == "padding" {
        guard let n = Int(value), n >= 0 else { throw fail("Grid padding must be a whole number, not \"\(value)\"") }
        padding = n
        continue
      }
      guard Int(key) != nil || Self.isResolution(key) else {
        throw fail("Unknown grid screen \"\(key)\"", hint: "use a screen index like 0 or a resolution like 1920x1080")
      }
      let size = value.split(separator: ",", omittingEmptySubsequences: false)
      guard size.count == 2, let width = Int(size[0]), let height = Int(size[1]), width > 0, height > 0 else {
        throw fail("Grid size for screen \(key) must be width,height in cells", hint: "like \(key):12,12")
      }
      let grid = GridScreen(screen: key, width: width, height: height)
      if let existing = grids.firstIndex(where: { $0.screen == key }) {
        grids[existing] = grid  // Like Slate, a later size for the same screen wins.
      } else {
        grids.append(grid)
      }
    }
    return .grid(padding: padding, grids: grids)
  }

  private func parseVisibility() throws -> Action {
    guard !arguments.isEmpty else { throw fail("Missing the apps") }
    var selectors: [AppSelector] = []
    var apps: [String] = []
    for piece in try SlateTokenizer.split(arguments, separators: [","]) {
      let item = piece.text
      guard !item.isEmpty else { throw fail("Empty app name in the list") }
      let lowered = item.lowercased()
      if lowered == "current" {
        selectors.append(.current)
      } else if lowered == "all" {
        selectors.append(.all)
      } else if lowered.hasPrefix("all-but:") {
        let app = SlateTokenizer.unquote(String(item.dropFirst("all-but:".count)))
        guard !app.isEmpty else { throw fail("all-but: needs an app name", hint: "like all-but:'Finder'") }
        selectors.append(.allBut(app))
      } else {
        // Quoted names lose their quotes; unquoted names (even with spaces) are taken as written, like Slate.
        apps.append(SlateTokenizer.unquote(item))
      }
    }
    if !selectors.isEmpty && (selectors.count > 1 || !apps.isEmpty) {
      throw fail("current, all and all-but: can't be combined with other apps")
    }
    let selector = selectors.first ?? .apps(apps)
    switch name.lowercased() {
    case "hide": return .hide(selector)
    case "show": return .show(selector)
    default: return .toggle(selector)
    }
  }

  // MARK: Shell and Slated's own actions

  private func parseShell() throws -> Action {
    let words = try tokens()
    guard let commandWord = words.last else { throw fail("Missing the command") }
    if !commandWord.isQuoted,
      commandWord.text.lowercased() == "wait" || commandWord.text.lowercased().hasPrefix("path:")
    {
      throw fail("Missing the command", hint: "quote it, like shell wait '/usr/bin/say hello'")
    }
    var wait = false
    var path: String?
    for option in words.dropLast() {
      if option.text.lowercased() == "wait" {
        wait = true
      } else if option.text.lowercased().hasPrefix("path:") {
        path = String(option.text.dropFirst("path:".count))
        guard !(path ?? "").isEmpty else { throw fail("path: needs a directory", hint: "like path:~/code") }
      } else {
        throw fail(
          "Unknown shell option \"\(option.text)\"", hint: "quote the whole command, like shell 'open -a Safari'")
      }
    }
    guard !commandWord.text.trimmingCharacters(in: .whitespaces).isEmpty else { throw fail("The command is empty") }
    return .shell(command: commandWord.text, wait: wait, path: path)
  }

  /// `by-orientation '<landscape operation>' '<portrait operation>'`
  private func parseByOrientation() throws -> Action {
    let words = try tokens()
    guard words.count == 2 else {
      throw fail(
        "by-orientation needs two quoted operations",
        hint: "like by-orientation 'move screenOriginX;screenOriginY screenSizeX/3;screenSizeY' 'push up'")
    }
    return .byOrientation(
      landscape: try SlateSyntax.parseOperation(words[0].text), portrait: try SlateSyntax.parseOperation(words[1].text))
  }

  private func parseInsertText() throws -> Action {
    let words = try tokens()
    guard !words.isEmpty else { throw fail("Missing the text", hint: "quote it, like insert-text 'Hello!'") }
    guard words.count <= 2 else {
      throw fail("Text with spaces needs quotes", hint: "write insert-text '\(arguments)'")
    }
    var method = InsertMethod.auto
    if words.count == 2 {
      guard !words[0].isQuoted, let parsed = InsertMethod(rawValue: words[0].text.lowercased()) else {
        throw fail("Unknown insert-text option \"\(words[0].text)\"", hint: "use type or paste, and quote the text")
      }
      method = parsed
    }
    return .insertText(SlateSyntax.unescapeText(words[words.count - 1].text), method: method)
  }

  private func parseOpenURL() throws -> Action {
    let words = try tokens()
    guard words.count == 1, !words[0].text.isEmpty else {
      if words.isEmpty || (words.count == 1 && words[0].text.isEmpty) { throw fail("Missing the URL") }
      throw fail("URLs with spaces need quotes", hint: "like open-url 'https://example.com/a b'")
    }
    return .openURL(words[0].text)
  }

  private func parseKeystrokeAction() throws -> Action {
    let words = try tokens()
    guard words.count == 1 else {
      throw fail(words.isEmpty ? "Missing the keys" : "Too many parameters", hint: "like keystroke cmd+shift+4")
    }
    let text = words[0].text
    if let combo = KeyCombo(string: text), KeyNames.isValid(combo.key) { return .keystroke(combo) }
    if text.contains(":"), let parsed = try? SlateSyntax.parseKeystroke(text), parsed.modal == nil {
      return .keystroke(parsed.keys)
    }
    throw fail("Unknown keystroke \"\(text)\"", hint: "write it like cmd+shift+4")
  }

  private func parseBare(_ action: Action) throws -> Action {
    guard arguments.isEmpty else { throw fail("\(action.name) takes no parameters") }
    return action
  }

  // MARK: Helpers

  private func tokens() throws -> [SlateToken] { try SlateTokenizer.tokenize(arguments) }

  private func expect(_ words: [SlateToken], count range: ClosedRange<Int>) throws {
    if words.count < range.lowerBound { throw fail("Missing parameters") }
    if words.count > range.upperBound { throw fail("Too many parameters") }
  }

  private func direction(_ word: SlateToken) throws -> Direction {
    guard let direction = Direction(slate: word.text) else {
      throw fail("Unknown direction \"\(word.text)\"", hint: "use up, down, left or right")
    }
    return direction
  }

  private func screenRef(_ word: SlateToken) throws -> ScreenRef {
    guard let ref = ScreenRef(slate: word.text) else {
      throw fail(
        "Unknown screen \"\(word.text)\"",
        hint: "use an index like 1, a resolution like 1920x1080, left, right, up, down, next or previous")
    }
    return ref
  }

  private func pair(_ word: SlateToken, what: String) throws -> (String, String) {
    try pair(word.text, what: what)
  }

  /// Splits `x;y` (or Slate's older `x,y`, with commas inside parentheses or braces ignored).
  private func pair(_ text: String, what: String) throws -> (String, String) {
    var parts = text.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
    if parts.count != 2 { parts = Self.splitTopLevelCommas(text) }
    guard parts.count == 2,
      !parts[0].trimmingCharacters(in: .whitespaces).isEmpty,
      !parts[1].trimmingCharacters(in: .whitespaces).isEmpty
    else {
      let example = what == "size" ? "width;height" : "x;y"
      throw fail("Expected the \(what) as \(example), found \"\(text)\"")
    }
    return (parts[0], parts[1])
  }

  private static func splitTopLevelCommas(_ text: String) -> [String] {
    var parts: [String] = []
    var current = ""
    var depth = 0
    for c in text {
      switch c {
      case "(", "{": depth += 1
      case ")", "}": depth -= 1
      default: break
      }
      if c == ",", depth == 0 {
        parts.append(current)
        current = ""
      } else {
        current.append(c)
      }
    }
    parts.append(current)
    return parts
  }

  static func isResolution(_ text: String) -> Bool {
    let parts = text.lowercased().split(separator: "x", omittingEmptySubsequences: false)
    return parts.count == 2 && Int(parts[0]) != nil && Int(parts[1]) != nil
  }

  /// An error like `Unknown direction "sideways" in "push sideways"; use up, down, left or right`.
  /// Without a hint, the operation's usage is appended instead.
  private func fail(_ problem: String, hint: String? = nil) -> SlatedError {
    var message = "\(problem) in \"\(operation)\""
    if let hint {
      message += "; \(hint)"
    } else if let usage = Self.usage[name.lowercased()] {
      message += ". Usage: \(usage)"
    }
    return SlatedError.invalidSyntax(message)
  }

  private static let usage: [String: String] = [
    "move": "move x;y width;height [screen]",
    "resize": "resize width height [anchor]",
    "push": "push direction [none|center|bar|bar-resize:expression] [screen]",
    "nudge": "nudge x y",
    "throw": "throw screen [resize|resize:width;height]",
    "corner": "corner top-left|top-right|bottom-left|bottom-right [resize:width;height] [screen]",
    "chain": "chain operation | operation …",
    "sequence": "sequence operation | operation > operation …",
    "layout": "layout name",
    "focus": "focus left|right|up|down|behind|'App Name'",
    "snapshot": "snapshot name [save-to-disk;stack]",
    "delete-snapshot": "delete-snapshot name [all]",
    "activate-snapshot": "activate-snapshot name [delete]",
    "grid": "grid [padding:n] [screen:width,height …]",
    "hide": "hide 'App','Other App' | current | all | all-but:'App'",
    "show": "show 'App','Other App' | current | all | all-but:'App'",
    "toggle": "toggle 'App','Other App' | current | all | all-but:'App'",
    "shell": "shell [wait] [path:~/dir] 'command'",
    "insert-text": "insert-text [type|paste] 'text'",
    "open-url": "open-url 'https://…'",
    "keystroke": "keystroke cmd+shift+4",
  ]

  // MARK: Amounts (shared with FrameCalculator)

  /// Checks a `resize` amount: `+10%`, `-100`, `+screenSizeX/10`, or (Slated) an absolute size such as
  /// `screenSizeX/2` or `50%`.
  static func validateResizeAmount(_ value: String) throws {
    let amount = ResizeAmount(value)
    do {
      guard !amount.magnitude.isEmpty else { throw SlatedError.invalidExpression("the amount is empty") }
      if amount.sign != nil, Int(amount.magnitude) != nil { return }
      try SlateExpression.validate(amount.magnitude)
    } catch let error as SlatedError {
      throw SlatedError.invalidExpression("Invalid resize amount \"\(value)\": \(error.description)")
    }
  }

  /// Checks a `nudge` amount: `+10%`, `-100`, or a signed expression such as `+screenSizeX/10`.
  static func validateNudgeAmount(_ value: String) throws {
    do {
      guard !value.trimmingCharacters(in: .whitespaces).isEmpty else {
        throw SlatedError.invalidExpression("the amount is empty")
      }
      try SlateExpression.validate(nudgeExpression(value, axis: "X", percentOf: "screenSize"))
    } catch let error as SlatedError {
      throw SlatedError.invalidExpression("Invalid nudge amount \"\(value)\": \(error.description)")
    }
  }

  /// Slate builds a nudge as text: `windowTopLeftX` followed by the amount, with `%` replaced by
  /// `*screenSizeX/100` (or `windowSizeX`, per `nudgePercentOf`). This returns that amount part; an
  /// unsigned amount counts as positive.
  static func nudgeExpression(_ value: String, axis: String, percentOf: String) -> String {
    var amount = value.trimmingCharacters(in: .whitespaces)
    if !amount.hasPrefix("+") && !amount.hasPrefix("-") { amount = "+" + amount }
    return amount.replacingOccurrences(of: "%", with: "*\(percentOf)\(axis)/100")
  }
}

/// A `resize` width or height: a sign (for a relative change), a magnitude, and whether it is a percentage.
struct ResizeAmount {
  /// `+1` or `-1` for a relative change; nil for an absolute size (a Slated extension).
  var sign: Double?
  /// The number or expression, without sign or `%`.
  var magnitude: String
  var isPercent: Bool

  init(_ value: String) {
    var text = value.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("+") || text.hasPrefix("-") {
      sign = text.hasPrefix("-") ? -1 : 1
      text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    isPercent = text.hasSuffix("%")
    if isPercent { text = String(text.dropLast()).trimmingCharacters(in: .whitespaces) }
    magnitude = text
  }
}
