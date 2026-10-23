import Foundation

/// One remembered clipboard entry.
public struct ClipboardItem: Hashable, Sendable, Codable, Identifiable {
  public var id: UUID
  public var text: String
  public var copiedAt: Date
  /// Bundle identifier of the app it was copied from, when known.
  public var sourceApp: String?
  /// Pinned items stay at hand: they survive limits, retention and "Clear".
  public var pinned: Bool

  public init(id: UUID = UUID(), text: String, copiedAt: Date, sourceApp: String? = nil, pinned: Bool = false) {
    self.id = id
    self.text = text
    self.copiedAt = copiedAt
    self.sourceApp = sourceApp
    self.pinned = pinned
  }
}

/// The clipboard history itself: newest first, de-duplicated, bounded. Pure value type; the app adds
/// pasteboard watching and persistence.
public struct ClipboardHistory: Hashable, Sendable, Codable {
  public private(set) var items: [ClipboardItem]

  public init(items: [ClipboardItem] = []) { self.items = items }

  /// Records a copy. Returns false when there was nothing worth keeping (empty or whitespace only).
  /// Copying something already in the history moves it to the top (keeping its pin).
  @discardableResult
  public mutating func add(_ text: String, from app: String? = nil, at date: Date, limit: Int) -> Bool {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
    var pinned = false
    if let existing = items.firstIndex(where: { $0.text == text }) {
      pinned = items[existing].pinned
      items.remove(at: existing)
    }
    items.insert(ClipboardItem(text: text, copiedAt: date, sourceApp: app, pinned: pinned), at: 0)
    enforce(limit: limit)
    return true
  }

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
  /// items first. An empty query returns everything.
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
