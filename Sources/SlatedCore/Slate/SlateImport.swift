import Foundation

/// A Slate config (`~/.slate.js`, `~/.slate`) converted into Slated's own bindings, layouts, display
/// defaults and window settings, ready to merge into a configuration (`SlatedConfiguration.merge`).
/// SlatedScript's `SlateConfigImport` makes it. Slated never runs Slate files itself.
public struct SlateImport: Hashable, Sendable {
  /// Where Slate looks for its config, in order: the first that exists is the user's Slate config.
  public static let standardPaths = ["~/.slate.js", "~/.slate"]

  /// The user's Slate config: the first of `standardPaths` that exists under `home`, as written
  /// there (`~/.slate.js`); nil when there's none.
  public static func find(home: String) -> String? {
    standardPaths.first { FileManager.default.fileExists(atPath: expand($0, home: home)) }
  }

  /// `path` with a leading `~` as `home`.
  public static func expand(_ path: String, home: String) -> String {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return home + path.dropFirst(1) }
    return path
  }

  /// Something that couldn't be converted: a shortcut by its keys (`"hyper+t"`) or a `slate.*` call
  /// (`slate.layout("work")`), with why. Never JavaScript source.
  public struct Item: Hashable, Sendable, Codable {
    public var what: String
    public var reason: String

    public init(_ what: String, _ reason: String) {
      self.what = what
      self.reason = reason
    }

    public var description: String { "\(what): \(reason)" }
  }

  /// The files read, as `~/.slate.js`.
  public var files: [String]
  public var bindings: [HotkeyBinding]
  public var layouts: [Layout]
  public var defaults: [ScreenDefault]
  /// `config` values, as settings.json's `windows`.
  public var windows: SlateSettings
  public var notConverted: [Item]
  /// Why what was converted may not be what a file does on this Mac, e.g. "it runs slate.shell while
  /// loading". Prefixed with the file.
  public var problems: [String]

  public init(
    files: [String] = [], bindings: [HotkeyBinding] = [], layouts: [Layout] = [], defaults: [ScreenDefault] = [],
    windows: SlateSettings = .init(), notConverted: [Item] = [], problems: [String] = []
  ) {
    self.files = files
    self.bindings = bindings
    self.layouts = layouts
    self.defaults = defaults
    self.windows = windows
    self.notConverted = notConverted
    self.problems = problems
  }

  /// Several files' imports as one, in order: a later file's settings win, as when Slate loaded them.
  public static func combined(_ imports: [SlateImport]) -> SlateImport {
    var result = SlateImport()
    for item in imports {
      result.files += item.files
      result.bindings += item.bindings
      result.layouts += item.layouts
      result.defaults += item.defaults
      result.windows = result.windows.merging(item.windows)
      result.notConverted += item.notConverted
      result.problems += item.problems
    }
    return result
  }
}

/// What importing a Slate config did, in counts and keys only: for the import alert, the notice in
/// Overview and Get Started, and the log.
public struct SlateImportReport: Hashable, Sendable, Codable {
  /// The files imported, as `~/.slate.js`.
  public var files: [String]
  /// Shortcuts added to Slated's bindings.
  public var added: Int
  /// Shortcuts left out because Slated already has one on the same keys (or imported it before).
  public var alreadyThere: Int
  public var layoutsAdded: Int
  public var defaultsAdded: Int
  /// `config` values added to settings.json's `windows` (ones already set there are kept).
  public var settingsAdded: Int
  public var notConverted: [SlateImport.Item]
  public var problems: [String]

  public init(
    files: [String] = [], added: Int = 0, alreadyThere: Int = 0, layoutsAdded: Int = 0, defaultsAdded: Int = 0,
    settingsAdded: Int = 0, notConverted: [SlateImport.Item] = [], problems: [String] = []
  ) {
    self.files = files
    self.added = added
    self.alreadyThere = alreadyThere
    self.layoutsAdded = layoutsAdded
    self.defaultsAdded = defaultsAdded
    self.settingsAdded = settingsAdded
    self.notConverted = notConverted
    self.problems = problems
  }

  /// "~/.slate.js", or "~/.slate.js and ~/.slate".
  public var fileNames: String {
    switch files.count {
    case 0: return "your Slate config"
    case 1: return files[0]
    default: return files.dropLast().joined(separator: ", ") + " and " + files[files.count - 1]
    }
  }

  /// The shortcuts that couldn't be converted, by their keys.
  public var notConvertedShortcuts: [String] {
    notConverted.map(\.what).filter { !$0.hasPrefix("slate.") }
  }

  /// "Imported 12 shortcuts", for the import alert.
  public var title: String {
    if added == 0 && alreadyThere > 0 { return "Your Slate shortcuts are already in Slated" }
    return "Imported \(added) shortcut\(added == 1 ? "" : "s")"
  }

  /// The import alert's text: what happened, then what didn't convert, in plain words.
  public var message: String {
    var parts: [String] = []
    var done: [String] = []
    if added > 0 { done.append("\(added) shortcut\(added == 1 ? "" : "s")") }
    if layoutsAdded > 0 { done.append("\(layoutsAdded) layout\(layoutsAdded == 1 ? "" : "s")") }
    if defaultsAdded > 0 { done.append("\(defaultsAdded) display default\(defaultsAdded == 1 ? "" : "s")") }
    if settingsAdded > 0 { done.append("\(settingsAdded) setting\(settingsAdded == 1 ? "" : "s")") }
    if !done.isEmpty {
      parts.append(
        "Added \(Self.list(done)) from \(fileNames) to Slated's config, where you can change them. "
          + "Slated doesn't read \(fileNames) itself.")
    }
    if alreadyThere > 0 {
      parts.append(
        "\(alreadyThere) shortcut\(alreadyThere == 1 ? " was" : "s were") already in Slated on the same keys, "
          + "so Slated kept its own.")
    }
    if !notConverted.isEmpty {
      parts.append(
        "\(notConverted.count) couldn't be converted:\n" + notConverted.map(\.description).joined(separator: "\n"))
    }
    if !problems.isEmpty {
      parts.append(
        "What was imported may not match what your Slate config does on this Mac:\n" + problems.joined(separator: "\n"))
    }
    if parts.isEmpty { parts.append("\(fileNames) has nothing Slated could import.") }
    return parts.joined(separator: "\n\n")
  }

  private static func list(_ items: [String]) -> String {
    items.count <= 1 ? items.joined() : items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
  }
}

extension HotkeyBinding {
  /// What fires it: its keys, modal key and app filter. Two bindings with the same trigger are the
  /// same shortcut, so an import keeps the one Slated already has.
  public var trigger: String {
    Self.shortcutID(keys: keys, modal: modal)
      + (onlyInApps.isEmpty ? "" : " in " + onlyInApps.sorted().joined(separator: ","))
  }

  /// `"ctrl+alt+f16"`, or behind a modal key `"ctrl+alt+f6 x"`: how version 1 configs listed imported
  /// shortcuts (`LegacyConfig.importedSlateShortcuts`).
  public static func shortcutID(keys: KeyCombo, modal: ModalKey?) -> String {
    (modal.map { $0.keys.string + " " } ?? "") + keys.string
  }
}

extension SlatedConfiguration {
  /// Adds a Slate config's bindings, layouts, display defaults and window settings. What Slated already
  /// has wins: a binding whose trigger (keys, modal key, app filter) is already bound is left out, as
  /// is a layout of a name Slated has, a display default it has, or a setting it sets. So running it
  /// again adds nothing twice. `alreadyImported` lists shortcuts (`HotkeyBinding.shortcutID`) imported
  /// before, which are left out too, however they were changed since.
  public mutating func merge(_ slate: SlateImport, alreadyImported: Set<String> = []) -> SlateImportReport {
    var report = SlateImportReport(files: slate.files, notConverted: slate.notConverted, problems: slate.problems)
    var triggers = Set(bindings.map(\.trigger))
    for binding in slate.bindings {
      guard !alreadyImported.contains(HotkeyBinding.shortcutID(keys: binding.keys, modal: binding.modal)),
        triggers.insert(binding.trigger).inserted
      else {
        report.alreadyThere += 1
        continue
      }
      bindings.append(binding)
      report.added += 1
    }
    for layout in slate.layouts where !layouts.contains(where: { $0.name == layout.name }) {
      layouts.append(layout)
      report.layoutsAdded += 1
    }
    for entry in slate.defaults where !defaults.contains(entry) {
      defaults.append(entry)
      report.defaultsAdded += 1
    }
    let newSettings = slate.windows.values.keys.filter { windows[$0] == nil }
    report.settingsAdded = newSettings.count
    windows = slate.windows.merging(windows)
    return report
  }
}
