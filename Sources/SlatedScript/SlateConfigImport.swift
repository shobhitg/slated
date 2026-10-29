import Foundation
import SlatedCore

/// Turns Slate config files into a `SlateImport`: `~/.slate.js` through `SlateImporter` (JavaScript on a
/// pretend Mac), `~/.slate` through `SlateConfigParser`. Used by "Import Slate Config into Slated…",
/// a first run and the migration of a version 1 config.json; Slated never loads Slate files itself.
@MainActor
public enum SlateConfigImport {
  /// Converts the files at `paths` (`~` is `home`), skipping ones that aren't there.
  public static func importFiles(
    _ paths: [String], home: String,
    readFile: @escaping (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
  ) -> SlateImport {
    var imports: [SlateImport] = []
    var seen = Set<String>()
    for path in paths {
      let full = expand(path, home: home)
      guard FileManager.default.fileExists(atPath: full) || readFile(full) != nil else { continue }
      // The same file listed twice (`~/.slate.js` and its full path) is read once.
      let resolved = URL(fileURLWithPath: full).resolvingSymlinksInPath().standardizedFileURL.path
      guard seen.insert(resolved).inserted else { continue }
      imports.append(importFile(full, displayPath: display(path, home: home), readFile: readFile))
    }
    return .combined(imports)
  }

  /// Converts one file. `displayPath` (`~/.slate.js`) names it in what the import reports.
  public static func importFile(
    _ path: String, displayPath: String,
    readFile: @escaping (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }
  ) -> SlateImport {
    var result = SlateImport(files: [displayPath])
    if path.hasSuffix(".js") {
      let converted = SlateImporter.importJavaScript(path: path, readFile: readFile)
      result.bindings = converted.bindings
      result.layouts = converted.layouts
      result.defaults = converted.defaults
      result.windows = converted.settings
      result.notConverted = converted.skipped.map { SlateImport.Item(shortcut($0.keystroke), $0.reason) }
      result.problems = converted.problems.map { "\(displayPath): \($0)" }
    } else if let text = readFile(path) {
      let file = SlateConfigParser.parse(text, path: path)
      result.bindings = file.bindings
      result.layouts = file.layouts
      result.defaults = file.defaults
      result.windows = file.settings
      // A line that doesn't parse is a shortcut (or layout, or setting) that didn't come over.
      result.notConverted = file.diagnostics.filter { $0.severity == .error }.map {
        SlateImport.Item($0.line.map { "line \($0)" } ?? displayPath, $0.message)
      }
    } else {
      result.problems = ["\(displayPath): Slated couldn't read the file"]
    }
    // Imported bindings are new: fresh ids, so importing twice can't make two bindings one item.
    result.bindings = result.bindings.map { binding in
      var binding = binding
      binding.id = UUID()
      return binding
    }
    return result
  }

  /// A Slate keystroke (`"a:ctrl,shift,alt,cmd"`) as Slated writes keys (`"hyper+a"`); anything else
  /// (`slate.layout("work")`) as it is.
  static func shortcut(_ keystroke: String) -> String {
    guard let parsed = try? SlateSyntax.parseKeystroke(keystroke) else { return keystroke }
    return HotkeyBinding.shortcutID(keys: parsed.keys, modal: parsed.modal)
  }

  static func expand(_ path: String, home: String) -> String { SlateImport.expand(path, home: home) }

  /// `path` with `home` written as `~`.
  static func display(_ path: String, home: String) -> String {
    let full = expand(path, home: home)
    return full.hasPrefix(home + "/") ? "~" + full.dropFirst(home.count) : full
  }
}
