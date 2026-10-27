import AppKit
import CryptoKit
import SlatedCore
import SlatedSystem

/// Slate's snapshots: remember where every window is and put them back later.
final class SnapshotStore {
  struct WindowState: Codable {
    var app: String
    /// A SHA-256 of the window's title. Windows are matched by title, and only ever for equality, so
    /// saved snapshots (snapshots.json) needn't hold titles: document names, page titles, mail subjects.
    var titleHash: String
    var frame: CGRect

    init(app: String, title: String, frame: CGRect) {
      self.app = app
      titleHash = Self.hash(title)
      self.frame = frame
    }

    static func hash(_ title: String) -> String {
      SHA256.hash(data: Data(title.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private enum CodingKeys: String, CodingKey { case app, titleHash, title, frame }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      app = try c.decode(String.self, forKey: .app)
      frame = try c.decode(CGRect.self, forKey: .frame)
      // Files saved before titles were hashed hold the title itself.
      titleHash =
        try c.decodeIfPresent(String.self, forKey: .titleHash) ?? Self.hash(c.decode(String.self, forKey: .title))
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: CodingKeys.self)
      try c.encode(app, forKey: .app)
      try c.encode(titleHash, forKey: .titleHash)
      try c.encode(frame, forKey: .frame)
    }
  }

  /// Snapshot name → stack of snapshots (the top is used; non-stack snapshots have one entry).
  private var stacks: [String: [[WindowState]]] = [:]
  private var persisted: Set<String> = []
  private let fileURL = SlatedPaths.supportURL.appendingPathComponent("snapshots.json")

  init() {
    if let data = try? Data(contentsOf: fileURL),
      let saved = try? JSONDecoder().decode([String: [[WindowState]]].self, from: data)
    {
      stacks = saved
      persisted = Set(saved.keys)
      // An older file holds titles: rewrite it with their hashes now, not at the next snapshot.
      if String(decoding: data, as: UTF8.self).contains("\"title\"") { persist() }
    }
  }

  func take(_ name: String, save: Bool, stack: Bool) {
    let states = Accessibility.allWindows().compactMap { window -> WindowState? in
      guard let frame = window.frame, let app = window.app?.localizedName else { return nil }
      return WindowState(app: app, title: window.title ?? "", frame: frame)
    }
    if stack { stacks[name, default: []].append(states) } else { stacks[name] = [states] }
    if save { persisted.insert(name) }
    persist()
  }

  /// Restores the snapshot. Windows are matched by app and title, then by order.
  func activate(_ name: String, delete: Bool) -> Bool {
    guard let states = stacks[name]?.last else { return false }
    let byApp = Dictionary(grouping: states, by: \.app)
    for app in NSWorkspace.shared.runningApplications {
      guard let name = app.localizedName, var wanted = byApp[name] else { continue }
      var unmatched: [AXWindow] = []
      for window in Accessibility.windows(of: app.processIdentifier) where window.isStandard {
        // A window without a title is matched by order only, as before.
        let hash = window.title.map(WindowState.hash)
        if let hash, let i = wanted.firstIndex(where: { $0.titleHash == hash }) {
          window.setFrame(wanted.remove(at: i).frame)
        } else {
          unmatched.append(window)
        }
      }
      for (window, state) in zip(unmatched, wanted) { window.setFrame(state.frame) }
    }
    if delete { self.delete(name, all: false) }
    return true
  }

  func delete(_ name: String, all: Bool) {
    if all || (stacks[name]?.count ?? 0) <= 1 {
      stacks[name] = nil
      persisted.remove(name)
    } else {
      stacks[name]?.removeLast()
    }
    persist()
  }

  private func persist() {
    let saved = stacks.filter { persisted.contains($0.key) }
    guard let data = try? JSONEncoder().encode(saved) else { return }
    try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: fileURL, options: .atomic)
  }
}
