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
          config.hotstrings = [empty, email, shadow, dupA, dupB]
          let issues = ConfigValidator.validate(config, knownLayouts: [])
          expect(issues.contains { $0.target == .hotstring(empty.id) && $0.severity == .error })
          expect(issues.contains { $0.target == .hotstring(email.id) && $0.message.contains(";e") })
          expect(!issues.contains { $0.target == .hotstring(shadow.id) })
          expect(issues.contains { $0.target == .hotstring(dupA.id) && $0.severity == .warning })
          expect(issues.contains { $0.target == .hotstring(dupB.id) && $0.severity == .warning })
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
