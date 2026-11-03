import AppKit
import CoreGraphics
import SlatedCore

/// Types or pastes text into the focused app, and presses key combos, by posting synthetic events.
///
/// Work happens on a serial background queue so long replacements never block the UI. Every event
/// is marked so Slated's own keyboard tap ignores it.
public final class TextInjector: @unchecked Sendable {
  public static let shared = TextInjector()

  /// Text longer than this is pasted rather than typed when the method is `.auto`.
  public var autoPasteThreshold = 80

  private let queue = DispatchQueue(label: "Slated.TextInjector", qos: .userInteractive)
  private let source = CGEventSource(stateID: .privateState)

  /// Deletes `count` characters before the cursor, inserts `text`, then types `suffix` (a delimiter
  /// that completed a hotstring).
  public func replace(deleting count: Int, with text: String, method: InsertMethod, suffix: String? = nil) {
    queue.async { [self] in
      for _ in 0..<count { key(51) }
      insert(text, method: method)
      if let suffix { type(suffix) }
    }
  }

  public func insert(text: String, method: InsertMethod) {
    queue.async { [self] in insert(text, method: method) }
  }

  /// Presses a key combo, e.g. ⌘⇧4. `keyCode` comes from `KeyCodes` (main actor) for `combo.key`.
  public func press(keyCode: UInt16, modifiers: Modifiers) {
    queue.async { [self] in key(keyCode, flags: KeyboardTap.flags(for: modifiers)) }
  }

  private func insert(_ text: String, method: InsertMethod) {
    let paste = method == .paste || (method == .auto && text.count > autoPasteThreshold)
    if paste { self.paste(text) } else { type(text) }
  }

  private func type(_ text: String) {
    for character in text {
      switch character {
      case "\n", "\r\n": key(36)
      case "\t": key(48)
      default: unicode(String(character))
      }
      // Some apps drop characters that arrive faster than they handle them.
      usleep(1_200)
    }
  }

  private func paste(_ text: String) {
    let saved = DispatchQueue.main.sync { Self.stage(text, on: .general) }
    key(9, flags: .maskCommand)  // ⌘V
    // Give the target app time to read the clipboard before restoring it.
    usleep(250_000)
    DispatchQueue.main.async { Self.restore(saved, on: .general) }
  }

  /// Puts `text` on `pasteboard` for one paste, and returns what was there to put back. Marked
  /// transient so clipboard histories skip it (Slated's own always does), and kept on this Mac:
  /// Universal Clipboard doesn't offer it to the user's other devices.
  static func stage(_ text: String, on pasteboard: NSPasteboard) -> [NSPasteboardItem] {
    let saved = (pasteboard.pasteboardItems ?? []).map { item -> NSPasteboardItem in
      let copy = NSPasteboardItem()
      for type in item.types {
        if let data = item.data(forType: type) { copy.setData(data, forType: type) }
      }
      return copy
    }
    pasteboard.prepareForNewContents(with: .currentHostOnly)
    pasteboard.setString(text, forType: .string)
    pasteboard.setString("", forType: PasteboardWatcher.transientType)
    pasteboard.setString("", forType: PasteboardWatcher.slatedPasteType)
    return saved
  }

  /// Puts back what `stage` saved, as it was. That's not a new copy, so clipboard history doesn't
  /// record it again (as if copied in the app in front, which may be one it never records).
  static func restore(_ saved: [NSPasteboardItem], on pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    if !saved.isEmpty { pasteboard.writeObjects(saved) }
    PasteboardWatcher.ignoreCurrentContents(of: pasteboard)
  }

  private func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    for down in [true, false] {
      guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
      event.flags = flags
      post(event)
    }
  }

  private func unicode(_ string: String) {
    for utf16 in Self.unicodeChunks(string) {
      for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
        event.flags = []
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        post(event)
      }
    }
  }

  /// A key event carries at most 20 UTF-16 units of text (macOS ignores the rest), so a longer character
  /// (a family emoji, a flag with tags) is typed in pieces, split between scalars: any text types whole.
  static func unicodeChunks(_ string: String, limit: Int = 20) -> [[UInt16]] {
    var chunks: [[UInt16]] = []
    var current: [UInt16] = []
    for scalar in string.unicodeScalars {
      let units = Array(String(scalar).utf16)
      if current.count + units.count > limit, !current.isEmpty {
        chunks.append(current)
        current = []
      }
      current += units
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
  }

  private func post(_ event: CGEvent) {
    event.setIntegerValueField(.eventSourceUserData, value: KeyboardTap.syntheticEventMarker)
    event.post(tap: .cghidEventTap)
  }
}
