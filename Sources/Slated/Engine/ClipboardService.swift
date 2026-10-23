import AppKit
import SlatedCore
import SlatedSystem

/// Clipboard history: records copies (skipping concealed items and excluded apps), stores them
/// privately, and pastes a picked item back into the app you were using.
///
/// The event log records that something was copied or pasted (length, app), never the text itself.
final class ClipboardService {
  private(set) var settings = ClipboardSettings()
  private(set) var history = ClipboardHistory()
  /// History changed (the UI and switcher refresh).
  var onChange: (() -> Void)?
  /// Shows the switcher panel (wired by the app delegate).
  var presentSwitcher: (() -> Void)?

  private let watcher = PasteboardWatcher()
  private var ignoreNextCopy = false
  private var saveWork: DispatchWorkItem?
  /// The app that was frontmost when the switcher opened; picked items are pasted there.
  private var previousApp: NSRunningApplication?
  private let fileURL = URL(fileURLWithPath: SlatedPaths.home)
    .appendingPathComponent("Library/Application Support/Slated/clipboard.json")

  init() {
    watcher.onCopy = { [weak self] copy in self?.record(copy) }
    if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(ClipboardHistory.self, from: data) {
      history = saved
    }
  }

  func apply(_ settings: ClipboardSettings) {
    let changed = settings != self.settings
    self.settings = settings
    if settings.enabled { watcher.start() } else { watcher.stop() }
    history.enforce(limit: settings.maxItems)
    history.prune(olderThanDays: settings.retentionDays, now: Date())
    if settings.persist { scheduleSave() } else { try? FileManager.default.removeItem(at: fileURL) }
    if changed {
      Log.record(
        "clipboard.settings",
        ["enabled": settings.enabled, "persist": settings.persist, "maxItems": settings.maxItems,
         "items": history.items.count])
    }
  }

  func stop() {
    watcher.stop()
    saveNow()
  }

  // MARK: Recording

  private func record(_ copy: PasteboardWatcher.Copy) {
    if ignoreNextCopy {
      ignoreNextCopy = false
      return
    }
    guard settings.enabled, let text = copy.text else { return }
    if settings.ignoreConcealed && copy.isConcealed {
      Log.record("clipboard.skipped", level: .debug, ["reason": "concealed", "app": copy.sourceApp ?? "unknown"])
      return
    }
    if let app = copy.sourceApp, settings.excludedApps.contains(app) {
      Log.record("clipboard.skipped", level: .debug, ["reason": "excluded app", "app": app])
      return
    }
    guard history.add(text, from: copy.sourceApp, at: Date(), limit: settings.maxItems) else { return }
    Log.record(
      "clipboard.captured",
      ["chars": text.count, "lines": text.split(whereSeparator: \.isNewline).count, "app": copy.sourceApp ?? "unknown",
       "items": history.items.count])
    changed()
  }

  // MARK: Switcher actions

  func showSwitcher() {
    guard settings.enabled else {
      Log.record("clipboard.switcher_unavailable", level: .notice, ["reason": "clipboard history is off"])
      return
    }
    previousApp = NSWorkspace.shared.frontmostApplication
    Log.record("clipboard.switcher_opened", ["items": history.items.count])
    presentSwitcher?()
  }

  /// Puts the item on the clipboard and, if configured, pastes it into the previous app.
  func paste(id: UUID) {
    guard let item = history.items.first(where: { $0.id == id }) else { return }
    put(item)
    guard settings.pasteAfterSelecting else { return }
    let target = previousApp
    target?.activate()
    // Give the app a moment to become active before ⌘V.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      InputSynth.tap(9, modifiers: .command)
    }
    Log.record("clipboard.pasted", ["chars": item.text.count, "app": target?.bundleIdentifier ?? "unknown"])
  }

  func copy(id: UUID) {
    guard let item = history.items.first(where: { $0.id == id }) else { return }
    put(item)
    previousApp?.activate()
    Log.record("clipboard.copied", ["chars": item.text.count])
  }

  func delete(id: UUID) {
    history.remove(id: id)
    Log.record("clipboard.deleted")
    changed()
  }

  func togglePin(id: UUID) {
    history.togglePin(id: id)
    Log.record("clipboard.pin_toggled", ["pinned": history.items.first { $0.id == id }?.pinned ?? false])
    changed()
  }

  func clear() {
    history.clear(keepPinned: true)
    Log.record("clipboard.cleared", ["kept": history.items.count])
    changed()
  }

  /// Writes the item to the pasteboard and moves it to the top of the history (without recording the
  /// write as a new copy).
  private func put(_ item: ClipboardItem) {
    ignoreNextCopy = true
    PasteboardWatcher.write(item.text)
    history.add(item.text, from: item.sourceApp, at: Date(), limit: settings.maxItems)
    changed()
  }

  // MARK: Persistence

  private func changed() {
    scheduleSave()
    onChange?()
  }

  private func scheduleSave() {
    guard settings.persist else { return }
    saveWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.saveNow() }
    saveWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
  }

  /// Saves readable only by the user (0600): clipboard history can contain private text.
  private func saveNow() {
    guard settings.persist, let data = try? JSONEncoder().encode(history) else { return }
    let fm = FileManager.default
    try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if fm.createFile(atPath: fileURL.path, contents: data, attributes: [.posixPermissions: 0o600]) {
      try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
  }
}
