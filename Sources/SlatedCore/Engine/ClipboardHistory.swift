import Foundation

/// A copied image. The app keeps its bytes in a file of their own; the history only names it.
public struct ClipboardImage: Hashable, Sendable, Codable {
  /// The file's name in the clipboard images folder: the SHA-256 of its bytes plus the type's
  /// extension (`.png`, `.tiff`), so the same image copied twice is one file and one item.
  public var file: String
  /// Size in pixels.
  public var width: Int
  public var height: Int
  /// Size of the file.
  public var bytes: Int

  public init(file: String, width: Int, height: Int, bytes: Int) {
    self.file = file
    self.width = width
    self.height = height
    self.bytes = bytes
  }
}

/// One remembered clipboard entry: text, or an image (then `text` is empty).
public struct ClipboardItem: Hashable, Sendable, Codable, Identifiable {
  public var id: UUID
  /// The copied text; empty for an image.
  public var text: String
  public var copiedAt: Date
  /// Bundle identifier of the app it was copied from, when known.
  public var sourceApp: String?
  /// Pinned items stay at hand: they survive limits, retention and "Clear".
  public var pinned: Bool
  /// Set for a copied image. Optional, so histories saved before images were kept still read (as text).
  public var image: ClipboardImage?

  public init(
    id: UUID = UUID(), text: String, copiedAt: Date, sourceApp: String? = nil, pinned: Bool = false,
    image: ClipboardImage? = nil
  ) {
    self.id = id
    self.text = text
    self.copiedAt = copiedAt
    self.sourceApp = sourceApp
    self.pinned = pinned
    self.image = image
  }

  public var isImage: Bool { image != nil }
}

/// The clipboard history itself: newest first, de-duplicated, bounded. Pure value type; the app adds
/// pasteboard watching, persistence and the image files (`imageFiles` says which are still needed).
public struct ClipboardHistory: Hashable, Sendable, Codable {
  public private(set) var items: [ClipboardItem]

  public init(items: [ClipboardItem] = []) { self.items = items }

  /// Records a copy. Returns false when there was nothing worth keeping (empty or whitespace only).
  /// Copying something already in the history moves it to the top (keeping its pin).
  @discardableResult
  public mutating func add(_ text: String, from app: String? = nil, at date: Date, limit: Int) -> Bool {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    var pinned = false
    if let existing = items.firstIndex(where: { !$0.isImage && $0.text == text }) {
      pinned = items[existing].pinned
      items.remove(at: existing)
    }
    items.insert(ClipboardItem(text: text, copiedAt: date, sourceApp: app, pinned: pinned), at: 0)
    enforce(limit: limit)
    return true
  }

  /// Records a copied image. Returns false for one without a file or pixels. Copying the same image
  /// again (the same file, so the same bytes) moves it to the top, keeping its pin, as text does.
  @discardableResult
  public mutating func add(image: ClipboardImage, from app: String? = nil, at date: Date, limit: Int) -> Bool {
    guard !image.file.isEmpty, image.width > 0, image.height > 0 else { return false }
    var pinned = false
    if let existing = items.firstIndex(where: { $0.image?.file == image.file }) {
      pinned = items[existing].pinned
      items.remove(at: existing)
    }
    items.insert(ClipboardItem(text: "", copiedAt: date, sourceApp: app, pinned: pinned, image: image), at: 0)
    enforce(limit: limit)
    return true
  }

  /// The image files the history refers to. Any other file in the images folder can go: its item was
  /// deleted, pruned, pushed out or cleared.
  public var imageFiles: Set<String> { Set(items.compactMap { $0.image?.file }) }

  /// Drops the oldest unpinned items beyond `limit`.
  public mutating func enforce(limit: Int) {
    let limit = max(limit, 1)
    var unpinnedSeen = 0
    items = items.filter { item in
      if item.pinned { return true }
      unpinnedSeen += 1
      return unpinnedSeen <= limit
    }
  }

  /// Forgets unpinned items copied more than `days` days before `now`. `days <= 0` keeps everything.
  public mutating func prune(olderThanDays days: Int, now: Date) {
    guard days > 0 else { return }
    let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
    items.removeAll { !$0.pinned && $0.copiedAt < cutoff }
  }

  public mutating func remove(id: UUID) { items.removeAll { $0.id == id } }

  public mutating func togglePin(id: UUID) {
    guard let i = items.firstIndex(where: { $0.id == id }) else { return }
    items[i].pinned.toggle()
  }

  /// Removes everything, except pinned items when `keepPinned`.
  public mutating func clear(keepPinned: Bool = true) {
    items = keepPinned ? items.filter(\.pinned) : []
  }

  /// Items matching every word of `query` (case- and diacritic-insensitive), newest first, pinned
  /// items first. An empty query returns everything. Only text is searched, so a query never
  /// matches an image.
  public func search(_ query: String) -> [ClipboardItem] {
    let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
    let matches = words.isEmpty
      ? items
      : items.filter { item in
        words.allSatisfy { item.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
      }
    return matches.filter(\.pinned) + matches.filter { !$0.pinned }
  }
}
