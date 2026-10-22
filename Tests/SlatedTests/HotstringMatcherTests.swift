import Foundation

@testable import SlatedCore

private func type(_ text: String, into matcher: inout HotstringMatcher, app: String? = nil) -> HotstringMatch? {
  var last: HotstringMatch?
  for c in text {
    if let m = matcher.feed(String(c), appBundleID: app) { last = m }
  }
  return last
}

let hotstringMatcherTests = Suite("HotstringMatcher", [
  ("fires immediately on the last trigger character", {
    var m = HotstringMatcher(hotstrings: [Hotstring(trigger: ";shrug", replacement: "¯\\_(ツ)_/¯")])
    let match = try require(type("hello ;shrug", into: &m))
    expectEqual(match.hotstring.trigger, ";shrug")
    // The final "g" is swallowed by the caller, so only ";shru" needs deleting.
    expectEqual(match.deleteCount, 5)
    expect(match.delimiter == nil)
  }),
  ("waits for a delimiter and keeps it", {
    var m = HotstringMatcher(hotstrings: [Hotstring(trigger: "brb", replacement: "be right back", fire: .afterDelimiter)])
    expect(type("brb", into: &m) == nil)
    let match = try require(m.feed(" ", appBundleID: nil))
    expectEqual(match.deleteCount, 3)
    expectEqual(match.delimiter, " ")
  }),
  ("respects word boundaries", {
    var m = HotstringMatcher(hotstrings: [Hotstring(trigger: "teh", replacement: "the", fire: .afterDelimiter, wordBoundary: true)])
    expect(type("pteh ", into: &m) == nil)
    expect(type(" teh ", into: &m) != nil)
  }),
  ("case sensitivity", {
    var sensitive = HotstringMatcher(hotstrings: [Hotstring(trigger: "Sig", replacement: "x")])
    expect(type("sig", into: &sensitive) == nil)
    var insensitive = HotstringMatcher(hotstrings: [Hotstring(trigger: "Sig", replacement: "x", caseSensitive: false)])
    expect(type("SIG", into: &insensitive) != nil)
  }),
  ("backspace edits the buffer", {
    var m = HotstringMatcher(hotstrings: [Hotstring(trigger: "abc", replacement: "x")])
    _ = type("abx", into: &m)
    m.backspace()
    expect(type("c", into: &m) != nil)
  }),
  ("longest trigger wins and app filters apply", {
    var m = HotstringMatcher(hotstrings: [
      Hotstring(trigger: "ab", replacement: "short", fire: .afterDelimiter),
      Hotstring(trigger: "xab", replacement: "long", fire: .afterDelimiter),
      Hotstring(trigger: "zz", replacement: "only mail", onlyInApps: ["com.apple.mail"]),
    ])
    expectEqual(type("xab ", into: &m)?.hotstring.replacement, "long")
    expect(type("zz", into: &m, app: "com.apple.Safari") == nil)
    expect(type("zz", into: &m, app: "com.apple.mail") != nil)
  }),
  ("disabled hotstrings and resets", {
    var m = HotstringMatcher(hotstrings: [Hotstring(trigger: "abc", replacement: "x", enabled: false), Hotstring(trigger: "def", replacement: "y")])
    expect(type("abc", into: &m) == nil)
    _ = type("de", into: &m)
    m.reset()
    expect(type("f", into: &m) == nil)
  }),
])
