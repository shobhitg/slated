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
  /// The name of the file the image came from, with its extension: a screenshot saved as a file.
  /// Nil for an image copied from an app.
  public var name: String?

  public init(file: String, width: Int, height: Int, bytes: Int, name: String? = nil) {
    self.file = file
    self.width = width
    self.height = height
    self.bytes = bytes
    self.name = name
  }
}

/// One remembered clipboard entry: text, an image (then `text` is empty), or files copied in the
/// Finder (then `text` is their names, one per line, so a search finds them by name).
public struct ClipboardItem: Hashable, Sendable, Codable, Identifiable {
  public var id: UUID
  /// The copied text; empty for an image; the files' names for files.
  public var text: String
  public var copiedAt: Date
  /// Bundle identifier of the app it was copied from, when known.
  public var sourceApp: String?
  /// Pinned items stay at hand: they survive limits, retention and "Clear".
  public var pinned: Bool
  /// Set for a copied image. Optional, so histories saved before images were kept still read (as text).
  public var image: ClipboardImage?
  /// Set for copied files: their absolute paths, in the order they were copied. Optional, so
  /// histories saved before files were kept still read.
  public var files: [String]?
  /// Why this text is a secret, when it is: kept in memory only (`ClipboardHistory` never encodes it),
  /// shown as dots until revealed, forgotten after `clipboard.secretMinutes` and when Slated quits.
  public var secret: ClipboardSecretReason?

  public init(
    id: UUID = UUID(), text: String, copiedAt: Date, sourceApp: String? = nil, pinned: Bool = false,
    image: ClipboardImage? = nil, files: [String]? = nil, secret: ClipboardSecretReason? = nil
  ) {
    self.id = id
    self.text = text
    self.copiedAt = copiedAt
    self.sourceApp = sourceApp
    self.pinned = pinned
    self.image = image
    self.files = files
    self.secret = secret
  }

  /// `secret` isn't one: a file never makes an item a secret (and never holds one, see
  /// `ClipboardHistory.encode`).
  private enum CodingKeys: String, CodingKey { case id, text, copiedAt, sourceApp, pinned, image, files }

  /// A secret: masked wherever it's shown, in memory only.
  public var isSecret: Bool { secret != nil }

  /// What a masked item shows instead of its text: always eight dots, whatever its length.
  public static let mask = "••••••••"

  public var isImage: Bool { image != nil }
  /// Files copied in the Finder (an image item is an image, whatever else it has).
  public var isFiles: Bool { files != nil && image == nil }
  /// Plain text: neither an image nor files.
  public var isText: Bool { image == nil && files == nil }

  /// The name a path shows in the history: its last component ("Report.pdf", or a folder's name),
  /// "/" for the root. Split on "/" only, as the GNOME port does.
  public static func fileName(ofPath path: String) -> String {
    let parts = path.unicodeScalars.split(separator: "/")
    guard let last = parts.last else { return path.isEmpty ? "" : "/" }
    return String(String.UnicodeScalarView(last))
  }

  /// A files item's text: the names, one per line.
  public static func text(forFiles paths: [String]) -> String {
    paths.map(fileName(ofPath:)).joined(separator: "\n")
  }
}

/// The clipboard history itself: newest first, de-duplicated, bounded. Pure value type; the app adds
/// pasteboard watching, persistence and the image files (`imageFiles` says which are still needed).
///
/// Secrets (`ClipboardItem.secret`) live here like any item, but encoding leaves them out: the
/// clipboard.json the app writes never has one.
public struct ClipboardHistory: Hashable, Sendable, Codable {
  public private(set) var items: [ClipboardItem]

  public init(items: [ClipboardItem] = []) { self.items = items }

  private enum CodingKeys: String, CodingKey { case items }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    items = try c.decode([ClipboardItem].self, forKey: .items)
  }

  /// Every item except secrets, which stay in memory.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(items.filter { !$0.isSecret }, forKey: .items)
  }

  /// Records a copy. Returns false when there was nothing worth keeping (empty or whitespace only).
  /// Copying something already in the history moves it to the top (keeping its pin). `secret` says
  /// why it's a secret; a copy of a secret already there stays one, for the more certain reason.
  @discardableResult
  public mutating func add(
    _ text: String, from app: String? = nil, at date: Date, limit: Int, secret: ClipboardSecretReason? = nil
  ) -> Bool {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    var pinned = false
    var reason = secret
    if let existing = items.firstIndex(where: { $0.isText && $0.text == text }) {
      pinned = items[existing].pinned
      reason = ClipboardSecretReason.stronger(secret, items[existing].secret)
      items.remove(at: existing)
    }
    items.insert(ClipboardItem(text: text, copiedAt: date, sourceApp: app, pinned: pinned, secret: reason), at: 0)
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

  /// Records files copied in the Finder: their absolute paths, in order (anything else is dropped).
  /// Returns false when no path is left. Copying the same files again (the same paths in the same
  /// order) moves that item to the top, keeping its pin, as text does.
  @discardableResult
  public mutating func add(files paths: [String], from app: String? = nil, at date: Date, limit: Int) -> Bool {
    let files = paths.filter { $0.hasPrefix("/") }
    guard !files.isEmpty else { return false }
    var pinned = false
    if let existing = items.firstIndex(where: { $0.isFiles && $0.files == files }) {
      pinned = items[existing].pinned
      items.remove(at: existing)
    }
    let item = ClipboardItem(
      text: ClipboardItem.text(forFiles: files), copiedAt: date, sourceApp: app, pinned: pinned, files: files)
    items.insert(item, at: 0)
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

  // MARK: Secrets

  /// "Hide Contents": makes a text item a secret, by hand. Returns whether it changed (images, files
  /// and items already secret don't).
  @discardableResult
  public mutating func hide(id: UUID) -> Bool {
    guard let i = items.firstIndex(where: { $0.id == id }), items[i].isText, items[i].secret == nil else {
      return false
    }
    items[i].secret = .manual
    return true
  }

  /// "Show Contents": a secret found by its look, or hidden by hand, becomes an ordinary item again
  /// (saved from then on). One its app marked secret, or copied from a password manager, stays a secret:
  /// returns false, as for an item that isn't one.
  @discardableResult
  public mutating func unhide(id: UUID) -> Bool {
    guard let i = items.firstIndex(where: { $0.id == id }), let reason = items[i].secret, !reason.isLocked else {
      return false
    }
    items[i].secret = nil
    return true
  }

  /// Forgets secrets copied more than `minutes` minutes before `now`, pinned or not. `minutes <= 0`
  /// keeps them until Slated quits. Returns how many went.
  @discardableResult
  public mutating func expireSecrets(olderThanMinutes minutes: Int, now: Date) -> Int {
    guard minutes > 0 else { return 0 }
    let cutoff = now.addingTimeInterval(-Double(minutes) * 60)
    let before = items.count
    items.removeAll { $0.isSecret && $0.copiedAt < cutoff }
    return before - items.count
  }

  /// When the next secret expires (`expireSecrets`), if one will.
  public func nextSecretExpiry(afterMinutes minutes: Int) -> Date? {
    guard minutes > 0 else { return nil }
    return items.filter(\.isSecret).map(\.copiedAt).min().map { $0.addingTimeInterval(Double(minutes) * 60) }
  }

  /// Forgets every secret (Slated is quitting). Returns how many went.
  @discardableResult
  public mutating func forgetSecrets() -> Int {
    let before = items.count
    items.removeAll(where: \.isSecret)
    return before - items.count
  }

  // MARK: Search

  /// Items matching every word of `query` (case- and diacritic-insensitive), newest first, pinned
  /// items first. An empty query returns everything. Only `text` is searched: files match by name,
  /// and a query never matches an image (not even a screenshot's name). A secret matches by the name
  /// of the app it came from (`appName`, given the app's id), never by its text: typing part of a
  /// password finds nothing.
  public func search(_ query: String, appName: (String) -> String = { $0 }) -> [ClipboardItem] {
    let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
    let matches =
      words.isEmpty
      ? items
      : items.filter { item in
        let text = item.isSecret ? item.sourceApp.map(appName) ?? "" : item.text
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
      }
    return matches.filter(\.pinned) + matches.filter { !$0.pinned }
  }
}
