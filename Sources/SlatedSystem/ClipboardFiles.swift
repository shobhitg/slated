import Darwin
import Foundation

/// Copied files on disk: which are still where they were copied from.
public enum ClipboardFiles {
  /// Nothing is at `path` any more: moved or deleted. A path Slated may not look at (in a folder macOS
  /// protects) counts as there: the app it's pasted into reads it, not Slated.
  public static func isMissing(_ path: String) -> Bool {
    var info = stat()
    if lstat(path, &info) == 0 { return false }
    return errno == ENOENT || errno == ENOTDIR
  }

  /// The paths that are still there, in order.
  public static func existing(_ paths: [String]) -> [String] { paths.filter { !isMissing($0) } }
}
