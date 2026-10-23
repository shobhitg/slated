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

  /// The app's display name for a bundle identifier, from running apps or the installed bundle.
  static func name(bundleID: String, running: [AppInfo]) -> String {
    if let app = running.first(where: { $0.bundleID == bundleID }) { return app.name }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
      return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    return bundleID
  }
}
