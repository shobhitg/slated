import Foundation
import SlatedCore

/// Slated's own global shortcuts, which live in their settings sections rather than in
/// `config.bindings`. A binding on the same keys wins over them.
enum BuiltInShortcut: CaseIterable, Hashable {
  case clipboard
  case stopAutomations

  var title: String {
    switch self {
    case .clipboard: return "the clipboard history shortcut"
    case .stopAutomations: return "the stop-automations shortcut"
    }
  }

  /// What the shortcut stops doing when a binding takes its keys: "… won't open the clipboard history".
  var effect: String {
    switch self {
    case .clipboard: return "open the clipboard history"
    case .stopAutomations: return "stop automations"
    }
  }

  /// The action a binding would need to run to make sharing the keys harmless.
  var action: Action {
    switch self {
    case .clipboard: return .clipboardHistory
    case .stopAutomations: return .stopAutomations
    }
  }

  /// The keys, when the shortcut is on.
  func keys(in config: SlatedConfiguration) -> KeyCombo? {
    switch self {
    case .clipboard: return config.clipboard.enabled ? config.clipboard.shortcut : nil
    case .stopAutomations: return config.automation.stopShortcut
    }
  }
}

extension AppModel {
  // MARK: Clipboard history

  var pinnedClipboardCount: Int { clipboardItems.filter(\.pinned).count }

  func copyClipboardItem(_ id: UUID) {
    services.copyClipboardItem(id: id)
    refresh()
    showToast("Copied to the clipboard", symbol: "doc.on.doc.fill")
  }

  func pasteClipboardItem(_ id: UUID) {
    services.pasteClipboardItem(id: id)
    refresh()
  }

  func deleteClipboardItem(_ id: UUID) {
    services.deleteClipboardItem(id: id)
    refresh()
  }

  func togglePinClipboardItem(_ id: UUID) {
    services.togglePinClipboardItem(id: id)
    refresh()
  }

  /// Forgets everything except pinned items.
  func clearClipboardHistory() {
    let removed = clipboardItems.count - pinnedClipboardCount
    services.clearClipboardHistory()
    refresh()
    let kept = pinnedClipboardCount
    let message =
      removed == 0
      ? "Nothing to clear"
      : "Cleared \(removed) item\(removed == 1 ? "" : "s")" + (kept > 0 ? ", kept \(kept) pinned" : "")
    showToast(message, symbol: "trash")
  }

  func showClipboardHistory() { services.showClipboardHistory() }

  /// A copied image's file, for thumbnails.
  func clipboardImageURL(_ image: ClipboardImage) -> URL? { services.clipboardImageURL(image) }

  /// Puts ⇧⌘V back after the shortcut was cleared.
  func restoreDefaultClipboardShortcut() { configuration.clipboard.shortcut = ClipboardSettings().shortcut }

  // MARK: Excluded apps

  /// An app the clipboard can ignore, for the excluded-apps picker.
  struct AppChoice: Identifiable, Hashable {
    var id: String { bundleID }
    var bundleID: String
    var name: String
    var path: String?
    /// One of the password managers excluded by default.
    var isDefault: Bool
  }

  /// The display name of a bundle identifier, for chips.
  func appName(bundleID: String) -> String {
    AppIcons.displayName(bundleID: bundleID, running: runningApps)
  }

  /// Running apps and the default password managers that aren't excluded yet: defaults first.
  var excludableApps: [AppChoice] {
    let excluded = Set(configuration.clipboard.excludedApps)
    let defaults = ClipboardSettings.defaultExcludedApps.filter { !excluded.contains($0) }.map { id in
      AppChoice(
        bundleID: id, name: ClipboardContent.knownAppNames[id] ?? id,
        path: runningApps.first { $0.bundleID == id }?.path, isDefault: true)
    }
    let running = runningApps.compactMap { app -> AppChoice? in
      guard let id = app.bundleID, !excluded.contains(id), !ClipboardSettings.defaultExcludedApps.contains(id) else {
        return nil
      }
      return AppChoice(bundleID: id, name: app.name, path: app.path, isDefault: false)
    }
    return defaults + running
  }

  func excludeFromClipboard(_ bundleID: String) {
    guard !configuration.clipboard.excludedApps.contains(bundleID) else { return }
    configuration.clipboard.excludedApps.append(bundleID)
  }

  func includeInClipboard(_ bundleID: String) {
    configuration.clipboard.excludedApps.removeAll { $0 == bundleID }
  }

  /// The default password managers that were removed from the excluded list.
  var missingDefaultExclusions: [String] {
    ClipboardSettings.defaultExcludedApps.filter { !configuration.clipboard.excludedApps.contains($0) }
  }

  func restoreDefaultExclusions() {
    configuration.clipboard.excludedApps += missingDefaultExclusions
  }

  // MARK: Shortcuts shared with bindings

  /// Every binding (Slated's and loaded Slate files') that uses `keys`, plus Slated's built-in
  /// shortcuts except `builtIn`. For "Also used by …" hints next to the built-in recorders.
  func otherUses(ofBuiltIn builtIn: BuiltInShortcut) -> [String] {
    guard let keys = builtIn.keys(in: configuration) else { return [] }
    return otherUses(of: keys, modal: nil, excluding: nil, excludingBuiltIn: builtIn)
  }

  /// The registration state of a built-in shortcut, as the engine reports it.
  func status(ofBuiltIn builtIn: BuiltInShortcut) -> HotkeyStatus? {
    guard let keys = builtIn.keys(in: configuration) else { return nil }
    return runtimeStatus.hotkeys[BindingStatusKey.key(keys, modal: nil)]
  }

  /// Keys (`BindingStatusKey` form) already taken by enabled bindings, loaded Slate files and the
  /// built-in shortcuts.
  var usedShortcutKeys: Set<String> {
    var used = Set(
      configuration.bindings.filter { $0.enabled && !$0.keys.key.isEmpty }.map {
        BindingStatusKey.key($0.keys, modal: $0.modal)
      })
    if configuration.general.loadSlateConfigs {
      for source in sources where source.loaded { used.formUnion(source.bindings.map(\.id)) }
    }
    for builtIn in BuiltInShortcut.allCases {
      if let keys = builtIn.keys(in: configuration) { used.insert(BindingStatusKey.key(keys, modal: nil)) }
    }
    return used
  }
}
