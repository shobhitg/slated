import Foundation
import SlatedCore

/// "Import Slate Config into Slated…" found neither `~/.slate.js` nor `~/.slate`.
struct SlateConfigNotFound: LocalizedError {
  var errorDescription: String? {
    "There's no Slate config to import: Slated looked for ~/.slate.js and ~/.slate in your home folder."
  }
}

/// What a first run or the migration imported from the user's Slate config, kept until they dismiss
/// it in Overview, so the main window can say so once whenever it's next opened. Counts and key combos
/// only, never what a shortcut runs. Kept in Slated's support folder (so test runs, with `SLATED_HOME`,
/// keep their own).
enum SlateImportNotice {
  static var fileURL: URL { SlatedPaths.supportURL.appendingPathComponent("slate-import-notice.json") }

  static func load() -> SlateImportReport? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    return try? JSONDecoder().decode(SlateImportReport.self, from: data)
  }

  static func save(_ report: SlateImportReport) {
    do {
      try FileManager.default.createDirectory(at: SlatedPaths.supportURL, withIntermediateDirectories: true)
      try JSONEncoder().encode(report).write(to: fileURL, options: .atomic)
    } catch {
      Log.error("slate.notice_save_failed", error.localizedDescription)
    }
  }

  static func dismiss() {
    try? FileManager.default.removeItem(at: fileURL)
  }
}
