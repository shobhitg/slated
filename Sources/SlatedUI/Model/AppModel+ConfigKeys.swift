import Foundation
import SlatedCore

/// The keys under each setting and their context menus: Copy Key, Copy Value as JSON, Open the file.
extension AppModel {
  /// Whether settings show their keys (`general.showConfigKeys`).
  var showsConfigKeys: Bool { configuration.general.showConfigKeys }

  func openConfigFile(_ file: ConfigFile) {
    // A pending edit goes to disk first, so the editor shows what the window shows.
    if hasUnsavedChanges { saveNow() }
    services.openConfigFile(file)
  }

  /// Copies the key's path in its file: `island.cheatSheetDelay`, `hotstrings[2].replacement`.
  func copyConfigKey(_ key: ConfigKey) {
    services.copyText(key.path)
    services.logConfigEvent(.keyCopied(key.file, value: false))
    showToast("Copied \(key.path)", symbol: "doc.on.doc.fill")
  }

  /// Copies the value as the file has it (the window's current version, which is what's saved).
  func copyConfigValue(_ key: ConfigKey) {
    guard let text = key.valueText(in: configuration) else {
      showToast(
        "\(key.path) isn't in \(key.file.rawValue): it's at its default.", symbol: "info.circle.fill", style: .info)
      return
    }
    services.copyText(text)
    services.logConfigEvent(.keyCopied(key.file, value: true))
    showToast("Copied the value of \(key.path)", symbol: "doc.on.doc.fill")
  }

  // MARK: Items' keys

  func configKey(forBinding id: UUID) -> ConfigKey? {
    configuration.bindings.firstIndex { $0.id == id }.map { ConfigKeys.binding(at: $0, in: configuration) }
  }

  func configKey(forHotstring id: UUID) -> ConfigKey? {
    configuration.hotstrings.firstIndex { $0.id == id }.map { ConfigKeys.hotstring(at: $0, in: configuration) }
  }

  func configKey(forLayoutAt index: Int) -> ConfigKey? {
    configuration.layouts.indices.contains(index) ? ConfigKeys.layout(at: index, in: configuration) : nil
  }
}
