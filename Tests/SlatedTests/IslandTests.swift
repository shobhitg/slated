import AppKit
import Foundation

@testable import SlatedCore
@testable import SlatedUI

// The notch island: its settings, the cheat sheet it builds from your shortcuts, which presentation
// wins when several things want the island, and the sizes the presenter uses for hit testing.

private func onMain(_ body: @MainActor () throws -> Void) throws {
  try MainActor.assumeIsolated(body)
}

private func decode(_ json: String) throws -> SlatedConfiguration {
  try SlatedConfiguration.decode(from: Data(json.utf8))
}

private func combo(_ string: String) throws -> KeyCombo { try require(KeyCombo(string: string), string) }

private func approximately(_ a: CGRect?, _ b: CGRect, tolerance: CGFloat = 0.002) -> Bool {
  guard let a else { return false }
  return abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance && abs(a.width - b.width) < tolerance
    && abs(a.height - b.height) < tolerance
}

let islandSettingsTests = Suite(
  "IslandSettings",
  [
    (
      "defaults: on, cheat sheet after half a second, failures explained",
      {
        let island = SlatedConfiguration().island
        expectEqual(island, IslandSettings(enabled: true, cheatSheet: true, cheatSheetDelay: 0.5, showFailures: true))
        expectEqual(try decode("{}").island, island)
      }
    ),
    (
      "a partial section keeps the other defaults",
      {
        let island = try decode(#"{"island": {"cheatSheet": false, "cheatSheetDelay": 0.8}}"#).island
        expectEqual(island, IslandSettings(enabled: true, cheatSheet: false, cheatSheetDelay: 0.8, showFailures: true))
      }
    ),
    (
      "round-trips and is always written out",
      {
        var config = SlatedConfiguration()
        config.island = IslandSettings(enabled: false, cheatSheet: false, cheatSheetDelay: 1.25, showFailures: false)
        let text = String(decoding: try config.encoded(), as: UTF8.self)
        expect(text.contains(#""island" : {"#), "island section missing:\n\(text)")
        expect(text.contains(#""cheatSheetDelay" : 1.25"#))
        expectEqual(try SlatedConfiguration.decode(from: config.encoded()), config)
      }
    ),
    (
      "a wrong type is an error, as in every other section",
      {
        expectThrows { _ = try decode(#"{"island": {"enabled": "yes"}}"#) }
      }
    ),
  ])

let uiCheatSheetTests = Suite(
  "UICheatSheet",
  [
    (
      "the starter bindings: windows in keyboard order, then displays",
      {
        try onMain {
          let shortcuts = StarterBindings.all.map {
            CheatSheet.Shortcut(keys: $0.keys, name: $0.name, action: $0.action)
          }
          let sheet = CheatSheet.hyper(shortcuts, hyperModifiers: .hyper)
          expectEqual(sheet.title, "Hyper")
          expect(sheet.isHyper)
          expectEqual(sheet.items.count, 21)
          expectEqual(sheet.sections.map(\.title), ["Windows", "Displays"])
          expectEqual(
            sheet.sections[0].items.map(\.label),
            ["A", "B", "C", "D", "E", "F", "G", "H", "Q", "S", "V", "W", "X", "Z", "'", "↩", "⇥"])
          expectEqual(sheet.sections[1].items.map(\.label), ["←", "↑", "↓", "→"])
          expectEqual(sheet.sections[0].items.first?.title, "Left half")
          expectEqual(sheet.sections[0].items.first?.id, "hyper+a")
        }
      }
    ),
    (
      "display titles drop what the section already says",
      {
        try onMain {
          let shortcuts = StarterBindings.all.map {
            CheatSheet.Shortcut(keys: $0.keys, name: $0.name, action: $0.action)
          }
          let displays = CheatSheet.hyper(shortcuts, hyperModifiers: .hyper).sections[1].items.map(\.title)
          expectEqual(displays, ["Screen on the left", "Screen above", "Second screen", "Screen on the right"])
          expectEqual(CheatSheet.shortened("Throw to Next Screen", in: .displays), "Next Screen")
          expectEqual(CheatSheet.shortened("Throw to Display Above, Resized", in: .displays), "Display Above")
          expectEqual(
            CheatSheet.shortened("Throw to the screen on the right", in: .windows), "Throw to the screen on the right")
          expectEqual(CheatSheet.shortened("Throw to ", in: .displays), "Throw to ")
        }
      }
    ),
    (
      "window glyphs show where each placement lands",
      {
        try onMain {
          let byName = Dictionary(
            uniqueKeysWithValues: StarterBindings.all.map { ($0.name ?? "", CheatSheet.region(for: $0.action)) })
          expect(approximately(byName["Left half"] ?? nil, CGRect(x: 0, y: 0, width: 0.5, height: 1)))
          expect(approximately(byName["First third"] ?? nil, CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1)))
          expect(approximately(byName["Top half"] ?? nil, CGRect(x: 0, y: 0, width: 1, height: 0.5)))
          expect(approximately(byName["Bottom-right quarter"] ?? nil, CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)))
          // Not a preset: worked out with the frame math on a sample screen.
          expect(
            approximately(
              byName["Large center"] ?? nil, CGRect(x: 0.125, y: 0.125, width: 1 / 1.3, height: 1 / 1.3),
              tolerance: 0.003),
            "\(String(describing: byName["Large center"]))")
          expectEqual(byName["Grid"] ?? nil, nil)
          expectEqual(CheatSheet.region(for: .focusApp("Safari")), nil)
        }
      }
    ),
    (
      "only Hyper shortcuts without a modal key; the first for a key wins",
      {
        try onMain {
          let shortcuts = [
            CheatSheet.Shortcut(keys: try combo("hyper+a"), name: "First", action: .undo),
            CheatSheet.Shortcut(keys: try combo("hyper+a"), name: "Duplicate", action: .relaunch),
            CheatSheet.Shortcut(keys: try combo("cmd+shift+v"), name: "Clipboard", action: .clipboardHistory),
            CheatSheet.Shortcut(keys: try combo("h"), modal: try combo("hyper+m"), name: "Modal", action: .undo),
          ]
          let sheet = CheatSheet.hyper(shortcuts, hyperModifiers: .hyper)
          expectEqual(sheet.items.map(\.title), ["First"])
        }
      }
    ),
    (
      "extra modifiers beyond Hyper show on the keycap",
      {
        try onMain {
          let meh: Modifiers = [.control, .option, .command]
          let shortcuts = [
            CheatSheet.Shortcut(keys: KeyCombo(key: "h", modifiers: meh), action: .undo),
            CheatSheet.Shortcut(keys: KeyCombo(key: "h", modifiers: meh.union(.shift)), action: .relaunch),
            CheatSheet.Shortcut(keys: KeyCombo(key: "j", modifiers: [.control, .option]), action: .undo),
          ]
          let sheet = CheatSheet.hyper(shortcuts, hyperModifiers: meh)
          expectEqual(sheet.items.map(\.label).sorted(), ["H", "⇧H"])
          // Plain H sorts before ⇧H.
          let windows = try require(sheet.sections.first { $0.title == "Windows" })
          expectEqual(windows.items.map(\.label), ["H"])
        }
      }
    ),
    (
      "a modal key's sheet lists only its keys, with their modifiers",
      {
        try onMain {
          let modal = try combo("ctrl+e")
          let shortcuts = [
            CheatSheet.Shortcut(keys: try combo("h"), modal: modal, name: "Left", action: .undo),
            CheatSheet.Shortcut(keys: try combo("shift+k"), modal: modal, name: "Top", action: .undo),
            CheatSheet.Shortcut(keys: try combo("j"), modal: try combo("ctrl+f"), name: "Elsewhere", action: .undo),
            CheatSheet.Shortcut(keys: try combo("hyper+a"), name: "Not modal", action: .undo),
          ]
          let sheet = CheatSheet.modal(modal, shortcuts)
          expectEqual(sheet.title, "⌃E")
          expect(!sheet.isHyper)
          expectEqual(sheet.items.map(\.label), ["H", "⇧K"])
        }
      }
    ),
    (
      "sections follow what each shortcut does",
      {
        try onMain {
          @MainActor func group(_ action: Action?) -> String { CheatSheet.group(for: action).title }
          expectEqual(group(.focusApp("Safari")), "Apps & Focus")
          expectEqual(group(.autoRepeat(.click(.left, count: 1), interval: 0.1, mode: .toggle)), "Automation")
          expectEqual(group(.hold(.key(KeyCombo(key: "w", modifiers: [])))), "Automation")
          expectEqual(group(.shell(command: "ls", wait: false, path: nil)), "Utilities")
          expectEqual(group(.layout(name: "coding")), "Layouts")
          expectEqual(group(.chain([.throwWindow(screen: .index(1), width: nil, height: nil)])), "Displays")
          // A macro sits with the automations, as in Settings; other sequences go by their first step.
          expectEqual(group(try require(AutomationRecipes.recipe("macro")).action), "Automation")
          expectEqual(group(.sequence(WindowPresets.defaultSequence)), "Displays")
          // Settings lists anything that clicks or presses under Automation, whatever its shape.
          let leftHalf = WindowPresets.preset("left-half").action
          let click = Action.click(.left, count: 1)
          expectEqual(group(.chain([leftHalf, click])), "Automation")
          expectEqual(group(.byOrientation(landscape: leftHalf, portrait: click)), "Automation")
          expectEqual(group(.byOrientation(landscape: click, portrait: leftHalf)), "Automation")
          expectEqual(group(.sequence([SequenceStep(leftHalf), SequenceStep(click)])), "Automation")
          expectEqual(group(.chain([leftHalf])), "Windows")
          expectEqual(group(.sequence([SequenceStep(.insertText("hi", method: .auto))])), "Utilities")
          expectEqual(group(.sequence([])), "Utilities")
          expectEqual(group(nil), "Scripts")
          let script = CheatSheet.Shortcut(keys: try combo("hyper+j"), summary: "JavaScript function")
          let sheet = CheatSheet.hyper([script], hyperModifiers: .hyper)
          expectEqual(sheet.items.first?.title, "JavaScript function")
          expectEqual(sheet.items.first?.symbol, "curlybraces")
        }
      }
    ),
    (
      "a blank name falls back to describing the action",
      {
        try onMain {
          let shortcut = CheatSheet.Shortcut(keys: try combo("hyper+t"), name: "  ", action: .focusApp("Terminal"))
          expectEqual(CheatSheet.title(for: shortcut), "Focus Terminal")
        }
      }
    ),
    (
      "a Slate file's functions are listed by what they do, the same in Settings and here",
      {
        try onMain {
          let firstThird = try require(WindowPresets.orientation.first).action
          let throwRight = Action.throwWindow(screen: .relative(.right), width: "screenSizeX", height: "screenSizeY")
          let described = SourceBinding(
            keys: try combo("hyper+f"), summary: "JavaScript function", action: firstThird, function: .described)
          let thrown = SourceBinding(
            keys: try combo("hyper+right"), summary: "JavaScript function", action: throwRight, function: .described)
          let unknown = SourceBinding(
            keys: try combo("hyper+i"), summary: "JavaScript function",
            function: .undescribed(reason: "depends on the focused app or window title"))
          let plain = SourceBinding(
            keys: try combo("hyper+s"), summary: "push up", action: .push(direction: .up, style: .none, screen: nil))

          // Settings: the title says what it does, the caption that it's a function, or why it can't.
          expectEqual(described.title, "First Third")
          expectEqual(described.caption, "JavaScript function")
          expectEqual(unknown.title, "JavaScript Function")
          expectEqual(unknown.caption, "Depends on the focused app or window title")
          expectEqual(unknown.undescribedReason, "depends on the focused app or window title")
          expectEqual(plain.caption, "push up")
          expect(described.runsFunction && unknown.runsFunction && !plain.runsFunction)
          // With no operation and no reason, it's still a function.
          let bare = SourceBinding(keys: try combo("hyper+j"), summary: "JavaScript function")
          expectEqual(bare.caption, "Runs code in your Slate file")

          // The cheat sheet groups them by what they do, under the same titles.
          let shortcuts = [described, thrown, unknown, plain].map(CheatSheet.Shortcut.init)
          let sheet = CheatSheet.hyper(shortcuts, hyperModifiers: .hyper)
          expectEqual(sheet.sections.map(\.title), ["Windows", "Displays", "Scripts"])
          expectEqual(
            sheet.items.map(\.title), ["First Third", "Push Up", "Right Display", "JavaScript function"])
          expectEqual(sheet.items.first?.region, WindowPresets.preset("left-third").region)
        }
      }
    ),
    (
      "keyboard order: letters, digits with 0 last, punctuation, arrows, named keys",
      {
        try onMain {
          let keys = ["tab", "right", "left", "0", "1", "'", "z", "a", "f5", "up"]
          let sorted = keys.map { KeyCombo(key: $0, modifiers: .hyper) }
            .sorted { CheatSheet.rank($0).lexicographicallyPrecedes(CheatSheet.rank($1)) }.map(\.key)
          expectEqual(Array(sorted.prefix(8)), ["a", "z", "1", "0", "'", "left", "up", "right"])
          expectEqual(Set(sorted.suffix(2)), ["tab", "f5"])
        }
      }
    ),
    (
      "named keys sort by name, then number (F2 before F10), whatever the config's order",
      {
        try onMain {
          let keys = ["f12", "f10", "f2", "f1", "f11", "pageDown", "pageUp", "space", "mouse5", "mouse4", "tab", "esc"]
          @MainActor func sorted(_ keys: [String]) -> [String] {
            keys.map { KeyCombo(key: $0, modifiers: .hyper) }
              .sorted { CheatSheet.rank($0).lexicographicallyPrecedes(CheatSheet.rank($1)) }.map(\.key)
          }
          let expected = [
            "esc", "f1", "f2", "f10", "f11", "f12", "mouse4", "mouse5", "pageDown", "pageUp", "space", "tab",
          ]
          expectEqual(sorted(keys), expected)
          expectEqual(sorted(keys.reversed()), expected)
        }
      }
    ),
  ])

let uiIslandModelTests = Suite(
  "UIIslandModel",
  [
    (
      "the cheat sheet beats the modal key, which beats a banner, which beats automations",
      {
        try onMain {
          let model = IslandModel()
          expectEqual(model.presentation, .hidden)
          model.automations = PreviewServices.sampleAutomations()
          expectEqual(model.presentation, .automations(expanded: false))
          model.isHovering = true
          expectEqual(model.presentation, .automations(expanded: true))
          expect(model.isInteractive)
          let feedback = IslandFeedback(title: "Left half")
          model.show(.done(feedback))
          expectEqual(model.presentation, .banner(.done(feedback)))
          expect(!model.isInteractive, "banners never take clicks")
          let modal = CheatSheet.modal(
            try combo("ctrl+e"), [CheatSheet.Shortcut(keys: try combo("h"), modal: try combo("ctrl+e"), action: .undo)])
          model.modal = modal
          expectEqual(model.presentation, .modal(modal, expanded: false))
          model.modalExpanded = true
          expectEqual(model.presentation, .modal(modal, expanded: true))
          let sheet = CheatSheet.hyper(
            [CheatSheet.Shortcut(keys: try combo("hyper+a"), action: .undo)], hyperModifiers: .hyper)
          model.cheatSheet = sheet
          expectEqual(model.presentation, .cheatSheet(sheet))
          model.isParked = true
          expect(model.presentation == .hidden, "parked: drawn collapsed while the panel comes on screen")
        }
      }
    ),
    (
      "empty sheets don't show",
      {
        try onMain {
          let model = IslandModel()
          model.cheatSheet = CheatSheet.hyper([], hyperModifiers: .hyper)
          expectEqual(model.presentation, .hidden)
          let empty = CheatSheet.modal(try combo("ctrl+e"), [])
          model.modal = empty
          model.modalExpanded = true
          expect(model.presentation == .modal(empty, expanded: false), "the modal key still shows, compact")
        }
      }
    ),
    (
      "a banner's expiry only clears that banner",
      {
        try onMain {
          let model = IslandModel()
          let first = model.show(.failed("No focused window to move"))
          let second = model.show(.done(IslandFeedback(title: "Maximize")))
          model.clearBanner(id: first)
          expectEqual(model.banner, .done(IslandFeedback(title: "Maximize")))
          model.clearBanner(id: second)
          expectEqual(model.banner, nil)
          expectEqual(model.presentation, .hidden)
        }
      }
    ),
    (
      "on a notch display the island hugs the notch and grows from it",
      {
        try onMain {
          let model = IslandModel()
          model.geometry = IslandGeometry(notch: CGSize(width: 185, height: 32), menuBarHeight: 32)
          expect(model.size == CGSize(width: 185, height: 32), "hidden: exactly the notch")
          model.automations = PreviewServices.sampleAutomations()
          expectEqual(model.size, CGSize(width: 185 + 2 * IslandLayout.wing, height: 32))
          let compact = model.size
          model.isHovering = true
          expect(model.size.width > compact.width && model.size.height > compact.height)
          model.isHovering = false
          model.show(.done(IslandFeedback(title: "Left half", app: "Safari")))
          expect(model.size.width >= 185 + 2 * IslandLayout.wing)
          expectEqual(model.size.height, 32 + IslandLayout.bannerRow)
        }
      }
    ),
    (
      "banners are wide enough for their text, up to a limit",
      {
        try onMain {
          let model = IslandModel()
          model.geometry = IslandGeometry(notch: nil, menuBarHeight: 24)
          let banner = IslandModel.Banner.done(
            IslandFeedback(
              title: "Throw to the screen on the right", app: "Xcode", symbol: "rectangle.portrait.and.arrow.right"))
          model.show(banner)
          expect(model.size.width >= IslandLayout.bannerContentWidth(banner) + 2 * IslandLayout.sheetPadding)
          expectEqual(model.size.height, 40)
          model.show(.failed(String(repeating: "Something went wrong. ", count: 20)))
          expectEqual(model.size.width, 560)
        }
      }
    ),
    (
      "the cheat sheet's size follows its rows and sections",
      {
        try onMain {
          let model = IslandModel()
          model.geometry = IslandGeometry(notch: CGSize(width: 185, height: 32), menuBarHeight: 32)
          let shortcuts = StarterBindings.all.map {
            CheatSheet.Shortcut(keys: $0.keys, name: $0.name, action: $0.action)
          }
          let sheet = CheatSheet.hyper(shortcuts, hyperModifiers: .hyper)
          model.cheatSheet = sheet
          expectEqual(IslandLayout.sheetGrid(sheet).columns, 3)
          // 17 windows → 6 rows, 4 displays → 2 rows, two section headers.
          let expectedHeight =
            32 + IslandLayout.sheetHeader + 8 * IslandLayout.sheetRow + 2 * IslandLayout.sheetSectionHeader
            + IslandLayout.sheetPadding
          expectEqual(model.size.height, expectedHeight)
          expectEqual(model.size.width, 3 * IslandLayout.sheetColumnWidth + 2 * IslandLayout.sheetPadding)
          let small = CheatSheet.hyper(Array(shortcuts.prefix(4)), hyperModifiers: .hyper)
          expectEqual(IslandLayout.sheetGrid(small).columns, 2)
        }
      }
    ),
    (
      "every SF Symbol the island names exists",
      {
        try onMain {
          let names = [
            "exclamationmark.triangle.fill", "computermouse.fill", "keyboard.fill", "cursorarrow.click.2", "repeat",
            "command.square.fill", "text.insert", "square.grid.3x3", "stop.fill", "laptopcomputer", "keyboard",
            "exclamationmark.triangle", "timer", "curlybraces", "checkmark",
          ]
          for name in names {
            expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "missing SF Symbol “\(name)”")
          }
        }
      }
    ),
  ])
