import Foundation

@testable import SlatedCore

let automationModelTests = Suite(
  "AutomationModel",
  [
    (
      "inputs parse and format",
      {
        expectEqual(SyntheticInput(string: "mouse:right"), .mouse(.right))
        expectEqual(SyntheticInput(string: "key:w"), .key(KeyCombo(key: "w")))
        expectEqual(SyntheticInput(string: "key:shift+w")?.string, "key:shift+w")
        expect(SyntheticInput(string: "mouse:fourth") == nil)
        expect(SyntheticInput(string: "w") == nil)
        expect(SyntheticInput(string: "key:") == nil)
      }
    ),
    (
      "automation actions round-trip through JSON and Slate syntax",
      {
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
        expectEqual(
          SlateSyntax.format(.autoRepeat(.click(.right, count: 1), interval: 0.1, mode: .whileHeld)),
          "repeat 0.1 while-held 'click right'")
        expectEqual(try SlateSyntax.parseOperation("click"), .click(.left, count: 1))
        expectEqual(try SlateSyntax.parseOperation("hold mouse:right"), .hold(.mouse(.right)))
        expect(Action.click(.left, count: 1).isAutomation)
        expect(!Action.clipboardHistory.isAutomation)
      }
    ),
    (
      "invalid automation actions are rejected with a reason",
      {
        expectThrows { _ = try SlateSyntax.parseOperation("repeat 0 'click left'") }
        expectThrows { _ = try SlateSyntax.parseOperation("repeat 0.1") }
        expectThrows { _ = try SlateSyntax.parseOperation("press key:w sideways") }
        expectThrows { _ = try SlateSyntax.parseOperation("hold w") }
        expectThrows { _ = try SlateSyntax.parseOperation("wait -1") }
        expectThrows { _ = try SlateSyntax.parseOperation("click left 0") }
        expectThrows {
          _ = try JSONDecoder().decode(Action.self, from: Data(#"{"op":"repeat","action":"click","interval":-1}"#.utf8))
        }
      }
    ),
    (
      "clipboard and automation settings default sensibly and allow turning shortcuts off",
      {
        let config = try SlatedConfiguration.decode(from: Data("{}".utf8))
        expect(config.clipboard.enabled)
        expectEqual(config.clipboard.shortcut, KeyCombo(string: "cmd+shift+v"))
        expect(config.clipboard.excludedApps.contains("com.1password.1password"))
        expectEqual(config.automation.stopShortcut, KeyCombo(string: "hyper+esc"))
        expect(config.automation.stopOnAppSwitch)
        let off = try SlatedConfiguration.decode(
          from: Data(#"{"clipboard":{"shortcut":null},"automation":{"stopShortcut":null}}"#.utf8))
        expect(off.clipboard.shortcut == nil)
        expect(off.automation.stopShortcut == nil)
        expectEqual(try roundTripped(off), off)
        expectEqual(try roundTripped(config), config)
      }
    ),
  ])

let clipboardHistoryTests = Suite(
  "ClipboardHistory",
  [
    (
      "newest first, de-duplicated, whitespace ignored",
      {
        var h = ClipboardHistory()
        let t0 = Date(timeIntervalSince1970: 1_000)
        expect(h.add("one", at: t0, limit: 10))
        expect(h.add("two", at: t0.addingTimeInterval(1), limit: 10))
        expect(!h.add("   \n", at: t0, limit: 10))
        expect(h.add("one", from: "com.apple.Safari", at: t0.addingTimeInterval(2), limit: 10))
        expectEqual(h.items.map(\.text), ["one", "two"])
        expectEqual(h.items.first?.sourceApp, "com.apple.Safari")
      }
    ),
    (
      "limits and retention spare pinned items",
      {
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
      }
    ),
    (
      "search, pin, remove and clear",
      {
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
      }
    ),
    (
      "images: deduped by file, never matched by a search, and listed in imageFiles until they go",
      {
        var h = ClipboardHistory()
        let t = Date(timeIntervalSince1970: 0)
        let shot = ClipboardImage(file: "aa.png", width: 1280, height: 720, bytes: 245_000)
        expect(h.add(image: shot, from: "com.apple.Safari", at: t, limit: 3))
        h.add("notes", at: t, limit: 3)
        expect(!h.add(image: ClipboardImage(file: "", width: 1, height: 1, bytes: 1), at: t, limit: 3))
        expect(!h.add(image: ClipboardImage(file: "zero.png", width: 0, height: 9, bytes: 1), at: t, limit: 3))
        h.togglePin(id: try require(h.items.last).id)
        h.add(image: shot, from: "com.apple.Preview", at: t.addingTimeInterval(5), limit: 3)
        expectEqual(h.items.count, 2)
        expectEqual(h.items[0].image, shot)
        expect(h.items[0].pinned, "copied again keeps its pin")
        expectEqual(h.items[0].sourceApp, "com.apple.Preview")
        expectEqual(h.search("png").map(\.text), [])
        expectEqual(h.search("").count, 2)
        expectEqual(h.imageFiles, ["aa.png"])
        h.add(image: ClipboardImage(file: "bb.tiff", width: 2, height: 2, bytes: 64), at: t, limit: 1)
        expectEqual(h.items.map { $0.image?.file ?? $0.text }, ["bb.tiff", "aa.png"])  // the limit spares the pinned image
        h.clear()
        expectEqual(h.imageFiles, ["aa.png"])
        h.clear(keepPinned: false)
        expect(h.imageFiles.isEmpty)
      }
    ),
    (
      "histories saved before images were kept still read, and text items save as they always have",
      {
        let old = #"{"items":[{"id":"00000000-0000-4000-8000-000000000001","text":"hi","copiedAt":1,"pinned":false}]}"#
        let history = try JSONDecoder().decode(ClipboardHistory.self, from: Data(old.utf8))
        expectEqual(history.items.map(\.text), ["hi"])
        expect(history.items[0].image == nil)
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: [[String: Any]]]
        expectEqual(saved?["items"]?.first.map { Set($0.keys) }, ["id", "text", "copiedAt", "pinned"])

        var withImage = history
        withImage.add(
          image: ClipboardImage(file: "cc.png", width: 3, height: 4, bytes: 5),
          at: Date(timeIntervalSinceReferenceDate: 9),
          limit: 9)
        let roundTrip = try JSONDecoder().decode(ClipboardHistory.self, from: JSONEncoder().encode(withImage))
        expectEqual(roundTrip, withImage)
      }
    ),
    (
      "files: named by their last component, found by name, deduped by paths, never merged with text",
      {
        var h = ClipboardHistory()
        let t = Date(timeIntervalSince1970: 0)
        let files = ["/Users/me/Desktop/Report.pdf", "/Users/me/Pictures/Trip/"]
        expect(h.add(files: files, from: "com.apple.finder", at: t, limit: 5))
        expectEqual(h.items[0].text, "Report.pdf\nTrip")
        expect(h.items[0].isFiles && !h.items[0].isText && !h.items[0].isImage)
        expect(!h.add(files: [], at: t, limit: 5))
        expect(!h.add(files: ["relative.txt", ""], at: t, limit: 5))
        h.add("Report.pdf\nTrip", at: t, limit: 5)
        h.togglePin(id: try require(h.items.last).id)
        h.add(files: files, at: t.addingTimeInterval(1), limit: 5)
        // The same files again move to the top, keeping the pin; text never merges with them.
        expectEqual(h.items.count, 2)
        expect(h.items[0].pinned && h.items[0].files == files)
        expectEqual(h.search("report").count, 2)
        expectEqual(h.search("pictures").count, 0)  // folders aren't searched
        expectEqual(ClipboardItem.fileName(ofPath: "/"), "/")
        expectEqual(ClipboardItem.fileName(ofPath: "/a//b/"), "b")

        let saved = try JSONEncoder().encode(h)
        expectEqual(try JSONDecoder().decode(ClipboardHistory.self, from: saved), h)
        let object = try JSONSerialization.jsonObject(with: saved) as? [String: [[String: Any]]]
        expectEqual(object?["items"]?.last.map { Set($0.keys) }, ["id", "text", "copiedAt", "pinned"])
      }
    ),
    (
      "a screenshot's name round-trips; an image without one saves as before",
      {
        var h = ClipboardHistory()
        let shot = ClipboardImage(file: "aa.png", width: 4, height: 3, bytes: 9, name: "Screenshot 1.png")
        h.add(image: shot, at: Date(timeIntervalSinceReferenceDate: 1), limit: 5)
        h.add(image: ClipboardImage(file: "bb.png", width: 1, height: 1, bytes: 1), at: .distantPast, limit: 5)
        let saved = try JSONEncoder().encode(h)
        expectEqual(try JSONDecoder().decode(ClipboardHistory.self, from: saved).items.last?.image?.name, "Screenshot 1.png")
        let object = try JSONSerialization.jsonObject(with: saved) as? [String: [[String: Any]]]
        expectEqual((object?["items"]?.first?["image"] as? [String: Any]).map { Set($0.keys) }, ["file", "width", "height", "bytes"])
        expectEqual(ClipboardSettings().screenshots, true)
        let off = try JSONDecoder().decode(ClipboardSettings.self, from: Data(#"{"screenshots": false}"#.utf8))
        expect(!off.screenshots)
      }
    ),
  ])

let repeatScheduleTests = Suite(
  "RepeatSchedule",
  [
    (
      "stops after the requested number of runs",
      {
        let once = RepeatSchedule(interval: 0.1, times: 1)
        expect(!once.shouldRunAgain(afterRuns: 1))
        let thrice = RepeatSchedule(interval: 0.1, times: 3)
        expect(thrice.shouldRunAgain(afterRuns: 1))
        expect(thrice.shouldRunAgain(afterRuns: 2))
        expect(!thrice.shouldRunAgain(afterRuns: 3))
        let forever = RepeatSchedule(interval: 0.1)
        expect(forever.shouldRunAgain(afterRuns: 1_000_000))
      }
    ),
    (
      "jitter stays within its range and exact timing has none",
      {
        let exact = RepeatSchedule(interval: 0.1)
        expectEqual(exact.nextInterval(random: 0), 0.1)
        expectEqual(exact.nextInterval(random: 1), 0.1)
        let varied = RepeatSchedule(interval: 0.1, jitter: 0.2)
        expect(abs(varied.nextInterval(random: 0) - 0.08) < 1e-9)
        expect(abs(varied.nextInterval(random: 1) - 0.12) < 1e-9)
        expect(abs(varied.nextInterval(random: 0.5) - 0.1) < 1e-9)
      }
    ),
    (
      "inputs are clamped to safe values",
      {
        let s = RepeatSchedule(interval: 0, times: 0, jitter: 3)
        expectEqual(s.interval, 0.01)
        expectEqual(s.times, 1)
        expectEqual(s.jitter, 0.5)
        expect(RepeatSchedule(interval: 0.01, jitter: 0.5).nextInterval(random: 0) >= 0.01)
      }
    ),
  ])

let automationOptionsTests = Suite(
  "AutomationOptions",
  [
    (
      "repeat limit and jitter round-trip through JSON and Slate syntax",
      {
        let action = Action.autoRepeat(.click(.left, count: 1), interval: 0.1, mode: .toggle, times: 50, jitter: 0.15)
        expectEqual(try JSONDecoder().decode(Action.self, from: JSONEncoder().encode(action)), action)
        expectEqual(SlateSyntax.format(action), "repeat 0.1 times:50 jitter:0.15 'click left'")
        expectEqual(try SlateSyntax.parseOperation(SlateSyntax.format(action)), action)
        expectEqual(
          try SlateSyntax.parseOperation("repeat 0.05 while-held jitter:0.1 'keystroke w'"),
          .autoRepeat(.keystroke(KeyCombo(key: "w")), interval: 0.05, mode: .whileHeld, times: nil, jitter: 0.1))
        expectThrows { _ = try SlateSyntax.parseOperation("repeat 0.1 times:0 'click left'") }
        expectThrows { _ = try SlateSyntax.parseOperation("repeat 0.1 jitter:0.9 'click left'") }
        expectThrows {
          _ = try JSONDecoder().decode(
            Action.self, from: Data(#"{"op":"repeat","action":"click","interval":0.1,"jitter":1}"#.utf8))
        }
      }
    ),
    (
      "modifier keys can be held; mouse buttons can be triggers",
      {
        expectEqual(SyntheticInput(string: "key:shift"), .key(KeyCombo(key: "shift")))
        expectEqual(SyntheticInput(string: "key:rightCtrl")?.string, "key:rightCtrl")
        expect(KeyNames.isModifierKey("shift"))
        expect(KeyNames.isMouseButton("mouse4"))
        expectEqual(KeyCombo(string: "mouse4"), KeyCombo(key: "mouse4"))
        expectEqual(KeyCombo(key: "mouse5").display(), "Mouse 5")
        expectEqual(try SlateSyntax.parseOperation("hold key:shift"), .hold(.key(KeyCombo(key: "shift"))))
      }
    ),
    (
      "bindings can be limited to apps, and only write the list when set",
      {
        let game = HotkeyBinding(
          keys: KeyCombo(key: "f"), action: .hold(.mouse(.left)), onlyInApps: ["com.mojang.minecraft"])
        expect(game.isActive(inApp: "com.mojang.minecraft"))
        expect(!game.isActive(inApp: "com.apple.Safari"))
        expect(!game.isActive(inApp: nil))
        let everywhere = HotkeyBinding(keys: KeyCombo(string: "hyper+a")!, action: .undo)
        expect(everywhere.isActive(inApp: nil))
        let json = String(decoding: try JSONEncoder().encode(everywhere), as: UTF8.self)
        expect(!json.contains("onlyInApps"), json)
        expectEqual(try JSONDecoder().decode(HotkeyBinding.self, from: JSONEncoder().encode(game)), game)
      }
    ),
  ])
