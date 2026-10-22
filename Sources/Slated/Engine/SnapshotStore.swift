import AppKit
import SlatedCore
import SlatedSystem

/// Slate's snapshots: remember where every window is and put them back later.
final class SnapshotStore {
  struct WindowState: Codable {
    var app: String
    var title: String
    var frame: CGRect
  }

  /// Snapshot name → stack of snapshots (the top is used; non-stack snapshots have one entry).
  private var stacks: [String: [[WindowState]]] = [:]
  private var persisted: Set<String> = []
  private let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Slated/snapshots.json")

  init() {
    if let data = try? Data(contentsOf: fileURL),
      let saved = try? JSONDecoder().decode([String: [[WindowState]]].self, from: data)
    {
      stacks = saved
      persisted = Set(saved.keys)
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
        if let i = wanted.firstIndex(where: { $0.title == window.title }) {
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
