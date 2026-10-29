import SlatedCore

extension SlateImport.Item {
  /// What couldn't be converted, for people: a shortcut as its keys' symbols (`⌃⌥⌘T`, or `⌃⌥F6 X`
  /// behind a modal key), anything else (`slate.layout("work")`, `line 3`) as written.
  var displayName: String {
    let parts = what.split(separator: " ").map(String.init)
    guard let first = parts.first, first.contains("+") else { return what }
    let combos = parts.compactMap { KeyCombo(string: $0) }
    guard combos.count == parts.count else { return what }
    return combos.map { $0.display() }.joined(separator: " ")
  }
}
