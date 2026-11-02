import Foundation
import SwiftUI

@testable import SlatedCore
@testable import SlatedSystem
@testable import SlatedUI

// Every name of one of Slated's files in the window opens it: which name opens which file, how it opens
// (never for real here: the opener is injected), the keys' captions, and a scan of the panes' source
// for a file's name shown some other way.

private func onMain(_ body: @MainActor () throws -> Void) throws {
  try MainActor.assumeIsolated(body)
}

private func links(in text: String) -> [String] {
  FileLink.segments(in: text).compactMap { segment in
    if case .link(let name, let link) = segment { return "\(name)=\(link.rawValue)" }
    return nil
  }
}

let fileLinkTests = Suite(
  "FileLinks",
  [
    (
      "each name in text links to its file, and only on its own",
      {
        expectEqual(
          links(in: "Updated from config.json and settings.json"), ["config.json=config", "settings.json=settings"])
        expectEqual(
          links(in: "edit them here or in ~/.config/slated/config.json."), ["~/.config/slated/config.json=config"])
        expectEqual(
          links(in: "These settings are in ~/.config/slated/settings.json;"),
          ["~/.config/slated/settings.json=settings"])
        expectEqual(links(in: "Open ~/.config/slated/ in Finder"), ["~/.config/slated=folder"])
        expectEqual(links(in: "a copy at config.v1.json, beside it"), ["config.v1.json=backup"])
        expectEqual(
          links(in: "Slated looks for ~/.slate.js, then ~/.slate."), ["~/.slate.js=slate-js", "~/.slate=slate"])
        expectEqual(links(in: "No ~/.slate or ~/.slate.js here"), ["~/.slate=slate", "~/.slate.js=slate-js"])
        // Not names of Slated's files.
        expectEqual(links(in: "myconfig.json, config.jsonc, config.json.bak, ~/.slated, a.settings.json"), [])
        expectEqual(links(in: "~/.config/slated/other.json"), [])
        expectEqual(links(in: "No files named here."), [])
        // The runs put back together are the text.
        let text = "\"config.json\" (settings.json) — ~/.slate!"
        expectEqual(FileLink.segments(in: text).map(\.text).joined(), text)
        expectEqual(links(in: text), ["config.json=config", "settings.json=settings", "~/.slate=slate"])
      }
    ),
    (
      "a Slate file is a link only while there's a Slate config",
      {
        expect(FileLink.config.isLinked(slateFound: false) && FileLink.folder.isLinked(slateFound: false))
        expect(!FileLink.slateJS.isLinked(slateFound: false) && !FileLink.slate.isLinked(slateFound: false))
        expect(FileLink.slateJS.isLinked(slateFound: true))
        let none = FileLink.segments(in: "No ~/.slate or ~/.slate.js here; config.json") {
          $0.isLinked(slateFound: false)
        }
        expectEqual(none.filter { if case .link = $0 { true } else { false } }.map(\.text), ["config.json"])
      }
    ),
    (
      "links are slated-file URLs, read back; any other URL isn't one",
      {
        for link in FileLink.allCases {
          expectEqual(link.url.scheme, "slated-file")
          expectEqual(FileLink(url: link.url), link)
        }
        expectEqual(FileLink.config.url.absoluteString, "slated-file://config")
        expectEqual(FileLink.slateJS.url.absoluteString, "slated-file://slate-js")
        for other in ["https://config", "file:///Users/me/.config/slated/config.json", "slated-file://nothing"] {
          expect(FileLink(url: try require(URL(string: other))) == nil, other)
        }
        expectEqual(FileLink(.config), .config)
        expectEqual(FileLink(.settings), .settings)
      }
    ),
    (
      "which name opens which file",
      {
        let config = URL(fileURLWithPath: "/u/.config/slated/config.json")
        let settings = URL(fileURLWithPath: "/u/.config/slated/settings.json")
        let home = URL(fileURLWithPath: "/u")
        let paths = FileLink.allCases.map { $0.location(configFile: config, settingsFile: settings, home: home).path }
        expectEqual(
          paths,
          [
            "/u/.config/slated/config.json", "/u/.config/slated/settings.json", "/u/.config/slated/config.v1.json",
            "/u/.config/slated", "/u/.slate.js", "/u/.slate",
          ])
        expectEqual(
          FileLink.allCases.map(\.logName),
          ["config.json", "settings.json", "config.v1.json", "folder", ".slate.js", ".slate"])
        expectEqual(FileLink.allCases.compactMap(\.configFile), [.config, .settings])
      }
    ),
    (
      "a file opens in its app, TextEdit when it has none, the folder in the Finder; a missing one doesn't",
      {
        try onMain {
          var opened: [String] = []
          var present: Set<String> = ["/c/config.json", "/c/settings.json", "/c", "/h/.slate"]
          let opener = FileOpener(
            exists: { present.contains($0.path) },
            defaultApp: { $0.pathExtension == "json" ? URL(fileURLWithPath: "/Apps/Editor.app") : nil },
            open: { url, app in opened.append("\(url.path) with \(app?.lastPathComponent ?? "default")") })
          let at = { (path: String) in URL(fileURLWithPath: path) }
          expectEqual(opener.open(.config, at: at("/c/config.json")), .defaultApp)
          expectEqual(opener.open(.slate, at: at("/h/.slate")), .textEdit)
          expectEqual(opener.open(.folder, at: at("/c")), .finder)
          expectEqual(opener.open(.backup, at: at("/c/config.v1.json")), .missing)
          expectEqual(opened, ["/c/config.json with default", "/h/.slate with TextEdit.app", "/c with default"])
          present.remove("/c/settings.json")
          expectEqual(opener.open(.settings, at: at("/c/settings.json")), .missing)
          expectEqual(opened.count, 3)
        }
      }
    ),
    (
      "the window routes its links to the files; other URLs go to the system",
      {
        try onMain {
          let services = PreviewServices()
          let model = AppModel(services: services)
          model.saveDelay = .seconds(600)
          expect(model.openLink(FileLink.settings.url))
          expect(model.openLink(try require(URL(string: "slated-file://backup"))))
          expect(model.openLink(FileLink.folder.url))
          expect(!model.openLink(try require(URL(string: "https://example.com/config.json"))))
          expect(!model.openLink(try require(URL(string: "slated-file://elsewhere"))))
          expectEqual(services.openedFiles, [.settings, .backup, .folder])
          expect(model.toast == nil)
          // A pending edit is saved first, so the editor shows what the window shows.
          model.configuration.island.cheatSheetDelay = 0.75
          expect(model.hasUnsavedChanges)
          model.openConfigFile(.settings)
          expect(!model.hasUnsavedChanges, "saved before opening")
          // Not there: nothing opens, and a toast says so.
          services.missingFiles = [.slateJS]
          expect(model.openLink(FileLink.slateJS.url))
          expectEqual(services.openedFiles.last, .settings)
          expectEqual(model.toast?.message, "There's no ~/.slate.js in your home folder.")
        }
      }
    ),
    (
      "text with file names has a link on each, to its file",
      {
        let text = LinkedText.attributed(FileLink.segments(in: "Not saved: config.json and settings.json changed"))
        let linked = text.runs.compactMap { run in run.link.map { (String(text[run.range].characters), $0) } }
        expectEqual(linked.map(\.0), ["config.json", "settings.json"])
        expectEqual(linked.map(\.1), [FileLink.config.url, FileLink.settings.url])
        expectEqual(LinkedText.attributed(FileLink.segments(in: "Nothing to open")).runs.count, 1)
      }
    ),
    (
      "every key's caption starts with its file's name, which is a link to that file",
      {
        for setting in ConfigKeys.settings {
          let key = setting.key
          let parts = ConfigKeyCaption.parts(of: key.display, file: key.file)
          expect(parts.link == FileLink(key.file), key.display)
          expect(parts.rest.hasPrefix(" › "), "the rest of \(key.display) is the path: \(parts.rest)")
        }
        let config = SlatedConfiguration.starter
        let hotstring = ConfigKeys.hotstring(at: 0, in: config)
        expectEqual(ConfigKeyCaption.parts(of: hotstring.display, file: hotstring.file).link, .config)
        // A field's key, relative to its item, names no file.
        expectEqual(ConfigKeyCaption.parts(of: "trigger", file: nil).link, nil)
      }
    ),
  ])

// MARK: - Source scan

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent()

/// Where a string literal naming a file is fine: shown by something that links it (the shared
/// components show `subtitle`, `footer`, `message` and `detail` as `LinkedText`), or not shown as text
/// (a tooltip, an accessibility label, a button's title, a toast, the log).
private let linkingContexts = [
  "LinkedText(", "subtitle:", "footer:", "message:", "detail:", ".help(", ".accessibilityLabel(", "Button(",
  "showToast(", "Log.",
]

/// Lines of the views' source that show a file's name in a string literal outside those, with no
/// `// file link: <why>` comment on the line or the one above.
func unlinkedFileNames(in text: String) -> [Int] {
  let lines = text.components(separatedBy: "\n")
  let spellings = FileLink.spellings.map(\.0)
  let literal = try! NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
  var found: [Int] = []
  for (index, line) in lines.enumerated() {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("//") { continue }
    let code = line.components(separatedBy: " // ").first ?? line
    let range = NSRange(code.startIndex..., in: code)
    let names = literal.matches(in: code, range: range).contains { match in
      let string = String(code[Range(match.range, in: code)!])
      return spellings.contains { string.contains($0) }
    }
    guard names else { continue }
    if line.contains("// file link:") || (index > 0 && lines[index - 1].contains("// file link:")) { continue }
    // The statement the literal is in: back over continued lines (`+ "…"`, an argument on the next line).
    var start = index
    while start > 0, index - start < 6 {
      let current = lines[start].trimmingCharacters(in: .whitespaces)
      let previous = lines[start - 1].trimmingCharacters(in: .whitespaces)
      guard
        current.hasPrefix("+") || current.hasPrefix("\"") || [":", "(", ",", "+"].contains(where: previous.hasSuffix)
      else { break }
      start -= 1
    }
    let statement = lines[start...index].joined(separator: "\n")
    if !linkingContexts.contains(where: statement.contains) { found.append(index + 1) }
  }
  return found
}

let fileLinkCoverageTests = Suite(
  "FileLinkCoverage",
  [
    (
      "the panes show every file name as a link",
      {
        var missing: [String] = []
        for folder in ["Settings", "GetStarted", "Design", "Clipboard"] {
          let url = repoRoot.appendingPathComponent("Sources/SlatedUI/\(folder)")
          let files = try require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
          for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            missing += unlinkedFileNames(in: text).map { "\(file.lastPathComponent):\($0)" }
          }
        }
        // Each of these shows a file's name as plain text: use LinkedText (or a component that does), or
        // say why not in a `// file link: …` comment.
        expectEqual(missing.sorted(), [])
      }
    ),
    (
      "the scan finds a file's name in plain Text, and passes linked or explained ones",
      {
        expectEqual(unlinkedFileNames(in: #"Text("Saved in config.json")"#), [1])
        expectEqual(unlinkedFileNames(in: "Label(\n  \"from ~/.slate.js\", systemImage: \"x\")"), [2])
        expectEqual(unlinkedFileNames(in: #"LinkedText("Saved in config.json")"#), [])
        expectEqual(unlinkedFileNames(in: "SettingsCard(\n  footer:\n    \"Saved in \"\n    + \"settings.json\")"), [])
        expectEqual(unlinkedFileNames(in: "// file link: a log message\nlet name = \"config.json\""), [])
        expectEqual(unlinkedFileNames(in: #"Text("No files named here")"#), [])
      }
    ),
    (
      "every whole key's caption links its file",
      {
        // `ConfigKeyCaption(text:)` is for a field's relative key; a whole key (`.display`) goes in as `key:`.
        let url = repoRoot.appendingPathComponent("Sources/SlatedUI")
        let files = try require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil))
          .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var plain: [String] = []
        for file in files {
          let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
          for (index, line) in lines.enumerated()
          where line.contains("ConfigKeyCaption(text:") && line.contains(".display") {
            plain.append("\(file.lastPathComponent):\(index + 1)")
          }
        }
        expectEqual(plain, [])
      }
    ),
  ])
