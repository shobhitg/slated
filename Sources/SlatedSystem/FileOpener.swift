import AppKit
import SlatedCore

/// Opens Slated's files from the settings window's links and buttons: a file in the app macOS opens it
/// with (the user's editor for .json), TextEdit when no app claims it, the folder in the Finder.
/// What it touches is injected, so tests never open anything.
@MainActor
public struct FileOpener {
  /// Whether something is at the URL.
  public var exists: (URL) -> Bool
  /// The app that opens the file by default; nil when none does.
  public var defaultApp: (URL) -> URL?
  /// Opens the URL, with the app when one is given.
  public var open: (URL, _ app: URL?) -> Void

  public init(
    exists: @escaping (URL) -> Bool, defaultApp: @escaping (URL) -> URL?, open: @escaping (URL, URL?) -> Void
  ) {
    self.exists = exists
    self.defaultApp = defaultApp
    self.open = open
  }

  /// TextEdit, where a file no app claims opens.
  public static let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")

  public static var live: FileOpener {
    FileOpener(
      exists: { FileManager.default.fileExists(atPath: $0.path) },
      defaultApp: { NSWorkspace.shared.urlForApplication(toOpen: $0) },
      open: { url, app in
        if let app {
          NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
          NSWorkspace.shared.open(url)
        }
      })
  }

  /// Opens `link`'s file at `url` and says how; `.missing` opens nothing.
  @discardableResult
  public func open(_ link: FileLink, at url: URL) -> FileOpenPlan {
    let there = exists(url)
    let plan = link.openPlan(exists: there, hasDefaultApp: there && !link.isFolder && defaultApp(url) != nil)
    switch plan {
    case .defaultApp, .finder: open(url, nil)
    case .textEdit: open(url, Self.textEdit)
    case .missing: break
    }
    return plan
  }
}
