import Foundation

@testable import SlatedCore

// Differential fuzzing: the fixture files again, but from seeded random inputs (~120,000 expected
// results), so the JavaScript port is compared with Swift far beyond the curated vectors.
//
//   make fuzz [SEED=n]
//
// (SLATED_FUZZ=<seed> swift run SlatedFixtures <dir>, then node linux/tests/run.mjs --fixtures <dir>.)
//
// A failure is a difference the golden vectors don't cover yet: add the input to the curated lists
// in this target and fix whichever side is wrong. The same seed always writes the same files.
//
// SLATED_FUZZ_DAMAGE=1 also damages the JSON5 configs character by character. It reports one known
// difference: Foundation only validates strings it decodes, so a bad escape or raw control
// character in a key Slated ignores loads on macOS, while the port's parser rejects the file.

struct FuzzRNG {
  var state: UInt64
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
  mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
  mutating func range(_ lo: Int, _ hi: Int) -> Int { lo + int(hi - lo + 1) }
  mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
  mutating func chance(_ p: Double) -> Bool { Double(next() % 1_000_000) / 1_000_000 < p }
  mutating func unit() -> Double { Double(next() % 1_000_000_007) / 1_000_000_007 }
}

// MARK: - Expressions

private let exprVariables = [
  "screenOriginX", "screenOriginY", "screenSizeX", "screenSizeY", "windowTopLeftX", "windowTopLeftY", "windowSizeX",
  "windowSizeY", "newWindowSizeX", "newWindowSizeY",
]
private let unaryFunctions = ["sqrt", "log", "ln", "exp", "floor", "ceiling", "abs", "trunc"]
private let aggregates = ["sum", "count", "min", "max", "average", "median", "stddev"]

private func numberLiteral(_ rng: inout FuzzRNG) -> String {
  switch rng.int(12) {
  case 0: return String(rng.int(10))
  case 1: return String(rng.int(5000))
  case 2: return "\(rng.int(100)).\(rng.int(1000))"
  case 3: return ".\(rng.int(100))"
  case 4: return "\(rng.int(100))."
  case 5: return "\(rng.range(1, 9))e\(rng.pick(["", "+", "-"]))\(rng.int(400))"
  case 6: return "\(rng.int(10)).\(rng.int(10))E\(rng.pick(["", "-"]))\(rng.int(20))"
  case 7: return "0"
  case 8: return "\(rng.pick(["1", "2", "3", "7", "9"]))\(String(repeating: "9", count: rng.int(20)))"
  case 9: return "0.\(String(repeating: "0", count: rng.int(8)))\(rng.range(1, 9))"
  case 10: return "1.5"
  default: return String(rng.range(1, 3))
  }
}

private func structuredExpression(_ rng: inout FuzzRNG, depth: Int) -> String {
  if depth == 0 || rng.chance(0.25) {
    return rng.chance(0.5) ? numberLiteral(&rng) : rng.pick(exprVariables)
  }
  let sp = { (rng: inout FuzzRNG) -> String in rng.chance(0.15) ? " " : "" }
  switch rng.int(8) {
  case 0, 1, 2:
    let op = rng.pick(["+", "-", "*", "/", "**", "*", "/"])
    return structuredExpression(&rng, depth: depth - 1) + sp(&rng) + op + sp(&rng)
      + structuredExpression(&rng, depth: depth - 1)
  case 3: return "(" + structuredExpression(&rng, depth: depth - 1) + ")"
  case 4: return rng.pick(["-", "+", "--"]) + structuredExpression(&rng, depth: depth - 1)
  case 5: return rng.pick(unaryFunctions) + "(" + structuredExpression(&rng, depth: depth - 1) + ")"
  default:
    let n = rng.int(4)
    let items = (0..<n).map { _ in structuredExpression(&rng, depth: depth - 1) }.joined(separator: ",")
    let name = rng.pick(aggregates)
    return rng.chance(0.6) ? "\(name)({\(items)})" : "\(name)(\(items))"
  }
}

private let soupPieces: [String] = [
  "1", "2", "0", "10", "1.5", ".5", "5.", "1e3", "1e400", "2e-3", "e", "E", "x", "_", "screenSizeX", "screenOriginY",
  "windowSizeX", "newWindowSizeY", "foo", "sqrt", "min", "max", "sum", "count", "median", "stddev", "average", "log",
  "ln", "exp", "floor", "ceiling", "ceil", "abs", "trunc", "random", "(", ")", "{", "}", ",", "+", "-", "*", "/", "**",
  " ", " ", "\t", "é", "😀", "\u{301}", "\u{00A0}", "１", "²", "٣", "ⅷ", "一", "\u{200B}", "\u{FEFF}", "#", "%", ";",
  "Sqrt", "SCREENSIZEX", "screensizex", ".", "..", "e5", "\u{915}\u{94D}", "\u{1100}", "\u{1161}", "👍🏽", "🇺",
]

func fuzzExpressionFile(_ rng: inout FuzzRNG, count: Int) -> FixtureFile {
  var file = expressionFixtures()
  let variables = file.extra["variables"]!
  guard case .object(let sets) = variables, case .object(let defaults) = sets["default"]! else { fatalError() }
  var values: [String: Double] = [:]
  for (k, v) in defaults { if case .number(let n) = v { values[k] = n } }
  var evaluate: [J] = []
  var validate: [J] = []
  for i in 0..<count {
    let expression: String
    if i % 2 == 0 {
      expression = structuredExpression(&rng, depth: rng.range(1, 5))
    } else {
      expression = (0..<rng.range(1, 10)).map { _ in rng.pick(soupPieces) }.joined()
    }
    guard !expression.lowercased().contains("random") else { continue }
    var item: [String: J] = ["expression": .string(expression), "variables": "default"]
    do {
      item["result"] = .number(try SlateExpression.evaluate(expression, variables: values))
      let lowered = expression.lowercased()
      if ["**", "log(", "ln(", "exp(", "stddev", "sqrt"].contains(where: { lowered.contains($0) }) {
        item["tolerance"] = "ulp"
      }
    } catch {
      item["error"] = errorJ(error)
    }
    evaluate.append(.object(item))
    var v: [String: J] = ["expression": .string(expression), "variables": "window"]
    do {
      try SlateExpression.validate(expression, variables: SlateExpression.windowVariableNames)
      v["valid"] = true
    } catch {
      v["error"] = errorJ(error)
    }
    validate.append(.object(v))
  }
  var closest: [J] = []
  var distances: [J] = []
  let nameAlphabet = ["a", "b", "e", "é", "e\u{301}", "S", "s", "ß", "x", "😀", "İ", "i", "screen", "Size", "X"]
  for _ in 0..<count / 4 {
    let name = (0..<rng.range(0, 6)).map { _ in rng.pick(nameAlphabet) }.joined()
    let candidates = (0..<rng.range(0, 5)).map { _ in (0..<rng.range(0, 6)).map { _ in rng.pick(nameAlphabet) }.joined()
    }
    closest.append([
      "name": .string(name), "candidates": .array(candidates.map(J.string)),
      "result": .optional(closestName(to: name, in: candidates)),
    ])
    let other = (0..<rng.range(0, 6)).map { _ in rng.pick(nameAlphabet) }.joined()
    distances.append(["a": .string(name), "b": .string(other), "distance": .int(editDistance(name, other))])
  }
  file.sections = ["evaluate": evaluate, "validate": validate, "closestName": closest, "editDistance": distances]
  return file
}

// MARK: - Tokenizer

private let tokenAlphabet: [String] = [
  "a", "b", "push", " ", " ", "'", "\"", "|", ">", ",", ":", "=", ";", "\t", "\n", "\r\n", "\u{00A0}", "\u{3000}",
  "\u{200B}", "\u{FEFF}", "é", "e\u{301}", "\u{301}", "😀", "👍🏽", "🇺🇸", "\\", "n", "t", "#", "\u{2028}", "\u{85}",
  "\r", "x", "\u{0B}",
]

private func randomText(_ rng: inout FuzzRNG, _ alphabet: [String], max: Int) -> String {
  (0..<rng.range(0, max)).map { _ in rng.pick(alphabet) }.joined()
}

private func tokensJ(_ tokens: [SlateToken]) -> J {
  .array(
    tokens.map {
      ["text": .string($0.text), "raw": .string($0.raw), "isQuoted": .bool($0.isQuoted), "column": .int($0.column)]
    })
}

func fuzzTokenizerFile(_ rng: inout FuzzRNG, count: Int) -> FixtureFile {
  var tokenize: [J] = []
  var leading: [J] = []
  var split: [J] = []
  var firstIndex: [J] = []
  var quote: [J] = []
  var unquote: [J] = []
  var shell: [J] = []
  var escape: [J] = []
  for _ in 0..<count {
    let input = randomText(&rng, tokenAlphabet, max: 10)
    tokenize.append(
      .object(
        ["input": .string(input)].merging(outcome("tokens") { tokensJ(try SlateTokenizer.tokenize(input)) }) { a, _ in a
        }))
    let n = rng.int(4)
    var item: [String: J] = ["input": .string(input), "count": .int(n)]
    do {
      let (tokens, rest) = try SlateTokenizer.leadingTokens(input, count: n)
      item["tokens"] = tokensJ(tokens)
      item["rest"] = .string(rest)
    } catch {
      item["error"] = errorJ(error)
    }
    leading.append(.object(item))
    let separators = rng.pick(["|", "|>", ",", ";", ">"])
    var s: [String: J] = ["input": .string(input), "separators": .string(separators)]
    s.merge(
      outcome("pieces") {
        .array(
          try SlateTokenizer.split(input, separators: Set(separators)).map {
            ["separator": .optional($0.separator.map(String.init)), "text": .string($0.text)]
          })
      }
    ) { a, _ in a }
    split.append(.object(s))
    let character: Character = rng.pick([":", "=", "|"])
    let index = SlateTokenizer.firstIndex(of: character, outsideQuotesIn: input)
    firstIndex.append([
      "input": .string(input), "character": .string(String(character)),
      "index": index.map { .int(input.distance(from: input.startIndex, to: $0)) } ?? .null,
    ])
    quote.append([
      "input": .string(input), "quoted": .string(SlateTokenizer.quote(input)),
      "quotedIfNeeded": .string(SlateTokenizer.quoteIfNeeded(input)),
    ])
    unquote.append(["input": .string(input), "unquoted": .string(SlateTokenizer.unquote(input))])
    shell.append(
      .object(
        ["input": .string(input)].merging(
          outcome("arguments") { .array(try SlateSyntax.shellArguments(input).map(J.string)) }
        ) {
          a, _ in a
        }))
    escape.append([
      "input": .string(input), "escaped": .string(SlateSyntax.escapeText(input)),
      "unescaped": .string(SlateSyntax.unescapeText(input)),
    ])
  }
  return FixtureFile(
    name: "tokenizer.json", description: "fuzz",
    sections: [
      "tokenize": tokenize, "leadingTokens": leading, "split": split, "firstIndexOutsideQuotes": firstIndex,
      "quote": quote, "unquote": unquote, "shellArguments": shell, "escapeText": escape,
    ])
}

// MARK: - Keys

private let keyAlphabet: [String] = [
  "ctrl", "alt", "cmd", "shift", "fn", "hyper", "meh", "opt", "control", "+", "+", ":", ",", ";", "a", "A", "f4", "F13",
  "pad", "pad+", "+", "return", "Enter", "esc", "left", "PageUp", "'", "é", "e\u{301}", "😀", " ", "toggle", ":toggle",
  "x", "1", "mouse4", "rightShift", "space", "⌘", "✦", "ab", "\t", "\u{00A0}", "ß", "İ", "pad1", "padEnter", "f21",
]

private func comboDetailsJ(_ combo: KeyCombo) -> [String: J] {
  [
    "combo": comboJ(combo), "string": .string(combo.string), "display": .string(combo.display()),
    "displayPlain": .string(combo.display(hyperGlyph: false)), "keyIsValid": .bool(KeyNames.isValid(combo.key)),
  ]
}

func fuzzKeyFile(_ rng: inout FuzzRNG, count: Int) -> FixtureFile {
  var combos: [J] = []
  var keystrokes: [J] = []
  var names: [J] = []
  for _ in 0..<count {
    let input = randomText(&rng, keyAlphabet, max: 6)
    var item: [String: J] = ["input": .string(input)]
    if let combo = KeyCombo(string: input) {
      item.merge(comboDetailsJ(combo)) { a, _ in a }
    } else {
      item["combo"] = .null
    }
    combos.append(.object(item))
    var k: [String: J] = ["input": .string(input)]
    do {
      let parsed = try SlateSyntax.parseKeystroke(input)
      k["keys"] = comboJ(parsed.keys)
      k["modal"] = parsed.modal.map { ["keys": comboJ($0.keys), "toggle": .bool($0.toggle)] } ?? .null
    } catch {
      k["error"] = errorJ(error)
    }
    keystrokes.append(.object(k))
    let name = randomText(&rng, keyAlphabet, max: 2)
    let canonical = KeyNames.canonical(name)
    names.append([
      "name": .string(name), "canonical": .string(canonical), "valid": .bool(KeyNames.isValid(name)),
      "display": .string(KeyNames.displayName(for: canonical)), "displayRaw": .string(KeyNames.displayName(for: name)),
      "modifierKey": .bool(KeyNames.isModifierKey(name)), "mouseButton": .bool(KeyNames.isMouseButton(name)),
    ])
  }
  return FixtureFile(
    name: "keys.json", description: "fuzz",
    sections: ["keyCombos": combos, "keystrokes": keystrokes, "keyNames": names])
}

// MARK: - Operations

private let opNames = [
  "move", "resize", "push", "nudge", "throw", "corner", "chain", "sequence", "layout", "focus", "snapshot",
  "delete-snapshot", "activate-snapshot", "hint", "grid", "hide", "show", "toggle", "shell", "undo", "relaunch",
  "switch", "by-orientation", "insert-text", "open-url", "keystroke", "click", "press", "hold", "repeat", "wait",
  "stop-automations", "clipboard-history",
]

private let argVocabulary: [String] = [
  "screenOriginX;screenOriginY", "screenSizeX/2;screenSizeY", "0;0", "100,100", "+10%", "-100", "50%", "+0",
  "bar-resize:screenSizeY/2", "center", "bar", "none", "up", "down", "left", "right", "top", "bottom", "above", "below",
  "next", "previous", "prev", "1", "0", "-1", "2", "ordered:1", "1920x1080", "resize", "noresize",
  "resize:screenSizeX/2;screenSizeY", "top-left", "bottom-right", "'Safari'", "\"Google Chrome\"", "current", "all",
  "all-but:'iTerm'", "wait", "path:~/x", "'ls -la'", "save-to-disk;stack", "stack", "delete", "padding:4", "0:6,6",
  "1:12,8", "1920x1080:4,4", "type", "paste", "'hello'", "cmd+shift+4", "4:cmd,shift", "middle", "key:w", "mouse:left",
  "0.1", "while-held", "toggle", "times:3", "jitter:0.2", "'click'", "'push left'", "|", ">", "'", "\"", ",", ";", ":",
  "x", "é", "😀", "+screenSizeX/10", "screenSizeX / 2", "'screenSizeX / 2;0'", "min({1,2});max(3,4)", "1e3", "0x10",
  "inf", "-0", "'a b','c'", "all-but:x", "'it''s'", "\"say 'hi'\"", "10", "11", "key:shift+w", "mouse:back",
  "'repeat 0.5 \"click\"'", "'chain push up | push down'", "times:0", "jitter:0.6", "1.5", "nan", "  ", "\t",
]

private func randomOperationString(_ rng: inout FuzzRNG, depth: Int = 0) -> String {
  var name = rng.pick(opNames)
  if rng.chance(0.1) { name = name.uppercased() }
  if depth < 1, ["chain", "sequence"].contains(name.lowercased()), rng.chance(0.7) {
    let parts = (0..<rng.range(1, 3)).map { _ in randomOperationString(&rng, depth: depth + 1) }
    let separators = name.lowercased() == "chain" ? ["|", " | "] : ["|", " | ", ">", " > "]
    var text = name + " "
    for (i, p) in parts.enumerated() {
      if i > 0 { text += rng.pick(separators) }
      text += p
    }
    return text
  }
  let args = (0..<rng.range(0, 4)).map { _ in rng.pick(argVocabulary) }
  return ([name] + args).joined(separator: rng.pick([" ", " ", "  ", "\t"]))
}

private let exprStrings = [
  "screenOriginX", "screenSizeX/2", "screenSizeY", "0", "100", "screenOriginX + 10", "+10%", "-5%", "a b", "it's",
  "", "x\"y", "screenSizeX*2/3", "1e3", "-100", "50%", "windowSizeX", "screenSizeX;1", "a|b", "#", "  ",
]
private let nameStrings = [
  "Safari", "Google Chrome", "it's", "say \"hi\"", "", "a|b", "x>y", "a,b", "#", "  spaced ", "é", "😀", "current",
  "all", "left", "Bob's \"Best\" App", "a'b\"c", "tab\tx", "new\nline",
]

private func randomScreenRef(_ rng: inout FuzzRNG) -> ScreenRef {
  switch rng.int(6) {
  case 0: return .index(rng.range(-2, 5))
  case 1: return .orderedIndex(rng.range(-1, 3))
  case 2: return .resolution(width: rng.pick([1920, 1440, 2560, -1, 0]), height: rng.pick([1080, 900, 1440, 5]))
  case 3: return .relative(rng.pick(Direction.allCases))
  case 4: return .next
  default: return .previous
  }
}

private func randomCombo(_ rng: inout FuzzRNG) -> KeyCombo {
  let keys = [
    "a", "4", "'", ",", "+", "#", "space", "pad+", "left", "f13", "\"", "|", "é", "shift", "mouse4", "return",
  ]
  let mods: [Modifiers] = [[], .command, [.command, .shift], .hyper, .meh, [.function, .control], [.option]]
  return KeyCombo(key: rng.pick(keys), modifiers: rng.pick(mods))
}

private func randomInput(_ rng: inout FuzzRNG) -> SyntheticInput {
  rng.chance(0.5) ? .mouse(rng.pick(MouseButton.allCases)) : .key(randomCombo(&rng))
}

private func randomAction(_ rng: inout FuzzRNG, depth: Int) -> Action {
  let e = { (rng: inout FuzzRNG) -> String in rng.pick(exprStrings) }
  let maybeE = { (rng: inout FuzzRNG) -> String? in rng.chance(0.5) ? rng.pick(exprStrings) : nil }
  let maybeScreen = { (rng: inout FuzzRNG) -> ScreenRef? in rng.chance(0.5) ? randomScreenRef(&rng) : nil }
  let leafCount = 30
  let kind = depth >= 2 ? rng.int(leafCount) : rng.int(leafCount + 5)
  switch kind {
  case 0: return .move(x: e(&rng), y: e(&rng), width: e(&rng), height: e(&rng), screen: maybeScreen(&rng))
  case 1: return .resize(width: e(&rng), height: e(&rng), anchor: rng.pick(Corner.allCases))
  case 2:
    let style: PushStyle = rng.pick([.none, .center, .bar, .barResize(rng.pick(exprStrings))])
    return .push(direction: rng.pick(Direction.allCases), style: style, screen: maybeScreen(&rng))
  case 3: return .nudge(x: e(&rng), y: e(&rng))
  case 4: return .throwWindow(screen: randomScreenRef(&rng), width: maybeE(&rng), height: maybeE(&rng))
  case 5:
    return .corner(rng.pick(Corner.allCases), width: maybeE(&rng), height: maybeE(&rng), screen: maybeScreen(&rng))
  case 6: return .layout(name: rng.pick(nameStrings))
  case 7: return .focus(rng.pick(FocusDirection.allCases))
  case 8: return .focusApp(rng.pick(nameStrings))
  case 9: return .snapshot(name: rng.pick(nameStrings), save: rng.chance(0.5), stack: rng.chance(0.5))
  case 10: return .deleteSnapshot(name: rng.pick(nameStrings), all: rng.chance(0.5))
  case 11: return .activateSnapshot(name: rng.pick(nameStrings), delete: rng.chance(0.5))
  case 12: return .hint(characters: rng.chance(0.5) ? rng.pick(nameStrings) : nil)
  case 13:
    let grids = (0..<rng.int(3)).map { _ in
      GridScreen(
        screen: rng.pick(["0", "1", "10", "2", "1920x1080", "-1"]), width: rng.range(1, 12), height: rng.range(1, 12))
    }
    return .grid(padding: rng.chance(0.5) ? rng.int(10) : nil, grids: grids)
  case 14:
    let selector: AppSelector = rng.pick([
      .current, .all, .allBut(rng.pick(nameStrings)), .apps((0..<rng.range(1, 3)).map { _ in rng.pick(nameStrings) }),
    ])
    return rng.pick([.hide(selector), .show(selector), .toggle(selector)])
  case 15:
    return .shell(
      command: rng.pick(nameStrings + ["ls -la", "say 'hi'"]), wait: rng.chance(0.5),
      path: rng.chance(0.5) ? rng.pick(nameStrings) : nil)
  case 16: return rng.pick([.undo, .relaunch, .switchApp, .stopAutomations, .clipboardHistory])
  case 17:
    return .insertText(rng.pick(nameStrings + ["a\\b", "\\n", "line\nbreak"]), method: rng.pick(InsertMethod.allCases))
  case 18: return .openURL(rng.pick(nameStrings + ["https://x.y/a b"]))
  case 19: return .keystroke(randomCombo(&rng))
  case 20: return .click(rng.pick(MouseButton.allCases), count: rng.range(1, 12))
  case 21: return .press(randomInput(&rng), phase: rng.pick(PressPhase.allCases))
  case 22: return .hold(randomInput(&rng))
  case 23: return .wait(rng.pick([0, 0.5, 1, 2.5, 1e-7, 1e20, 0.1 + 0.2, 1e-5, 123456.789]))
  case 24, 25, 26, 27, 28, 29: return rng.pick([.undo, .focus(.left)])
  default:
    switch rng.int(4) {
    case 0: return .chain((0..<rng.range(1, 3)).map { _ in randomAction(&rng, depth: depth + 1) })
    case 1:
      return .sequence(
        (0..<rng.range(1, 3)).map { _ in SequenceStep(randomAction(&rng, depth: depth + 1), keepWindow: rng.chance(0.3))
        })
    case 2:
      return .byOrientation(
        landscape: randomAction(&rng, depth: depth + 1), portrait: randomAction(&rng, depth: depth + 1))
    default:
      return .autoRepeat(
        randomAction(&rng, depth: depth + 1), interval: rng.pick([0.1, 1, 0.05, 1e-3, 2.5, 1e15, 0.30000000000000004]),
        mode: rng.pick(RepeatMode.allCases), times: rng.chance(0.5) ? rng.range(1, 100) : nil,
        jitter: rng.pick([0, 0.1, 0.5, 0.123456789]))
    }
  }
}

private let jsonKeys = [
  "op", "x", "y", "width", "height", "screen", "anchor", "direction", "style", "operations", "steps", "name", "app",
  "save", "stack", "all", "delete", "characters", "padding", "grids", "command", "wait", "path", "text", "method",
  "url",
  "keys", "landscape", "portrait", "button", "count", "input", "phase", "action", "interval", "mode", "seconds",
  "times",
  "jitter",
]

private func randomJSONValue(_ rng: inout FuzzRNG, depth: Int) -> String {
  switch rng.int(depth > 1 ? 9 : 11) {
  case 0: return "null"
  case 1: return rng.chance(0.5) ? "true" : "false"
  case 2:
    return rng.pick([
      "0", "1", "-1", "2.5", "1e21", "1e300", "-0.0", "0.1", "12345678901234567890", "1e-7", "100.0", "4.5", "11",
      "0.6",
    ])
  case 3, 4, 5:
    let strings =
      argVocabulary + exprStrings + nameStrings + opNames + [
        "top-left", "bottom-right", "while-held", "toggle", "auto", "type", "paste", "mouse:right", "key:w", "down",
        "up",
        "left", "current", "all-but:x", "cmd+shift+4", "bogus", "1", "ordered:2",
      ]
    return J.quote(rng.pick(strings))
  case 6:
    return "[" + (0..<rng.int(3)).map { _ in randomJSONValue(&rng, depth: depth + 1) }.joined(separator: ",") + "]"
  case 7, 8: return randomJSONAction(&rng, depth: depth + 1)
  default:
    return "{"
      + (0..<rng.int(3)).map { _ in
        "\(J.quote(rng.pick(["0", "1", "width", "height", "x"]))):\(randomJSONValue(&rng, depth: depth + 1))"
      }.joined(separator: ",") + "}"
  }
}

private func randomJSONAction(_ rng: inout FuzzRNG, depth: Int) -> String {
  var members = ["\"op\":\(J.quote(rng.chance(0.95) ? rng.pick(opNames) : rng.pick(["MOVE", "teleport", ""])))"]
  var used: Set<String> = ["op"]
  for _ in 0..<rng.int(5) {
    let key = rng.pick(jsonKeys)
    guard used.insert(key).inserted else { continue }
    members.append("\(J.quote(key)):\(randomJSONValue(&rng, depth: depth + 1))")
  }
  return "{" + members.joined(separator: ",") + "}"
}

func fuzzOperationFile(_ rng: inout FuzzRNG, count: Int) -> FixtureFile {
  var parse: [J] = []
  for _ in 0..<count {
    let input = randomOperationString(&rng)
    var item: [String: J] = ["input": .string(input)]
    do {
      let action = try SlateSyntax.parseOperation(input)
      item["action"] = actionJ(action)
      item["isWindowGeometry"] = .bool(action.isWindowGeometry)
      let text = SlateSyntax.format(action)
      item["format"] = .string(text)
      let canonical = try JSONDecoder().decode(Action.self, from: JSONEncoder().encode(action))
      let canonicalText = SlateSyntax.format(canonical)
      if canonicalText != text { item["formatCanonical"] = .string(canonicalText) }
      do {
        let reparsed = try SlateSyntax.parseOperation(canonicalText)
        item["roundTrips"] = .bool(reparsed == canonical)
        if reparsed != canonical { item["reparsed"] = actionJ(reparsed) }
      } catch {
        item["reparseError"] = errorJ(error)
      }
    } catch {
      item["error"] = errorJ(error)
    }
    parse.append(.object(item))
  }
  var format: [J] = []
  for _ in 0..<count {
    let action = randomAction(&rng, depth: 0)
    guard let data = try? JSONEncoder().encode(action), let decoded = try? JSONDecoder().decode(Action.self, from: data)
    else { continue }
    var item: [String: J] = ["action": actionJ(action)]
    let text = SlateSyntax.format(decoded)
    item["format"] = .string(text)
    do {
      let reparsed = try SlateSyntax.parseOperation(text)
      item["reparsed"] = actionJ(reparsed)
      item["roundTrips"] = .bool(reparsed == decoded)
    } catch {
      item["reparseError"] = errorJ(error)
    }
    format.append(.object(item))
  }
  var decode: [J] = []
  for _ in 0..<count {
    let input = rng.chance(0.15) ? J.quote(randomOperationString(&rng)) : randomJSONAction(&rng, depth: 0)
    var item: [String: J] = ["json": .string(input)]
    item.merge(outcome("action") { actionJ(try JSONDecoder().decode(Action.self, from: Data(input.utf8))) }) { a, _ in a
    }
    decode.append(.object(item))
  }
  return FixtureFile(
    name: "operations.json", description: "fuzz", sections: ["parse": parse, "format": format, "decode": decode])
}

// MARK: - Screens and frames

private let sizes: [(CGFloat, CGFloat)] = [
  (1440, 900), (1512, 982), (1920, 1080), (2560, 1440), (1080, 1920), (1728, 1117), (1280, 800), (1366, 768),
  (1600, 900), (1050, 1680), (1920, 1920), (3008, 1692), (1470, 956), (1000, 1000), (1279.5, 799.5),
]

private func randomSetup(_ rng: inout FuzzRNG, name: String) -> ScreenSetup {
  var screens: [ScreenInfo] = []
  let n = rng.range(1, 4)
  for i in 0..<n {
    let (w, h) = rng.pick(sizes)
    var frame: CGRect
    if i == 0 {
      frame = CGRect(x: 0, y: 0, width: w, height: h)
    } else {
      let anchor = rng.pick(screens).frame
      let offset = CGFloat(rng.pick([0, 0, -100, 100, 240, -420, 37, 0.5]))
      switch rng.int(6) {
      case 0: frame = CGRect(x: anchor.maxX, y: anchor.minY + offset, width: w, height: h)
      case 1: frame = CGRect(x: anchor.minX - w, y: anchor.minY + offset, width: w, height: h)
      case 2: frame = CGRect(x: anchor.minX + offset, y: anchor.minY - h, width: w, height: h)
      case 3: frame = CGRect(x: anchor.minX + offset, y: anchor.maxY, width: w, height: h)
      case 4: frame = CGRect(x: anchor.maxX, y: anchor.maxY, width: w, height: h)  // corner only
      default:
        frame = CGRect(
          x: anchor.maxX + CGFloat(rng.pick([0, 50, 1000])), y: CGFloat(rng.pick([-2000, 0, 3000])), width: w, height: h
        )
      }
    }
    let top = i == 0 ? CGFloat(rng.pick([0, 25, 32, 38])) : CGFloat(rng.pick([0, 25]))
    let dock = CGFloat(rng.pick([0, 0, 50, 80]))
    var visible = CGRect(x: frame.minX, y: frame.minY + top, width: frame.width, height: frame.height - top)
    switch rng.int(3) {
    case 0: visible.size.height -= dock
    case 1:
      visible.origin.x += dock
      visible.size.width -= dock
    default: visible.size.width -= dock
    }
    screens.append(
      ScreenInfo(
        displayID: UInt32(i + 1), name: "S\(i)", frame: frame, visibleFrame: visible, isMain: i == 0,
        scale: rng.pick([1, 2, 1.5])))
  }
  if rng.chance(0.2) { screens.shuffle(using: &rng) }
  var windows: [(String, CGRect)] = []
  for j in 0..<rng.range(1, 3) {
    let s = rng.pick(screens).frame
    let x = s.minX + CGFloat(rng.int(Int(s.width))) + (rng.chance(0.3) ? 0.5 : 0) - (rng.chance(0.2) ? 300 : 0)
    let y = s.minY + CGFloat(rng.int(Int(s.height))) + (rng.chance(0.3) ? 0.25 : 0)
    let w = CGFloat(rng.pick([400, 800, 1200, 3000, 1, 0, 333.5]))
    let h = CGFloat(rng.pick([300, 600, 900, 2000, 1, 0, 222.25]))
    windows.append(("w\(j)", CGRect(x: x, y: y, width: w, height: h)))
  }
  if rng.chance(0.1) { windows.append(("off", CGRect(x: 90000, y: -90000, width: 100, height: 100))) }
  return ScreenSetup(
    name: name, description: "fuzz", screens: screens, windows: windows,
    settings: [rng.pick(allSettingsVariants), rng.pick(allSettingsVariants)])
}

extension FuzzRNG: RandomNumberGenerator {}

private let fuzzRefs: [String?] = [
  nil, "0", "1", "2", "3", "-1", "-2", "ordered:0", "ordered:2", "ordered:-1", "1920x1080", "1440x900", "1080x1920",
  "left", "right", "up", "down", "next", "previous",
]

private func randomGeometryOp(_ rng: inout FuzzRNG) -> String {
  let ex = [
    "screenOriginX", "screenOriginY", "screenSizeX/2", "screenSizeY", "screenSizeX/3", "windowSizeX", "screenSizeX*2/3",
    "screenOriginX+screenSizeX/2", "screenOriginY+screenSizeY-newWindowSizeY", "screenSizeX/1.3", "windowTopLeftX+10",
    "100", "0", "-50", "screenOriginX+screenSizeX-newWindowSizeX", "floor(screenSizeX/3)", "newWindowSizeX/2",
  ]
  let screen = rng.chance(0.4) ? " " + rng.pick(fuzzRefs.compactMap { $0 }) : ""
  switch rng.int(7) {
  case 0: return "move \(rng.pick(ex));\(rng.pick(ex)) \(rng.pick(ex));\(rng.pick(ex))\(screen)"
  case 1:
    let amounts = [
      "+10%", "-10%", "+0", "+100", "-100", "50%", "screenSizeX/2", "+screenSizeX/10", "-33%", "+7%", "400", "+1.5",
    ]
    let anchor = rng.chance(0.6) ? " " + rng.pick(Corner.allCases).rawValue : ""
    return "resize \(rng.pick(amounts)) \(rng.pick(amounts))\(anchor)"
  case 2:
    let style = rng.pick(["", " none", " center", " bar", " bar-resize:screenSizeX/3", " bar-resize:screenSizeY/2"])
    return
      "push \(rng.pick(["up", "down", "left", "right"]))\(style.isEmpty && !screen.isEmpty ? " none" : style)\(screen)"
  case 3:
    let amounts = ["+10%", "-10%", "+0", "+100", "-100", "50", "+screenSizeX/10", "+0.5", "-0.5"]
    return "nudge \(rng.pick(amounts)) \(rng.pick(amounts))"
  case 4:
    let style = rng.pick([
      "", " resize", " noresize", " resize:screenSizeX/2;screenSizeY", " resize:windowSizeX*2;windowSizeY/2",
    ])
    return "throw \(rng.pick(fuzzRefs.compactMap { $0 }))\(style)"
  case 5:
    let style = rng.pick([
      "", " resize:screenSizeX/2;screenSizeY/2", " resize:400;300", " noresize", " resize:newWindowSizeX;screenSizeY",
    ])
    return
      "corner \(rng.pick(Corner.allCases).rawValue)\(style.isEmpty && !screen.isEmpty ? " noresize" : style)\(screen)"
  default:
    return "by-orientation '\(randomGeometryOpNoQuotes(&rng))' '\(randomGeometryOpNoQuotes(&rng))'"
  }
}

private func randomGeometryOpNoQuotes(_ rng: inout FuzzRNG) -> String {
  var op = randomGeometryOp(&rng)
  while op.contains("'") { op = randomGeometryOp(&rng) }
  return op
}

func fuzzScreenAndFrameFiles(_ rng: inout FuzzRNG, setupCount: Int, opCount: Int) -> [FixtureFile] {
  let setups = (0..<setupCount).map { randomSetup(&rng, name: "fuzz\($0)") }
  var resolve: [J] = []
  var containing: [J] = []
  var ordered: [J] = []
  for setup in setups {
    ordered.append([
      "setup": .string(setup.name), "names": .array(setup.screens.orderedLeftToRight().map { .string($0.name) }),
    ])
    for (windowName, window) in setup.windows {
      for settingsName in setup.settings {
        let settings = SlateSettings(settingsVariants[settingsName]!)
        var results: [String: J] = [:]
        for raw in fuzzRefs {
          let ref = raw.flatMap { ScreenRef(slate: $0) }
          results[raw ?? "(none)"] =
            ScreenResolver.screen(for: ref, windowFrame: window, screens: setup.screens, settings: settings).map {
              .string($0.name)
            } ?? .null
        }
        resolve.append([
          "setup": .string(setup.name), "window": .string(windowName), "settings": .string(settingsName),
          "results": .object(results),
        ])
      }
      containing.append([
        "setup": .string(setup.name), "rect": rectJ(window),
        "screen": setup.screens.screen(containing: window).map { .string($0.name) } ?? .null,
      ])
    }
  }
  let screensFile = FixtureFile(
    name: "screens.json", description: "fuzz",
    sections: ["resolve": resolve, "containing": containing, "orderedLeftToRight": ordered],
    extra: [
      "setups": .object(Dictionary(uniqueKeysWithValues: setups.map { ($0.name, $0.json) })),
      "settings": .object(settingsVariants.mapValues { settingsJ(SlateSettings($0)) }),
    ])

  var ops: [String] = []
  var parsed: [String: Action] = [:]
  while ops.count < opCount {
    let op = randomGeometryOp(&rng)
    guard parsed[op] == nil, let action = try? SlateSyntax.parseOperation(op) else { continue }
    ops.append(op)
    parsed[op] = action
  }
  var frames: [J] = []
  var origins: [J] = []
  for setup in setups {
    for (windowName, window) in setup.windows {
      for settingsName in setup.settings {
        let context = WindowContext(
          frame: window, screens: setup.screens, settings: SlateSettings(settingsVariants[settingsName]!))
        var results: [String: J] = [:]
        for op in ops {
          do {
            let r = try FrameCalculator.targetFrame(for: parsed[op]!, in: context)
            results[op] = [
              .number(Double(r.origin.x)), .number(Double(r.origin.y)), .number(Double(r.size.width)),
              .number(Double(r.size.height)),
            ]
          } catch {
            results[op] = ["error": errorJ(error)]
          }
        }
        frames.append([
          "setup": .string(setup.name), "window": .string(windowName), "settings": .string(settingsName),
          "results": .object(results),
        ])
        let size = CGSize(
          width: CGFloat(rng.pick([300, 2000, 333.5, 0])), height: CGFloat(rng.pick([200, 1500, 222.25, 0])))
        var originResults: [String: J] = [:]
        for op in ops {
          do {
            let p = try FrameCalculator.targetOrigin(for: parsed[op]!, in: context, actualSize: size)
            originResults[op] = [.number(Double(p.x)), .number(Double(p.y))]
          } catch {
            originResults[op] = ["error": errorJ(error)]
          }
        }
        origins.append([
          "setup": .string(setup.name), "window": .string(windowName), "settings": .string(settingsName),
          "actualSize": ["width": .number(Double(size.width)), "height": .number(Double(size.height))],
          "results": .object(originResults),
        ])
      }
    }
  }
  let framesFile = FixtureFile(
    name: "frames.json", description: "fuzz", sections: ["targetFrame": frames, "targetOrigin": origins],
    extra: ["actions": .object(parsed.mapValues(actionJ))])
  return [screensFile, framesFile]
}

// MARK: - Config

private let comboStrings = [
  "hyper+a", "ctrl+cmd+left", "cmd+shift+'", "f", "mouse4", "Hyper+Return", "shift+cmd+ctrl+alt+PageUp", "bogus+a", "",
  "ctrl+alt+f4", "fn+ctrl+a", "meh+x", "cmd++", "a", "ctrl+pad+",
]

private func randomConfigJSON(_ rng: inout FuzzRNG) -> String {
  var top: [String] = []
  if rng.chance(0.3) { top.append("\"version\": \(rng.pick(["1", "2", "1.0", "\"1\"", "null"]))") }
  if rng.chance(0.4) {
    var g: [String] = []
    if rng.chance(0.5) { g.append("\"launchAtLogin\": \(rng.pick(["true", "false", "null"]))") }
    if rng.chance(0.5) { g.append("\"slateConfigPaths\": [\(rng.pick(["", "\"~/a\"", "\"~/.slate.js\", \"/b\""]))]") }
    if rng.chance(0.5) { g.append("\"hotstringsEnabled\": \(rng.pick(["true", "false"]))") }
    if rng.chance(0.5) { g.append("\"showActionHUD\": \(rng.pick(["true", "false"]))") }
    top.append("\"general\": {\(g.joined(separator: ", "))}")
  }
  if rng.chance(0.4) {
    let settingKeys = [
      "defaultToCurrentScreen", "nudgePercentOf", "a", "b", "undoMaxStackSize", "x y", "é", "A", "_z", "10", "9",
    ]
    let settingValues = [
      "true", "false", "\"windowSize\"", "0.1", "20", "1e20", "-0.0", "\"\"", "1.5", "123456.789", "1e-7",
      "9007199254740993", "100.0", "\"x\"",
    ]
    let s = (0..<rng.int(5)).map { _ in "\(J.quote(rng.pick(settingKeys))): \(rng.pick(settingValues))" }
    top.append("\"settings\": {\(s.joined(separator: ", "))}")
  }
  if rng.chance(0.4) {
    var k: [String] = []
    if rng.chance(0.5) { k.append("\"capsLock\": \(rng.pick(["\"hyper\"", "\"off\""]))") }
    if rng.chance(0.5) { k.append("\"capsLockAlone\": \(rng.pick(["\"escape\"", "\"nothing\""]))") }
    if rng.chance(0.6) {
      let tokens = [
        "\"ctrl\"", "\"alt\"", "\"shift\"", "\"cmd\"", "\"fn\"", "\"hyper\"", "\"meh\"", "\"bogus\"", "\"Control\"",
        "\"⌘\"",
      ]
      k.append("\"hyperModifiers\": [\((0..<rng.int(5)).map { _ in rng.pick(tokens) }.joined(separator: ", "))]")
    }
    top.append("\"keyboard\": {\(k.joined(separator: ", "))}")
  }
  if rng.chance(0.7) {
    var bindings: [String] = []
    for i in 0..<rng.int(4) {
      var b: [String] = []
      if rng.chance(0.7) { b.append("\"id\": \"E0000000-0000-4000-8000-0000000001\(String(format: "%02d", i))\"") }
      if rng.chance(0.4) { b.append("\"name\": \(J.quote(rng.pick(nameStrings)))") }
      b.append("\"keys\": \(J.quote(rng.pick(comboStrings)))")
      if rng.chance(0.2) {
        b.append(
          "\"modal\": {\"keys\": \(J.quote(rng.pick(comboStrings)))\(rng.chance(0.5) ? ", \"toggle\": true" : "")}")
      }
      b.append(
        "\"action\": \(rng.chance(0.4) ? J.quote(randomOperationString(&rng)) : randomJSONAction(&rng, depth: 1))")
      if rng.chance(0.3) { b.append("\"repeats\": \(rng.pick(["true", "false", "null"]))") }
      if rng.chance(0.3) { b.append("\"enabled\": \(rng.pick(["true", "false"]))") }
      if rng.chance(0.3) {
        b.append(
          "\"onlyInApps\": [\((0..<rng.int(3)).map { _ in J.quote(rng.pick(["com.a", "b.desktop", "steam_app_1"])) }.joined(separator: ","))]"
        )
      }
      bindings.append("{\(b.joined(separator: ", "))}")
    }
    top.append("\"bindings\": [\(bindings.joined(separator: ", "))]")
  }
  if rng.chance(0.3) {
    var hs: [String] = []
    for i in 0..<rng.int(3) {
      var h: [String] = ["\"trigger\": \(J.quote(rng.pick([";x", "brb", "", "é", "a b"])))"]
      if rng.chance(0.7) { h.append("\"id\": \"F0000000-0000-4000-8000-0000000001\(String(format: "%02d", i))\"") }
      if rng.chance(0.5) { h.append("\"replacement\": \(J.quote(rng.pick(nameStrings)))") }
      if rng.chance(0.3) { h.append("\"fire\": \(rng.pick(["\"afterDelimiter\"", "\"immediately\""]))") }
      if rng.chance(0.3) { h.append("\"method\": \(rng.pick(["\"paste\"", "\"type\"", "\"auto\""]))") }
      if rng.chance(0.3) { h.append("\"caseSensitive\": \(rng.pick(["true", "false"]))") }
      if rng.chance(0.3) { h.append("\"wordBoundary\": \(rng.pick(["true", "false"]))") }
      if rng.chance(0.2) { h.append("\"notes\": \(J.quote(rng.pick(nameStrings)))") }
      if rng.chance(0.2) { h.append("\"action\": \(randomJSONAction(&rng, depth: 1))") }
      if rng.chance(0.2) { h.append("\"exceptInApps\": [\"x\"]") }
      hs.append("{\(h.joined(separator: ", "))}")
    }
    top.append("\"hotstrings\": [\(hs.joined(separator: ", "))]")
  }
  if rng.chance(0.3) {
    var c: [String] = []
    if rng.chance(0.5) {
      c.append("\"shortcut\": \(rng.pick(["null", "\"cmd+shift+v\"", "\"Ctrl+Alt+V\"", "\"bogus+v\""]))")
    }
    if rng.chance(0.5) { c.append("\"maxItems\": \(rng.pick(["5", "0", "-1", "200"]))") }
    if rng.chance(0.5) { c.append("\"retentionDays\": \(rng.pick(["0", "30", "-7"]))") }
    if rng.chance(0.5) { c.append("\"excludedApps\": [\(rng.pick(["", "\"a\"", "\"a\", \"b\""]))]") }
    top.append("\"clipboard\": {\(c.joined(separator: ", "))}")
  }
  if rng.chance(0.3) {
    var a: [String] = []
    if rng.chance(0.5) { a.append("\"stopShortcut\": \(rng.pick(["null", "\"hyper+esc\"", "\"ctrl+alt+esc\""]))") }
    if rng.chance(0.5) { a.append("\"maxRunMinutes\": \(rng.pick(["0", "2.5", "10", "1e-7", "0.1"]))") }
    top.append("\"automation\": {\(a.joined(separator: ", "))}")
  }
  if rng.chance(0.3) {
    var l: [String] = []
    for _ in 0..<rng.int(3) {
      let apps = (0..<rng.int(3)).map { _ in
        "{\"app\": \(J.quote(rng.pick(nameStrings))), \"operations\": [\(rng.chance(0.5) ? J.quote(randomOperationString(&rng)) : "")]\(rng.chance(0.4) ? ", \"options\": {\"repeat\": true, \"titleOrder\": [\"a\"]}" : "")}"
      }
      l.append("{\"name\": \(J.quote(rng.pick(nameStrings))), \"apps\": [\(apps.joined(separator: ", "))]}")
    }
    top.append("\"layouts\": [\(l.joined(separator: ", "))]")
  }
  if rng.chance(0.2) {
    top.append(
      "\"defaults\": [{\"target\": \"x\", \(rng.pick(defaultConditions))}]"
    )
  }
  if rng.chance(0.2) {
    top.append(
      "\"island\": {\"cheatSheetDelay\": \(rng.pick(["0.5", "1", "1.25", "0"]))\(rng.chance(0.5) ? ", \"enabled\": false" : "")}"
    )
  }
  // A section from a newer Slated: kept and written back as read.
  if rng.chance(0.2) {
    top.append("\(J.quote(rng.pick(["future", "aaa", "Bindings", "zzz"]))): \(randomJSONValue(&rng, depth: 0))")
  }
  return "{" + top.joined(separator: ", ") + "}"
}

/// Display default conditions: today's shape, the old one (Swift's enum coding), and mixes that fail.
private let defaultConditions = [
  "\"count\": 2", "\"resolutions\": [\"1x1\", \"2560x1440\"]", "\"condition\": {\"count\": {\"_0\": 2}}",
  "\"condition\": {\"resolutions\": {\"_0\": [\"1x1\", \"2560x1440\"]}}", "\"count\": 2, \"resolutions\": []",
  "\"count\": null, \"condition\": {\"count\": {\"_0\": 1}}",
]

func fuzzConfigFile(_ rng: inout FuzzRNG, count: Int) -> FixtureFile {
  var decode: [J] = []
  for i in 0..<count {
    let input = randomConfigJSON(&rng)
    var item: [String: J] = ["name": .string("fuzz \(i)"), "input": .string(input)]
    do {
      let config = try SlatedConfiguration.decode(from: Data(input.utf8))
      do {
        let encoded = String(decoding: try config.encoded(), as: UTF8.self)
        item["encoded"] = .string(maskRandomUUIDs(encoded, input: input))
        let again = try SlatedConfiguration.decode(from: config.encoded())
        item["roundTrips"] = .bool(again == config)
        if again != config { FileHandle.standardError.write(Data("config round trip differs: \(input)\n".utf8)) }
        let encodedAgain = String(decoding: try again.encoded(), as: UTF8.self)
        if encodedAgain != encoded { FileHandle.standardError.write(Data("config re-encode differs: \(input)\n".utf8)) }
      } catch {
        item["encodeError"] = errorJ(error)
      }
    } catch {
      item["error"] = errorJ(error)
    }
    decode.append(.object(item))
  }
  return FixtureFile(name: "config.json", description: "fuzz", sections: ["decode": decode], depth: ["decode": 2])
}

// MARK: - Hotstrings

private let hotAlphabet = [
  "a", "b", "c", "A", "B", "é", "e\u{301}", ";", ".", "!", " ", "x", "ß", "S", "s", "😀", "\u{0301}", "_", "\n", "İ",
  "i",
]

private func randomHotstrings(_ rng: inout FuzzRNG, base: Int) -> [Hotstring] {
  (0..<rng.range(1, 4)).map { i in
    let trigger = (0..<rng.range(0, 3)).map { _ in rng.pick(hotAlphabet) }.joined()
    return Hotstring(
      id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", base + i))!, trigger: trigger,
      replacement: "r", enabled: rng.chance(0.9), caseSensitive: rng.chance(0.5),
      fire: rng.chance(0.5) ? .immediately : .afterDelimiter, wordBoundary: rng.chance(0.4),
      onlyInApps: rng.chance(0.2) ? ["a"] : [], exceptInApps: rng.chance(0.2) ? ["b"] : [])
  }
}

func fuzzHotstringFile(_ rng: inout FuzzRNG, count: Int) -> FixtureFile {
  var matcher: [J] = []
  for s in 0..<count {
    let hotstrings = randomHotstrings(&rng, base: s * 100)
    var m = HotstringMatcher(hotstrings: hotstrings)
    var steps: [J] = []
    for _ in 0..<rng.range(5, 25) {
      switch rng.int(10) {
      case 0:
        m.backspace()
        steps.append(["backspace": true])
      case 1 where rng.chance(0.3):
        m.reset()
        steps.append(["reset": true])
      case 2 where rng.chance(0.3):
        let update = randomHotstrings(&rng, base: s * 100 + 50)
        m.update(update)
        steps.append(["update": toJ(update)])
      default:
        let app: String? = rng.pick([nil, "a", "b", nil])
        let text =
          rng.chance(0.15) ? (0..<rng.range(0, 3)).map { _ in rng.pick(hotAlphabet) }.joined() : rng.pick(hotAlphabet)
        let match = m.feed(text, appBundleID: app)
        steps.append([
          "feed": .string(text), "app": .optional(app),
          "match": match.map { match in
            [
              "id": .string(match.hotstring.id.uuidString), "trigger": .string(match.hotstring.trigger),
              "deleteCount": .int(match.deleteCount), "delimiter": .optional(match.delimiter),
            ]
          } ?? .null,
        ])
      }
    }
    matcher.append(["name": .string("fuzz \(s)"), "hotstrings": toJ(hotstrings), "steps": .array(steps)])
  }
  var templates: [J] = []
  let pieces = [
    "{", "}", "{{", "}}", "date", "time", "datetime", "clipboard", "date:", "yyyy", "MM", "dd", "HH", "'", "x", " ",
    "é", "EEE", "a", "Z", "h:mm",
  ]
  let posix = Locale(identifier: "en_US_POSIX")
  for _ in 0..<count {
    let text = (0..<rng.range(0, 7)).map { _ in rng.pick(pieces) }.joined()
    let seconds = rng.pick([1_793_000_000.0, 0, -3600, 951_782_400, 1_792_681_445.678])
    templates.append([
      "text": .string(text), "date": "fuzz", "now": .number(seconds), "clipboard": "clip",
      "result": .string(
        HotstringTemplate.expand(text, now: Date(timeIntervalSince1970: seconds), clipboard: "clip", locale: posix)),
    ])
  }
  return FixtureFile(
    name: "hotstrings.json", description: "fuzz", sections: ["matcher": matcher, "templates": templates],
    extra: ["locale": "en_US_POSIX", "timeZone": "UTC"], depth: ["matcher": 3])
}

// MARK: - Slate config files

private let slateLines: [String] = [
  "config defaultToCurrentScreen true", "config nudgePercentOf windowSize", "config bogusSetting 1", "config a:b c",
  "config windowHintsCharacters 'A B'", "alias full move screenOriginX;screenOriginY screenSizeX;screenSizeY",
  "alias dir left", "bind a:ctrl ${full}", "bind b:ctrl push ${dir}", "bind c:ctrl ${missing}",
  "bind ':ctrl push up # c",
  "bind 1:ctrl,f4 push up", "bind 1:ctrl,f4:toggle push down", "bind x:ctrl,shift chain push up | push down",
  "layout l 'iTerm':REPEAT,IGNORE_FAIL push up | push down", "layout l BEFORE shell 'ls'", "layout l AFTER undo",
  "layout l 'Safari':TITLE_ORDER=a;b push left", "layout l 'X':BOGUS push left",
  "layout l 'Y':TITLE_ORDER_REGEX=[ push",
  "default l count:2", "default l resolutions:1440x900;1920x1080", "default l bogus", "source ~/.other if_exists",
  "source missing.slate", "source /abs.slate", "source ~/.slate.js", "# comment", "   ", "bind", "bogus line",
  "bind a:ctrl push sideways", "bind z:cmd hint ASDF", "bind q:alt grid padding:4 0:6,6", "BIND m:ctrl undo",
  "bind a:ctrl push up", "bind a:ctrl push up", "config orderScreensLeftToRight false", "alias x ${dir} ${dir}",
  "bind w:ctrl ${x}", "layout 'Two Words' 'App':MAIN_FIRST,MAIN_LAST push up", "bind e:ctrl focus 'Safari' # x",
]

func fuzzSlateConfigFile(_ rng: inout FuzzRNG, count: Int) -> FixtureFile {
  let home = "/Users/tester"
  var parsed: [J] = []
  for i in 0..<count {
    let text = (0..<rng.range(1, 8)).map { _ in rng.pick(slateLines) }.joined(
      separator: rng.pick(["\n", "\r\n", "\n\n"]))
    let files: [String: String] = [
      "\(home)/.other": (0..<rng.range(0, 3)).map { _ in rng.pick(slateLines) }.joined(separator: "\n"),
      "/abs.slate": "bind y:ctrl undo\nsource /abs.slate",
    ]
    let path: String? = rng.chance(0.8) ? "\(home)/.slate" : nil
    let result = SlateConfigParser.parse(text, path: path, homeDirectory: home) { files[$0] }
    let fileJ: J = [
      "settings": settingsJ(result.settings), "bindings": toJ(result.bindings), "layouts": toJ(result.layouts),
      "defaults": toJ(result.defaults),
      "diagnostics": .array(
        result.diagnostics.map { d in
          var object = toJ(d)
          if case .object(var members) = object {
            members["description"] = .string(d.description)
            object = .object(members)
          }
          return object
        }),
    ]
    parsed.append([
      "name": .string("fuzz \(i)"), "text": .string(text), "path": .optional(path), "home": .string(home),
      "files": .object(files.mapValues(J.string)), "result": fileJ,
    ])
  }
  return FixtureFile(name: "slate-config.json", description: "fuzz", sections: ["parse": parsed], depth: ["parse": 2])
}

// MARK: - Settings

func fuzzSettingsFile(_ rng: inout FuzzRNG, count: Int) -> FixtureFile {
  let alphabet = [
    "0", "1", "9", ".", "e", "E", "+", "-", "x", "X", "p", "P", "i", "n", "f", "a", "t", "y", "I", "N", "_", " ", ",",
    "(", ")", "true", "no", "１", "\t",
  ]
  var fromSlate: [J] = []
  for _ in 0..<count {
    let input = (0..<rng.range(0, 6)).map { _ in rng.pick(alphabet) }.joined()
    fromSlate.append(["input": .string(input), "value": settingJ(SettingValue(slate: input))])
  }
  return FixtureFile(name: "settings.json", description: "fuzz", sections: ["fromSlate": fromSlate])
}

// MARK: - JSON5 mutations of configs

/// Rewrites JSON text with JSON5 conveniences at random: comments, trailing commas, unquoted or
/// single-quoted keys, other number spellings, escapes and odd whitespace.
private func json5Mutation(_ json: String, _ rng: inout FuzzRNG) -> String {
  var out = ""
  var chars = Array(json)
  var i = 0
  var inString = false
  var stringStart = 0
  if rng.chance(0.1) { out += "\u{FEFF}" }
  while i < chars.count {
    let c = chars[i]
    if inString {
      if c == "\\" {
        out.append(c)
        out.append(chars[i + 1])
        i += 2
        continue
      }
      if c == "\"" {
        inString = false
        // A key (followed by ':') may lose its quotes or get single quotes.
        var j = i + 1
        while j < chars.count, chars[j] == " " { j += 1 }
        let content = String(chars[(stringStart + 1)..<i])
        let isKey = j < chars.count && chars[j] == ":"
        let identifier = !content.isEmpty && content.allSatisfy { $0.isLetter || $0 == "_" || $0 == "$" }
        if isKey && identifier && rng.chance(0.4) {
          out.removeLast(content.count + 1)
          out += content
        } else if rng.chance(0.2) && !content.contains("'") && !content.contains("\\") {
          out.removeLast(content.count + 1)
          out += "'" + content + "'"
          i += 1
          continue
        } else {
          out.append(c)
        }
        i += 1
        continue
      }
      if rng.chance(0.03), let ascii = c.asciiValue, ascii >= 0x20 {
        out += String(format: "\\u%04x", ascii)
      } else {
        out.append(c)
      }
      i += 1
      continue
    }
    if c == "\"" {
      inString = true
      stringStart = i
      out.append(c)
      i += 1
      continue
    }
    if c == "}" || c == "]", rng.chance(0.3), let last = out.last(where: { !$0.isWhitespace }),
      last != "{" && last != "["
    {
      out += ","
    }
    if (c == "," || c == ":" || c == "{" || c == "[") && rng.chance(0.15) {
      out.append(c)
      out += rng.pick([" /* c */ ", " // line\n", "\t", "\r\n", "\u{00A0}", " /**/", "\u{2028}"])
      i += 1
      continue
    }
    if c.isNumber || (c == "-" && i + 1 < chars.count && chars[i + 1].isNumber) {
      var j = i
      while j < chars.count, "+-0123456789.eE".contains(chars[j]) { j += 1 }
      let text = String(chars[i..<j])
      if let n = Int(text), n >= 0, n < 4096, rng.chance(0.3) {
        out += rng.pick(["0x" + String(n, radix: 16), "+\(n)", "\(n).0", "\(n)."])
      } else if text.hasPrefix("0."), rng.chance(0.3) {
        out += String(text.dropFirst())
      } else {
        out += text
      }
      i = j
      continue
    }
    out.append(c)
    i += 1
  }
  chars = []
  return out
}

/// Random character-level damage: insertions, deletions and substitutions of JSON-ish characters.
private func damage(_ text: String, _ rng: inout FuzzRNG) -> String {
  var chars = Array(text)
  let pieces: [Character] = [
    "{", "}", "[", "]", ",", ":", "\"", "'", "/", "*", "\\", "\n", " ", "0", "1", ".", "e", "x", "-", "+", "N", "I",
    "a", "\u{FEFF}", "\u{2028}", "\u{00A0}", "\t", "u", "#",
  ]
  for _ in 0..<rng.range(1, 3) where !chars.isEmpty {
    let i = rng.int(chars.count)
    switch rng.int(3) {
    case 0: chars.insert(rng.pick(pieces), at: i)
    case 1: chars.remove(at: i)
    default: chars[i] = rng.pick(pieces)
    }
  }
  return String(chars)
}

func fuzzJSON5ConfigFile(_ rng: inout FuzzRNG, count: Int) -> FixtureFile {
  var decode: [J] = []
  for i in 0..<count {
    var input = json5Mutation(randomConfigJSON(&rng), &rng)
    if ProcessInfo.processInfo.environment["SLATED_FUZZ_DAMAGE"] != nil { input = damage(input, &rng) }
    var item: [String: J] = ["name": .string("json5 fuzz \(i)"), "input": .string(input)]
    do {
      let config = try SlatedConfiguration.decode(from: Data(input.utf8))
      do {
        let encoded = String(decoding: try config.encoded(), as: UTF8.self)
        item["encoded"] = .string(maskRandomUUIDs(encoded, input: input))
        item["roundTrips"] = .bool(try SlatedConfiguration.decode(from: config.encoded()) == config)
      } catch {
        item["encodeError"] = errorJ(error)
      }
    } catch {
      item["error"] = errorJ(error)
    }
    decode.append(.object(item))
  }
  return FixtureFile(name: "config.json", description: "fuzz", sections: ["decode": decode], depth: ["decode": 2])
}

// MARK: - Clipboard search

func fuzzClipboardFile(_ rng: inout FuzzRNG, count: Int) -> FixtureFile {
  let alphabet = [
    "a", "e", "s", "S", "ß", "ẞ", "é", "e\u{301}", "É", "ﬁ", "f", "i", "İ", "ı", "I", " ", "æ", "Æ", "ø", "o", "ö",
    "Ö", "ſ", "ﬆ", "t", "k", "\u{212A}", "å", "\u{212B}", "σ", "ς", "Σ", "ǅ", "ǆ", "x", "1", "١", "１", "ｆ", "\t",
    "😀", "👍🏽", "\u{0301}", "\u{0308}", "n", "ŉ", "ʼ", "ﬀ", "ﬃ", "Ⅻ", "x\u{20DD}",
    // Grapheme_Extend characters Foundation ignores, and precomposed characters it doesn't fold.
    "\u{200C}", "\u{200D}", "ی", "か", "が", "\u{3099}", "\u{309A}", "ハ", "パ", "ﾊ", "ﾞ", "ﾟ", "ক", "\u{9BE}", "ا", "آ",
    "\u{653}", "ש", "\u{FB2A}", "\u{5C1}", "가", "\u{1100}", "\u{1161}", "\u{11A8}", "=", "≠", "\u{338}", "\u{F900}",
    "\u{8C48}",
  ]
  var items: [ClipboardItem] = []
  for n in 0..<60 {
    let text = (0..<rng.range(1, 6)).map { _ in rng.pick(alphabet) }.joined()
    items.append(
      ClipboardItem(
        id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", 500 + n))!, text: text,
        copiedAt: Date(timeIntervalSinceReferenceDate: 800_000_000 - Double(n)), pinned: rng.chance(0.2)))
  }
  var seen = Set<String>()
  items = items.filter { seen.insert($0.text).inserted }
  let history = ClipboardHistory(items: items)
  var search: [J] = []
  for _ in 0..<count {
    let query = (0..<rng.range(0, 3)).map { _ in rng.pick(alphabet) }.joined()
    search.append(["query": .string(query), "results": .array(history.search(query).map { .string($0.text) })])
  }
  let itemsJ: J = .array(
    history.items.map { item in
      [
        "text": .string(item.text), "app": .optional(item.sourceApp),
        "copiedAt": .number(item.copiedAt.timeIntervalSinceReferenceDate), "pinned": .bool(item.pinned),
      ]
    })
  return FixtureFile(
    name: "clipboard.json", description: "fuzz", sections: ["search": search], extra: ["searchItems": itemsJ])
}

// MARK: - Entry

/// Every fixture file, with fuzzed cases where there is a fuzzer (starter.json and automation.json
/// are the regular ones), so linux/tests/run.mjs checks them like the golden vectors.
func fuzzFiles(seed: UInt64) -> [FixtureFile] {
  var rng = FuzzRNG(state: seed)
  var files: [FixtureFile] = []
  files.append(fuzzExpressionFile(&rng, count: 4000))
  files.append(fuzzTokenizerFile(&rng, count: 2000))
  files.append(fuzzKeyFile(&rng, count: 2000))
  files.append(fuzzOperationFile(&rng, count: 3000))
  files += fuzzScreenAndFrameFiles(&rng, setupCount: 60, opCount: 120)
  var config = fuzzConfigFile(&rng, count: 800)
  config.sections["decode"]! += fuzzJSON5ConfigFile(&rng, count: 2000).sections["decode"]!
  files.append(config)
  files.append(fuzzHotstringFile(&rng, count: 400))
  files.append(fuzzSlateConfigFile(&rng, count: 400))
  files.append(fuzzSettingsFile(&rng, count: 1000))
  files.append(fuzzClipboardFile(&rng, count: 3000))
  files.append(starterFixtures())
  files.append(automationFixtures())
  return files
}
