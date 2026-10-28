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
  /// The time copies are recorded at (a smoke test moves it ahead).
  var now: () -> Date = Date.init

  private let watcher = PasteboardWatcher()
  private var ignoreNextCopy = false
  private var saveWork: DispatchWorkItem?
  /// The app that was frontmost when the switcher opened; a picked item is pasted there. Cleared
  /// shortly after the switcher closes, so Copy elsewhere (Settings) never jumps to a stale app.
  private var previousApp: NSRunningApplication?
  private var forgetPreviousApp: DispatchWorkItem?
  /// The last app in front that wasn't Slated: the target when the switcher opens from Slated's own
  /// window.
  private var lastExternalApp: NSRunningApplication?
  /// Slated was the app in front when the switcher opened (from its main window).
  private var openedFromSlated = false
  private var activationObserver: NSObjectProtocol?
  private let fileURL = URL(fileURLWithPath: SlatedPaths.home)
    .appendingPathComponent("Library/Application Support/Slated/clipboard.json")

  init() {
    watcher.onCopy = { [weak self] copy in self?.record(copy) }
    lastExternalApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0 }
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
        app.bundleIdentifier != Bundle.main.bundleIdentifier
      else { return }
      MainActor.assumeIsolated { self?.lastExternalApp = app }
    }
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

  func record(_ copy: PasteboardWatcher.Copy) {
    if ignoreNextCopy {
      ignoreNextCopy = false
      return
    }
    // A hotstring replacement Slated is pasting: never history, whatever the concealed-items setting.
    guard settings.enabled, !copy.isSlatedPaste, let text = copy.text else { return }
    if settings.ignoreConcealed && copy.isConcealed {
      Log.record("clipboard.skipped", level: .debug, ["reason": "concealed", "app": copy.sourceApp ?? "unknown"])
      return
    }
    if let app = copy.sourceApp, settings.excludedApps.contains(app) {
      Log.record("clipboard.skipped", level: .debug, ["reason": "excluded app", "app": app])
      return
    }
    let now = now()
    guard history.add(text, from: copy.sourceApp, at: now, limit: settings.maxItems) else { return }
    // Expired items go as copies come in too, not only when settings are applied (at launch or on a
    // change): a Slated left running for weeks keeps to retentionDays.
    history.prune(olderThanDays: settings.retentionDays, now: now)
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
    // Closed and reopened within half a second: that close mustn't forget this target.
    forgetPreviousApp?.cancel()
    let front = NSWorkspace.shared.frontmostApplication
    openedFromSlated = front?.bundleIdentifier == Bundle.main.bundleIdentifier
    previousApp = openedFromSlated ? lastExternalApp : front
    Log.record(
      "clipboard.switcher_opened", ["items": history.items.count, "target": previousApp?.bundleIdentifier ?? "none"])
    presentSwitcher?()
  }

  /// Puts the item on the clipboard and, if configured, pastes it into the previous app.
  func paste(id: UUID) {
    guard let item = history.items.first(where: { $0.id == id }) else { return }
    put(item)
    let target = previousApp
    previousApp = nil
    target?.activate()
    guard settings.pasteAfterSelecting else { return }
    guard let target else {
      // ⌘V would land in whatever is in front, possibly a text field in Slated's own settings.
      Log.record(
        "clipboard.paste_skipped", level: .notice, ["reason": "no app to paste into", "chars": item.text.count])
      return
    }
    // Give the app a moment to become active before ⌘V.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      self?.pasteOnceInFront(target, chars: item.text.count, triesLeft: 20)
    }
  }

  /// Sends ⌘V once `target` is the frontmost app (activating is asynchronous), checking every 50 ms
  /// for a second. If it never comes to the front, the item stays on the clipboard, unpasted.
  private func pasteOnceInFront(_ target: NSRunningApplication, chars: Int, triesLeft: Int) {
    let app = target.bundleIdentifier ?? "unknown"
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
      InputSynth.tap(9, modifiers: .command)
      Log.record("clipboard.pasted", ["chars": chars, "app": app])
    } else if triesLeft > 0 && !target.isTerminated {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.pasteOnceInFront(target, chars: chars, triesLeft: triesLeft - 1)
      }
    } else {
      Log.record("clipboard.paste_skipped", level: .notice, ["reason": "the app didn't come to the front", "app": app])
    }
  }

  func copy(id: UUID) {
    guard let item = history.items.first(where: { $0.id == id }) else { return }
    put(item)
    // Back to the app you were in when copying from the switcher; from Settings, stay put.
    previousApp?.activate()
    previousApp = nil
    Log.record("clipboard.copied", ["chars": item.text.count])
  }

  /// The switcher closed; `intoSlatedWindow` when a click into Slated's own window closed it. A paste
  /// or copy it triggered runs right after, so forget the target a moment later rather than
  /// immediately.
  func switcherClosed(intoSlatedWindow: Bool) {
    forgetPreviousApp?.cancel()
    // Closed without a pick (Esc): give the keyboard back to the app you were in, as the hints and
    // grid overlays do; the switcher made Slated the active app. A pick has taken `previousApp` by
    // now. Opened from Slated's window, or closed by clicking into it or into another app: stay there.
    let returnToApp = !openedFromSlated && !intoSlatedWindow
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      guard returnToApp, let app = self?.previousApp, NSApp.isActive else { return }
      Log.record("clipboard.switcher_dismissed", ["returnedTo": app.bundleIdentifier ?? "unknown"])
      app.activate()
    }
    let work = DispatchWorkItem { [weak self] in self?.previousApp = nil }
    forgetPreviousApp = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
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
