import AppKit
import SlatedCore
import SlatedSystem
import SlatedUI

/// Clipboard history: records copies of text, images and files (skipping concealed items and excluded
/// apps) and screenshots saved as files, stores them privately, and pastes a picked item back into
/// the app you were using.
///
/// The event log records that something was copied or pasted (length, an image's size and
/// dimensions, how many files), never the text, the image, or a file's name or path.
final class ClipboardService {
  private(set) var settings = ClipboardSettings()
  private(set) var history = ClipboardHistory()
  /// History or the screenshot folder's status changed (the UI and picker refresh).
  var onChange: (() -> Void)?
  /// Whether screenshots saved as files are being added, for Settings.
  private(set) var screenshotStatus = ScreenshotFolderStatus.off
  /// Shows the picker below this rectangle, where you're typing (top-left-origin global
  /// coordinates). Wired by the app delegate.
  var presentSwitcher: ((CGRect) -> Void)?
  /// The time copies are recorded at (a smoke test moves it ahead).
  var now: () -> Date = Date.init

  private let pasteboard: NSPasteboard
  private let watcher: PasteboardWatcher
  /// Started only while `clipboard.screenshots` (and history) are on: otherwise the folder isn't read.
  private var screenshots: ScreenshotWatcher?
  /// Copied images, one file each beside clipboard.json; the history names them.
  let images = ClipboardImageStore(
    directory: URL(fileURLWithPath: SlatedPaths.home)
      .appendingPathComponent("Library/Application Support/Slated/clipboard-images"))
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

  /// `pasteboard` is the general one; a smoke step uses a private one.
  init(pasteboard: NSPasteboard = .general) {
    self.pasteboard = pasteboard
    watcher = PasteboardWatcher(pasteboard: pasteboard)
    watcher.onCopy = { [weak self] copy in self?.record(copy) }
    lastExternalApp = NSWorkspace.shared.frontmostApplication.flatMap {
      $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0
    }
    activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { [weak self] note in
      guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
        app.bundleIdentifier != Bundle.main.bundleIdentifier
      else { return }
      MainActor.assumeIsolated { self?.lastExternalApp = app }
    }
    if let data = try? Data(contentsOf: fileURL),
      let saved = try? JSONDecoder().decode(ClipboardHistory.self, from: data)
    {
      history = saved
    }
    // Images whose items went while Slated wasn't saving (a crash, or history kept only in memory),
    // and items whose image is gone (deleted by hand): neither can be shown or pasted.
    let orphans = images.removeFiles(except: history.imageFiles)
    if orphans > 0 { Log.record("clipboard.images_removed", ["files": orphans, "reason": "not in the history"]) }
    let missing = history.items.filter { $0.image.map { imageURL($0) == nil } ?? false }
    for item in missing { history.remove(id: item.id) }
    if !missing.isEmpty {
      Log.record("clipboard.items_removed", ["items": missing.count, "reason": "image file missing"])
    }
  }

  func apply(_ settings: ClipboardSettings) {
    let changed = settings != self.settings
    self.settings = settings
    if settings.enabled { watcher.start() } else { watcher.stop() }
    if settings.enabled && settings.screenshots { screenshotWatcher().start() } else { screenshots?.stop() }
    changeHistory { history in
      history.enforce(limit: settings.maxItems)
      history.prune(olderThanDays: settings.retentionDays, now: Date())
    }
    if settings.persist { scheduleSave() } else { try? FileManager.default.removeItem(at: fileURL) }
    if changed {
      Log.record(
        "clipboard.settings",
        [
          "enabled": settings.enabled, "persist": settings.persist, "maxItems": settings.maxItems,
          "screenshots": settings.screenshots, "items": history.items.count,
        ])
    }
  }

  func stop() {
    watcher.stop()
    screenshots?.stop()
    saveNow()
    // History that isn't kept across restarts doesn't leave its images behind either.
    if !settings.persist { images.removeFiles(except: []) }
  }

  // MARK: Recording

  func record(_ copy: PasteboardWatcher.Copy) {
    if ignoreNextCopy {
      ignoreNextCopy = false
      return
    }
    // A hotstring replacement Slated is pasting: never history, whatever the concealed-items setting.
    guard settings.enabled, !copy.isSlatedPaste, copy.text != nil || copy.image != nil || copy.files != nil
    else { return }
    if settings.ignoreConcealed && copy.isConcealed {
      Log.record("clipboard.skipped", level: .debug, ["reason": "concealed", "app": copy.sourceApp ?? "unknown"])
      return
    }
    if let app = copy.sourceApp, settings.excludedApps.contains(app) {
      Log.record("clipboard.skipped", level: .debug, ["reason": "excluded app", "app": app])
      return
    }
    if let files = copy.files {
      let paths = files.map(\.path)
      guard add({ $0.add(files: paths, from: copy.sourceApp, at: $1, limit: settings.maxItems) }) else { return }
      Log.record(
        "clipboard.captured",
        ["kind": "files", "count": paths.count, "app": copy.sourceApp ?? "unknown", "items": history.items.count])
    } else if let text = copy.text {
      guard add({ $0.add(text, from: copy.sourceApp, at: $1, limit: settings.maxItems) }) else { return }
      Log.record(
        "clipboard.captured",
        [
          "chars": text.count, "lines": text.split(whereSeparator: \.isNewline).count,
          "app": copy.sourceApp ?? "unknown",
          "items": history.items.count,
        ])
    } else if let copied = copy.image {
      record(copied, from: copy.sourceApp)
    }
  }

  /// Stores a copied image and adds it. The log gets its size and dimensions only.
  private func record(_ copied: PasteboardWatcher.CopiedImage, from app: String?) {
    add(images.save(copied), from: app, source: "clipboard")
  }

  /// A screenshot saved as a file: its bytes are copied into the store, the file is left alone.
  func recordScreenshot(at url: URL) {
    guard settings.enabled, settings.screenshots else { return }
    add(images.saveScreenshot(at: url), from: nil, source: "screenshot")
  }

  /// Adds a stored image (or says why there's none). The log gets its size and dimensions only.
  private func add(_ saved: ClipboardImageStore.SaveResult, from app: String?, source: String) {
    switch saved {
    case .tooLarge(let bytes, let width, let height):
      Log.record(
        "clipboard.skipped", level: .notice,
        [
          "reason": "image too large", "source": source, "bytes": bytes, "width": width ?? 0, "height": height ?? 0,
          "maxBytes": images.maxBytes,
        ])
    case .failed(let bytes):
      Log.record(
        "clipboard.skipped", level: .notice,
        ["reason": "image unreadable or not saved", "source": source, "bytes": bytes])
    case .saved(let image):
      guard add({ $0.add(image: image, from: app, at: $1, limit: settings.maxItems) }) else {
        if !history.imageFiles.contains(image.file) { images.remove([image.file]) }
        return
      }
      Log.record(
        "clipboard.captured",
        [
          "kind": "image", "source": source, "bytes": image.bytes, "width": image.width, "height": image.height,
          "items": history.items.count,
        ])
    }
  }

  // MARK: Screenshots

  private func screenshotWatcher() -> ScreenshotWatcher {
    if let screenshots { return screenshots }
    let watcher = ScreenshotWatcher(folder: Self.screenshotFolder) { [weak self] event in
      switch event {
      case .screenshot(let url): self?.recordScreenshot(at: url)
      case .status(let status): self?.screenshotsChanged(status)
      }
    }
    screenshots = watcher
    return watcher
  }

  /// Where screenshots go. With a home of its own (tests), never the real screenshot folder.
  nonisolated private static func screenshotFolder() -> URL {
    if ProcessInfo.processInfo.environment["SLATED_HOME"] != nil {
      return URL(fileURLWithPath: SlatedPaths.home).appendingPathComponent("Desktop", isDirectory: true)
    }
    return Screenshots.currentFolder()
  }

  /// Records the folder's new status for Settings; the log gets the change, never the folder's path.
  private func screenshotsChanged(_ status: ScreenshotWatcher.Status) {
    let new: ScreenshotFolderStatus
    switch status {
    case .off: new = .off
    case .watching(let url): new = .watching(folder: Self.displayName(url))
    case .accessDenied(let url): new = .denied(folder: Self.displayName(url))
    case .folderMissing(let url): new = .missing(folder: Self.displayName(url))
    }
    guard new != screenshotStatus else { return }
    screenshotStatus = new
    switch new {
    case .off: Log.record("clipboard.screenshots", ["state": "off"])
    case .watching: Log.record("clipboard.screenshots", ["state": "watching"])
    case .denied:
      Log.record("clipboard.screenshots_unavailable", level: .notice, ["reason": "no access to the folder"])
    case .missing:
      Log.record("clipboard.screenshots_unavailable", level: .notice, ["reason": "folder missing"])
    }
    onChange?()
  }

  /// "Desktop", "Screenshots": what Settings calls the folder.
  private static func displayName(_ folder: URL) -> String {
    FileManager.default.displayName(atPath: folder.path)
  }

  /// Adds a copy with `add` (given the time), then forgets what expired. Returns what `add` did.
  private func add(_ add: (inout ClipboardHistory, Date) -> Bool) -> Bool {
    let now = now()
    var added = false
    changeHistory { history in
      added = add(&history, now)
      // Expired items go as copies come in too, not only when settings are applied (at launch or on a
      // change): a Slated left running for weeks keeps to retentionDays.
      if added { history.prune(olderThanDays: settings.retentionDays, now: now) }
    }
    if added { changed() }
    return added
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
    // Where you're typing: the caret, else the focused field, else the pointer. Opened from Slated's
    // own window, the pointer: the app you were in is behind it.
    let typing =
      openedFromSlated ? nil : front.flatMap { Accessibility.typingLocation(pid: $0.processIdentifier) }
    Log.record(
      "clipboard.switcher_opened",
      [
        "items": history.items.count, "target": previousApp?.bundleIdentifier ?? "none",
        "anchor": typing?.source.rawValue ?? "pointer",
      ])
    presentSwitcher?(typing?.rect ?? CGRect(origin: Screens.pointerLocation(), size: .zero))
  }

  /// Puts the item on the clipboard and, if configured, pastes it into the previous app.
  func paste(id: UUID) {
    guard let item = history.items.first(where: { $0.id == id }), put(item) else { return }
    let target = previousApp
    previousApp = nil
    target?.activate()
    guard settings.pasteAfterSelecting else { return }
    guard let target else {
      // ⌘V would land in whatever is in front, possibly a text field in Slated's own settings.
      Log.record(
        "clipboard.paste_skipped", level: .notice,
        Self.size(of: item).merging(["reason": "no app to paste into"]) { a, _ in a })
      return
    }
    // Give the app a moment to become active before ⌘V.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      self?.pasteOnceInFront(target, item: item, triesLeft: 20)
    }
  }

  /// Sends ⌘V once `target` is the frontmost app (activating is asynchronous), checking every 50 ms
  /// for a second. If it never comes to the front, the item stays on the clipboard, unpasted.
  private func pasteOnceInFront(_ target: NSRunningApplication, item: ClipboardItem, triesLeft: Int) {
    let app = target.bundleIdentifier ?? "unknown"
    if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
      InputSynth.tap(9, modifiers: .command)
      Log.record("clipboard.pasted", Self.size(of: item).merging(["app": app]) { a, _ in a })
    } else if triesLeft > 0 && !target.isTerminated {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        self?.pasteOnceInFront(target, item: item, triesLeft: triesLeft - 1)
      }
    } else {
      Log.record("clipboard.paste_skipped", level: .notice, ["reason": "the app didn't come to the front", "app": app])
    }
  }

  func copy(id: UUID) {
    guard let item = history.items.first(where: { $0.id == id }), put(item) else { return }
    // Back to the app you were in when copying from the switcher; from Settings, stay put.
    previousApp?.activate()
    previousApp = nil
    Log.record("clipboard.copied", Self.size(of: item))
  }

  /// What the log says about an item: its length, an image's size and dimensions, or how many files.
  /// Never content, names or paths.
  private static func size(of item: ClipboardItem) -> [String: Any] {
    if let image = item.image {
      return ["kind": "image", "bytes": image.bytes, "width": image.width, "height": image.height]
    }
    if let files = item.files, item.isFiles { return ["kind": "files", "count": files.count] }
    return ["chars": item.text.count]
  }

  /// A copied file is gone from where it was copied, for "Moved or deleted".
  func fileMissing(_ path: String) -> Bool { ClipboardFiles.isMissing(path) }

  /// A copied image's file, for thumbnails and previews; nil once it's gone.
  func imageURL(_ image: ClipboardImage) -> URL? {
    let url = images.url(for: image)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// The switcher closed; `intoSlatedWindow` when a click into Slated's own window closed it. A paste
  /// or copy it triggered runs right after, so forget the target a moment later rather than
  /// immediately.
  func switcherClosed(intoSlatedWindow: Bool) {
    forgetPreviousApp?.cancel()
    // Closed without a pick (Esc): the picker doesn't activate Slated, so the app you were in usually
    // still is active; if Slated became active meanwhile, give the keyboard back. A pick has taken
    // `previousApp` by now. Opened from Slated's window, or closed by clicking into it or into another
    // app: stay there.
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
    changeHistory { $0.remove(id: id) }
    Log.record("clipboard.deleted")
    changed()
  }

  func togglePin(id: UUID) {
    history.togglePin(id: id)
    Log.record("clipboard.pin_toggled", ["pinned": history.items.first { $0.id == id }?.pinned ?? false])
    changed()
  }

  func clear() {
    changeHistory { $0.clear(keepPinned: true) }
    Log.record("clipboard.cleared", ["kept": history.items.count])
    changed()
  }

  /// Writes the item to the pasteboard and moves it to the top of the history (without recording the
  /// write as a new copy). False when an image's file, or every one of the files, is gone: the
  /// clipboard is left as it was.
  private func put(_ item: ClipboardItem) -> Bool {
    if let files = item.files, item.isFiles {
      // The files still there; those moved or deleted are left out.
      let existing = ClipboardFiles.existing(files)
      guard !existing.isEmpty else {
        Log.record(
          "clipboard.paste_skipped", level: .notice, ["reason": "files missing", "kind": "files", "count": files.count])
        return false
      }
      if existing.count < files.count {
        Log.record(
          "clipboard.files_missing", level: .notice, ["missing": files.count - existing.count, "count": files.count])
      }
      ignoreNextCopy = true
      PasteboardWatcher.write(files: existing.map { URL(fileURLWithPath: $0) }, to: pasteboard)
      changeHistory { $0.add(files: files, from: item.sourceApp, at: Date(), limit: settings.maxItems) }
    } else if let image = item.image {
      guard let copied = images.load(image) else {
        Log.record(
          "clipboard.paste_skipped", level: .error, ["reason": "the image's file is missing", "bytes": image.bytes])
        return false
      }
      ignoreNextCopy = true
      PasteboardWatcher.write(copied, to: pasteboard)
      changeHistory { $0.add(image: image, from: item.sourceApp, at: Date(), limit: settings.maxItems) }
    } else {
      ignoreNextCopy = true
      PasteboardWatcher.write(item.text, to: pasteboard)
      changeHistory { $0.add(item.text, from: item.sourceApp, at: Date(), limit: settings.maxItems) }
    }
    changed()
    return true
  }

  /// Changes the history, then deletes the files of images it no longer has: deleted, pruned, pushed
  /// out by the limit or cleared.
  private func changeHistory(_ change: (inout ClipboardHistory) -> Void) {
    let before = history.imageFiles
    change(&history)
    let gone = before.subtracting(history.imageFiles)
    if !gone.isEmpty { images.remove(gone) }
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
