import Foundation
import SlatedCore
import SlatedUI

/// Loads Slate config files (`~/.slate`, `~/.slate.js`) alongside Slated's own configuration and
/// reloads them when they change on disk.
final class SlateSourceLoader {
  private(set) var sources: [SlateSource] = []
  private(set) var settings = SlateSettings()
  private(set) var layouts: [Layout] = []
  private(set) var defaults: [ScreenDefault] = []
  /// Called when a Slate file changes on disk.
  var onChange: (() -> Void)?

  private var bindings: [(source: String, binding: HotkeyBinding)] = []
  private weak var runner: ActionRunner?
  private var modificationDates: [String: Date] = [:]
  private var pollTimer: Timer?
  let javascript = JavaScriptSources()

  func load(paths: [String], runner: ActionRunner) {
    self.runner = runner
    sources = []
    settings = SlateSettings()
    layouts = []
    defaults = []
    bindings = []
    modificationDates = [:]
    javascript.reset()

    for raw in paths {
      let path = NSString(string: raw).expandingTildeInPath
      let exists = FileManager.default.fileExists(atPath: path)
      let kind: SlateSource.Kind = path.hasSuffix(".js") ? .javascript : .classic
      modificationDates[path] = Self.modificationDate(path)
      guard exists else {
        sources.append(SlateSource(path: raw, kind: kind, exists: false, loaded: false))
        continue
      }
      switch kind {
      case .classic: loadClassic(path: path, displayPath: raw)
      case .javascript: sources.append(javascript.load(path: path, displayPath: raw, runner: runner))
      }
    }
    settings = settings.merging(javascript.settings)
    layouts += javascript.layouts
    defaults += javascript.defaults
    startPolling()
  }

  /// Hotkey entries for every binding the sources define.
  func entries(settings: SlateSettings) -> [HotkeyManager.Entry] {
    let classic = bindings.map { item in
      let binding = item.binding
      let repeats = binding.repeats ?? settings.repeatOnHoldOps.contains(binding.action.name)
      return HotkeyManager.Entry(keys: binding.keys, modal: binding.modal, repeats: repeats) { [weak self] in
        self?.runner?.perform(binding.action, chainKey: "\(item.source)#\(binding.id)")
      }
    }
    return classic + javascript.entries(settings: settings)
  }

  private func loadClassic(path: String, displayPath: String) {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
      sources.append(
        SlateSource(
          path: displayPath, kind: .classic, exists: true, loaded: false,
          diagnostics: [Diagnostic(.error, "Couldn't read the file", file: path)]))
      return
    }
    let file = SlateConfigParser.parse(text, path: path)
    settings = settings.merging(file.settings)
    layouts += file.layouts
    defaults += file.defaults
    bindings += file.bindings.map { (path, $0) }
    let summaries = file.bindings.map {
      SourceBinding(keys: $0.keys, modal: $0.modal, summary: SlateSyntax.format($0.action), action: $0.action)
    }
    let loaded = !file.diagnostics.contains { $0.severity == .error } || !file.bindings.isEmpty
    sources.append(
      SlateSource(
        path: displayPath, kind: .classic, exists: true, loaded: loaded, bindings: summaries,
        diagnostics: file.diagnostics))
  }

  /// Editors save in many ways (in place, atomic rename); polling modification dates catches all.
  private func startPolling() {
    guard pollTimer == nil else { return }
    pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.checkForChanges() }
    }
  }

  private func checkForChanges() {
    let changed = modificationDates.contains { path, date in Self.modificationDate(path) != date }
    if changed { onChange?() }
  }

  private static func modificationDate(_ path: String) -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
  }
}
