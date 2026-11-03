import AppKit
import Foundation

@testable import SlatedCore
@testable import SlatedUI

// View-model logic behind Settings → Clipboard and Settings → Automation, the clipboard switcher,
// the menu bar's running automations, and the validation of automation actions. SlatedUI is
// main-actor isolated; the harness runs every test on the main thread.

private func onMain(_ body: @MainActor () throws -> Void) throws {
  try MainActor.assumeIsolated(body)
}

private func json(_ action: Action) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return String(decoding: try encoder.encode(action), as: UTF8.self)
}

private let game = "com.mojang.minecraft"

let uiRecipeTests = Suite(
  "UIRecipes",
  [
    (
      "every recipe writes the action JSON the docs describe",
      {
        try onMain {
          let expected: [String: String] = [
            "auto-click-left": #"{"action":{"button":"left","op":"click"},"interval":0.1,"op":"repeat"}"#,
            "auto-click-right": #"{"action":{"button":"right","op":"click"},"interval":0.1,"op":"repeat"}"#,
            "double-click": #"{"button":"left","count":2,"op":"click"}"#,
            "click-times": #"{"action":{"button":"left","op":"click"},"interval":0.1,"op":"repeat","times":50}"#,
            "hold-left": #"{"input":"mouse:left","op":"hold"}"#,
            "hold-right": #"{"input":"mouse:right","op":"hold"}"#,
            "hold-w": #"{"input":"key:w","op":"hold"}"#,
            "toggle-sprint": #"{"input":"key:shift","op":"hold"}"#,
            "toggle-crouch": #"{"input":"key:ctrl","op":"hold"}"#,
            "spam-key": #"{"action":{"keys":"e","op":"keystroke"},"interval":0.05,"mode":"while-held","op":"repeat"}"#,
            "macro":
              #"{"op":"sequence","operations":[{"input":"key:w","op":"press","phase":"down"},{"op":"wait","seconds":2},{"input":"key:w","op":"press","phase":"up"},{"button":"left","op":"click"}]}"#,
          ]
          let ids = AutomationRecipes.all.map(\.id)
          expectEqual(Set(ids).count, ids.count)
          // A new recipe needs its JSON here too.
          expectEqual(Set(ids), Set(expected.keys))
          for recipe in AutomationRecipes.all {
            expectEqual(try json(recipe.action), expected[recipe.id] ?? "missing \(recipe.id)")
          }
        }
      }
    ),
    (
      "recipes are valid automations that round-trip and recognize themselves",
      {
        try onMain {
          for recipe in AutomationRecipes.all {
            let errors = ConfigValidator.actionProblems(recipe.action, knownLayouts: []).filter {
              $0.severity == .error
            }
            expect(errors.isEmpty, "\(recipe.id): \(errors)")
            expect(recipe.action.containsAutomation, recipe.id)
            expect(recipe.matches(recipe.action), recipe.id)
            let decoded = try JSONDecoder().decode(Action.self, from: JSONEncoder().encode(recipe.action))
            expectEqual(decoded, recipe.action)
            expectEqual(try SlateSyntax.parseOperation(SlateSyntax.format(recipe.action)), recipe.action)
          }
          // Each recipe recognizes only its own shape.
          for recipe in AutomationRecipes.all {
            let others = AutomationRecipes.all.filter { $0.id != recipe.id && $0.matches(recipe.action) }.map(\.id)
            expect(others.isEmpty, "\(recipe.id) is also matched by \(others)")
          }
        }
      }
    ),
    (
      "adding a recipe with keys creates a live, named binding where you are",
      {
        try onMain {
          let services = PreviewServices(scenario: .empty)
          let model = AppModel(services: services)
          model.selectedPane = .automation
          let recipe = try require(AutomationRecipes.recipe("auto-click-left"))
          let id = model.addRecipe(recipe, keys: KeyCombo(key: "f"), onlyInApps: [game])
          let binding = try require(model.binding(id))
          expectEqual(binding.name, "Auto-Click Left")
          expectEqual(binding.keys, KeyCombo(key: "f"))
          expectEqual(binding.onlyInApps, [game])
          expectEqual(binding.action, recipe.action)
          expect(model.selectedPane == .automation)
          expect(model.selectedBinding == .slated(id))
          expect(model.toast?.message.contains("Auto-Click Left") ?? false)
          model.saveNow()
          // A plain key is fine inside a game, so it saves right away.
          expectEqual(services.configuration.bindings.map(\.id), [id])
          expectEqual(model.binding(for: recipe)?.id, id)
          expectEqual(model.automationBindings.map(\.id), [id])
        }
      }
    ),
    (
      "adding a recipe without keys opens it in the editor, recording",
      {
        try onMain {
          let services = PreviewServices(scenario: .empty)
          let model = AppModel(services: services)
          model.selectedPane = .automation
          let id = model.addRecipe(try require(AutomationRecipes.recipe("macro")), keys: nil)
          expect(model.selectedPane == .windows)
          expect(model.selectedBinding == .slated(id))
          expectEqual(model.recordShortcutFor, id)
          model.saveNow()
          expect(services.configuration.bindings.isEmpty)  // waits for its keys
          expect(model.state(for: try require(model.binding(id))) == .new)
        }
      }
    ),
    (
      "adjusted recipes get fitting names and still count as set up",
      {
        try onMain {
          let clicks = try require(AutomationRecipes.recipe("click-times"))
          let twentyFive = Action.autoRepeat(.click(.left, count: 1), interval: 0.2, mode: .toggle, times: 25)
          expectEqual(clicks.bindingName(for: twentyFive), "Click 25 Times")
          expectEqual(
            clicks.bindingName(for: .autoRepeat(.click(.left, count: 1), interval: 0.1, mode: .toggle, times: 1)),
            "Click 1 Time")
          expect(clicks.matches(twentyFive))
          let spam = try require(AutomationRecipes.recipe("spam-key"))
          expectEqual(spam.bindingName(for: spam.action), "Spam a Key")
          expectEqual(
            spam.bindingName(for: .autoRepeat(.keystroke(KeyCombo(key: "f")), interval: 0.05, mode: .whileHeld)),
            "Spam F")
          let holdW = try require(AutomationRecipes.recipe("hold-w"))
          expectEqual(holdW.bindingName(for: .hold(.key(KeyCombo(key: "space")))), "Hold Space")
          expect(holdW.matches(.hold(.key(KeyCombo(key: "space")))))
          expect(!holdW.matches(.hold(.key(KeyCombo(key: "shift")))))
          let sprint = try require(AutomationRecipes.recipe("toggle-sprint"))
          expect(sprint.matches(.hold(.key(KeyCombo(key: "rightShift")))))
          // The modifier picked in the add sheet names the binding, so it never claims Shift for Option.
          expectEqual(sprint.bindingName(for: sprint.action), "Toggle Sprint (Shift)")
          expectEqual(sprint.bindingName(for: .hold(.key(KeyCombo(key: "alt")))), "Toggle Sprint (Option)")
          let crouch = try require(AutomationRecipes.recipe("toggle-crouch"))
          expectEqual(crouch.bindingName(for: .hold(.key(KeyCombo(key: "cmd")))), "Toggle Crouch (Command)")
          let autoClick = try require(AutomationRecipes.recipe("auto-click-left"))
          expect(autoClick.matches(.autoRepeat(.click(.left, count: 1), interval: 0.25, mode: .toggle, jitter: 0.2)))
          expect(!autoClick.matches(.autoRepeat(.click(.left, count: 1), interval: 0.1, mode: .toggle, times: 5)))

          let model = AppModel(services: PreviewServices(scenario: .empty))
          let id = model.addRecipe(clicks, keys: KeyCombo(key: "f8"), action: twentyFive)
          expectEqual(model.binding(id)?.name, "Click 25 Times")
          expectEqual(model.binding(for: clicks)?.id, id)
        }
      }
    ),
    (
      "sprint and crouch on any modifier are told apart by the name they were added with",
      {
        try onMain {
          let sprint = try require(AutomationRecipes.recipe("toggle-sprint"))
          let crouch = try require(AutomationRecipes.recipe("toggle-crouch"))
          @MainActor func hold(_ key: String) -> Action { .hold(.key(KeyCombo(key: key))) }
          // The default key and the same key picked in the sheet name the binding alike.
          expectEqual(crouch.bindingName(for: crouch.action), "Toggle Crouch (Control)")
          expectEqual(crouch.bindingName(for: hold("ctrl")), crouch.bindingName(for: crouch.action))

          let model = AppModel(services: PreviewServices(scenario: .empty))
          let sprintOnControl = model.addRecipe(sprint, keys: KeyCombo(key: "f6"), action: hold("ctrl"))
          expectEqual(model.binding(sprintOnControl)?.name, "Toggle Sprint (Control)")
          expectEqual(model.binding(for: sprint)?.id, sprintOnControl)
          expect(model.binding(for: crouch) == nil, "a sprint on Control isn't the crouch recipe")
          let crouchOnOption = model.addRecipe(crouch, keys: KeyCombo(key: "f7"), action: hold("alt"))
          expectEqual(model.binding(for: crouch)?.id, crouchOnOption)
          expectEqual(model.binding(for: sprint)?.id, sprintOnControl)

          // Renamed, a binding goes by its key: Shift is sprint, Control is crouch.
          let duck = HotkeyBinding(name: "Duck", keys: KeyCombo(key: "f8"), action: hold("rightCtrl"))
          expect(crouch.matches(duck) && !sprint.matches(duck))
          let run = HotkeyBinding(name: "Run", keys: KeyCombo(key: "f9"), action: hold("shift"))
          expect(sprint.matches(run) && !crouch.matches(run))
          // Bindings saved before the title said “Control” still count.
          let old = HotkeyBinding(name: "Toggle Crouch (Ctrl)", keys: KeyCombo(key: "f10"), action: hold("ctrl"))
          expect(crouch.matches(old) && !sprint.matches(old))
        }
      }
    ),
    (
      "suggested shortcuts are free function keys, then a free Hyper digit",
      {
        try onMain {
          // The sample setup uses F6 (auto-click) and ✦1 (a layout).
          let configured = AppModel(services: PreviewServices())
          expectEqual(
            configured.suggestedAutomationKeys(), [KeyCombo(key: "f7"), KeyCombo(key: "2", modifiers: .hyper)])
          let empty = AppModel(services: PreviewServices(scenario: .empty))
          expectEqual(empty.suggestedAutomationKeys(), [KeyCombo(key: "f6"), KeyCombo(key: "f7")])
          expectEqual(empty.suggestedAutomationKeys(limit: 1), [KeyCombo(key: "f6")])
          // The built-in shortcuts count as used.
          empty.configuration.automation.stopShortcut = KeyCombo(key: "f6")
          expectEqual(empty.suggestedAutomationKeys(limit: 1), [KeyCombo(key: "f7")])
        }
      }
    ),
    (
      "the add sheet's conflict check respects app limits",
      {
        try onMain {
          let model = AppModel(services: PreviewServices(scenario: .empty))
          model.configuration.bindings = [
            HotkeyBinding(name: "Game A", keys: KeyCombo(key: "f"), action: .hold(.mouse(.left)), onlyInApps: [game])
          ]
          expectEqual(model.otherUses(ofNewKeys: KeyCombo(key: "f"), onlyInApps: [game]), ["“Game A”"])
          expect(model.otherUses(ofNewKeys: KeyCombo(key: "f"), onlyInApps: ["com.example.other"]).isEmpty)
          expectEqual(model.otherUses(ofNewKeys: KeyCombo(key: "f"), onlyInApps: []), ["“Game A”"])
          let stop = try require(model.configuration.automation.stopShortcut)
          expectEqual(model.otherUses(ofNewKeys: stop, onlyInApps: []), [BuiltInShortcut.stopAutomations.title])
        }
      }
    ),
  ])

let uiClipboardTests = Suite(
  "UIClipboard",
  [
    (
      "the model shows the history and follows changes from the app",
      {
        try onMain {
          let services = PreviewServices()
          let model = AppModel(services: services)
          expectEqual(model.clipboardItems, services.clipboard.items)
          expect(model.clipboardItems.count > 5)
          services.simulateCopy("freshly copied", from: "com.apple.Safari")
          expectEqual(model.clipboardItems.first?.text, "freshly copied")
          let empty = AppModel(services: PreviewServices(scenario: .empty))
          expect(empty.clipboardItems.isEmpty)
        }
      }
    ),
    (
      "pin, copy, delete and clear go through the services",
      {
        try onMain {
          let services = PreviewServices()
          let model = AppModel(services: services)
          let item = try require(model.clipboardItems.first { !$0.pinned })
          model.togglePinClipboardItem(item.id)
          expect(model.clipboardItems.first { $0.id == item.id }?.pinned == true)
          model.togglePinClipboardItem(item.id)

          let older = try require(model.clipboardItems.last)
          model.copyClipboardItem(older.id)
          expectEqual(services.pastedClipboardItems, [older.id])
          expectEqual(model.clipboardItems.first?.text, older.text)
          expectEqual(model.toast?.message, "Copied to the clipboard")

          let doomed = try require(model.clipboardItems.first { !$0.pinned })
          model.deleteClipboardItem(doomed.id)
          expect(!model.clipboardItems.contains { $0.id == doomed.id })

          let pinned = model.pinnedClipboardCount
          let removed = model.clipboardItems.count - pinned
          model.clearClipboardHistory()
          expectEqual(model.clipboardItems.count, pinned)
          expect(model.clipboardItems.allSatisfy(\.pinned))
          expectEqual(model.toast?.message, "Cleared \(removed) items, kept \(pinned) pinned")
          model.clearClipboardHistory()
          expectEqual(model.toast?.message, "Nothing to clear")
        }
      }
    ),
    (
      "Settings lists images with their thumbnails, and pins, copies and deletes them like text",
      {
        try onMain {
          let services = PreviewServices()
          let model = AppModel(services: services)
          let image = try require(model.clipboardItems.first(where: \.isImage))
          let url = try require(model.clipboardImageURL(try require(image.image)))
          expect(FileManager.default.fileExists(atPath: url.path))
          model.togglePinClipboardItem(image.id)
          expect(model.clipboardItems.first { $0.id == image.id }?.pinned == true)
          model.copyClipboardItem(image.id)
          expectEqual(model.clipboardItems.first?.image, image.image)  // copied to the top, still an image
          expect(model.clipboardItems.first?.pinned == true)
          let copied = try require(model.clipboardItems.first)
          model.deleteClipboardItem(copied.id)
          expect(!model.clipboardItems.contains { $0.image == image.image })
          expect(model.clipboardImageURL(ClipboardImage(file: "gone.png", width: 1, height: 1, bytes: 1)) == nil)
        }
      }
    ),
    (
      "excluded apps offer password managers first, then running apps; none is excluded by default",
      {
        try onMain {
          let model = AppModel(services: PreviewServices())
          // Password managers' copies are kept, hidden: nothing is excluded at first.
          expectEqual(model.configuration.clipboard.excludedApps, [])
          expectEqual(model.excludableApps.first?.bundleID, "com.1password.1password")
          expectEqual(model.excludableApps.first?.name, "1Password")
          expect(model.excludableApps.first?.isPasswordManager == true)
          expect(model.excludableApps.filter(\.isPasswordManager).allSatisfy { PasswordManagers.contains($0.bundleID) })
          model.excludeFromClipboard("com.1password.1password")
          expect(model.configuration.clipboard.excludedApps.contains("com.1password.1password"))
          expect(!model.excludableApps.contains { $0.bundleID == "com.1password.1password" })
          model.excludeFromClipboard("com.apple.Safari")
          model.excludeFromClipboard("com.apple.Safari")
          expectEqual(model.configuration.clipboard.excludedApps.filter { $0 == "com.apple.Safari" }.count, 1)
          expect(!model.excludableApps.contains { $0.bundleID == "com.apple.Safari" })
          expectEqual(model.appName(bundleID: "com.apple.Safari"), "Safari")
          expectEqual(AppIcons.displayName(bundleID: "com.example.NotInstalledApp", running: []), "NotInstalledApp")
        }
      }
    ),
    (
      "built-in shortcuts and bindings on the same keys are flagged",
      {
        try onMain {
          let model = AppModel(services: PreviewServices(scenario: .empty))
          let keys = try require(KeyCombo(string: "cmd+shift+v"))
          let clash = HotkeyBinding(
            name: "Paste Plain", keys: keys, action: .keystroke(KeyCombo(key: "v", modifiers: .command)))
          let same = HotkeyBinding(name: "History", keys: keys, action: .clipboardHistory)
          model.configuration.bindings = [clash, same]
          let issues = ConfigValidator.validate(model.configuration, knownLayouts: [])
          expect(
            issues.contains {
              $0.target == .binding(clash.id) && $0.message.hasPrefix("Same keys as the clipboard history shortcut")
            })
          expect(!issues.contains { $0.target == .binding(same.id) && $0.message.hasPrefix("Same keys as") })
          expect(model.otherUses(ofBuiltIn: .clipboard).contains("“Paste Plain”"))
          expect(model.otherUses(of: keys, modal: nil, excluding: clash.id).contains(BuiltInShortcut.clipboard.title))
          // Turning clipboard history off frees its keys.
          model.configuration.clipboard.enabled = false
          expect(
            !ConfigValidator.validate(model.configuration, knownLayouts: []).contains {
              $0.message.hasPrefix("Same keys as")
            })
          model.configuration.clipboard.enabled = true
          model.restoreDefaultClipboardShortcut()
          model.configuration.clipboard.shortcut = nil
          expect(model.otherUses(ofBuiltIn: .clipboard).isEmpty)
          model.restoreDefaultClipboardShortcut()
          expectEqual(model.configuration.clipboard.shortcut, keys)
        }
      }
    ),
    (
      "content kinds pick the right presentation",
      {
        try onMain {
          let samples: [(String, ClipboardContentKind)] = [
            ("https://github.com/shobhitg/slated", .link), ("www.example.com", .link),
            ("raycast://extensions/clipboard", .link), ("hello@example.com", .email), ("#6B5EFC", .color),
            ("#fff", .color), ("~/Library/Application Support/Slated", .path), ("/usr/local/bin", .path),
            ("42.50", .number), ("1,234", .number),
            ("git commit -m \"Make the author's Slate config the default\"", .code),
            ("screenOriginX+screenSizeX/2", .code), ("{\"keys\": \"hyper+a\"}", .code),
            ("func greet(_ name: String) -> String {\n  return name\n}", .code), ("let total = price * 2", .code),
            ("Let's sync tomorrow at 10 — I'll bring the layout sketches.", .text),
            ("1 Infinite Loop\nCupertino, CA 95014", .text), ("let me know if that works for you", .text),
            ("Select the files from your folder and drag them over.", .text), ("// a comment", .text),
            ("note: buy milk", .text), ("", .text),
          ]
          for (text, kind) in samples {
            expect(
              ClipboardContent.kind(of: text) == kind,
              "“\(text)” should be \(kind), got \(ClipboardContent.kind(of: text))")
          }
          expectEqual(ClipboardContent.host(of: "https://www.github.com/x"), "github.com")
          let rgba = try require(ClipboardContent.rgba("#FF8000"))
          expectEqual(rgba.red, 1)
          expect(abs(rgba.green - 128.0 / 255) < 1e-9)
          expectEqual(ClipboardContent.rgba("#abc")?.blue, 0xCC / 255.0)
          expect(ClipboardContent.rgba("#12") == nil)
          expectEqual(ClipboardContent.singleLine("a\n\n  b  \nc"), "a ⏎ b ⏎ c")
          expectEqual(ClipboardContent.stats("one two\nthree"), .init(characters: 13, words: 3, lines: 2))
        }
      }
    ),
    (
      "an image reads as its size and app in a row, and its size and bytes under the preview",
      {
        try onMain {
          let shot = ClipboardImage(file: "a.png", width: 1280, height: 720, bytes: 245_000)
          expectEqual(ClipboardContent.imageTitle(shot, app: "Safari"), "Image · 1280×720 · Safari")
          expectEqual(ClipboardContent.imageTitle(shot, app: nil), "Image · 1280×720")
          expect(ClipboardContent.imageDetails(shot).hasPrefix("1280×720 · 245"))
          // The preview fits the long side in 240 pt and never enlarges.
          expectEqual(ClipboardImagePreview.fittedSize(shot), CGSize(width: 240, height: 135))
          let portrait = ClipboardImage(file: "b.png", width: 800, height: 1000, bytes: 1)
          expectEqual(ClipboardImagePreview.fittedSize(portrait), CGSize(width: 192, height: 240))
          let icon = ClipboardImage(file: "c.png", width: 64, height: 40, bytes: 1)
          expectEqual(ClipboardImagePreview.fittedSize(icon), CGSize(width: 64, height: 40))
          // Its panel keeps room for the caption, even beside a narrow image.
          expectEqual(ClipboardImagePreview.size(for: icon), CGSize(width: 136, height: 75))
          expectEqual(ClipThumbnail.width(for: shot, height: 28), 50)
          expectEqual(ClipThumbnail.width(for: portrait, height: 28), 22)
          expectEqual(
            ClipThumbnail.width(for: ClipboardImage(file: "d", width: 4000, height: 100, bytes: 1), height: 28), 50)
        }
      }
    ),
  ])

let uiClipboardPickerTests = Suite(
  "UIClipboardPicker",
  [
    (
      "pinned first, ⌘-numbers for the first nine, and a size fixed when it opens",
      {
        try onMain {
          let picker = ClipboardPickerModel(services: PreviewServices())
          picker.resetForShowing()
          let results = picker.results
          expect(results.prefix { $0.pinned }.count == results.filter(\.pinned).count)  // pinned first
          expectEqual(picker.selectedID, results.first?.id)
          expectEqual(picker.number(at: 0), 1)
          expectEqual(picker.number(at: 8), 9)
          expect(picker.number(at: 9) == nil)
          expect(picker.pasteAfterSelecting)
          // Nine rows show (an image row is taller), and half the next: the list scrolls.
          let shown = Array(results.prefix(9))
          let rows = shown.reduce(CGFloat(0)) { $0 + ($1.isImage ? 36 : 26) } + 13
          expect(shown.contains(where: \.isImage) && results.count > 9)
          expectEqual(picker.size, CGSize(width: 320, height: 32 + 0.5 + rows + 10))
          picker.query = "git"
          expectEqual(picker.size.height, 32 + 0.5 + rows + 10)  // filtering doesn't resize it

          let empty = ClipboardPickerModel(services: PreviewServices(scenario: .empty))
          empty.resetForShowing()
          expectEqual(empty.size.height, 32 + 0.5 + 26 + 10)
          expect(empty.results.isEmpty && empty.selectedID == nil)
        }
      }
    ),
    (
      "the arrow keys move the selection and stop at the ends",
      {
        try onMain {
          let picker = ClipboardPickerModel(services: PreviewServices())
          picker.resetForShowing()
          let results = picker.results
          picker.moveSelection(by: -1)
          expectEqual(picker.selectedID, results[0].id)
          picker.moveSelection(by: 3)
          expectEqual(picker.selectedID, results[3].id)
          picker.moveSelection(by: 100)
          expectEqual(picker.selectedID, results.last?.id)
        }
      }
    ),
    (
      "filtering selects the first match; writing the same text back doesn't; an image never matches",
      {
        try onMain {
          let picker = ClipboardPickerModel(services: PreviewServices())
          picker.resetForShowing()
          let third = picker.results[2].id
          picker.selectedID = third
          picker.query = ""  // a text field writing back its value on focus
          expectEqual(picker.selectedID, third)
          picker.query = "git"  // matches github.com too
          expectEqual(picker.results.count, 2)
          picker.query = "commit"
          expectEqual(picker.results.map(\.text), ["git commit -m \"Make the author's Slate config the default\""])
          expectEqual(picker.selectedID, picker.results.first?.id)
          picker.query = "image"
          expect(picker.results.isEmpty, "images aren't text")
          expect(picker.selectedID == nil)
          picker.resetForShowing()
          expectEqual(picker.query, "")
          expectEqual(picker.results.count, picker.items.count)
        }
      }
    ),
    (
      "↩, ⌘1–9 and a click paste through the services and close the picker",
      {
        try onMain {
          let services = PreviewServices()
          let picker = ClipboardPickerModel(services: services)
          var closed = 0
          picker.onClose = { closed += 1 }
          picker.resetForShowing()
          let second = picker.results[1]
          picker.pick(number: 2)
          expectEqual(services.pastedClipboardItems, [second.id])
          expectEqual(closed, 1)
          picker.pick(number: 99)
          picker.pick(number: 0)
          expectEqual(closed, 1)

          picker.resetForShowing()
          picker.moveSelection(by: 2)
          let selected = try require(picker.selectedID)
          picker.paste()
          expectEqual(services.pastedClipboardItems.last, selected)
          picker.resetForShowing()
          let clicked = picker.results[4].id
          picker.paste(clicked)
          expectEqual(services.pastedClipboardItems.last, clicked)
          expectEqual(closed, 3)

          // With pasteAfterSelecting off, Return only copies (the app decides; the picker says so).
          var config = services.configuration
          config.clipboard.pasteAfterSelecting = false
          try services.saveConfiguration(config)
          picker.reload()
          expect(!picker.pasteAfterSelecting)
        }
      }
    ),
    (
      "the pointer selects the row under it, unless it hasn't moved since a key or the opening",
      {
        try onMain {
          let picker = ClipboardPickerModel(services: PreviewServices())
          let resting = CGPoint(x: 500, y: 300)
          picker.resetForShowing(pointer: resting)
          let results = picker.results
          picker.hover(results[3].id, pointer: resting)  // opened under a resting pointer
          expectEqual(picker.selectedID, results[0].id)
          picker.hover(results[3].id, pointer: CGPoint(x: 500, y: 310))
          expectEqual(picker.selectedID, results[3].id)
          picker.moveSelection(by: 1, pointer: CGPoint(x: 500, y: 310))
          expectEqual(picker.selectedID, results[4].id)
          picker.hover(results[2].id, pointer: CGPoint(x: 500, y: 310))  // the list scrolled under it
          expectEqual(picker.selectedID, results[4].id)
          picker.hover(results[2].id, pointer: CGPoint(x: 502, y: 290))
          expectEqual(picker.selectedID, results[2].id)
        }
      }
    ),
    (
      "an image row shows its preview beside the picker; a text row hides it",
      {
        try onMain {
          let picker = ClipboardPickerModel(services: PreviewServices())
          var changes = 0
          picker.onPreviewChange = { changes += 1 }
          picker.resetForShowing()
          expect(picker.previewItem == nil, "the newest item is text")
          let image = try require(picker.results.first(where: \.isImage))
          let before = changes
          picker.hover(image.id, pointer: nil)
          expectEqual(picker.previewItem?.id, image.id)
          expect(changes > before, "the panel is told to show it")
          expect(picker.previewRowFrame == nil, "not laid out yet: the panel aligns with the picker")
          let row = CGRect(x: 5, y: 57, width: 310, height: 36)
          picker.rowMoved(image.id, to: row)
          expectEqual(picker.previewRowFrame, row)
          let moved = changes
          picker.rowMoved(image.id, to: row)  // the same frame again: nothing to move
          expectEqual(changes, moved)
          picker.moveSelection(by: 1)
          expect(picker.previewItem == nil, "a text row has no preview")
          expectEqual(
            picker.imageURL(try require(image.image)).map { FileManager.default.fileExists(atPath: $0.path) }, true)
        }
      }
    ),
    (
      "files are one-line rows with a preview; a screenshot's row reads its name",
      {
        try onMain {
          let picker = ClipboardPickerModel(services: PreviewServices())
          picker.resetForShowing()
          let files = try require(picker.results.first { ($0.files?.count ?? 0) > 1 })
          expectEqual(ClipboardPickerModel.rowHeight(files), 26)
          expectEqual(ClipboardContent.filesTitle(files.files ?? []).name, "Quarterly Report.pdf")
          expectEqual(ClipboardContent.filesTitle(files.files ?? []).more, "+ 1 more")
          picker.selectedID = files.id
          expectEqual(picker.previewItem?.id, files.id)
          expectEqual(SlatedUI.clipboardImagePreviewSize(model: picker), CGSize(width: 196, height: 234))
          expect(!picker.isUnavailable(files))
          expect(ClipboardContent.filesDetails(files.files ?? [], missing: []).hasPrefix("2 files · "))

          let shot = try require(picker.results.first { $0.image?.name != nil })
          expectEqual(
            ClipboardContent.imageTitle(try require(shot.image), app: "Safari"), "Screenshot 2026-10-29 at 09.41.12.png"
          )
          expectEqual(ClipboardContent.imageTitle(PreviewImages.photo, app: "Preview"), "Image · 800×1000 · Preview")
          picker.query = "quarterly"
          expectEqual(picker.results.map(\.id), [files.id])
          picker.query = "screenshot"
          expect(picker.results.isEmpty, "images aren't searched, not even by name")
        }
      }
    ),
    (
      "files that were all moved or deleted are dimmed, and picking them leaves the picker open",
      {
        try onMain {
          let services = PreviewServices()
          let picker = ClipboardPickerModel(services: services)
          var closed = 0
          var beeps = 0
          picker.onClose = { closed += 1 }
          picker.beep = { beeps += 1 }
          picker.resetForShowing()
          let gone = try require(picker.results.first { $0.files == [PreviewFiles.missing] })
          expect(picker.isUnavailable(gone))
          expectEqual(
            ClipboardContent.filesDetails([PreviewFiles.missing], missing: [PreviewFiles.missing]), "Moved or deleted")
          picker.paste(gone.id)
          expectEqual(closed, 0)
          expectEqual(beeps, 1)
          expectEqual(services.pastedClipboardItems, [gone.id])  // the app logs it and leaves the clipboard alone
          expectEqual(services.clipboardItems().first { $0.id == gone.id }?.copiedAt, gone.copiedAt)

          // Some of them gone: what's left is pasted.
          services.simulateCopy(files: [PreviewFiles.notes, PreviewFiles.missing])
          picker.resetForShowing()
          let partly = try require(picker.results.first { $0.files == [PreviewFiles.notes, PreviewFiles.missing] })
          expect(!picker.isUnavailable(partly))
          expectEqual(picker.missingFiles[partly.id], [PreviewFiles.missing])
          expect(
            ClipboardContent.filesDetails(partly.files ?? [], missing: [PreviewFiles.missing]).hasSuffix(
              "1 moved or deleted"))
          picker.paste(partly.id)
          expectEqual(closed, 1)
        }
      }
    ),
    (
      "Settings: copying files that are gone says so; the screenshot switch saves and its notice opens Privacy",
      {
        try onMain {
          let services = PreviewServices()
          let model = AppModel(services: services)
          let gone = try require(model.clipboardItems.first { $0.files == [PreviewFiles.missing] })
          expectEqual(model.missingClipboardFiles(gone), [PreviewFiles.missing])
          model.copyClipboardItem(gone.id)
          expectEqual(model.toast?.message, "Those files were moved or deleted")

          expect(model.configuration.clipboard.screenshots)
          model.configuration.clipboard.screenshots = false
          model.saveNow()
          expect(try !services.loadConfiguration().clipboard.screenshots)
          services.setScreenshotStatus(.denied(folder: "Desktop"))
          expectEqual(model.runtimeStatus.screenshots, .denied(folder: "Desktop"))
          model.openFilesAndFoldersSettings()
          expectEqual(services.openedFilesAndFoldersSettings, 1)
        }
      }
    ),
  ])

let uiAutomationTests = Suite(
  "UIAutomation",
  [
    (
      "the running card says how automations stop, in a sentence for every combination",
      {
        try onMain {
          @MainActor func hint(appSwitch: Bool, minutes: Double) -> String {
            RunningAutomationsCard.stopHint(AutomationSettings(stopOnAppSwitch: appSwitch, maxRunMinutes: minutes))
          }
          expectEqual(hint(appSwitch: true, minutes: 15), "Stops when you switch apps or after 15 min")
          expectEqual(hint(appSwitch: true, minutes: 0), "Stops when you switch apps")
          expectEqual(hint(appSwitch: false, minutes: 15), "Stops after 15 min")
          expectEqual(hint(appSwitch: false, minutes: 0), "Runs until you stop it")
        }
      }
    ),
    (
      "a time limit too big for a whole number still reads as one",
      {
        try onMain {
          // config.json takes 1e300 as plain JSON, and JSON5 Infinity. Int(_:) traps on both, and the
          // running card, the time limit picker and the rail chip all show the limit.
          let config = try SlatedConfiguration.decode(
            from: Data(#"{"automation": {"maxRunMinutes": Infinity, "stopOnAppSwitch": false}}"#.utf8))
          expectEqual(RunningAutomationsCard.stopHint(config.automation), "Stops after ∞ min")
          expectEqual(AutomationLimits.timeLimitTitle(1e300), "1e+300 min")
          expectEqual(AutomationLimits.timeLimitTitle(1e19), "1e+19 min")
          expectEqual(AutomationLimits.timeLimitTitle(-.infinity), "-∞ min")
          // Numbers that fit read as before.
          expectEqual(AutomationLimits.timeLimitTitle(1e15), "1000000000000000 min")
          expectEqual(AutomationLimits.timeLimitTitle(2.5), "2.5 min")
          expectEqual(AutomationLimits.timeLimitTitle(90), "90 min")
        }
      }
    ),
    (
      "running automations refresh on change and lead back to their bindings",
      {
        try onMain {
          let services = PreviewServices()
          let model = AppModel(services: services)
          expect(model.activeAutomations.isEmpty)
          services.setActiveAutomations(PreviewServices.sampleAutomations())
          expectEqual(model.activeAutomations.count, 2)
          let clicker = try require(model.activeAutomations.first { $0.id == "hotkey f6" })
          expectEqual(clicker.triggerKeys, KeyCombo(key: "f6"))
          expectEqual(model.binding(for: clicker)?.name, "Auto-Click Left")
          expectEqual(model.title(for: clicker), "Auto-Click Left")
          let hold = try require(model.activeAutomations.first { $0.id == "hold:key:w" })
          expectEqual(hold.triggerKeys, KeyCombo(key: "mouse4"))
          expectEqual(model.title(for: hold), "Hold W (Auto-Run)")
          let auto = try require(model.configuration.bindings.first { $0.name == "Auto-Click Left" })
          expectEqual(model.activeAutomations(for: auto).map(\.id), ["hotkey f6"])
          let orphan = ActiveAutomation(
            id: "x", title: "Repeat click", trigger: "hotstring ;x", startedAt: Date(), repetitions: 3)
          expect(model.binding(for: orphan) == nil)
          expectEqual(model.title(for: orphan), "Repeat click")
          expect(orphan.triggerKeys == nil)
          expect(
            ActiveAutomation(id: "m", title: "", trigger: "hotkey ctrl+f4 1", startedAt: Date(), repetitions: 1)
              .triggerKeys == nil)

          model.stopAutomations()
          expect(model.activeAutomations.isEmpty)
          expectEqual(model.toast?.message, "Stopped 2 automations")
          // Polling picks up counts the app changed without notifying.
          services.automations = [clicker]
          model.refreshAutomations()
          expectEqual(model.activeAutomations.map(\.id), ["hotkey f6"])
        }
      }
    ),
    (
      "automation bindings are found in nested actions and reorder within their own section",
      {
        try onMain {
          let model = AppModel(services: PreviewServices(scenario: .empty))
          let window = HotkeyBinding(
            name: "Left", keys: KeyCombo(key: "a", modifiers: .hyper), action: WindowPresets.preset("left-half").action)
          let click = HotkeyBinding(name: "Click", keys: KeyCombo(key: "f6"), action: .click(.left, count: 1))
          let window2 = HotkeyBinding(
            name: "Right", keys: KeyCombo(key: "d", modifiers: .hyper),
            action: WindowPresets.preset("right-half").action)
          let nested = HotkeyBinding(
            name: "Nested", keys: KeyCombo(key: "f7"),
            action: .chain([.undo, .sequence([SequenceStep(.wait(1)), SequenceStep(.hold(.mouse(.left)))])]))
          model.configuration.bindings = [window, click, window2, nested]
          expectEqual(model.automationBindings.map(\.name), ["Click", "Nested"])
          expect(Action.byOrientation(landscape: .undo, portrait: .click(.left, count: 1)).containsAutomation)
          expect(!Action.chain([.undo, .relaunch]).containsAutomation)
          expect(Action.sequence([SequenceStep(.click(.left, count: 1)), SequenceStep(.undo)]).containsAutomation)
          expect(!Action.sequence([SequenceStep(.click(.left, count: 1))]).containsWindowGeometry)
          expect(
            Action.sequence([SequenceStep(.click(.left, count: 1)), SequenceStep(window.action)]).containsWindowGeometry
          )

          // Dragging "Nested" above "Click" in the Automation section leaves window shortcuts in place.
          model.moveBindings(model.automationBindings.map(\.id), fromOffsets: IndexSet(integer: 1), toOffset: 0)
          expectEqual(model.configuration.bindings.map(\.name), ["Left", "Nested", "Right", "Click"])
          model.moveBindings([window.id, window2.id], fromOffsets: IndexSet(integer: 0), toOffset: 2)
          expectEqual(model.configuration.bindings.map(\.name), ["Right", "Nested", "Left", "Click"])
        }
      }
    ),
    (
      "rates, sentences and facts read naturally",
      {
        try onMain {
          expectEqual(AutomationDescriber.rate(0.1), "10 per second")
          expectEqual(AutomationDescriber.rate(0.05), "20 per second")
          expectEqual(AutomationDescriber.rate(0.25), "4 per second")
          expectEqual(AutomationDescriber.rate(0.5), "2 per second")
          expectEqual(AutomationDescriber.rate(1), "1 per second")
          expectEqual(AutomationDescriber.rate(0.3), "3.3 per second")
          expectEqual(AutomationDescriber.rate(2), "once every 2 seconds")
          expectEqual(AutomationDescriber.rate(2.5), "once every 2.5 seconds")
          expectEqual(AutomationDescriber.shortRate(0.1), "10/s")
          expectEqual(AutomationDescriber.shortRate(2), "1 per 2 s")
          expectEqual(AutomationDescriber.jitter(0.15), "±15%")

          expectEqual(
            AutomationDescriber.sentence(.autoRepeat(.click(.left, count: 1), interval: 0.1, mode: .toggle)),
            "Clicks the left button 10 times a second until pressed again")
          expectEqual(
            AutomationDescriber.sentence(
              .autoRepeat(.keystroke(KeyCombo(key: "e")), interval: 0.05, mode: .whileHeld, jitter: 0.1)),
            "Presses E 20 times a second while held, timing varied ±10%")
          expectEqual(
            AutomationDescriber.sentence(
              .autoRepeat(.click(.right, count: 1), interval: 0.1, mode: .toggle, times: 50)),
            "Clicks the right button 50 times, 10 times a second")
          expectEqual(
            AutomationDescriber.sentence(.hold(.mouse(.right))), "Holds the right button down until pressed again")
          expectEqual(
            AutomationDescriber.sentence(.hold(.key(KeyCombo(key: "shift")))), "Holds Shift down until pressed again")
          expectEqual(AutomationDescriber.sentence(.click(.left, count: 2)), "Double-clicks the left button")
          expectEqual(AutomationDescriber.sentence(.press(.key(KeyCombo(key: "w")), phase: .up)), "Releases W")
          expectEqual(AutomationDescriber.inputName(.key(KeyCombo(key: "rightCtrl"))), "Right Control")
          let macro = try require(AutomationRecipes.recipe("macro")).action
          expectEqual(AutomationDescriber.sentence(macro), "4 steps: Press W → Wait 2 s → Release W → Click Left")
          expectEqual(AutomationDescriber.facts(macro), ["4 steps", "2 s"])
          expectEqual(
            AutomationDescriber.facts(
              .autoRepeat(.click(.left, count: 1), interval: 0.1, mode: .toggle, times: 50, jitter: 0.2)),
            ["10/s", "50×", "±20%"])
          expectEqual(AutomationLimits.timeLimitTitle(0), "No limit")
          expectEqual(AutomationLimits.timeLimitTitle(60), "1 hour")
          expectEqual(AutomationLimits.timeLimitTitle(5), "5 min")
          expectEqual(ClipboardOptions.retentionTitle(0), "Forever")
          expectEqual(ClipboardOptions.retentionTitle(7), "1 week")
        }
      }
    ),
    (
      "a macro's timeline: held keys become spans, clicks instants, waits move time",
      {
        try onMain {
          let w = SyntheticInput.key(KeyCombo(key: "w"))
          let macro = try require(AutomationRecipes.recipe("macro"))
          guard case .sequence(let steps) = macro.action else {
            throw TestFailure(description: "macro isn't a sequence")
          }
          let schedule = MacroSchedule(steps: steps.map(\.action))
          expectEqual(schedule.duration, 2)
          expectEqual(schedule.spans, [MacroSchedule.Span(input: w, start: 0, end: 2)])
          expectEqual(schedule.instants, [MacroSchedule.Instant(label: "Click", time: 2, input: .mouse(.left))])
          expectEqual(schedule.lanes, [w, .mouse(.left)])
          expect(schedule.unreleased.isEmpty)

          let open = MacroSchedule(steps: [.press(w, phase: .down), .wait(0.5), .hold(.mouse(.right)), .wait(1), .undo])
          expectEqual(open.duration, 1.5)
          expectEqual(Set(open.unreleased), [w, .mouse(.right)])
          expectEqual(open.lanes, [w, .mouse(.right), nil])
        }
      }
    ),
  ])

let uiAutomationValidationTests = Suite(
  "UIAutomationValidation",
  [
    (
      "repeats: nesting and too fast are errors; pointless repeats warn",
      {
        try onMain {
          @MainActor func problems(_ action: Action) -> [ConfigValidator.Problem] {
            ConfigValidator.actionProblems(action, knownLayouts: [])
          }
          expect(problems(.autoRepeat(.click(.left, count: 1), interval: 0.1, mode: .toggle)).isEmpty)
          let nested = problems(
            .autoRepeat(
              .autoRepeat(.click(.left, count: 1), interval: 0.1, mode: .toggle), interval: 0.5, mode: .toggle))
          expect(nested.contains { $0.severity == .error && $0.message.contains("can't repeat another") })
          expect(
            problems(.autoRepeat(.click(.left, count: 1), interval: 0.005, mode: .toggle)).contains {
              $0.severity == .error
            })
          expect(problems(.autoRepeat(.wait(1), interval: 0.5, mode: .toggle)).contains { $0.severity == .warning })
          expect(
            problems(.autoRepeat(.stopAutomations, interval: 0.5, mode: .toggle)).contains { $0.severity == .warning })
          expect(
            problems(.autoRepeat(.keystroke(KeyCombo(key: "")), interval: 0.1, mode: .toggle)).contains {
              $0.severity == .error && $0.message.hasPrefix("Repeated:")
            })
          expect(problems(.wait(700)).contains { $0.severity == .warning })
        }
      }
    ),
    (
      "keys to press or hold must be real keys; modifier keys can be held",
      {
        try onMain {
          @MainActor func errors(_ action: Action) -> [String] {
            ConfigValidator.actionProblems(action, knownLayouts: []).filter { $0.severity == .error }.map(\.message)
          }
          expect(!errors(.press(.key(KeyCombo(key: "")), phase: .down)).isEmpty)
          expect(!errors(.hold(.key(KeyCombo(key: "nope")))).isEmpty)
          expect(errors(.hold(.key(KeyCombo(key: "shift")))).isEmpty)
          expect(errors(.press(.key(KeyCombo(key: "rightAlt")), phase: .down)).isEmpty)
          expect(errors(.hold(.mouse(.middle))).isEmpty)
        }
      }
    ),
    (
      "a macro that presses without releasing warns; holds and releases don't",
      {
        try onMain {
          let w = SyntheticInput.key(KeyCombo(key: "w"))
          @MainActor func warnings(_ steps: [Action]) -> [String] {
            ConfigValidator.actionProblems(.sequence(steps.map { SequenceStep($0) }), knownLayouts: [])
              .filter { $0.severity == .warning }.map(\.message)
          }
          expect(
            warnings([.press(w, phase: .down), .click(.left, count: 1)]).contains { $0.hasPrefix("W stays down") })
          expect(warnings([.press(w, phase: .down), .wait(1), .press(w, phase: .up)]).isEmpty)
          expect(warnings([.hold(w), .click(.left, count: 1)]).isEmpty)
          expect(
            warnings([.press(.mouse(.right), phase: .down)]).contains { $0.hasPrefix("Right Button stays down") })
          expectEqual(ConfigValidator.unreleasedPresses([.press(w, phase: .down), .press(w, phase: .down)]), [w])
          expect(ConfigValidator.unreleasedPresses([.press(w, phase: .up)]).isEmpty)
        }
      }
    ),
    (
      "a wait on its own warns; inside a sequence it doesn't",
      {
        try onMain {
          var config = SlatedConfiguration()
          let lone = HotkeyBinding(keys: KeyCombo(key: "f8"), action: .wait(1))
          let macro = HotkeyBinding(
            keys: KeyCombo(key: "f9"),
            action: .sequence([SequenceStep(.wait(1)), SequenceStep(.click(.left, count: 1))]))
          config.bindings = [lone, macro]
          let issues = ConfigValidator.validate(config, knownLayouts: [])
          expect(
            issues.contains {
              $0.target == .binding(lone.id) && $0.field == .action && $0.message.hasPrefix("A wait on its own")
            })
          expect(!issues.contains { $0.target == .binding(macro.id) })
        }
      }
    ),
    (
      "per-app bindings: plain keys are fine, and only overlapping apps clash",
      {
        try onMain {
          var config = SlatedConfiguration()
          let gameA = HotkeyBinding(
            name: "A", keys: KeyCombo(key: "f"), action: .hold(.mouse(.left)), onlyInApps: [game])
          let gameB = HotkeyBinding(
            name: "B", keys: KeyCombo(key: "f"), action: .hold(.mouse(.right)), onlyInApps: ["com.example.other"])
          config.bindings = [gameA, gameB]
          var issues = ConfigValidator.validate(config, knownLayouts: [])
          expect(issues.isEmpty, "\(issues)")
          let alsoA = HotkeyBinding(
            name: "A2", keys: KeyCombo(key: "f"), action: .click(.left, count: 1), onlyInApps: [game, "x"])
          let everywhere = HotkeyBinding(name: "Global", keys: KeyCombo(key: "f"), action: .undo)
          config.bindings = [gameA, gameB, alsoA, everywhere]
          issues = ConfigValidator.validate(config, knownLayouts: [])
          @MainActor func duplicates(_ binding: HotkeyBinding) -> String? {
            issues.first { $0.target == .binding(binding.id) && $0.message.hasPrefix("Same shortcut") }?.message
          }
          expect(duplicates(gameA)?.contains("“A2”") ?? false)
          expect(!(duplicates(gameA)?.contains("“B”") ?? true))
          expect(duplicates(gameB)?.contains("“Global”") ?? false)
          expect(!(duplicates(gameB)?.contains("“A”") ?? true))
          expect(issues.contains { $0.target == .binding(everywhere.id) && $0.message.hasPrefix("Without ⌃, ⌥ or ⌘") })
          expect(!issues.contains { $0.target == .binding(gameA.id) && $0.message.hasPrefix("Without") })
        }
      }
    ),
    (
      "bare mouse buttons warn unless limited to an app or given a modifier",
      {
        try onMain {
          var config = SlatedConfiguration()
          let back = HotkeyBinding(keys: KeyCombo(key: "mouse4"), action: .hold(.mouse(.left)))
          let middle = HotkeyBinding(keys: KeyCombo(key: "mouse3"), action: .click(.left, count: 2))
          let withModifier = HotkeyBinding(keys: KeyCombo(key: "mouse5", modifiers: .control), action: .undo)
          let inGame = HotkeyBinding(keys: KeyCombo(key: "mouse5"), action: .undo, onlyInApps: [game])
          let shift = HotkeyBinding(keys: KeyCombo(key: "shift"), action: .undo)
          config.bindings = [back, middle, withModifier, inGame, shift]
          let issues = ConfigValidator.validate(config, knownLayouts: [])
          @MainActor func messages(_ binding: HotkeyBinding) -> [String] {
            issues.filter { $0.target == .binding(binding.id) }.map(\.message)
          }
          expect(messages(back).contains { $0.contains("Back") && $0.contains("Only In") })
          expect(messages(middle).contains { $0.hasPrefix("Middle-click stops working") })
          expect(messages(withModifier).isEmpty, "\(messages(withModifier))")
          expect(messages(inGame).isEmpty, "\(messages(inGame))")
          expect(issues.contains { $0.target == .binding(shift.id) && $0.severity == .error })
        }
      }
    ),
    (
      "the recorder accepts mouse buttons and maps AppKit's numbers to Mouse 3–5",
      {
        try onMain {
          expectEqual(KeyEventMapping.mouseButtonName(for: 2), "mouse3")
          expectEqual(KeyEventMapping.mouseButtonName(for: 3), "mouse4")
          expectEqual(KeyEventMapping.mouseButtonName(for: 4), "mouse5")
          expect(KeyEventMapping.mouseButtonName(for: 0) == nil)
          expect(KeyEventMapping.mouseButtonName(for: 1) == nil)
          expect(ShortcutRules.isAcceptableGlobalShortcut(KeyCombo(key: "mouse4")))
          expect(!ShortcutRules.isAcceptableGlobalShortcut(KeyCombo(key: "f")))
          expect(AppIcons.isGameCategory("public.app-category.games"))
          expect(AppIcons.isGameCategory("public.app-category.action-games"))
          expect(!AppIcons.isGameCategory("public.app-category.productivity"))
          expect(AppIcons.isGame(path: nil, bundleID: game))
        }
      }
    ),
  ])

/// SF Symbols names are plain strings; a typo or a symbol newer than the OS shows as nothing. This
/// checks every symbol the clipboard and automation UI uses exists on this macOS.
let uiSymbolContractTests = Suite(
  "UISymbolsContract",
  [
    (
      "every SF Symbol the settings UI names exists",
      {
        try onMain {
          var names = Set(SettingsPane.allCases.map(\.symbol))
          names.formUnion(ActionKind.allCases.map(\.symbol))
          names.formUnion(ClipboardContentKind.allCases.map(\.symbol))
          names.formUnion([
            "arrow.down.to.line.compact", "arrow.left.arrow.right", "arrow.up.forward.app", "calendar.badge.clock",
            "chevron.right", "clock", "clock.arrow.circlepath", "doc.on.clipboard.fill", "doc.on.doc",
            "dot.radiowaves.left.and.right",
            "ellipsis.circle", "exclamationmark.shield.fill", "globe", "hand.point.down.fill", "hand.raised.fill",
            "hare.fill", "internaldrive.fill", "key.fill", "list.clipboard.fill", "lock.shield", "moon.zzz.fill",
            "pin", "pin.fill", "pin.slash", "plus", "power", "record.circle", "repeat", "shield.lefthalf.filled",
            "shift",
            "sparkles", "square.stack.3d.up.fill", "stop.circle.fill", "stop.fill", "timeline.selection", "timer",
            "trash", "wand.and.stars", "xmark.circle.fill", "arrow.down.to.line", "arrow.up.to.line", "bolt.fill",
            "magnifyingglass", "questionmark.folder.fill",
          ])
          for name in names.sorted() {
            expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "missing SF Symbol “\(name)”")
          }
        }
      }
    ),
    (
      "every icon-only button and menu has an accessibility label",
      {
        // Hosted views expose no accessibility tree to check (HostingContractTests), so this reads the
        // source: a control whose label is just an SF Symbol needs `.accessibilityLabel` among the
        // modifiers that follow it, or VoiceOver reads the symbol's name.
        let ui = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
          .appendingPathComponent("../../Sources/SlatedUI").standardizedFileURL
        let files = try require(FileManager.default.enumerator(at: ui, includingPropertiesForKeys: nil))
          .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        expect(files.count > 50, "read \(files.count) files in \(ui.path)")
        var unlabeled: [String] = []
        for file in files {
          let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
          for index in lines.indices.dropLast(2) {
            let line = lines[index]
            let opensLabel = line.hasSuffix("label: {") || (line.hasPrefix("Button(action:") && line.hasSuffix(") {"))
            guard opensLabel, lines[index + 1].hasPrefix("Image(systemName:"), lines[index + 2] == "}" else { continue }
            let modifiers = lines[(index + 3)...].prefix { $0.hasPrefix(".") }
            if !modifiers.contains(where: { $0.hasPrefix(".accessibilityLabel(") }) {
              unlabeled.append("\(file.lastPathComponent):\(index + 1)")
            }
          }
        }
        expectEqual(unlabeled, [])
      }
    ),
  ])
