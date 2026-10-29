import Foundation
import SlatedScript
import SlatedSystem

@testable import SlatedCore

// Slated's two files on disk (ConfigFileStore), in temporary homes: the migration of a version 1
// config.json and its Slate config, a first run, and saves that write only the file that changed.

/// A temporary home with `~/.config/slated`, and a store on it that imports Slate configs the way
/// the app does.
@MainActor
private final class Home {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("SlatedHome-\(UUID().uuidString)")
  var folder: URL { url.appendingPathComponent(".config/slated") }
  var config: URL { folder.appendingPathComponent("config.json") }
  var settings: URL { folder.appendingPathComponent("settings.json") }
  var backup: URL { folder.appendingPathComponent("config.v1.json") }

  init() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  deinit { try? FileManager.default.removeItem(at: url) }

  func store() -> ConfigFileStore {
    let store = ConfigFileStore(configURL: config, home: url.path)
    let home = url.path
    store.importSlate = { SlateConfigImport.importFiles($0, home: home) }
    return store
  }

  func write(_ text: String, to file: URL) throws { try Data(text.utf8).write(to: file) }
  func write(_ text: String, home name: String) throws { try write(text, to: url.appendingPathComponent(name)) }
  func read(_ file: URL) -> String? { (try? Data(contentsOf: file)).map { String(decoding: $0, as: UTF8.self) } }
  func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

  /// A file's top-level keys, parsed.
  func keys(_ file: URL) throws -> Set<String> {
    let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: file)) as? [String: Any]
    return Set(try require(object).keys)
  }

  func json(_ file: URL) throws -> [String: Any] {
    try require(try JSONSerialization.jsonObject(with: try Data(contentsOf: file)) as? [String: Any])
  }
}

private func onMain(_ body: @MainActor () throws -> Void) throws { try MainActor.assumeIsolated(body) }

/// The author's situation: version 1, no bindings of their own (well, one here), Slate files loading,
/// settings in every section.
private let legacyConfig = #"""
  {
    // Hand-edited, with comments.
    "version": 1,
    "general": { "showActionHUD": true, "loadSlateConfigs": true, "slateConfigPaths": ["~/.slate.js", "~/.slate"] },
    "settings": { "nudgePercentOf": "windowSize" },
    "island": { "enabled": false },
    "clipboard": { "maxItems": 50 },
    "keyboard": { "capsLock": "hyper" },
    "bindings": [ { "id": "A0000000-0000-4000-8000-000000000001", "keys": "hyper+b", "action": "undo" } ],
    "hotstrings": [ { "id": "B0000000-0000-4000-8000-000000000001", "trigger": "brb", "replacement": "be right back" } ],
  }
  """#

/// Three shortcuts: one plain, one function that converts, one on keys config.json already uses, and
/// one that needs JavaScript.
private let slateJS = #"""
  slate.config("nudgePercentOf", "screenSize");
  slate.config("undoMaxStackSize", 5);
  slate.bind("a:ctrl,shift,alt,cmd", "push left");
  slate.bind("f:ctrl,shift,alt,cmd", (win) => { win.doOperation("push right"); });
  slate.bind("b:ctrl,shift,alt,cmd", "push up");
  slate.bind("t:ctrl,shift,alt,cmd", (win) => { win.doOperation(win.title() === "x" ? "push up" : "push down"); });
  """#

@MainActor
private func migratesAVersion1Config() throws {
  let home = try Home()
  try home.write(legacyConfig, to: home.config)
  try home.write(slateJS, home: ".slate.js")
  let store = home.store()
  let result = store.load()
  expectEqual(result.kind, .migrated)
  expect(result.settingsMoved && result.backedUp)
  expectEqual(result.written, [.settings, .config])
  expectEqual(store.loadError, nil)
  let report = try require(result.slateImport)
  expectEqual(report.files, ["~/.slate.js"])
  expectEqual([report.added, report.alreadyThere, report.notConverted.count], [2, 1, 1])
  expectEqual(report.notConverted.map(\.what), ["hyper+t"])

  // The old file, kept as it was.
  expectEqual(home.read(home.backup), legacyConfig)
  // config.json: what keys do, version 2. The native hyper+b won over the Slate one.
  expectEqual(try home.keys(home.config), ["version", "keyboard", "bindings", "hotstrings", "layouts", "defaults"])
  expectEqual(try home.json(home.config)["version"] as? Int, 2)
  let config = store.configuration
  expectEqual(config.bindings.map(\.keys.string), ["hyper+b", "hyper+a", "hyper+f"])
  expectEqual(config.bindings[0].action, .undo)
  expectEqual(config.hotstrings.map(\.trigger), ["brb"])
  expectEqual(config.keyboard.capsLock, .hyper)
  // settings.json: how Slated behaves, with `settings` as `windows`; config.json's value won.
  expectEqual(
    try home.keys(home.settings), ["version", "general", "windows", "clipboard", "automation", "island"])
  expect(config.general.showActionHUD && !config.island.enabled)
  expectEqual(config.clipboard.maxItems, 50)
  expectEqual(config.windows["nudgePercentOf"], .string("windowSize"))
  expectEqual(config.windows["undoMaxStackSize"], .number(5))
  let text = (home.read(home.config) ?? "") + (home.read(home.settings) ?? "")
  for gone in ["loadSlateConfigs", "slateConfigPaths", "importedSlateShortcuts", #""settings""#] {
    expect(!text.contains(gone), gone)
  }

  // Idempotent: the next launch reads both files and changes nothing.
  let (configBefore, settingsBefore) = (home.read(home.config), home.read(home.settings))
  let next = home.store()
  let again = next.load()
  expectEqual(again.kind, .loaded)
  expectEqual(again.written, [])
  expectEqual(next.configuration, store.configuration)
  expectEqual(home.read(home.config), configBefore)
  expectEqual(home.read(home.settings), settingsBefore)
  expectEqual(home.read(home.backup), legacyConfig)
}

@MainActor
private func existingSettingsWin() throws {
  let home = try Home()
  try home.write(legacyConfig, to: home.config)
  // A settings.json already there (the other platform migrated first, say): it wins, comments and all.
  let settings = "{\n  // mine\n  \"version\": 2, \"island\": { \"enabled\": true, \"cheatSheetDelay\": 1 },\n}\n"
  try home.write(settings, to: home.settings)
  let store = home.store()
  let result = store.load()
  expectEqual(result.kind, .migrated)
  expect(!result.settingsMoved)
  // No Slate config here, so nothing to import, and settings.json said the same before and after.
  expect(result.slateImport == nil)
  expectEqual(result.written, [.config])
  expectEqual(home.read(home.settings), settings)
  expect(store.configuration.island.enabled)
  expectEqual(store.configuration.island.cheatSheetDelay, 1)
  expect(!store.configuration.general.showActionHUD, "config.json's general section was dropped")
  expectEqual(store.configuration.clipboard.maxItems, ClipboardSettings().maxItems)
  expectEqual(try home.keys(home.config), ["version", "keyboard", "bindings", "hotstrings", "layouts", "defaults"])
}

@MainActor
private func backupIsNeverOverwritten() throws {
  let home = try Home()
  try home.write("an older backup", to: home.backup)
  try home.write(legacyConfig, to: home.config)
  let result = home.store().load()
  expectEqual(result.kind, .migrated)
  expect(!result.backedUp)
  expectEqual(home.read(home.backup), "an older backup")
}

@MainActor
private func brokenFilesAreNotMigrated() throws {
  // A version 1 config.json that doesn't parse: left alone, with no backup and no settings.json.
  let home = try Home()
  let broken = #"{ "version": 1, "general": { "showActionHUD": true, "#
  try home.write(broken, to: home.config)
  try home.write(slateJS, home: ".slate.js")
  let store = home.store()
  let result = store.load()
  expectEqual(result.kind, .failed)
  expectEqual(result.failedFile, .config)
  expect(store.loadError?.contains("config.json") == true, store.loadError ?? "")
  expectEqual(home.read(home.config), broken)
  expect(!home.exists(home.settings) && !home.exists(home.backup))
  expectThrows { try store.save(SlatedConfiguration()) }
  expectEqual(home.read(home.config), broken)

  // A broken settings.json beside a version 1 config.json: no migration either, and the message names it.
  let other = try Home()
  try other.write(legacyConfig, to: other.config)
  try other.write(#"{ "island": { "enabled": "yes" } }"#, to: other.settings)
  let second = other.store()
  let failed = second.load()
  expectEqual(failed.kind, .failed)
  expectEqual(failed.failedFile, .settings)
  expect(second.loadError?.contains("settings.json") == true, second.loadError ?? "")
  expect(second.loadError?.contains("island.enabled") == true, second.loadError ?? "")
  expectEqual(other.read(other.config), legacyConfig)
  expect(!other.exists(other.backup))
  do {
    try second.save(SlatedConfiguration())
    expect(false, "saved over a broken settings.json")
  } catch let error as ConfigUnreadable {
    expect(error.message.contains("won't save over it"), error.message)
  }
}

@MainActor
private func slateLoadingOffMeansNoImport() throws {
  let home = try Home()
  try home.write(#"{"general": {"loadSlateConfigs": false}, "bindings": []}"#, to: home.config)
  try home.write(slateJS, home: ".slate.js")
  let store = home.store()
  let result = store.load()
  expectEqual(result.kind, .migrated)
  expect(result.slateImport == nil)
  expectEqual(store.configuration.bindings, [])
  // No settings sections but general: they moved, so settings.json is written too.
  expect(home.exists(home.settings))

  // Shortcuts a version 1 config imported earlier aren't imported again, wherever they went since.
  let earlier = try Home()
  try earlier.write(
    #"{"general": {"importedSlateShortcuts": ["hyper+a"]}, "bindings": [{"keys": "hyper+z", "action": "push left"}]}"#,
    to: earlier.config)
  try earlier.write(slateJS, home: ".slate.js")
  let merged = earlier.store()
  let report = try require(merged.load().slateImport)
  expectEqual(merged.configuration.bindings.map(\.keys.string), ["hyper+z", "hyper+f", "hyper+b"])
  expectEqual(report.alreadyThere, 1)

  // No slateConfigPaths: the first of ~/.slate.js and ~/.slate that's there.
  let classic = try Home()
  try classic.write(#"{"version": 1}"#, to: classic.config)
  try classic.write("bind a:ctrl push left", home: ".slate")
  let fromClassic = classic.store()
  expectEqual(fromClassic.load().slateImport?.files, ["~/.slate"])
  expectEqual(fromClassic.configuration.bindings.map(\.keys.string), ["ctrl+a"])
}

@MainActor
private func firstRuns() throws {
  // With a Slate config: it's the configuration, converted; both files are written.
  let home = try Home()
  try home.write(slateJS, home: ".slate.js")
  let store = home.store()
  let result = store.load()
  expectEqual(result.kind, .created)
  expectEqual(result.written, [.settings, .config])
  expectEqual(result.slateImport?.added, 3)
  expectEqual(store.configuration.bindings.map(\.keys.string), ["hyper+a", "hyper+f", "hyper+b"])
  expectEqual(store.configuration.keyboard.capsLock, .off)
  expectEqual(store.configuration.windows["nudgePercentOf"], .string("screenSize"))
  expect(home.exists(home.config) && home.exists(home.settings) && !home.exists(home.backup))
  expectEqual(home.store().load().kind, .loaded)

  // Without one: the starter configuration.
  let bare = try Home()
  let starter = bare.store()
  let created = starter.load()
  expectEqual(created.kind, .created)
  expect(created.slateImport == nil)
  expectEqual(starter.configuration.bindings.count, SlatedConfiguration.starter.bindings.count)
  expectEqual(starter.configuration.keyboard.capsLock, .hyper)
  expect(bare.exists(bare.config) && bare.exists(bare.settings))

  // A settings.json there already (no config.json) is kept.
  let kept = try Home()
  try kept.write(#"{"island": {"enabled": false}}"#, to: kept.settings)
  let keeping = kept.store()
  expectEqual(keeping.load().written, [.config])
  expect(!keeping.configuration.island.enabled)
  expectEqual(kept.read(kept.settings), #"{"island": {"enabled": false}}"#)
}

@MainActor
private func savesWriteOnlyTheirOwnFile() throws {
  let home = try Home()
  // Both hand-written, with comments a rewrite would lose.
  let config = "{\n  // keys\n  \"version\": 2, \"bindings\": [{\"keys\": \"hyper+a\", \"action\": \"undo\"}]\n}\n"
  let settings = "{\n  // behavior\n  \"version\": 2, \"island\": {\"enabled\": true}\n}\n"
  try home.write(config, to: home.config)
  try home.write(settings, to: home.settings)
  let store = home.store()
  expectEqual(store.load().kind, .loaded)

  var edited = store.configuration
  edited.island.enabled = false
  expectEqual(try store.save(edited), [.settings])
  expectEqual(home.read(home.config), config)
  expectEqual(try home.json(home.settings)["island"].flatMap { $0 as? [String: Any] }?["enabled"] as? Bool, false)

  let settingsNow = home.read(home.settings)
  edited.bindings.append(HotkeyBinding(keys: try require(KeyCombo(string: "hyper+b")), action: .relaunch))
  expectEqual(try store.save(edited), [.config])
  expectEqual(home.read(home.settings), settingsNow)
  expectEqual(try store.save(edited), [])

  // A hand edit to settings.json the watcher hasn't seen yet is loaded, not overwritten.
  let hand = #"{"version": 2, "general": {"showActionHUD": true}}"#
  try home.write(hand, to: home.settings)
  edited.island.enabled = true
  do {
    try store.save(edited)
    expect(false, "saved over a hand edit")
  } catch let error as ConfigChangedOnDisk {
    expectEqual(error.file, .settings)
  }
  expectEqual(home.read(home.settings), hand)
  expect(store.configuration.general.showActionHUD)

  // Deleting settings.json by hand puts every setting back to its default.
  var reloaded: ConfigFile?
  store.onReload = { file, _ in reloaded = file }
  try FileManager.default.removeItem(at: home.settings)
  expect(store.checkForChanges(comparingContents: true))
  expectEqual(reloaded, .settings)
  expect(!store.configuration.general.showActionHUD)
  expectEqual(store.configuration.bindings.count, 2)
}

let configFileStoreTests = Suite(
  "ConfigFileStore",
  [
    ("migrates a version 1 config.json and its Slate config, once", { try onMain { try migratesAVersion1Config() } }),
    ("an existing settings.json wins over the old sections", { try onMain { try existingSettingsWin() } }),
    ("never overwrites config.v1.json", { try onMain { try backupIsNeverOverwritten() } }),
    ("a file that doesn't parse isn't migrated or saved over", { try onMain { try brokenFilesAreNotMigrated() } }),
    (
      "imports the Slate config only when it was loading, and not what was imported before",
      { try onMain { try slateLoadingOffMeansNoImport() } }
    ),
    ("a first run writes both files, from the Slate config or the starter", { try onMain { try firstRuns() } }),
    ("saving one section rewrites only its own file", { try onMain { try savesWriteOnlyTheirOwnFile() } }),
  ])
