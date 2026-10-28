import Foundation

/// Says what the bound functions of `~/.slate.js` files do (`SlateImporter.describeFunctions`), and
/// keeps each file's answer while the files its script read stay the same: the app reloads Slate
/// files on every settings change, and trying every function again each time would be wasted work.
@MainActor
public final class SlateFunctionDescriber {
  private let readFile: (String) -> String?
  /// Per config file: every file its script read (`nil` for one it couldn't), and what was found.
  private var cache: [String: (files: [String: String?], descriptions: FunctionDescriptions)] = [:]
  /// Whether the last `describe(path:)` reused an earlier answer.
  public private(set) var reusedLast = false

  public init(readFile: @escaping (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) {
    self.readFile = readFile
  }

  public func describe(path: String) -> FunctionDescriptions {
    if let cached = cache[path], cached.files.allSatisfy({ readFile($0.key) == $0.value }) {
      reusedLast = true
      return cached.descriptions
    }
    var files: [String: String?] = [:]
    let descriptions = SlateImporter.describeFunctions(path: path) { [readFile] file in
      let text = readFile(file)
      files.updateValue(text, forKey: file)
      return text
    }
    cache[path] = (files, descriptions)
    reusedLast = false
    return descriptions
  }
}
