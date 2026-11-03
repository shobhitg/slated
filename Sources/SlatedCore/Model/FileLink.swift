import Foundation

/// A file of Slated's that the settings window names (config.json, settings.json, secrets.json, the
/// version 1 backup, the folder they're in, or a Slate config), which opens when its name is clicked.
///
/// Links in the window's text are `slated-file://config` and the like, routed to the app rather than
/// opened as URLs. The GNOME preferences have the same links (lib/prefs/filelinks.js).
public enum FileLink: String, CaseIterable, Hashable, Sendable {
  case config
  case settings
  /// secrets.json: sensitive hotstrings' text.
  case secrets
  /// config.v1.json: the copy of a version 1 config.json kept when Slated split it in two.
  case backup
  /// ~/.config/slated.
  case folder
  /// ~/.slate.js.
  case slateJS = "slate-js"
  /// ~/.slate.
  case slate

  /// The links' URL scheme. Never a real URL: the window opens these itself.
  public static let scheme = "slated-file"

  public init(_ file: ConfigFile) {
    switch file {
    case .config: self = .config
    case .settings: self = .settings
    case .secrets: self = .secrets
    }
  }

  /// The link a URL names; nil for any other URL (a web page, a file:// URL).
  public init?(url: URL) {
    guard url.scheme == Self.scheme, let host = url.host, let link = FileLink(rawValue: host) else { return nil }
    self = link
  }

  public var url: URL { URL(string: "\(Self.scheme)://\(rawValue)")! }

  /// How the window writes it.
  public var name: String {
    switch self {
    case .config: return ConfigFile.config.rawValue
    case .settings: return ConfigFile.settings.rawValue
    case .secrets: return ConfigFile.secrets.rawValue
    case .backup: return "config.v1.json"
    case .folder: return "~/.config/slated"
    case .slateJS: return "~/.slate.js"
    case .slate: return "~/.slate"
    }
  }

  /// What the event log calls it: the file's name, never a path.
  public var logName: String {
    switch self {
    case .folder: return "folder"
    case .slateJS: return ".slate.js"
    case .slate: return ".slate"
    default: return name
    }
  }

  /// config.json, settings.json or secrets.json, whose pending edits are saved before it opens.
  public var configFile: ConfigFile? {
    switch self {
    case .config: return .config
    case .settings: return .settings
    case .secrets: return .secrets
    default: return nil
    }
  }

  public var isFolder: Bool { self == .folder }

  /// Whether the window links it where it's named. A Slate file is a link while Slated finds a Slate
  /// config, so "No ~/.slate or ~/.slate.js here" names them without offering to open them; Slated's own
  /// files are always links (a missing one says so when clicked).
  public func isLinked(slateFound: Bool) -> Bool {
    (self != .slateJS && self != .slate) || slateFound
  }

  /// Where it is, given where config.json and settings.json are (the backup and the folder are beside
  /// them) and the home folder (the Slate files).
  public func location(configFile: URL, settingsFile: URL, home: URL) -> URL {
    let folder = configFile.deletingLastPathComponent()
    switch self {
    case .config: return configFile
    case .settings: return settingsFile
    case .secrets: return folder.appendingPathComponent(ConfigFile.secrets.rawValue)
    case .backup: return folder.appendingPathComponent("config.v1.json")
    case .folder: return folder
    case .slateJS: return home.appendingPathComponent(".slate.js")
    case .slate: return home.appendingPathComponent(".slate")
    }
  }

  /// What the window says when it isn't there, instead of opening nothing without a word.
  public var missingMessage: String {
    switch self {
    case .config, .settings:
      return "\(name) isn't there yet. Slated creates it the first time it saves a change."
    case .secrets:
      return "There's no secrets.json yet. Slated creates it when you make a hotstring Sensitive."
    case .backup:
      return "There's no config.v1.json. Slated keeps one only when it updates a version 1 config.json."
    case .folder:
      return "~/.config/slated isn't there yet. Slated creates it the first time it saves a change."
    case .slateJS, .slate:
      return "There's no \(name) in your home folder."
    }
  }

  /// How a link opens: in the file's default app, in TextEdit when no app opens it (a `.slate` file), in
  /// the Finder for the folder, or not at all when it isn't there.
  public func openPlan(exists: Bool, hasDefaultApp: Bool) -> FileOpenPlan {
    guard exists else { return .missing }
    if isFolder { return .finder }
    return hasDefaultApp ? .defaultApp : .textEdit
  }

  // MARK: Finding the names in text

  /// What the window's text calls each file, longest first, so `~/.config/slated/config.json` is one link
  /// and `~/.slate.js` isn't `~/.slate` followed by `.js`.
  static let spellings: [(String, FileLink)] = [
    ("~/.config/slated/config.v1.json", .backup),
    ("~/.config/slated/config.json", .config),
    ("~/.config/slated/settings.json", .settings),
    ("~/.config/slated/secrets.json", .secrets),
    ("~/.config/slated", .folder),
    ("config.v1.json", .backup),
    ("config.json", .config),
    ("settings.json", .settings),
    ("secrets.json", .secrets),
    ("~/.slate.js", .slateJS),
    ("~/.slate", .slate),
  ]

  /// `text` split into plain runs and the file names in it, in order; joined, the runs are `text`. A
  /// name counts only on its own: `myconfig.json`, `config.jsonc` and `~/.slated` aren't links.
  /// `linked` says which links to make (all by default).
  public static func segments(in text: String, linked: (FileLink) -> Bool = { _ in true }) -> [FileLinkSegment] {
    let chars = Array(text)
    var out: [FileLinkSegment] = []
    var plain = ""
    var i = 0
    func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "-" }
    func matches(_ pattern: [Character], at k: Int) -> Bool {
      k + pattern.count <= chars.count && Array(chars[k..<(k + pattern.count)]) == pattern
    }
    func standsAlone(from start: Int, to end: Int) -> Bool {
      if start > 0, isWordChar(chars[start - 1]) || chars[start - 1] == "." { return false }
      guard end < chars.count else { return true }
      if isWordChar(chars[end]) { return false }
      // "config.json." ends a sentence; "config.json.bak" and "~/.config/slated/x" go on.
      if chars[end] == "." || chars[end] == "/", end + 1 < chars.count, isWordChar(chars[end + 1]) { return false }
      return true
    }
    let patterns = spellings.map { (Array($0.0), $0.1) }
    while i < chars.count {
      if let (pattern, link) = patterns.first(where: {
        linked($0.1) && matches($0.0, at: i) && standsAlone(from: i, to: i + $0.0.count)
      }) {
        if !plain.isEmpty { out.append(.text(plain)) }
        plain = ""
        out.append(.link(String(pattern), link))
        i += pattern.count
      } else {
        plain.append(chars[i])
        i += 1
      }
    }
    if !plain.isEmpty { out.append(.text(plain)) }
    return out
  }
}

/// A run of text: plain, or a file's name that opens it.
public enum FileLinkSegment: Hashable, Sendable {
  case text(String)
  case link(String, FileLink)

  public var text: String {
    switch self {
    case .text(let text), .link(let text, _): return text
    }
  }
}

/// How a file link opens (see `FileLink.openPlan`).
public enum FileOpenPlan: String, Hashable, Sendable {
  case defaultApp = "default"
  case textEdit = "textedit"
  case finder
  case missing
}
