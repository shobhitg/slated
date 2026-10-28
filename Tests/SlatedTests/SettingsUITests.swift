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

/// The sample services, as the app reports itself when the keyboard event tap won't start: permission
/// granted, the hotstrings switch on, not paused, and yet no hotstrings running.
@MainActor private final class TapFailedServices: AppServices {
  let base = PreviewServices()
  var setupFinished = true

  var configurationFileURL: URL { base.configurationFileURL }
  func loadConfiguration() throws -> SlatedConfiguration { try base.loadConfiguration() }
  func saveConfiguration(_ configuration: SlatedConfiguration) throws { try base.saveConfiguration(configuration) }
  func runtimeStatus() -> RuntimeStatus {
    var status = base.runtimeStatus()
    status.hotstringsActive = false
    return status
  }
  func slateSources() -> [SlateSource] { base.slateSources() }
  func screens() -> [ScreenInfo] { base.screens() }
  func runningApplications() -> [AppInfo] { base.runningApplications() }
  func requestAccessibilityPermission() {}
  func openAccessibilitySettings() {}
  func reload() {}
  func revealConfigurationFile() {}
  func revealFile(atPath path: String) {}
  func setHotkeysSuspended(_ suspended: Bool) { base.setHotkeysSuspended(suspended) }
  func setPaused(_ paused: Bool) { base.setPaused(paused) }
  func setHotstringsEnabled(_ enabled: Bool) { base.setHotstringsEnabled(enabled) }
  func setLaunchAtLogin(_ enabled: Bool) throws {}
  func onChange(_ handler: @escaping @MainActor () -> Void) { base.onChange(handler) }
  func clipboardItems() -> [ClipboardItem] { [] }
  func pasteClipboardItem(id: UUID) {}
  func copyClipboardItem(id: UUID) {}
  func deleteClipboardItem(id: UUID) {}
  func togglePinClipboardItem(id: UUID) {}
  func clearClipboardHistory() {}
  func showClipboardHistory() {}
  func activeAutomations() -> [ActiveAutomation] { [] }
  func stopAutomations() {}
}

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
      "thirds that turn with the display are named by position, displays above and below by place",
      {
        try onMain {
          // The starter's thirds are the author's Slate thirds, spelled the same way.
          let turning = StarterBindings.all.filter {
            if case .byOrientation = $0.action { return true }
            return false
          }
          expectEqual(
            turning.map { ActionDescriber.title($0.action) },
            ["First Third", "Middle Third", "Last Third", "First Two Thirds", "Last Two Thirds"])
          for binding in turning {
            guard case .byOrientation(let landscape, _) = binding.action else { continue }
            // The glyph shows where the window goes on a landscape display, as the cheat sheet does.
            expectEqual(WindowPresets.matching(binding.action)?.region, WindowPresets.matching(landscape)?.region)
          }
          for preset in WindowPresets.orientation {
            expectEqual(WindowPresets.matching(preset.action)?.id, preset.id)
            for alias in preset.aliases { expectEqual(WindowPresets.matching(alias)?.id, preset.id) }
          }
          // The pickers offer only the plain presets.
          expect(Set(WindowPresets.orientation.map(\.id)).isDisjoint(with: WindowPresets.all.map(\.id)))
          // Other pairs name both sides, once when they're the same.
          let pair = Action.byOrientation(landscape: preset("left-half"), portrait: preset("top-half"))
          expectEqual(ActionDescriber.title(pair), "Left Half / Top Half")
          expectEqual(ActionDescriber.title(.byOrientation(landscape: .undo, portrait: .undo)), "Undo")
          // Slate's `throw up resize` and `throw down`, as the author's file has them.
          expectEqual(
            ActionDescriber.title(.throwWindow(screen: .relative(.up), width: "screenSizeX", height: "screenSizeY")),
            "Throw to Display Above, Resized")
          expectEqual(
            ActionDescriber.title(.throwWindow(screen: .relative(.down), width: nil, height: nil)),
            "Throw to Display Below")
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
      "a Slate binding imported while its file keeps loading shows as imported, not as another use",
      {
        try onMain {
          let model = AppModel(services: PreviewServices())
          let source = try require(model.sources.first?.bindings.first { $0.keys == hyper("n") })
          expect(model.state(for: source) != .imported)
          model.configuration.general.importedSlateShortcuts = [source.id]
          expect(model.state(for: source) == .imported)
          let others = model.otherUses(of: hyper("n"), modal: nil, excluding: nil)
          expect(!others.contains { $0.contains(".slate.js") }, "\(others)")
        }
      }
    ),
    (
      "onboarding still shows the Slate config after its switch turns loading off, so it can go back on",
      {
        try onMain {
          let services = PreviewServices(scenario: .firstRun)
          let model = AppModel(services: services)
          expectEqual(model.slateFilesFound.map(\.displayName), ["~/.slate.js"])
          model.configuration.general.loadSlateConfigs = false  // not saved yet
          expectEqual(model.slateFilesFound.map(\.displayName), ["~/.slate.js"])
          model.saveNow()
          // Like the app: listed, but not loaded.
          expect(model.sources.contains { $0.exists && !$0.loaded })
          expectEqual(model.slateFilesFound.map(\.displayName), ["~/.slate.js"])
          model.configuration.general.loadSlateConfigs = true  // not saved yet, so still not loaded
          expectEqual(model.slateFilesFound.map(\.displayName), ["~/.slate.js"])
          model.saveNow()
          expectEqual(model.slateFilesFound.filter(\.loaded).map(\.displayName), ["~/.slate.js"])
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
          expect(model.selectedLayout == .slated(name: "Deep Work", index: 0))
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
          // selection for every keystroke.
          for name in ["Work ", "Work", "Wor", "Workshop"] {
            guard case .slated(let selected, let index) = model.selectedLayout else {
              throw TestFailure(description: "no layout")
            }
            try require(model.layoutBinding(selected, at: index)).wrappedValue.name = name
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
          expect(model.selectedLayout == .slated(name: "Workshop", index: 1))
          // What the name field shows while the typed name can't be used yet. Spaces around a name
          // don't show in any list, so “Work ” would look like a second “Work”.
          expectEqual(model.layoutNameProblem("Work", renaming: "Workshop"), "Another layout already has this name.")
          expectEqual(model.layoutNameProblem("Work ", renaming: "Workshop"), "Another layout already has this name.")
          expectEqual(model.layoutNameProblem(" Work", renaming: "Workshop"), "Another layout already has this name.")
          expectEqual(model.layoutNameProblem(" ", renaming: "Workshop"), "Name the layout.")
          expect(model.layoutNameProblem("Workshop", renaming: "Workshop") == nil)
        }
      }
    ),
    (
      "renaming a layout re-points every step, hotstring and display default that applies it",
      {
        try onMain {
          let model = AppModel(services: PreviewServices(scenario: .empty))
          let half = preset("left-half")
          func steps(_ name: String) -> [Action] {
            let layout = Action.layout(name: name)
            return [
              layout, .chain([layout, half]), .byOrientation(landscape: layout, portrait: half),
              .sequence([SequenceStep(layout), SequenceStep(.wait(1))]),
              .autoRepeat(layout, interval: 60, mode: .toggle),
            ]
          }
          model.configuration.layouts = [Layout(name: "Code")]
          model.configuration.bindings = steps("Code").enumerated().map { index, action in
            HotkeyBinding(keys: hyper("\(index + 1)"), action: action)
          }
          model.configuration.hotstrings = [Hotstring(trigger: ";code", replacement: "", action: .layout(name: "Code"))]
          model.configuration.defaults = [ScreenDefault(target: "Code", condition: .count(2))]
          try require(model.layoutBinding("Code")).wrappedValue.name = "Coding"
          expectEqual(model.configuration.bindings.map(\.action), steps("Coding"))
          expectEqual(model.configuration.hotstrings.map(\.action), [.layout(name: "Coding")])
          expectEqual(model.configuration.defaults.map(\.target), ["Coding"])
          expect(!model.issues.contains { $0.message.contains("no layout named") }, "something names the old name")
        }
      }
    ),
    (
      "a layout rename waits with its shortcuts while a layout can't be saved",
      {
        try onMain {
          let good = preset("maximize")
          let bad = Action.move(x: "screenOriginX", y: "screenOriginY", width: "", height: "screenSizeY", screen: nil)
          @MainActor func start(chat: Action, code: [LayoutApp] = []) throws -> (AppModel, PreviewServices) {
            let services = PreviewServices(scenario: .empty)
            var config = SlatedConfiguration()
            config.layouts = [
              Layout(name: "Code", apps: code),
              Layout(name: "Chat", apps: [LayoutApp(app: "Slack", operations: [chat])]),
            ]
            config.bindings = [HotkeyBinding(keys: hyper("1"), action: .layout(name: "Code"))]
            config.hotstrings = [Hotstring(trigger: ";code", replacement: "", action: .layout(name: "Code"))]
            config.defaults = [ScreenDefault(target: "Code", condition: .count(2))]
            try services.saveConfiguration(config)
            return (AppModel(services: services), services)
          }
          @MainActor func onDisk(_ services: PreviewServices) -> [String] {
            let disk = services.configuration
            return [
              disk.layouts.map(\.name).joined(separator: ", "), ActionDescriber.title(disk.bindings[0].action),
              disk.hotstrings[0].action.map(ActionDescriber.title) ?? "", disk.defaults[0].target,
            ]
          }
          let before = ["Code, Chat", "Layout “Code”", "Layout “Code”", "Code"]
          let after = ["Coding, Chat", "Layout “Coding”", "Layout “Coding”", "Coding"]

          // An operation half-typed in another layout while this one is renamed.
          var (model, services) = try start(chat: good)
          model.configuration.layouts[1].apps[0].operations = [bad]
          try require(model.layoutBinding("Code")).wrappedValue.name = "Coding"
          model.saveNow()
          // The shortcuts keep the name config.json has.
          expectEqual(onDisk(services), before)
          model.configuration.layouts[1].apps[0].operations = [good]
          model.saveNow()
          // Fixed: the rename and its shortcuts save together.
          expectEqual(onDisk(services), after)

          // A typo already in the file, in another layout.
          (model, services) = try start(chat: bad)
          try require(model.layoutBinding("Code")).wrappedValue.name = "Coding"
          model.saveNow()
          expectEqual(onDisk(services), before)

          // An error in the renamed layout itself.
          (model, services) = try start(chat: good)
          try require(model.layoutBinding("Code")).wrappedValue.name = "Coding"
          model.configuration.layouts[0].apps = [LayoutApp(app: "Terminal", operations: [bad])]
          model.saveNow()
          expectEqual(onDisk(services), before)
          model.configuration.layouts[0].apps = []
          model.saveNow()
          expectEqual(onDisk(services), after)
        }
      }
    ),
    (
      "renaming a layout never takes a Slate file's layout name, or another's with spaces around it",
      {
        try onMain {
          // Slated's “Coding” (hyper+1 applies it); the Slate file has “Writing” and “Meeting”.
          let services = PreviewServices()
          let model = AppModel(services: services)
          let writingKey = HotkeyBinding(keys: hyper("w"), action: .layout(name: "Writing"))
          model.configuration.bindings.append(writingKey)
          let codingKey = try require(model.configuration.bindings.first { $0.action == .layout(name: "Coding") })
          let taken = "Another layout already has this name."
          expectEqual(model.layoutNameProblem("Writing", renaming: "Coding"), taken)
          expectEqual(model.layoutNameProblem("Meeting ", renaming: "Coding"), taken)
          // Typed one keystroke at a time over “Coding”, saved as if the user paused after each.
          var typed = ""
          for character in "Writing Room" {
            typed.append(character)
            let current = try require(model.configuration.layouts.first?.name)
            try require(model.layoutBinding(current)).wrappedValue.name = typed
            model.saveNow()
            let disk = services.configuration
            expect(
              !disk.layouts.contains { $0.name.trimmingCharacters(in: .whitespaces) == "Writing" },
              "after typing “\(typed)” Slated's layout would replace the Slate file's")
            expectEqual(disk.bindings.first { $0.id == writingKey.id }?.action, .layout(name: "Writing"))
          }
          expectEqual(model.configuration.layouts.map(\.name), ["Writing Room"])
          expectEqual(model.binding(writingKey.id)?.action, .layout(name: "Writing"))
          expectEqual(model.binding(codingKey.id)?.action, .layout(name: "Writing Room"))
        }
      }
    ),
    (
      "typing a layout's name keeps what applied a name before the layout took it on that name",
      {
        try onMain {
          let model = AppModel(services: PreviewServices(scenario: .empty))
          model.configuration.layouts = [Layout(name: "Terminals")]
          let own = HotkeyBinding(keys: hyper("t"), action: .layout(name: "Terminals"))
          // Made before any layout called “Gaming”.
          let waiting = HotkeyBinding(keys: hyper("g"), action: .chain([.layout(name: "Gaming"), .undo]))
          let hotstring = Hotstring(trigger: ";game", replacement: "", action: .layout(name: "Gaming"))
          model.configuration.bindings = [own, waiting]
          model.configuration.hotstrings = [hotstring]
          model.configuration.defaults = [ScreenDefault(target: "Gaming", condition: .count(2))]
          expectEqual(
            model.layoutReferences("Gaming"), [.binding(waiting.id), .hotstring(hotstring.id), .screenDefault(0)])
          // As the editor types “Gaming 2” over “Terminals”: “Gaming” arrives with what applies it.
          var arrivals: [String: Set<LayoutReference>] = [:]
          var name = "Terminals"
          for typed in ["Gaming", "Gaming ", "Gaming 2"] {
            name = model.typeLayoutName(typed, renaming: name, at: 0, arrivals: &arrivals)
            expectEqual(name, typed)
          }
          expectEqual(model.binding(own.id)?.action, .layout(name: "Gaming 2"))
          expectEqual(model.binding(waiting.id)?.action, .chain([.layout(name: "Gaming"), .undo]))
          expectEqual(model.configuration.hotstrings.map(\.action), [.layout(name: "Gaming")])
          expectEqual(model.configuration.defaults.map(\.target), ["Gaming"])
          // A refused name (another layout's) changes nothing.
          model.configuration.layouts.append(Layout(name: "Chat"))
          expectEqual(model.typeLayoutName("Chat", renaming: name, at: 0, arrivals: &arrivals), "Gaming 2")
          expectEqual(model.binding(own.id)?.action, .layout(name: "Gaming 2"))
        }
      }
    ),
    (
      "a layout copied in config.json is its own: editing or deleting the copy spares the original",
      {
        try onMain {
          @MainActor func copied() throws -> (AppModel, PreviewServices) {
            let services = PreviewServices(scenario: .empty)
            var config = SlatedConfiguration()
            config.layouts = ["Mail", "Xcode"].map { app in
              Layout(name: "Work", apps: [LayoutApp(app: app, operations: [preset("maximize")])])
            }
            config.bindings = [HotkeyBinding(keys: hyper("1"), action: .layout(name: "Work"))]
            try services.saveConfiguration(config)
            return (AppModel(services: services), services)
          }
          func apps(_ layouts: [Layout]) -> [String] { layouts.map { "\($0.name): \($0.apps.map(\.app).joined())" } }
          var (model, services) = try copied()
          expectEqual(model.layoutIndex("Work", at: 1), 1)
          expectEqual(try require(model.layoutBinding("Work", at: 1)).wrappedValue.apps.map(\.app), ["Xcode"])
          // Renaming the copy: the original still has the name, so the shortcut stays with it.
          try require(model.layoutBinding("Work", at: 1)).wrappedValue.name = "Work Xcode"
          model.saveNow()
          expectEqual(apps(services.configuration.layouts), ["Work: Mail", "Work Xcode: Xcode"])
          expectEqual(services.configuration.bindings.map(\.action), [.layout(name: "Work")])
          expect(model.selectedLayout == .slated(name: "Work Xcode", index: 1))
          // Renaming the original: the copy still has the name.
          (model, services) = try copied()
          try require(model.layoutBinding("Work", at: 0)).wrappedValue.name = "Work Mail"
          model.saveNow()
          expectEqual(apps(services.configuration.layouts), ["Work Mail: Mail", "Work: Xcode"])
          expectEqual(services.configuration.bindings.map(\.action), [.layout(name: "Work")])
          // Deleting the copy (the one the validator flags) leaves the original.
          (model, services) = try copied()
          model.selectedLayout = .slated(name: "Work", index: 1)
          model.deleteLayout("Work", at: 1)
          model.saveNow()
          expectEqual(apps(services.configuration.layouts), ["Work: Mail"])
          expect(model.selectedLayout == nil)
          // Deleting a layout before the selected one keeps the selection on it.
          model.configuration.layouts += [Layout(name: "Home"), Layout(name: "Gym")]
          model.selectedLayout = .slated(name: "Gym", index: 2)
          model.deleteLayout("Home", at: 1)
          expect(model.selectedLayout == .slated(name: "Gym", index: 1))
        }
      }
    ),
    (
      "a new layout doesn't take a name that shortcuts still apply",
      {
        try onMain {
          let model = AppModel(services: PreviewServices(scenario: .empty))
          expectEqual(model.addLayout(), "New Layout")
          expectEqual(model.addLayout(), "New Layout 2")
          let key = model.addBinding(action: .layout(name: "New Layout 2"))
          model.deleteLayout("New Layout 2")  // its shortcut stays, waiting for a layout of that name
          expectEqual(model.addLayout(), "New Layout 3")
          expectEqual(model.binding(key)?.action, .layout(name: "New Layout 2"))
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
      "the hotstrings switch keeps items that aren't finished yet",
      {
        try onMain {
          // PreviewServices writes the switch to config.json and reports it before returning, as the
          // app does. Nothing is waiting for the debounce here.
          let services = PreviewServices(scenario: .empty)
          let model = AppModel(services: services)
          let bindingID = model.addBinding()
          try require(model.bindingBinding(bindingID)).wrappedValue.name = "My sequence"
          let hotstringID = model.addHotstring()
          try require(model.hotstringBinding(hotstringID)).wrappedValue.replacement = "no trigger yet"
          model.saveNow()  // both held back: no keys, no trigger
          model.setHotstringsEnabled(false)
          expectEqual(model.configuration.bindings.map(\.name), ["My sequence"])
          expectEqual(model.configuration.hotstrings.map(\.replacement), ["no trigger yet"])
          expect(!services.configuration.general.hotstringsEnabled)
          expect(!model.runtimeStatus.hotstringsEnabled)
          expect(!model.configuration.general.hotstringsEnabled, "the draft has the switch too")

          // Finished, they save with the switch as it is now.
          try require(model.bindingBinding(bindingID)).wrappedValue.keys = hyper("m")
          try require(model.hotstringBinding(hotstringID)).wrappedValue.trigger = ";nt"
          model.saveNow()
          expectEqual(services.configuration.bindings.map(\.name), ["My sequence"])
          expectEqual(services.configuration.hotstrings.map(\.trigger), [";nt"])
          expect(!services.configuration.general.hotstringsEnabled, "the switch stays off")
          expectEqual(model.saveState, .saved)
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
      "a hotstring isn't Active when hotstrings don't run despite permission",
      {
        try onMain {
          let model = AppModel(services: TapFailedServices())
          let hotstring = try require(model.configuration.hotstrings.first { $0.enabled })
          expect(model.state(for: hotstring) == .notRunning, "nothing expands")
          model.beginHotkeySuspension()  // the Try It field has focus: expansion pauses on purpose
          expect(model.state(for: hotstring) == .active)
          model.endHotkeySuspension()

          // The first hotstring runs once it's saved; the engine has none to run until then.
          let services = PreviewServices(scenario: .empty)
          let empty = AppModel(services: services)
          empty.configuration.hotstrings = [Hotstring(trigger: ";a", replacement: "b")]
          expect(!empty.runtimeStatus.hotstringsActive)
          expect(empty.state(for: empty.configuration.hotstrings[0]) == .active, "not “Not running” meanwhile")
          empty.saveNow()
          expect(empty.runtimeStatus.hotstringsActive)
          expect(empty.state(for: empty.configuration.hotstrings[0]) == .active)
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
      "pasting the original into config.json again makes a third item, not a second copy's twin",
      {
        try onMain {
          let services = PreviewServices(scenario: .empty)
          let left = HotkeyBinding(name: "Left", keys: hyper("left"), action: preset("left-half"))
          var right = left  // pasted in config.json, id and all
          right.name = "Right"
          right.keys = hyper("right")
          let shrug = Hotstring(trigger: ";shrug", replacement: "¯\\_(ツ)_/¯")
          var flip = shrug
          flip.trigger = ";flip"
          var config = SlatedConfiguration()
          config.bindings = [left, right]
          config.hotstrings = [shrug, flip]
          try services.saveConfiguration(config)

          let model = AppModel(services: services)
          try require(model.bindingBinding(left.id)).wrappedValue.name = "Left Half"
          model.saveNow()  // writes the copies' new ids
          let rightID = model.configuration.bindings[1].id
          let flipID = model.configuration.hotstrings[1].id
          expectEqual(services.configuration.bindings.map(\.id), [left.id, rightID])
          expectEqual(services.configuration.hotstrings.map(\.id), [shrug.id, flipID])

          // The originals pasted again by hand: after the copy, and before it.
          var edited = services.configuration
          var up = left
          up.name = "Up"
          up.keys = hyper("up")
          edited.bindings.append(up)
          var sig = shrug
          sig.trigger = ";sig"
          edited.hotstrings.insert(sig, at: 1)
          try services.saveConfiguration(edited)  // notifies the model, like the file watcher

          let bindingIDs = model.configuration.bindings.map(\.id)
          let hotstringIDs = model.configuration.hotstrings.map(\.id)
          expectEqual(model.configuration.bindings.map(\.name), ["Left Half", "Right", "Up"])
          expectEqual(Set(bindingIDs).count, 3)  // each binding is its own
          expectEqual(bindingIDs[1], rightID)
          expectEqual(model.configuration.hotstrings.map(\.trigger), [";shrug", ";sig", ";flip"])
          expectEqual(Set(hotstringIDs).count, 3)  // each hotstring is its own
          expectEqual(hotstringIDs[2], flipID)

          // Edits and deletes reach the item they're meant for, and so does the save.
          model.deleteBinding(bindingIDs[2])
          try require(model.hotstringBinding(flipID)).wrappedValue.replacement = "(╯°□°)╯︵ ┻━┻"
          model.configuration.bindings[1].keys = KeyCombo(key: "")  // re-recording Right: held back
          model.saveNow()
          expectEqual(services.configuration.bindings.map(\.name), ["Left Half", "Right"])
          expectEqual(services.configuration.bindings.map(\.keys), [hyper("left"), hyper("right")])
          expectEqual(services.configuration.hotstrings.map(\.trigger), [";shrug", ";sig", ";flip"])
          expectEqual(
            services.configuration.hotstrings.map(\.replacement), ["¯\\_(ツ)_/¯", "¯\\_(ツ)_/¯", "(╯°□°)╯︵ ┻━┻"])
          expectEqual(Set(services.configuration.hotstrings.map(\.id)).count, 3)
          // Read again, the ids stay put.
          services.simulateCopy("anything")
          expectEqual(model.configuration.hotstrings.map(\.id), hotstringIDs)
          expectEqual(model.configuration.bindings.map(\.id), [left.id, rightID])
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
