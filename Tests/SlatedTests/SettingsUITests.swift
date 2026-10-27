import AppKit
import Foundation

@testable import SlatedCore
@testable import SlatedUI

// View-model logic behind the settings UI. SlatedUI is main-actor isolated; the harness runs every
// test on the main thread, so `onMain` can assume that isolation.

private func onMain(_ body: @MainActor () throws -> Void) throws {
  try MainActor.assumeIsolated(body)
}

private func hyper(_ key: String) -> KeyCombo { KeyCombo(key: key, modifiers: .hyper) }

@MainActor private func preset(_ id: String) -> Action { WindowPresets.preset(id).action }

/// Each hotstring's validation messages, in order; apps are named from `names` (else their id).
@MainActor private func hotstringWarnings(_ hotstrings: [Hotstring], names: [String: String] = [:]) -> [[String]] {
  var config = SlatedConfiguration()
  config.hotstrings = hotstrings
  let issues = ConfigValidator.validate(config, knownLayouts: [], appName: { names[$0] ?? $0 })
  return hotstrings.map { hotstring in issues.filter { $0.target == .hotstring(hotstring.id) }.map(\.message) }
}

private let higherInTheList =
  "Another hotstring with the same trigger is higher in the list, so this one never fires. "
  + "Drag this one above it to use it."

let uiActionTests = Suite(
  "UIActions",
  [
    (
      "presets are unique and recognize their Slate spellings",
      {
        try onMain {
          let ids = WindowPresets.all.map(\.id)
          expectEqual(Set(ids).count, ids.count)
          for preset in WindowPresets.all {
            expectEqual(WindowPresets.matching(preset.action)?.id, preset.id)
            for alias in preset.aliases { expectEqual(WindowPresets.matching(alias)?.id, preset.id) }
          }
          let pushLeft = Action.push(direction: .left, style: .barResize("screenSizeX/2"), screen: nil)
          expectEqual(ActionDescriber.title(pushLeft), "Left Half")
          expectEqual(
            ActionDescriber.title(.corner(.topRight, width: "screenSizeX/2", height: "screenSizeY/2", screen: nil)),
            "Top Right")
          expectEqual(ActionDescriber.title(.focusApp("Safari")), "Focus Safari")
        }
      }
    ),
    (
      "starter shortcuts use distinct Hyper keys",
      {
        try onMain {
          let starter = WindowPresets.starterBindings
          expect(starter.allSatisfy { $0.keys.modifiers == .hyper })
          expectEqual(Set(starter.map(\.keys)).count, starter.count)
          expect(starter.allSatisfy { ConfigValidator.actionProblems($0.action, knownLayouts: []).isEmpty })
        }
      }
    ),
    (
      "the action form round-trips every operation",
      {
        try onMain {
          let samples: [Action] = [
            preset("left-half"), .resize(width: "+10%", height: "-5%", anchor: .bottomRight),
            .push(direction: .up, style: .bar, screen: .next), .nudge(x: "+10%", y: "-20"),
            .throwWindow(screen: .index(1), width: "screenSizeX", height: "screenSizeY"),
            .corner(.bottomLeft, width: nil, height: nil, screen: nil), .chain(WindowPresets.defaultChain),
            .sequence(WindowPresets.defaultSequence), .layout(name: "Coding"), .focus(.behind), .focusApp("Mail"),
            .snapshot(name: "work", save: true, stack: false), .deleteSnapshot(name: "work", all: true),
            .activateSnapshot(name: "work", delete: true), .hint(characters: "ASDF"),
            .grid(padding: 4, grids: [GridScreen(screen: "0", width: 6, height: 4)]), .hide(.allBut("Finder")),
            .show(.apps(["Mail", "Notes"])), .toggle(.current), .shell(command: "say hi", wait: true, path: "/tmp"),
            .undo, .relaunch, .switchApp, .insertText("Hello\nWorld", method: .paste), .openURL("https://example.com"),
            .byOrientation(
              landscape: .push(direction: .left, style: .none, screen: nil),
              portrait: .corner(.topLeft, width: nil, height: nil, screen: nil)),
            .clipboardHistory, .click(.right, count: 2), .press(.key(KeyCombo(key: "w")), phase: .down),
            .hold(.mouse(.right)), .autoRepeat(.click(.left, count: 1), interval: 0.1, mode: .whileHeld), .wait(0.5),
            .stopAutomations,
            .keystroke(KeyCombo(key: "4", modifiers: [.command, .shift])),
          ]
          expectEqual(Set(samples.map { ActionKind($0) }).count, ActionKind.allCases.count)
          for action in samples { expectEqual(ActionForm(action).action, action) }
          for kind in ActionKind.allCases { expect(ActionKind(ActionForm(kind: kind).action) == kind, "\(kind)") }
        }
      }
    ),
    (
      "switching operations keeps compatible parameters",
      {
        try onMain {
          expectEqual(
            ActionForm.convert(preset("top-left"), to: .corner),
            .corner(.topLeft, width: "screenSizeX/2", height: "screenSizeY/2", screen: nil))
          expectEqual(
            ActionForm.convert(preset("left-half"), to: .throwWindow),
            .throwWindow(screen: .next, width: nil, height: nil))
          expectEqual(
            ActionForm.convert(.push(direction: .right, style: .bar, screen: .index(1)), to: .move),
            .move(
              x: "screenOriginX", y: "screenOriginY", width: "screenSizeX/2", height: "screenSizeY", screen: .index(1)))
        }
      }
    ),
    (
      "hotstring simulation follows the trigger rules",
      {
        try onMain {
          let shrug = Hotstring(trigger: ";shrug", replacement: "¯\\_(ツ)_/¯")
          expectEqual(
            HotstringTester.expand(previous: "hi ;shru", current: "hi ;shrug", hotstring: shrug), "hi ¯\\_(ツ)_/¯")
          expect(HotstringTester.expand(previous: "hi ;shr", current: "hi ;shrug", hotstring: shrug) == nil)

          let teh = Hotstring(
            trigger: "teh", replacement: "the", caseSensitive: false, fire: .afterDelimiter, wordBoundary: true)
          expectEqual(
            HotstringTester.expand(previous: "I saw TEH", current: "I saw TEH ", hotstring: teh), "I saw the ")
          expect(HotstringTester.expand(previous: "I saw teh", current: "I saw tehx", hotstring: teh) == nil)
          expect(HotstringTester.expand(previous: "xteh", current: "xteh.", hotstring: teh) == nil)

          let exact = Hotstring(trigger: "Abc", replacement: "x")
          expect(HotstringTester.expand(previous: "ab", current: "abc", hotstring: exact) == nil)
        }
      }
    ),
    (
      "expressions accept relative amounts and catch mistakes",
      {
        try onMain {
          expect(ExpressionCheck.isRelativeAmount("+10%"))
          expect(ExpressionCheck.isRelativeAmount("-100"))
          expect(!ExpressionCheck.isRelativeAmount("10%x"))
          expect(ExpressionCheck.check("   ") == .empty)
          expect(ExpressionCheck.check("screenOriginX+screenSizeX/2").message == nil)
          expect(ExpressionCheck.check("screenOriginX+(screenSizeX-windowSizeX)/2").message == nil)
          expect(ExpressionCheck.check("+10%", relative: true).message == nil)
          expect(ExpressionCheck.check("screenOriginX+").message != nil)
          expect(ExpressionCheck.check("(screenSizeX").message != nil)
          expect(ExpressionCheck.check("screenSizeZ").message != nil)
        }
      }
    ),
    (
      "key events map to Slate key names",
      {
        try onMain {
          @MainActor func keyDown(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(
              with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
              characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
          }
          expectEqual(KeyEventMapping.keyName(for: keyDown(123)), "left")
          expectEqual(KeyEventMapping.keyName(for: keyDown(36)), "return")
          expectEqual(KeyEventMapping.keyName(for: keyDown(KeyEventMapping.hyperKeyCode)), "f18")
          expectEqual(KeyEventMapping.modifiers([.command, .function, .shift]), [.command, .shift])
          expect(ShortcutRules.isAcceptableGlobalShortcut(KeyCombo(key: "f5")))
          expect(!ShortcutRules.isAcceptableGlobalShortcut(KeyCombo(key: "a", modifiers: .shift)))
          expect(ShortcutRules.isAcceptableGlobalShortcut(hyper("a")))
        }
      }
    ),
    (
      "grid rows name their display by index or by resolution",
      {
        try onMain {
          // Slate configs key grid sizes by resolution as well as by index.
          expectEqual(["0", "2", "1680x1050"].map(GridEditor.displayTitle), ["Display 1", "Display 3", "1680×1050"])
          // VoiceOver tells every row apart.
          let phrases = ["0", "1", "1680x1050", "1920x1080"].map(GridEditor.displayPhrase)
          expectEqual(phrases, ["display 1", "display 2", "the 1680×1050 display", "the 1920×1080 display"])
        }
      }
    ),
  ])

let uiValidationTests = Suite(
  "UIValidation",
  [
    (
      "duplicate shortcuts warn on every enabled binding that shares them",
      {
        try onMain {
          var config = SlatedConfiguration()
          let a = HotkeyBinding(name: "A", keys: hyper("m"), action: preset("maximize"))
          let b = HotkeyBinding(name: "B", keys: hyper("m"), action: preset("center"))
          let off = HotkeyBinding(name: "Off", keys: hyper("m"), action: preset("center"), enabled: false)
          config.bindings = [a, b, off]
          let issues = ConfigValidator.validate(config, knownLayouts: [])
          expect(
            issues.contains { $0.target == .binding(a.id) && $0.severity == .warning && $0.message.contains("“B”") })
          expect(issues.contains { $0.target == .binding(b.id) && $0.severity == .warning })
          expect(!issues.contains { $0.target == .binding(off.id) })
        }
      }
    ),
    (
      "shortcut keys: missing is an error, bare letters a warning",
      {
        try onMain {
          var config = SlatedConfiguration()
          let empty = HotkeyBinding(keys: KeyCombo(key: ""), action: .undo)
          let bare = HotkeyBinding(keys: KeyCombo(key: "a"), action: .undo)
          let fKey = HotkeyBinding(keys: KeyCombo(key: "f5"), action: .undo)
          config.bindings = [empty, bare, fKey]
          let issues = ConfigValidator.validate(config, knownLayouts: [])
          expect(issues.contains { $0.target == .binding(empty.id) && $0.severity == .error })
          expect(issues.contains { $0.target == .binding(bare.id) && $0.severity == .warning })
          expect(!issues.contains { $0.target == .binding(fKey.id) })
        }
      }
    ),
    (
      "action problems",
      {
        try onMain {
          @MainActor func errors(_ action: Action, layouts: Set<String> = []) -> [String] {
            ConfigValidator.actionProblems(action, knownLayouts: layouts).filter { $0.severity == .error }.map(
              \.message)
          }
          expect(errors(preset("left-third")).isEmpty)
          expect(!errors(.move(x: "", y: "0", width: "1", height: "1", screen: nil)).isEmpty)
          expect(!errors(.openURL("https://")).isEmpty)
          expect(errors(.openURL("raycast://extensions")).isEmpty)
          // URL(string:) percent-encodes what doesn't belong in a path, query, fragment or user name, but
          // a host or port must be RFC 3986's (with IDNA for other characters in a host). The GNOME
          // settings copy that rule and check these same URLs (linux/tests/prefs/validator.test.mjs), so
          // a change in Foundation shows up here first.
          let fullURLs = [
            "https://www.google.com/search?q=hello world", "https://example.com/a b", "https://example.com/a\tb",
            "https://example.com/a\nb", "https://example.com/ ", "mailto:me @example.com", "https://example.com/#a b",
            "https://user name@example.com/", "file:///home/me/a b.txt", "https://example.com?q=a b",
            "obsidian://open?vault=My Notes", "https://example.com/\u{00A0}x", "slack://open",
            "http://localhost:3000/", "https://[::1]:8080/", "https://example.com:/x", "https://exa%41mple.com",
            "https://münchen.de/", "https://例え.テスト/", "https://exa\u{FEFF}mple.com", "https://exa\u{200B}mple.com",
          ]
          let notFullURLs = [
            "https://example.com ", " https://example.com", "https://exa mple.com", "https://a\nb", "https://",
            "https:", "https:// example.com", "ht tp://example.com", "https://example.com:80 /x",
            "https://exa\u{00A0}mple.com", "https://{host}/path", "https://localhost:port/", "https://example.com:8o8o/",
            "https://[::1/", "https://[::1]x/", "https://exa|mple.com/", "https://exa%mple.com",
            "https://exa\u{0085}mple.com", "https://exa\u{3000}mple.com", "https://exa\u{FF1A}mple.com",
            "https://exa\u{200E}mple.com",
          ]
          for url in fullURLs { expect(errors(.openURL(url)).isEmpty, url.debugDescription) }
          for url in notFullURLs { expect(!errors(.openURL(url)).isEmpty, url.debugDescription) }
          expect(!errors(.chain([])).isEmpty)
          expect(errors(.chain([.focusApp("")])).first?.hasPrefix("Step 1:") ?? false)
          expect(!errors(.hide(.apps([]))).isEmpty)
          expect(errors(.layout(name: "Nope")).isEmpty)
          let warnings = ConfigValidator.actionProblems(.layout(name: "Nope"), knownLayouts: ["Coding"])
          expect(warnings.contains { $0.severity == .warning })
        }
      }
    ),
    (
      "hotstrings: empty, duplicate and shadowed triggers",
      {
        try onMain {
          var config = SlatedConfiguration()
          let empty = Hotstring(trigger: "", replacement: "x")
          let email = Hotstring(trigger: ";email", replacement: "a@b.c")
          let shadow = Hotstring(trigger: ";e", replacement: "e")
          let dupA = Hotstring(trigger: "btw", replacement: "by the way", caseSensitive: false)
          let dupB = Hotstring(trigger: "BTW", replacement: "By the way")
          // Character.isNewline: the GNOME settings flag the same characters.
          let separator = Hotstring(trigger: ";a\u{2028}b", replacement: "x")
          config.hotstrings = [empty, email, shadow, dupA, dupB, separator]
          let issues = ConfigValidator.validate(config, knownLayouts: [])
          expect(issues.contains { $0.target == .hotstring(separator.id) && $0.severity == .error })
          expect(issues.contains { $0.target == .hotstring(empty.id) && $0.severity == .error })
          expectEqual(
            issues.filter { $0.target == .hotstring(email.id) }.map(\.message),
            ["“;e” fires as soon as it's typed, so this one never gets the chance."])
          expect(!issues.contains { $0.target == .hotstring(shadow.id) })
          // “btw” also matches “BTW” and comes first, so only “BTW” never fires.
          expect(!issues.contains { $0.target == .hotstring(dupA.id) })
          expectEqual(issues.filter { $0.target == .hotstring(dupB.id) }.map(\.message), [higherInTheList])
        }
      }
    ),
    (
      "of two hotstrings with the same trigger the first wins, only where both work",
      {
        try onMain {
          let mail = "com.apple.mail"
          let mailOnly = Hotstring(trigger: ";sig", replacement: "Best, S", onlyInApps: [mail])
          let global = Hotstring(trigger: ";sig", replacement: "S.")
          // A per-app override: Mail gets its own, every other app the global one.
          expectEqual(hotstringWarnings([mailOnly, global]), [[], []])
          // Below the global one, the Mail one never fires.
          expectEqual(hotstringWarnings([global, mailOnly]), [[], [higherInTheList]])
          // Each still fires somewhere: Mail gets the first, Notes the second.
          let mailAndNotes = Hotstring(trigger: ";sig", replacement: "S", onlyInApps: [mail, "com.apple.Notes"])
          expectEqual(hotstringWarnings([mailOnly, mailAndNotes]), [[], []])
          expectEqual(hotstringWarnings([mailAndNotes, mailOnly]), [[], [higherInTheList]])
          // Firing as soon as it's typed beats waiting for a delimiter, whatever the order.
          let waits = Hotstring(trigger: ";sig", replacement: "W", fire: .afterDelimiter)
          let firesFirst =
            "Another hotstring with the same trigger fires as soon as it's typed, so this one never gets the chance."
          expectEqual(hotstringWarnings([waits, global]), [[firesFirst], []])
          expectEqual(hotstringWarnings([global, waits]), [[], [firesFirst]])
          // A case-sensitive “BTW” first leaves “btw” and “Btw” to the other.
          let upper = Hotstring(trigger: "BTW", replacement: "By the way")
          let anyCase = Hotstring(trigger: "btw", replacement: "by the way", caseSensitive: false)
          expectEqual(hotstringWarnings([upper, anyCase]), [[], []])
          expectEqual(hotstringWarnings([anyCase, upper]), [[], [higherInTheList]])
          // A whole-word one first leaves typing inside a word to the other.
          let word = Hotstring(trigger: "teh", replacement: "the", wordBoundary: true)
          let inWords = Hotstring(trigger: "teh", replacement: "the")
          expectEqual(hotstringWarnings([word, inWords]), [[], []])
          expectEqual(hotstringWarnings([inWords, word]), [[], [higherInTheList]])
          // One that's off shadows nothing.
          var off = global
          off.enabled = false
          expectEqual(hotstringWarnings([off, mailOnly]), [[], []])
        }
      }
    ),
    (
      "a trigger that fires first says where, when that's only some of this one's apps",
      {
        try onMain {
          let names = ["com.apple.mail": "Mail", "com.apple.TextEdit": "TextEdit"]
          let email = Hotstring(trigger: ";email", replacement: "a@b.c")
          // Everywhere but Mail, “;e” fires first; in Mail “;email” works.
          let notInMail = Hotstring(trigger: ";e", replacement: "e", exceptInApps: ["com.apple.mail"])
          expectEqual(
            hotstringWarnings([notInMail, email], names: names),
            [[], ["“;e” fires as soon as it's typed, so this one only works in Mail."]])
          // Only in Mail and TextEdit does “;e” fire first.
          let twoApps = Hotstring(
            trigger: ";e", replacement: "e", onlyInApps: ["com.apple.TextEdit", "com.apple.mail"])
          expectEqual(
            hotstringWarnings([twoApps, email], names: names)[1],
            ["In Mail and TextEdit, “;e” fires as soon as it's typed, so this one never gets the chance there."])
          // Where “;e” works in all of “;email”'s apps, “;email” never fires.
          let mailEmail = Hotstring(trigger: ";email", replacement: "a@b.c", onlyInApps: ["com.apple.mail"])
          expectEqual(
            hotstringWarnings([twoApps, mailEmail], names: names)[1],
            ["“;e” fires as soon as it's typed, so this one never gets the chance."])
        }
      }
    ),
    (
      "a trigger typed on the way to another one fires first",
      {
        try onMain {
          let shrug = Hotstring(trigger: ";shrug", replacement: "¯\\_(ツ)_/¯")
          @MainActor func warnings(_ other: Hotstring, _ longer: Hotstring = shrug) -> [String] {
            hotstringWarnings([other, longer])[1]
          }
          let sh = "“sh” fires as soon as it's typed, so this one never gets the chance."
          expectEqual(warnings(Hotstring(trigger: "sh", replacement: "x")), [sh])
          expectEqual(
            warnings(Hotstring(trigger: "SH", replacement: "x", caseSensitive: false)),
            ["“SH” fires as soon as it's typed, so this one never gets the chance."])
          // A whole-word trigger fires after the “;” but not after a letter.
          expectEqual(warnings(Hotstring(trigger: "sh", replacement: "x", wordBoundary: true)), [sh])
          expectEqual(warnings(Hotstring(trigger: "hr", replacement: "x", wordBoundary: true)), [])
          // Waiting for a delimiter, or ending where this one does (the longer trigger wins), is fine.
          expectEqual(warnings(Hotstring(trigger: "sh", replacement: "x", fire: .afterDelimiter)), [])
          expectEqual(warnings(Hotstring(trigger: "rug", replacement: "x")), [])
          // Kept to different apps, they never meet.
          expectEqual(
            warnings(
              Hotstring(trigger: "sh", replacement: "x", onlyInApps: ["com.apple.mail"]),
              Hotstring(trigger: ";shrug", replacement: "x", onlyInApps: ["com.apple.Notes"])),
            [])
          // The one typed first is named: “;s” fires before “hr” is complete.
          let hr = Hotstring(trigger: "hr", replacement: "x")
          let semicolonS = Hotstring(trigger: ";s", replacement: "x")
          expectEqual(
            hotstringWarnings([hr, semicolonS, shrug])[2],
            ["“;s” fires as soon as it's typed, so this one never gets the chance."])
        }
      }
    ),
    (
      "hotstrings kept to different apps don't clash; overlapping ones do",
      {
        try onMain {
          let mail = "com.apple.mail"
          let messages = "com.apple.MobileSMS"
          var config = SlatedConfiguration()
          let mailSignature = Hotstring(trigger: ";sig", replacement: "Best, S", onlyInApps: [mail])
          let chatSignature = Hotstring(trigger: ";sig", replacement: "cheers", onlyInApps: [messages])
          let notInMail = Hotstring(trigger: ";e", replacement: "e", exceptInApps: [mail])
          let mailOnlyEmail = Hotstring(trigger: ";email", replacement: "a@b.c", onlyInApps: [mail])
          config.hotstrings = [mailSignature, chatSignature, notInMail, mailOnlyEmail]
          // The matcher only considers hotstrings available in the app in front: each one fires there.
          expect(ConfigValidator.validate(config, knownLayouts: []).isEmpty)

          let everywhere = Hotstring(trigger: ";sig", replacement: "S.")
          let chatEmail = Hotstring(trigger: ";email", replacement: "a@b.c", onlyInApps: [messages])
          config.hotstrings += [everywhere, chatEmail]
          let issues = ConfigValidator.validate(config, knownLayouts: [])
          // Listed first, the app-limited ones win in their apps, and the global one fires everywhere else.
          for signature in [mailSignature, chatSignature, everywhere] {
            expect(!issues.contains { $0.target == .hotstring(signature.id) }, signature.replacement)
          }
          expect(issues.contains { $0.target == .hotstring(chatEmail.id) && $0.message.contains("“;e”") })
          expect(!issues.contains { $0.target == .hotstring(mailOnlyEmail.id) })
        }
      }
    ),
    (
      "saving keeps the last good version of an item with errors",
      {
        try onMain {
          let good = HotkeyBinding(name: "Left", keys: hyper("left"), action: preset("left-half"))
          var saved = SlatedConfiguration()
          saved.bindings = [good]
          var draft = saved
          draft.bindings[0].keys = KeyCombo(key: "")  // mid-edit: keys cleared
          draft.bindings.append(HotkeyBinding(keys: KeyCombo(key: ""), action: .undo))  // brand new, unfinished
          draft.keyboard.capsLock = .hyper  // an unrelated, valid edit
          let issues = ConfigValidator.validate(draft, knownLayouts: [])
          let output = ConfigValidator.savable(draft, lastSaved: saved, issues: issues)
          expectEqual(output.bindings, [good])
          expectEqual(output.keyboard.capsLock, .hyper)

          // Renaming a layout onto another's name mid-edit must not drop either from disk.
          saved.layouts = [Layout(name: "Coding"), Layout(name: "Writing")]
          draft = saved
          draft.layouts[1].name = "Coding"
          let clash = ConfigValidator.validate(draft, knownLayouts: ["Coding", "Writing"])
          expectEqual(ConfigValidator.savable(draft, lastSaved: saved, issues: clash).layouts, saved.layouts)
        }
      }
    ),
  ])

let uiModelTests = Suite(
  "UIAppModel",
  [
    (
      "edits are validated and saved through the services",
      {
        try onMain {
          let services = PreviewServices(scenario: .empty)
          let model = AppModel(services: services)
          model.configuration.keyboard.capsLock = .hyper
          model.saveNow()
          expectEqual(services.configuration.keyboard.capsLock, .hyper)
          expect(model.saveState == .saved)

          // A new shortcut isn't written until it has keys, and waiting for them isn't an error.
          model.newBinding()
          model.saveNow()
          expect(services.configuration.bindings.isEmpty)
          expect(model.saveState == .saved)
          expect(model.state(for: model.configuration.bindings[0]) == .new)
          model.configuration.bindings[0].keys = hyper("left")
          model.saveNow()
          expectEqual(services.configuration.bindings.map(\.keys), [hyper("left")])
          expect(model.saveState == .saved)

          // Breaking a saved shortcut keeps its saved version on disk and flags it.
          let saved = services.configuration.bindings
          model.configuration.bindings[0].action = .move(x: "", y: "0", width: "1", height: "1", screen: nil)
          model.saveNow()
          expectEqual(services.configuration.bindings, saved)
          expect(model.saveState == .partiallySaved(count: 1))
          if case .notSaved(_, let wasSaved) = model.state(for: model.configuration.bindings[0]) {
            expect(wasSaved)
          } else {
            expect(false, "a broken saved shortcut should be not saved")
          }
        }
      }
    ),
    (
      "never overwrites a config.json it couldn't read",
      {
        try onMain {
          let services = PreviewServices(scenario: .brokenConfig)
          let before = services.configuration
          let model = AppModel(services: services)
          expect(model.loadError?.contains("line 14") ?? false)
          model.configuration.keyboard.capsLock = .off
          model.saveNow()
          expectEqual(services.configuration, before)
          expect(model.saveState == .blocked)
        }
      }
    ),
    (
      "reports the engine's active, duplicate and failed shortcuts",
      {
        try onMain {
          let model = AppModel(services: PreviewServices())
          @MainActor func binding(_ name: String) throws -> HotkeyBinding {
            try require(model.configuration.bindings.first { $0.name == name }, name)
          }
          expect(model.state(for: try binding("Left Half")) == .active)
          expect(model.state(for: try binding("Almost Maximize")) == .duplicate)
          if case .failed = model.state(for: try binding("Window Hints")) {
          } else {
            expect(false, "Window Hints should fail")
          }
          expect(model.state(for: try binding("Paste as Plain Text")) == .disabled)
          let others = model.otherUses(of: hyper("n"), modal: nil, excluding: nil)
          expect(others.contains { $0.contains(".slate.js") })
        }
      }
    ),
    (
      "copies static Slate bindings into Slated",
      {
        try onMain {
          let model = AppModel(services: PreviewServices())
          let source = try require(model.sources.first?.bindings.first { $0.action != nil })
          expect(!model.isCopied(source))
          model.copyIntoSlated(source)
          expect(model.isCopied(source))
          expectEqual(model.configuration.bindings.last?.keys, source.keys)
          expect(model.selectedBinding == .slated(model.configuration.bindings.last!.id))
        }
      }
    ),
    (
      "starter shortcuts are added once",
      {
        try onMain {
          let model = AppModel(services: PreviewServices(scenario: .empty))
          model.addStarterBindings()
          model.addStarterBindings()
          expectEqual(model.configuration.bindings.count, WindowPresets.starterBindings.count)
        }
      }
    ),
    (
      "hotkeys stay suspended until every recorder is done",
      {
        try onMain {
          let services = PreviewServices()
          let model = AppModel(services: services)
          model.beginHotkeySuspension()
          model.beginHotkeySuspension()
          expect(services.hotkeysSuspended)
          model.endHotkeySuspension()
          expect(services.hotkeysSuspended)
          model.endHotkeySuspension()
          expect(!services.hotkeysSuspended)
          model.endHotkeySuspension()
          expect(!services.hotkeysSuspended)
        }
      }
    ),
    (
      "renaming a layout updates the shortcuts that apply it",
      {
        try onMain {
          let model = AppModel(services: PreviewServices())
          let layout = try require(model.layoutBinding("Coding"))
          layout.wrappedValue.name = "Deep Work"
          expect(model.configuration.bindings.contains { $0.action == .layout(name: "Deep Work") })
          expect(!model.configuration.bindings.contains { $0.action == .layout(name: "Coding") })
          expect(model.selectedLayout == .slated(name: "Deep Work"))
        }
      }
    ),
    (
      "renaming a layout through another layout's name leaves that layout and its shortcuts alone",
      {
        try onMain {
          let services = PreviewServices(scenario: .empty)
          let model = AppModel(services: services)
          let mail = LayoutApp(app: "Mail", operations: [preset("maximize")])
          let xcode = LayoutApp(app: "Xcode", operations: [preset("left-half")])
          model.configuration.layouts = [Layout(name: "Work", apps: [mail]), Layout(name: "Work 2", apps: [xcode])]
          let workKey = HotkeyBinding(keys: hyper("1"), action: .layout(name: "Work"))
          let work2Key = HotkeyBinding(keys: hyper("2"), action: .layout(name: "Work 2"))
          model.configuration.bindings = [workKey, work2Key]
          model.selectedLayout = .slated(name: "Work 2")
          // Backspacing "Work 2" to "Work", then typing on. The pane finds the layout by the
          // selected name for every keystroke.
          for name in ["Work ", "Work", "Wor", "Workshop"] {
            guard case .slated(let selected) = model.selectedLayout else { throw TestFailure(description: "no layout") }
            try require(model.layoutBinding(selected)).wrappedValue.name = name
            // Saved as if the user paused after each keystroke: on disk, Work 2's shortcut never
            // applies Work.
            model.saveNow()
            let saved = Dictionary(uniqueKeysWithValues: services.configuration.bindings.map { ($0.id, $0.action) })
            expectEqual(saved[workKey.id], .layout(name: "Work"))
            expect(saved[work2Key.id] != .layout(name: "Work"), "after typing “\(name)”")
          }
          expectEqual(model.configuration.layouts.map(\.name), ["Work", "Workshop"])
          expectEqual(model.configuration.layouts.map { $0.apps.map(\.app) }, [["Mail"], ["Xcode"]])
          expectEqual(model.binding(workKey.id)?.action, .layout(name: "Work"))
          expectEqual(model.binding(work2Key.id)?.action, .layout(name: "Workshop"))
          expect(model.selectedLayout == .slated(name: "Workshop"))
          // What the name field shows while the typed name can't be used yet.
          expectEqual(model.layoutNameProblem("Work", renaming: "Workshop"), "Another layout already has this name.")
          expectEqual(model.layoutNameProblem(" ", renaming: "Workshop"), "Name the layout.")
          expect(model.layoutNameProblem("Workshop", renaming: "Workshop") == nil)
        }
      }
    ),
    (
      "the hotstrings switch survives an edit that's still waiting to be saved",
      {
        try onMain {
          let services = PreviewServices(scenario: .empty)
          let model = AppModel(services: services)
          model.configuration.keyboard.capsLock = .hyper  // an edit, waiting for the debounce
          model.setHotstringsEnabled(false)  // the app writes the switch to config.json right away
          model.saveNow()  // then the debounced save runs
          expect(!services.configuration.general.hotstringsEnabled, "the switch stays off")
          expectEqual(services.configuration.keyboard.capsLock, .hyper)
          expect(!model.runtimeStatus.hotstringsEnabled)
        }
      }
    ),
    (
      "a hotstring stays Active while Try It pauses expansion; only missing permission waits",
      {
        try onMain {
          let services = PreviewServices()
          let model = AppModel(services: services)
          let hotstring = try require(model.configuration.hotstrings.first { $0.enabled })
          expect(model.state(for: hotstring) == .active)
          model.beginHotkeySuspension()  // the Try It field has focus
          expect(!model.runtimeStatus.hotstringsActive, "the engine pauses expansion meanwhile")
          expect(model.state(for: hotstring) == .active, "that's not “Waiting for permission”")
          model.endHotkeySuspension()

          let firstRun = AppModel(services: PreviewServices(scenario: .firstRun))
          firstRun.configuration.hotstrings = [Hotstring(trigger: ";a", replacement: "b")]
          expect(firstRun.state(for: firstRun.configuration.hotstrings[0]) == .waitingForPermission)
          firstRun.configuration.hotstrings[0].trigger = ""
          expect(firstRun.state(for: firstRun.configuration.hotstrings[0]) == .notSaved)
        }
      }
    ),
    (
      "a binding or hotstring copied in config.json with its id becomes an item of its own",
      {
        try onMain {
          let services = PreviewServices(scenario: .empty)
          let left = HotkeyBinding(name: "Left", keys: hyper("left"), action: preset("left-half"))
          var right = left  // pasted in config.json, id and all, then edited by hand
          right.name = "Right"
          right.keys = hyper("right")
          right.action = preset("right-half")
          let shrug = Hotstring(trigger: ";shrug", replacement: "¯\\_(ツ)_/¯")
          var flip = shrug
          flip.trigger = ";flip"
          var config = SlatedConfiguration()
          config.bindings = [left, right]
          config.hotstrings = [shrug, flip]
          try services.saveConfiguration(config)

          let model = AppModel(services: services)
          let bindingIDs = model.configuration.bindings.map(\.id)
          let hotstringIDs = model.configuration.hotstrings.map(\.id)
          expectEqual(bindingIDs.first, left.id)
          expectEqual(Set(bindingIDs).count, 2)
          expectEqual(hotstringIDs.first, shrug.id)
          expectEqual(Set(hotstringIDs).count, 2)
          // Reading the file again (any change the app reports) keeps the new ids.
          services.simulateCopy("anything")
          expectEqual(model.configuration.bindings.map(\.id), bindingIDs)
          expectEqual(model.configuration.hotstrings.map(\.id), hotstringIDs)

          // Edits and deletes reach the copy, not the original.
          try require(model.bindingBinding(bindingIDs[1])).wrappedValue.name = "Right Half"
          expectEqual(model.configuration.bindings.map(\.name), ["Left", "Right Half"])
          model.deleteHotstring(hotstringIDs[1])
          expectEqual(model.configuration.hotstrings.map(\.trigger), [";shrug"])
          // The next save writes the new id.
          model.saveNow()
          expectEqual(services.configuration.bindings.map(\.id), bindingIDs)
          expectEqual(services.configuration.bindings.map(\.name), ["Left", "Right Half"])
          expectEqual(services.configuration.hotstrings.map(\.trigger), [";shrug"])
        }
      }
    ),
    (
      "its own saves don't count as hand edits",
      {
        try onMain {
          // PreviewServices reports the change from inside saveConfiguration, as the app may.
          let services = PreviewServices(scenario: .empty)
          let model = AppModel(services: services)
          model.newBinding()  // unfinished: not written yet
          model.configuration.keyboard.capsLock = .hyper  // finished: written now
          model.saveNow()
          expectEqual(services.configuration.keyboard.capsLock, .hyper)
          expectEqual(model.configuration.bindings.count, 1)
        }
      }
    ),
    (
      "picks up hand edits to config.json when nothing is pending",
      {
        try onMain {
          let services = PreviewServices()
          let model = AppModel(services: services)
          var edited = services.configuration
          edited.hotstrings.append(Hotstring(trigger: ";new", replacement: "fresh"))
          try services.saveConfiguration(edited)  // notifies the model, like a file watcher would
          expect(model.configuration.hotstrings.contains { $0.trigger == ";new" })
        }
      }
    ),
  ])
