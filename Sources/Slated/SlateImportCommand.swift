import SlatedUI

extension AppModel {
  /// "Import Slate Config into Slated…" in the menu bar, with this Settings model open or not.
  func importSlateConfigs(_ engine: Engine) throws -> Engine.ImportSummary {
    // An edit still waiting for its debounce would be saved after the import, from a draft without
    // it, and undo it. Save it first, so the import builds on it.
    saveNow()
    let summary = try engine.importSlateConfigs()
    showSavedConfiguration()
    return summary
  }
}
