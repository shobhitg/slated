import Foundation

/// A hotstring that just completed.
public struct HotstringMatch: Hashable, Sendable {
  public var hotstring: Hotstring
  /// Characters already delivered to the app that must be deleted before inserting. The key that
  /// completed the match is assumed to be swallowed by the caller, so it is not counted.
  public var deleteCount: Int
  /// The delimiter that completed an `afterDelimiter` trigger; re-typed after the replacement.
  public var delimiter: String?
}

/// Watches typed characters and reports when a hotstring trigger has been typed.
///
/// Pure state machine: the keyboard tap feeds it characters and resets it on clicks, app switches,
/// navigation keys and shortcuts. It only ever holds the last few characters needed for matching.
public struct HotstringMatcher: Sendable {
  public private(set) var hotstrings: [Hotstring]
  private var buffer: [Character] = []
  private var capacity = 1

  public init(hotstrings: [Hotstring] = []) {
    self.hotstrings = []
    update(hotstrings)
  }

  public mutating func update(_ hotstrings: [Hotstring]) {
    self.hotstrings = hotstrings.filter { $0.enabled && !$0.trigger.isEmpty }
    // One extra character so word-boundary checks can see what precedes the trigger.
    capacity = (self.hotstrings.map(\.trigger.count).max() ?? 0) + 1
    if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
  }

  public mutating func reset() { buffer.removeAll(keepingCapacity: true) }

  public mutating func backspace() {
    if !buffer.isEmpty { buffer.removeLast() }
  }

  /// Characters that end a word: whitespace and punctuation.
  public static func isDelimiter(_ c: Character) -> Bool {
    c.isWhitespace || c.isNewline || (c.isPunctuation && c != "_") || c.isSymbol
  }

  /// Feeds the text one key produced. Returns a match when this key completes a trigger; the caller
  /// should then swallow the key and perform the replacement.
  public mutating func feed(_ text: String, appBundleID: String?) -> HotstringMatch? {
    guard !hotstrings.isEmpty, !text.isEmpty else { return nil }
    var result: HotstringMatch?
    for c in text {
      result = feed(character: c, appBundleID: appBundleID) ?? result
      if result != nil { break }
    }
    return result
  }

  private mutating func feed(character c: Character, appBundleID: String?) -> HotstringMatch? {
    let candidates = hotstrings.filter { $0.isAvailable(in: appBundleID) }

    // A delimiter can complete an `afterDelimiter` trigger that is already in the buffer.
    if Self.isDelimiter(c),
      let hit = longestMatch(in: candidates.filter { $0.fire == .afterDelimiter }, buffer: buffer)
    {
      reset()
      return HotstringMatch(hotstring: hit, deleteCount: hit.trigger.count, delimiter: String(c))
    }

    buffer.append(c)
    if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }

    if let hit = longestMatch(in: candidates.filter { $0.fire == .immediately }, buffer: buffer) {
      reset()
      return HotstringMatch(hotstring: hit, deleteCount: hit.trigger.count - 1, delimiter: nil)
    }
    return nil
  }

  private func longestMatch(in candidates: [Hotstring], buffer: [Character]) -> Hotstring? {
    var best: Hotstring?
    for h in candidates {
      let trigger = Array(h.trigger)
      guard trigger.count <= buffer.count else { continue }
      let tail = buffer.suffix(trigger.count)
      let matches =
        h.caseSensitive
        ? Array(tail) == trigger
        : String(tail).lowercased() == h.trigger.lowercased()
      guard matches else { continue }
      if h.wordBoundary {
        let before = buffer.count - trigger.count - 1
        if before >= 0 && !Self.isDelimiter(buffer[before]) { continue }
      }
      if (best?.trigger.count ?? 0) < trigger.count { best = h }
    }
    return best
  }
}

extension Hotstring {
  /// Whether app filters allow this hotstring in the app with `bundleID`.
  public func isAvailable(in bundleID: String?) -> Bool {
    if let bundleID, exceptInApps.contains(bundleID) { return false }
    if onlyInApps.isEmpty { return true }
    guard let bundleID else { return false }
    return onlyInApps.contains(bundleID)
  }
}
