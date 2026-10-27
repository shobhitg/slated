import Foundation

/// Where Slated looks for files. `SLATED_HOME` stands in for the home directory, so the smoke tests
/// can run the real app against temporary homes without touching the user's files.
nonisolated enum SlatedPaths {
  static var home: String { ProcessInfo.processInfo.environment["SLATED_HOME"] ?? NSHomeDirectory() }

  /// Expands a leading `~` to `home`.
  static func expand(_ path: String) -> String {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return home + path.dropFirst(1) }
    return path
  }

  static var configURL: URL {
    if let override = ProcessInfo.processInfo.environment["SLATED_CONFIG"] { return URL(fileURLWithPath: override) }
    return URL(fileURLWithPath: home).appendingPathComponent(".config/slated/config.json")
  }

  /// Slated's own files: snapshots, clipboard history, crash marker.
  static var supportURL: URL {
    URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/Slated")
  }

  /// Present while Slated's Caps Lock → F18 mapping is in place (`HIDRemapper`); `install.sh` reads it
  /// too, through `scripts/restore-caps-lock.py`.
  static var capsLockRecordURL: URL { supportURL.appendingPathComponent("caps-lock-mapping.json") }
}
