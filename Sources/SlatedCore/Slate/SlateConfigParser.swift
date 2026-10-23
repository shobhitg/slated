import Foundation

/// Result of parsing a classic `.slate` file (and everything it `source`s).
public struct SlateConfigFile: Hashable, Sendable {
  public var settings: SlateSettings
  public var bindings: [HotkeyBinding]
  public var layouts: [Layout]
  public var defaults: [ScreenDefault]
  public var diagnostics: [Diagnostic]

  public init(
    settings: SlateSettings = .init(), bindings: [HotkeyBinding] = [], layouts: [Layout] = [],
    defaults: [ScreenDefault] = [], diagnostics: [Diagnostic] = []
  ) {
    self.settings = settings
    self.bindings = bindings
    self.layouts = layouts
    self.defaults = defaults
    self.diagnostics = diagnostics
  }
}

/// Parser for classic `.slate` files: `config`, `alias`, `layout`, `default`, `bind`, `source`.
///
/// Each line is one directive; `#` starts a comment (except inside quotes, unlike Slate). A line that
/// fails becomes an error `Diagnostic` with its file and line, and parsing carries on with the next
/// line. Questionable but usable lines (an unknown setting, an unknown layout option) load with a
/// warning.
///
/// Differences from Slate worth knowing:
/// - `config` values may contain spaces (Slate kept only the first word); quotes around them are removed.
/// - Per-app settings (`config snapshotTitleMatch:'App' sequential`) aren't supported yet and are skipped
///   with a warning.
/// - `source` can't load `.js` files (they are JavaScript configs; list them in Settings instead), and a
///   file that sources itself, directly or not, is an error instead of an endless loop.
/// - Unknown directives are errors rather than being silently ignored.
public enum SlateConfigParser {
  /// Parses `text`. `path` names the file in diagnostics and guards against it sourcing itself.
  /// Relative `source` paths resolve against `homeDirectory`, as in Slate; `readFile` loads sourced
  /// files (injected so tests don't touch the disk) and returns nil when a file can't be read.
  public static func parse(
    _ text: String, path: String? = nil,
    homeDirectory: String = NSHomeDirectory(),
    readFile: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
  ) -> SlateConfigFile {
    withoutActuallyEscaping(readFile) { readFile in
      var parser = ConfigFileParser(home: homeDirectory, readFile: readFile)
      if let path { parser.sourceStack.append(parser.standardized(parser.resolve(path))) }
      parser.parse(text, file: path)
      return parser.result
    }
  }

  /// The settings Slate understands. Others still load (with a warning), since a typo is the likely cause.
  public static let knownSettings: Set<String> = [
    "defaultToCurrentScreen", "nudgePercentOf", "resizePercentOf", "repeatOnHoldOps", "secondsBeforeRepeat",
    "secondsBetweenRepeat", "checkDefaultsOnLoad", "focusCheckWidth", "focusCheckWidthMax",
    "focusPreferSameApp", "orderScreensLeftToRight", "windowHintsFontName", "windowHintsFontSize",
    "windowHintsFontColor", "windowHintsWidth", "windowHintsHeight", "windowHintsBackgroundColor",
    "windowHintsDuration", "windowHintsRoundedCornerSize", "windowHintsIgnoreHiddenWindows",
    "windowHintsTopLeftX", "windowHintsTopLeftY", "windowHintsOrder", "windowHintsShowIcons",
    "windowHintsIconAlpha", "windowHintsSpread", "windowHintsSpreadSearchWidth", "windowHintsSpreadSearchHeight",
    "windowHintsSpreadPadding", "switchIconSize", "switchIconPadding", "switchBackgroundColor",
    "switchSelectedBackgroundColor", "switchSelectedBorderColor", "switchSelectedBorderSize",
    "switchRoundedCornerSize", "switchOrientation", "switchSecondsBeforeRepeat", "switchSecondsBetweenRepeat",
    "switchStopRepeatAtEdge", "switchOnlyFocusMainWindow", "switchFontSize", "switchFontColor", "switchFontName",
    "switchShowTitles", "switchType", "switchSelectedPadding", "keyboardLayout", "snapshotTitleMatch",
    "snapshotMaxStackSize", "undoMaxStackSize", "undoOps", "gridBackgroundColor", "gridRoundedCornerSize",
    "gridCellBackgroundColor", "gridCellSelectedColor", "gridCellRoundedCornerSize", "layoutFocusOnActivate",
    "modalEscapeKey", "jsReceiveMoveEvent", "jsReceiveResizeEvent",
  ]

  /// Removes a trailing `# comment`. A `#` inside quotes is kept; on `bind` lines quote tracking starts
  /// after the key, because the key itself may be a quote character (`bind ':ctrl …`).
  static func stripComment(_ line: String) -> String {
    let chars = Array(line)
    var start = 0
    if line.lowercased().hasPrefix("bind"), chars.count > 4, chars[4].isWhitespace {
      var i = 4
      while i < chars.count, chars[i].isWhitespace { i += 1 }
      while i < chars.count, !chars[i].isWhitespace {
        if chars[i] == "#" { return String(chars[..<i]).trimmingCharacters(in: .whitespaces) }
        i += 1
      }
      start = i
    }
    var quote: Character?
    for i in start..<chars.count {
      let c = chars[i]
      if let open = quote {
        if c == open { quote = nil }
      } else if c == "#" {
        return String(chars[..<i]).trimmingCharacters(in: .whitespaces)
      } else if SlateTokenizer.quoteCharacters.contains(c) {
        quote = c
      }
    }
    return line
  }
}

/// The working state while parsing one file and the files it sources.
private struct ConfigFileParser {
  var result = SlateConfigFile()
  var aliases: [String: String] = [:]
  var layoutIndex: [String: Int] = [:]
  /// How many identical bindings were seen so far, so duplicates still get distinct ids.
  var bindingOccurrences: [String: Int] = [:]
  /// Standardized paths of the files being parsed, outermost first, to catch `source` loops.
  var sourceStack: [String] = []
  let home: String
  let readFile: (String) -> String?

  private static let maximumSourceDepth = 16

  init(home: String, readFile: @escaping (String) -> String?) {
    self.home = home
    self.readFile = readFile
  }

  /// Where a directive came from, for diagnostics.
  struct Location {
    var file: String?
    var line: Int
  }

  mutating func parse(_ text: String, file: String?) {
    var text = text
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
    // Split on any line break; "\r\n" is a single Character in Swift, so splitting on "\n" would miss it.
    for (index, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty || line.hasPrefix("#") { continue }
      let content = SlateConfigParser.stripComment(line)
      if content.isEmpty { continue }
      let location = Location(file: file, line: index + 1)
      do {
        try handle(try substituteAliases(content), at: location)
      } catch let error as SlatedError {
        report(.error, error.description, at: location)
      } catch {
        report(.error, "\(error)", at: location)
      }
    }
  }

  private mutating func report(_ severity: Diagnostic.Severity, _ message: String, at location: Location) {
    result.diagnostics.append(Diagnostic(severity, message, file: location.file, line: location.line))
  }

  private func invalid(_ message: String) -> SlatedError { SlatedError.invalidSyntax(message) }

  // MARK: Directives

  private mutating func handle(_ line: String, at location: Location) throws {
    let (directive, rest) = splitFirstWord(line)
    switch directive.lowercased() {
    case "config": try handleConfig(rest, at: location)
    case "alias": try handleAlias(rest)
    case "bind": try handleBind(rest, at: location)
    case "layout": try handleLayout(rest, at: location)
    case "default": try handleDefault(rest)
    case "source": try handleSource(rest, at: location)
    default:
      throw invalid(
        "Unknown directive \"\(directive)\"; lines start with config, alias, layout, default, bind or source")
    }
  }

  /// `config name value`
  private mutating func handleConfig(_ rest: String, at location: Location) throws {
    let (key, value) = splitFirstWord(rest)
    guard !key.isEmpty, !value.isEmpty else {
      throw invalid("config needs a name and a value, like config defaultToCurrentScreen true")
    }
    if key.contains(":") {
      report(.warning, "Per-app settings like \"\(key)\" aren't supported yet; skipped this line", at: location)
      return
    }
    if !SlateConfigParser.knownSettings.contains(key) {
      var message = "Unknown setting \"\(key)\""
      if let suggestion = closestName(to: key, in: SlateConfigParser.knownSettings.sorted()) {
        message += "; did you mean \"\(suggestion)\"?"
      }
      report(.warning, message, at: location)
    }
    result.settings[key] = SettingValue(slate: SlateTokenizer.unquote(value))
  }

  /// `alias name value`; later lines use it as `${name}`.
  private mutating func handleAlias(_ rest: String) throws {
    let (name, value) = splitFirstWord(rest)
    guard !name.isEmpty, !value.isEmpty else {
      throw invalid("alias needs a name and a value, like alias half push left bar-resize:screenSizeX/2")
    }
    aliases[name] = value
  }

  /// `bind key:modifiers operation`
  private mutating func handleBind(_ rest: String, at location: Location) throws {
    let (keystroke, operation) = splitFirstWord(rest)
    guard !keystroke.isEmpty, !operation.isEmpty else {
      throw invalid("bind needs a key and an operation, like bind left:ctrl;cmd push left")
    }
    let keys = try SlateSyntax.parseKeystroke(keystroke)
    let action = try SlateSyntax.parseOperation(operation)
    // The id depends only on what the binding is (and where), so reloading an unchanged file gives the
    // same bindings, and editing an unrelated line doesn't change them.
    let modal = keys.modal.map { "\($0.keys.string)\($0.toggle ? ":toggle" : "")" } ?? ""
    let identity = [location.file ?? "", keys.keys.string, modal, SlateSyntax.format(action)].joined(separator: "\n")
    let occurrence = bindingOccurrences[identity, default: 0]
    bindingOccurrences[identity] = occurrence + 1
    result.bindings.append(
      HotkeyBinding(
        id: stableUUID("\(identity)\n\(occurrence)"), keys: keys.keys, modal: keys.modal, action: action))
  }

  /// `layout name 'App Name':OPTIONS operation | operation …`, or `layout name BEFORE|AFTER operation`.
  private mutating func handleLayout(_ rest: String, at location: Location) throws {
    let (words, operations) = try SlateTokenizer.leadingTokens(rest, count: 2)
    guard words.count == 2, !words[0].text.isEmpty, !operations.isEmpty else {
      throw invalid("layout needs a name, an app and operations, like layout coding 'Terminal' push left")
    }
    let name = words[0].text
    let appWord = words[1]

    if !appWord.isQuoted, appWord.text == "BEFORE" || appWord.text == "AFTER" {
      let action = try SlateSyntax.parseOperation(operations)
      let isBefore = appWord.text == "BEFORE"
      updateLayout(name) { layout in
        if isBefore { layout.before.append(action) } else { layout.after.append(action) }
      }
      return
    }

    let raw = appWord.raw
    let colon = SlateTokenizer.firstIndex(of: ":", outsideQuotesIn: raw)
    let app = SlateTokenizer.unquote(colon.map { String(raw[..<$0]) } ?? raw)
    guard !app.isEmpty else { throw invalid("The app name is empty in \"\(raw)\"") }
    if !appWord.isQuoted, app == "BEFORE" || app == "AFTER" {
      throw invalid("\(app) doesn't take options")
    }
    let optionText = colon.map { String(raw[raw.index(after: $0)...]) } ?? ""
    let (options, warnings) = try layoutOptions(optionText, app: app)

    let pieces = try SlateTokenizer.split(operations, separators: ["|"])
    if pieces.contains(where: { $0.text.isEmpty }) {
      throw invalid("Missing an operation next to \"|\" in \"\(operations)\"")
    }
    let actions = try pieces.map { try SlateSyntax.parseOperation($0.text) }

    for warning in warnings { report(.warning, warning, at: location) }
    updateLayout(name) { layout in
      // Like Slate, a later line for the same app replaces it and moves it to the end.
      layout.apps.removeAll { $0.app == app }
      layout.apps.append(LayoutApp(app: app, operations: actions, options: options))
    }
  }

  private func layoutOptions(_ text: String, app: String) throws -> (LayoutAppOptions, [String]) {
    var options = LayoutAppOptions()
    var warnings: [String] = []
    guard !text.isEmpty else { return (options, warnings) }
    for piece in try SlateTokenizer.split(text, separators: [","]) where !piece.text.isEmpty {
      let item = piece.text
      let equals = SlateTokenizer.firstIndex(of: "=", outsideQuotesIn: item)
      let key = (equals.map { String(item[..<$0]) } ?? item).trimmingCharacters(in: .whitespaces).uppercased()
      let value = equals.map { SlateTokenizer.unquote(String(item[item.index(after: $0)...])) }
      switch key {
      case "IGNORE_FAIL": options.ignoreFail = true
      case "REPEAT": options.repeat = true
      case "REPEAT_LAST": options.repeatLast = true
      case "MAIN_FIRST": options.mainFirst = true
      case "MAIN_LAST": options.mainLast = true
      case "SORT_TITLE": options.sortTitle = true
      case "TITLE_ORDER":
        options.titleOrder = try titles(value, option: key)
      case "TITLE_ORDER_REGEX":
        let patterns = try titles(value, option: key)
        for pattern in patterns {
          do {
            _ = try NSRegularExpression(pattern: pattern)
          } catch {
            throw invalid("Invalid regular expression \"\(pattern)\" in TITLE_ORDER_REGEX")
          }
        }
        options.titleOrderRegex = patterns
      default:
        warnings.append("Unknown layout option \"\(key)\" for \"\(app)\"; ignored it")
      }
    }
    if options.mainFirst && options.mainLast {
      warnings.append("MAIN_FIRST and MAIN_LAST can't both apply to \"\(app)\"")
    }
    return (options, warnings)
  }

  private func titles(_ value: String?, option: String) throws -> [String] {
    let titles = (value ?? "").split(separator: ";").map(String.init).filter { !$0.isEmpty }
    guard !titles.isEmpty else {
      throw invalid("\(option) needs window titles separated by ;, like \(option)=Inbox;Drafts")
    }
    return titles
  }

  private mutating func updateLayout(_ name: String, _ update: (inout Layout) -> Void) {
    if let index = layoutIndex[name] {
      update(&result.layouts[index])
    } else {
      var layout = Layout(name: name)
      update(&layout)
      layoutIndex[name] = result.layouts.count
      result.layouts.append(layout)
    }
  }

  /// `default name count:N` or `default name resolutions:1440x900;1920x1080`
  private mutating func handleDefault(_ rest: String) throws {
    let words = try SlateTokenizer.tokenize(rest)
    let usage = "like default coding count:2 or default coding resolutions:1440x900;1920x1080"
    guard words.count == 2, !words[0].text.isEmpty else {
      throw invalid("default needs a layout or snapshot name and a screen setup, \(usage)")
    }
    let setup = words[1].text
    guard let colon = setup.firstIndex(of: ":") else { throw invalid("Unknown screen setup \"\(setup)\"; \(usage)") }
    let value = String(setup[setup.index(after: colon)...])
    let condition: ScreenDefault.Condition
    switch setup[..<colon].lowercased() {
    case "count":
      guard let count = Int(value), count > 0 else {
        throw invalid("count: needs a number of screens, not \"\(value)\"")
      }
      condition = .count(count)
    case "resolutions":
      var resolutions: [String] = []
      for item in value.split(whereSeparator: { $0 == ";" || $0 == "," }) {
        let parts = item.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]), width > 0, height > 0 else {
          throw invalid("Unknown resolution \"\(item)\"; write resolutions like 1920x1080")
        }
        resolutions.append("\(width)x\(height)")
      }
      guard !resolutions.isEmpty else { throw invalid("resolutions: needs at least one resolution, \(usage)") }
      condition = .resolutions(resolutions)
    default:
      throw invalid("Unknown screen setup \"\(setup)\"; \(usage)")
    }
    result.defaults.append(ScreenDefault(target: words[0].text, condition: condition))
  }

  /// `source path [if_exists]`
  private mutating func handleSource(_ rest: String, at location: Location) throws {
    let words = try SlateTokenizer.tokenize(rest)
    guard (1...2).contains(words.count), !words[0].text.isEmpty else {
      throw invalid("source needs a file, like source ~/.slate.local if_exists")
    }
    var ifExists = false
    if words.count == 2 {
      guard words[1].text.lowercased() == "if_exists" else {
        throw invalid("Unknown source option \"\(words[1].text)\"; the only option is if_exists")
      }
      ifExists = true
    }
    let written = words[0].text
    let path = resolve(written)
    if path.lowercased().hasSuffix(".js") {
      report(
        .warning,
        "Can't source the JavaScript config \"\(written)\" from a .slate file; add it to Slated's Slate config files instead",
        at: location)
      return
    }
    let key = standardized(path)
    if let start = sourceStack.firstIndex(of: key) {
      let loop = (sourceStack[start...] + [key]).map { ($0 as NSString).lastPathComponent }.joined(separator: " → ")
      throw invalid("\"\(written)\" is already being loaded (\(loop)); skipped it to avoid an endless loop")
    }
    guard sourceStack.count < Self.maximumSourceDepth else {
      throw invalid("Too many nested source directives (more than \(Self.maximumSourceDepth))")
    }
    guard let text = readFile(path) else {
      if ifExists { return }
      throw invalid("Couldn't read \"\(written)\"; check the path, or add if_exists to skip it when it's missing")
    }
    sourceStack.append(key)
    parse(text, file: path)
    sourceStack.removeLast()
  }

  // MARK: Helpers

  /// Replaces each `${name}` with the alias's value. Values were expanded when defined, so one pass is enough.
  private func substituteAliases(_ line: String) throws -> String {
    var result = ""
    var rest = Substring(line)
    while let start = rest.range(of: "${") {
      result += rest[..<start.lowerBound]
      guard let end = rest[start.upperBound...].firstIndex(of: "}") else {
        throw invalid("Missing } after \"${\" in \"\(line)\"")
      }
      let name = String(rest[start.upperBound..<end])
      guard let value = aliases[name] else {
        var message = "Unknown alias \"${\(name)}\""
        if let suggestion = closestName(to: name, in: aliases.keys.sorted()) {
          message += "; did you mean \"${\(suggestion)}\"?"
        } else {
          message += "; define it with an alias line above this one"
        }
        throw invalid(message)
      }
      result += value
      rest = rest[rest.index(after: end)...]
    }
    return result + rest
  }

  /// Slate's rule: `~` expands to the home directory, and paths that aren't absolute are relative to it.
  func resolve(_ path: String) -> String {
    let home = home as NSString
    if path == "~" { return home as String }
    if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
    if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
    if path.hasPrefix("/") { return path }
    return home.appendingPathComponent(path)
  }

  func standardized(_ path: String) -> String { (path as NSString).standardizingPath }
}

/// A UUID derived from `name` (two 64-bit FNV-1a hashes, marked as a name-based UUID), so the same name
/// always gives the same identifier. Not cryptographic; it only needs to be stable and unlikely to clash.
func stableUUID(_ name: String) -> UUID {
  var first: UInt64 = 0xcbf2_9ce4_8422_2325
  var second: UInt64 = 0x6c62_272e_07bb_0142
  for byte in name.utf8 {
    first = (first ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
    second = (second ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
  }
  var bytes = [UInt8](repeating: 0, count: 16)
  for i in 0..<8 {
    bytes[i] = UInt8(truncatingIfNeeded: first >> (8 * UInt64(i)))
    bytes[8 + i] = UInt8(truncatingIfNeeded: second >> (8 * UInt64(i)))
  }
  bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5: name-based
  bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
  return UUID(
    uuid: (
      bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    ))
}

/// The first whitespace-separated word of `text` and the trimmed rest.
private func splitFirstWord(_ text: String) -> (String, String) {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  let end = trimmed.firstIndex(where: \.isWhitespace) ?? trimmed.endIndex
  return (String(trimmed[..<end]), trimmed[end...].trimmingCharacters(in: .whitespacesAndNewlines))
}
