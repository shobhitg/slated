import Foundation

@testable import SlatedCore

let automationModelTests = Suite("AutomationModel", [
  ("inputs parse and format", {
    expectEqual(SyntheticInput(string: "mouse:right"), .mouse(.right))
    expectEqual(SyntheticInput(string: "key:w"), .key(KeyCombo(key: "w")))
    expectEqual(SyntheticInput(string: "key:shift+w")?.string, "key:shift+w")
    expect(SyntheticInput(string: "mouse:fourth") == nil)
    expect(SyntheticInput(string: "w") == nil)
    expect(SyntheticInput(string: "key:") == nil)
  }),
  ("automation actions round-trip through JSON and Slate syntax", {
    let actions: [Action] = [
      .click(.left, count: 1), .click(.right, count: 2),
      .press(.key(KeyCombo(key: "w")), phase: .down), .press(.mouse(.middle), phase: .up),
      .hold(.mouse(.right)), .hold(.key(KeyCombo(key: "w", modifiers: .shift))),
      .autoRepeat(.click(.left, count: 1), interval: 0.1, mode: .toggle),
      .autoRepeat(.keystroke(KeyCombo(key: "w")), interval: 0.05, mode: .whileHeld),
      .wait(0.5), .wait(2), .stopAutomations, .clipboardHistory,
      .sequence([
        SequenceStep(.press(.key(KeyCombo(key: "w")), phase: .down)), SequenceStep(.wait(2)),
        SequenceStep(.press(.key(KeyCombo(key: "w")), phase: .up)), SequenceStep(.click(.left, count: 1)),
      ]),
    ]
    for action in actions {
      let data = try JSONEncoder().encode(action)
      expectEqual(try JSONDecoder().decode(Action.self, from: data), action)
      expectEqual(try SlateSyntax.parseOperation(SlateSyntax.format(action)), action)
    }
    expectEqual(SlateSyntax.format(.autoRepeat(.click(.right, count: 1), interval: 0.1, mode: .whileHeld)), "repeat 0.1 while-held 'click right'")
    expectEqual(try SlateSyntax.parseOperation("click"), .click(.left, count: 1))
    expectEqual(try SlateSyntax.parseOperation("hold mouse:right"), .hold(.mouse(.right)))
    expect(Action.click(.left, count: 1).isAutomation)
    expect(!Action.clipboardHistory.isAutomation)
  }),
  ("invalid automation actions are rejected with a reason", {
    expectThrows { _ = try SlateSyntax.parseOperation("repeat 0 'click left'") }
    expectThrows { _ = try SlateSyntax.parseOperation("repeat 0.1") }
    expectThrows { _ = try SlateSyntax.parseOperation("press key:w sideways") }
    expectThrows { _ = try SlateSyntax.parseOperation("hold w") }
    expectThrows { _ = try SlateSyntax.parseOperation("wait -1") }
    expectThrows { _ = try SlateSyntax.parseOperation("click left 0") }
    expectThrows { _ = try JSONDecoder().decode(Action.self, from: Data(#"{"op":"repeat","action":"click","interval":-1}"#.utf8)) }
  }),
  ("clipboard and automation settings default sensibly and allow turning shortcuts off", {
    let config = try SlatedConfiguration.decode(from: Data("{}".utf8))
    expect(config.clipboard.enabled)
    expectEqual(config.clipboard.shortcut, KeyCombo(string: "cmd+shift+v"))
    expect(config.clipboard.excludedApps.contains("com.1password.1password"))
    expectEqual(config.automation.stopShortcut, KeyCombo(string: "hyper+esc"))
    expect(config.automation.stopOnAppSwitch)
    let off = try SlatedConfiguration.decode(from: Data(#"{"clipboard":{"shortcut":null},"automation":{"stopShortcut":null}}"#.utf8))
    expect(off.clipboard.shortcut == nil)
    expect(off.automation.stopShortcut == nil)
    expectEqual(try SlatedConfiguration.decode(from: off.encoded()), off)
    expectEqual(try SlatedConfiguration.decode(from: config.encoded()), config)
  }),
])

let clipboardHistoryTests = Suite("ClipboardHistory", [
  ("newest first, de-duplicated, whitespace ignored", {
    var h = ClipboardHistory()
    let t0 = Date(timeIntervalSince1970: 1_000)
    expect(h.add("one", at: t0, limit: 10))
    expect(h.add("two", at: t0.addingTimeInterval(1), limit: 10))
    expect(!h.add("   \n", at: t0, limit: 10))
    expect(h.add("one", from: "com.apple.Safari", at: t0.addingTimeInterval(2), limit: 10))
    expectEqual(h.items.map(\.text), ["one", "two"])
    expectEqual(h.items.first?.sourceApp, "com.apple.Safari")
  }),
  ("limits and retention spare pinned items", {
    var h = ClipboardHistory()
    let now = Date(timeIntervalSince1970: 10_000_000)
    h.add("old pinned", at: now.addingTimeInterval(-40 * 86_400), limit: 3)
    h.togglePin(id: h.items[0].id)
    h.add("old", at: now.addingTimeInterval(-40 * 86_400), limit: 3)
    for i in 0..<5 { h.add("item \(i)", at: now, limit: 3) }
    expectEqual(h.items.map(\.text), ["item 4", "item 3", "item 2", "old pinned"])
    h.add("stale", at: now.addingTimeInterval(-31 * 86_400), limit: 10)
    h.prune(olderThanDays: 30, now: now)
    expect(!h.items.contains { $0.text == "stale" })
    expect(h.items.contains { $0.text == "old pinned" })
  }),
  ("search, pin, remove and clear", {
    var h = ClipboardHistory()
    let t = Date(timeIntervalSince1970: 0)
    h.add("Café receipt 42", at: t, limit: 10)
    h.add("meeting notes", at: t, limit: 10)
    h.add("cafe menu", at: t, limit: 10)
    expectEqual(h.search("cafe").map(\.text), ["cafe menu", "Café receipt 42"])
    expectEqual(h.search("receipt cafe").map(\.text), ["Café receipt 42"])
    let notes = try require(h.items.first { $0.text == "meeting notes" })
    h.togglePin(id: notes.id)
    expectEqual(h.search("").first?.text, "meeting notes")
    h.clear()
    expectEqual(h.items.map(\.text), ["meeting notes"])
    h.remove(id: notes.id)
    expect(h.items.isEmpty)
  }),
])
