import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An application's icon, looked up from its bundle path or bundle identifier.
struct AppIconView: View {
  var path: String?
  var bundleID: String?
  var size: CGFloat = 20

  var body: some View {
    Image(nsImage: AppIcons.icon(path: path, bundleID: bundleID))
      .resizable()
      .interpolation(.high)
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

/// Icon and name lookups for apps that aren't in the running-apps list (e.g. a hotstring limited to
/// an app that isn't open right now). Read-only metadata; cached.
@MainActor
enum AppIcons {
  private static var cache: [String: NSImage] = [:]

  static func icon(path: String?, bundleID: String?) -> NSImage {
    let resolved = path ?? bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }
    let key = resolved ?? bundleID ?? "?"
    if let cached = cache[key] { return cached }
    let image: NSImage
    if let resolved, FileManager.default.fileExists(atPath: resolved) {
      image = NSWorkspace.shared.icon(forFile: resolved)
    } else {
      image = NSWorkspace.shared.icon(for: .applicationBundle)
    }
    cache[key] = image
    return image
  }

  private static var gameCache: [String: Bool] = [:]

  /// Whether an app declares itself a game (`LSApplicationCategoryType` is a games category), so
  /// "Only in…" pickers can offer it first. Read-only bundle metadata; cached.
  static func isGame(path: String?, bundleID: String?) -> Bool {
    if let bundleID, knownGames.contains(bundleID) { return true }
    let resolved = path ?? bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }
    guard let resolved else { return false }
    if let cached = gameCache[resolved] { return cached }
    let category = Bundle(path: resolved)?.infoDictionary?["LSApplicationCategoryType"] as? String
    let isGame = category.map(isGameCategory) ?? false
    gameCache[resolved] = isGame
    return isGame
  }

  /// Games that don't declare a category in their bundle.
  static let knownGames: Set<String> = ["com.mojang.minecraft", "com.mojang.minecraftlauncher"]

  /// `public.app-category.games` and its subcategories (`…action-games`, `…puzzle-games`).
  nonisolated static func isGameCategory(_ category: String) -> Bool {
    let lower = category.lowercased()
    return lower.hasPrefix("public.app-category.") && lower.hasSuffix("games")
  }

  /// Like `name(bundleID:running:)`, but never shows a raw bundle identifier: an app that isn't
  /// installed gets its identifier's last part ("com.apple.dt.Xcode" → "Xcode").
  static func displayName(bundleID: String, running: [AppInfo]) -> String {
    if let known = ClipboardContent.knownAppNames[bundleID] { return known }
    let name = self.name(bundleID: bundleID, running: running)
    guard name == bundleID, let last = bundleID.split(separator: ".").last, !last.isEmpty else { return name }
    return last.prefix(1).uppercased() + last.dropFirst()
  }

  /// The app's display name for a bundle identifier, from running apps or the installed bundle.
  static func name(bundleID: String, running: [AppInfo]) -> String {
    if let app = running.first(where: { $0.bundleID == bundleID }) { return app.name }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    return bundleID
  }
}
