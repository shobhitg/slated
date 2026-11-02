import Foundation

@testable import SlatedCore

// Every control in a settings pane names its key in the files, so a new setting can't skip it. SwiftUI
// can't be walked at run time here (hosted views expose no accessibility tree), so this reads the
// panes' source: each control (a row, toggle, picker, field, recorder…) must name a key itself
// (`configKey:`, `key:`, `.configField(…)`, `.configKeyMenu(…)`), sit inside a control that does, or
// say why it has none in a `// config key: …` comment on its line or the line above.

/// The views that edit a setting. `SearchField` and buttons aren't settings.
private let controls = [
  "ToggleRow", "SettingRow", "Toggle", "Picker", "FittingPicker", "Stepper", "Slider", "TextField", "TextEditor",
  "SecureField", "DatePicker", "ColorPicker", "ShortcutRecorder", "OptionalShortcutRecorder", "LabeledField",
  "FieldGroup", "ExpressionField",
]
private let keyMarkers = ["configKey", "key:", "configField(", "configFieldMenu("]

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent()

/// A control call found in a source file.
struct ControlCall {
  var name: String
  var line: Int
  var keyed: Bool
  /// Its trailing closure's range in the file, if it has one.
  var closure: Range<Int>?
  var start: Int
}

/// Swift source with comments and string literals blanked (newlines kept), and the lines that carry a
/// `// config key:` comment.
func blankedSwiftSource(_ text: String) -> (code: [Character], exempt: Set<Int>) {
  var chars = Array(text)
  var exempt = Set<Int>()
  var line = 1
  var i = 0
  func blank(_ from: Int, _ to: Int) {
    for k in from..<min(to, chars.count) where chars[k] != "\n" { chars[k] = " " }
  }
  func starts(_ s: String, at k: Int) -> Bool {
    let p = Array(s)
    return k + p.count <= chars.count && Array(chars[k..<(k + p.count)]) == p
  }
  while i < chars.count {
    let c = chars[i]
    if c == "\n" {
      line += 1
      i += 1
    } else if starts("//", at: i) {
      var end = i
      while end < chars.count, chars[end] != "\n" { end += 1 }
      if String(chars[i..<end]).contains("config key:") { exempt.insert(line) }
      blank(i, end)
      i = end
    } else if starts("/*", at: i) {
      var end = i + 2
      while end < chars.count, !starts("*/", at: end) { end += 1 }
      for k in i..<min(end, chars.count) where chars[k] == "\n" { line += 1 }
      blank(i, end + 2)
      i = end + 2
    } else if starts("#\"", at: i) || starts("\"\"\"", at: i) || c == "\"" {
      let (close, from): (String, Int) =
        starts("#\"", at: i) ? ("\"#", i + 2) : starts("\"\"\"", at: i) ? ("\"\"\"", i + 3) : ("\"", i + 1)
      var end = from
      while end < chars.count, !starts(close, at: end) {
        if chars[end] == "\\", close == "\"" { end += 1 }
        if end < chars.count, chars[end] == "\n" { line += 1 }
        end += 1
      }
      blank(from, end)
      i = end + close.count
    } else {
      i += 1
    }
  }
  return (chars, exempt)
}

/// The control calls in `text`, with whether each names a key.
func controlCalls(in text: String) -> (calls: [ControlCall], exempt: Set<Int>) {
  let (code, exempt) = blankedSwiftSource(text)
  var lineAt = [Int](repeating: 1, count: code.count + 1)
  var line = 1
  for (k, c) in code.enumerated() {
    lineAt[k] = line
    if c == "\n" { line += 1 }
  }
  func isIdentifier(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
  func skipSpace(_ k: Int) -> Int {
    var k = k
    while k < code.count, code[k].isWhitespace { k += 1 }
    return k
  }
  /// The index just past the bracket matching the one at `k`.
  func matching(_ k: Int) -> Int {
    let open = code[k]
    let close: Character = open == "(" ? ")" : open == "{" ? "}" : "]"
    var depth = 0
    var j = k
    while j < code.count {
      if code[j] == open {
        depth += 1
      } else if code[j] == close {
        depth -= 1
        if depth == 0 { return j + 1 }
      }
      j += 1
    }
    return code.count
  }
  var calls: [ControlCall] = []
  var i = 0
  while i < code.count {
    guard isIdentifier(code[i]), i == 0 || (!isIdentifier(code[i - 1]) && code[i - 1] != ".") else {
      i += 1
      continue
    }
    var end = i
    while end < code.count, isIdentifier(code[end]) { end += 1 }
    let name = String(code[i..<end])
    guard controls.contains(name), end < code.count, code[end] == "(" else {
      i = end
      continue
    }
    let argsEnd = matching(end)
    var own = String(code[i..<argsEnd])
    var closure: Range<Int>?
    var k = skipSpace(argsEnd)
    if k < code.count, code[k] == "{" {
      let closureEnd = matching(k)
      closure = k..<closureEnd
      k = closureEnd
    }
    // The modifier chain: `.name`, `.name(…)`, `.name { … }`, across lines.
    while true {
      let next = skipSpace(k)
      guard next < code.count, code[next] == ".", next + 1 < code.count, isIdentifier(code[next + 1]) else { break }
      var j = next + 1
      while j < code.count, isIdentifier(code[j]) { j += 1 }
      if j < code.count, code[j] == "(" { j = matching(j) }
      let brace = skipSpace(j)
      if brace < code.count, code[brace] == "{" { j = matching(brace) }
      own += String(code[next..<j])
      k = j
    }
    // `key: nil` names no key: such a control needs its reason in a comment.
    own = own.replacingOccurrences(of: "key: nil", with: "")
    calls.append(
      ControlCall(
        name: name, line: lineAt[i], keyed: keyMarkers.contains { own.contains($0) }, closure: closure, start: i))
    i = end
  }
  return (calls, exempt)
}

/// Controls in `text` that name no key, aren't inside a control that does, and give no reason. A file
/// whose controls are all for something not in the files yet says so once: `// config keys: none in
/// this file. <why>`.
func unkeyedControls(in text: String) -> [ControlCall] {
  if text.hasPrefix("// config keys: none in this file.") { return [] }
  let (calls, exempt) = controlCalls(in: text)
  return calls.filter { call in
    if call.keyed || exempt.contains(call.line) || exempt.contains(call.line - 1) { return false }
    return !calls.contains { other in other.keyed && other.closure?.contains(call.start) == true }
  }
}

let configKeyCoverageTests = Suite(
  "ConfigKeyCoverage",
  [
    (
      "every control in the settings panes names its config key",
      {
        let folder = repoRoot.appendingPathComponent("Sources/SlatedUI/Settings")
        let files = try require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
          .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        expect(files.count > 20, "found the panes")
        var missing: [String] = []
        for file in files {
          let text = try String(contentsOf: file, encoding: .utf8)
          for call in unkeyedControls(in: text) {
            missing.append("\(file.lastPathComponent):\(call.line) \(call.name)")
          }
        }
        // Each of these needs `configKey:` / `key:` (see ConfigKeyViews.swift), or `// config key: <why none>`.
        expectEqual(missing.sorted(), [])
      }
    ),
    (
      "every setting the Mac offers appears in a pane",
      {
        let folder = repoRoot.appendingPathComponent("Sources/SlatedUI")
        let files = try require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
          .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let source = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        for setting in ConfigKeys.settings where setting.platforms.contains(.mac) {
          expect(source.contains("ConfigKeys.\(setting.id)"), "no control shows \(setting.key.display)")
        }
      }
    ),
    (
      "the source check finds unkeyed controls and accepts keyed, nested and explained ones",
      {
        let sample = #"""
          SettingRow(title: "A", configKey: ConfigKeys.islandEnabled) {
            Picker("Inner", selection: $x) { Text("\(value)") }
          }
          Toggle("Bare", isOn: $y)
          Toggle("Modified", isOn: $y)
            .toggleStyle(.checkbox)
            .configField("save")
          // config key: a search field, not a setting
          TextField("Search", text: $search)
          let s = "Toggle(" // Toggle( in a comment
          FittingPicker("Nested in a plain stack", selection: $z) {
            Toggle("Inner bare", isOn: $w)
          }
          """#
        let found = unkeyedControls(in: sample).map { "\($0.line) \($0.name)" }
        expectEqual(found, ["4 Toggle", "11 FittingPicker", "12 Toggle"])
      }
    ),
  ])
