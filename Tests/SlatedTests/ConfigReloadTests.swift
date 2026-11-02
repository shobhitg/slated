import Foundation

@testable import SlatedCore
@testable import SlatedUI

// Hand edits to config.json and settings.json while the window is open: adopted visibly, or, when the
// window has unsaved edits in that file, a banner that lets the user pick the version. And the keys'
// context menus: Copy Key, Copy Value as JSON, Open the file.

private func onMain(_ body: @MainActor () throws -> Void) throws {
  try MainActor.assumeIsolated(body)
}

/// A model whose edits wait to be saved until the test says so.
@MainActor private func makeModel() -> (AppModel, PreviewServices) {
  let services = PreviewServices()
  let model = AppModel(services: services)
  model.saveDelay = .seconds(600)
  return (model, services)
}

let configReloadTests = Suite(
  "ConfigReload",
  [
    (
      "a hand edit is adopted and says which file it came from",
      {
        try onMain {
          let (model, services) = makeModel()
          var edited = services.configuration
          edited.island.cheatSheetDelay = 0.8
          services.simulateHandEdit(edited)
          expectEqual(model.configuration.island.cheatSheetDelay, 0.8)
          expectEqual(model.updatedFromDisk, [.settings])
          expectEqual(model.saveState, .saved)
          expectEqual(services.configEvents, [.reloaded([.settings], source: "disk")])
          expectEqual(
            ConfigUIEvent.reloaded([.settings], source: "disk").data, ["files": "settings.json", "source": "disk"])
        }
      }
    ),
    (
      "a hand edit to the other file is adopted and the window's unsaved edit is kept and saved",
      {
        try onMain {
          let (model, services) = makeModel()
          model.configuration.island.enabled = false
          expectEqual(model.saveState, .pending)
          var edited = services.configuration
          edited.hotstrings.removeAll()
          services.simulateHandEdit(edited)
          expect(model.conflict.isEmpty)
          expectEqual(model.configuration.hotstrings, [])
          expectEqual(model.configuration.island.enabled, false)
          expectEqual(model.updatedFromDisk, [.config])
          model.saveNow()
          expectEqual(services.configuration.hotstrings, [])
          expectEqual(services.configuration.island.enabled, false)
        }
      }
    ),
    (
      "a hand edit to a file with unsaved edits asks; Reload from File takes the file",
      {
        try onMain {
          let (model, services) = makeModel()
          let before = services.configuration
          model.configuration.hotstrings.removeAll()
          var edited = services.configuration
          edited.keyboard.capsLockAlone = .escape
          services.simulateHandEdit(edited)
          expectEqual(model.conflict, [.config])
          expectEqual(model.saveState, .conflict)
          expectEqual(model.configuration.hotstrings, [])  // The window keeps its version meanwhile.
          // Nothing is written while the banner waits, even when asked to save.
          model.configuration.keyboard.hyperModifiers = [.control]
          model.saveNow()
          expectEqual(services.configuration, edited)
          model.reloadConflictingFiles()
          expect(model.conflict.isEmpty)
          expectEqual(model.configuration.hotstrings, before.hotstrings)
          expectEqual(model.configuration.keyboard.capsLockAlone, .escape)
          expectEqual(model.saveState, .saved)
          expectEqual(model.updatedFromDisk, [.config])
          expectEqual(
            services.configEvents,
            [
              .conflict([.config], choice: nil), .conflict([.config], choice: "reload"),
              .reloaded([.config], source: "conflict"),
            ])
        }
      }
    ),
    (
      "Keep My Changes saves the window's version over the file's",
      {
        try onMain {
          let (model, services) = makeModel()
          model.configuration.hotstrings.removeAll()
          var edited = services.configuration
          edited.keyboard.capsLockAlone = .escape
          services.simulateHandEdit(edited)
          expectEqual(model.conflict, [.config])
          model.keepMyChanges()
          expect(model.conflict.isEmpty)
          expectEqual(model.saveState, .pending)
          model.saveNow()
          expectEqual(services.configuration.hotstrings, [])
          expectEqual(services.configuration.keyboard.capsLockAlone, .nothing)  // The window's version wins.
          expectEqual(services.configEvents.last, .conflict([.config], choice: "keep"))
        }
      }
    ),
    (
      "the app's own write (an import) isn't a conflict",
      {
        try onMain {
          let services = PreviewServices(scenario: .configured)
          let model = AppModel(services: services)
          model.configuration.bindings.append(
            HotkeyBinding(keys: KeyCombo(key: "", modifiers: []), action: .undo))  // held back: no keys yet
          model.saveNow()
          _ = try model.importSlateConfig()
          expect(model.conflict.isEmpty)
        }
      }
    ),
    (
      "Copy Key copies the path, Copy Value the value as the file has it, and both log the file only",
      {
        try onMain {
          let (model, services) = makeModel()
          model.copyConfigKey(ConfigKeys.islandCheatSheetDelay)
          model.copyConfigValue(ConfigKeys.islandCheatSheetDelay)
          model.copyConfigValue(ConfigKeys.capsLock)
          expectEqual(services.copiedTexts, ["island.cheatSheetDelay", "0.5", "\"hyper\""])
          expectEqual(
            services.configEvents,
            [.keyCopied(.settings, value: false), .keyCopied(.settings, value: true), .keyCopied(.config, value: true)])
          expectEqual(
            ConfigUIEvent.keyCopied(.settings, value: true).data, ["file": "settings.json", "copied": "value"])
          // Not in the file (a Slate setting at its default): nothing copied, and a toast says why.
          model.copyConfigValue(ConfigKeys.secondsBeforeRepeat)
          expectEqual(services.copiedTexts.count, 3)
          expect(model.toast?.message.contains("default") == true)
          model.openConfigFile(.settings)
          expectEqual(services.openedConfigFiles, [.settings])
        }
      }
    ),
    (
      "item keys follow the configuration: by natural key, by index when it repeats",
      {
        try onMain {
          let (model, _) = makeModel()
          let first = try require(model.configuration.hotstrings.first)
          let key = try require(model.configKey(forHotstring: first.id))
          expectEqual(key.display, "config.json › hotstrings › \(ConfigKey.quoted(first.trigger))")
          model.configuration.hotstrings.append(Hotstring(trigger: first.trigger, replacement: "again"))
          expectEqual(try require(model.configKey(forHotstring: first.id)).display, "config.json › hotstrings[0]")
        }
      }
    ),
  ])
