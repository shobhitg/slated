import Foundation

@testable import SlatedCore
@testable import SlatedSystem

// secrets.json on disk (ConfigFileStore), in temporary folders: it follows config.json's rules (read
// beside it, reloaded after hand edits, a broken file named and never saved over, atomic writes,
// symlinks followed) and is readable only by the user from its first byte.

@MainActor
private final class Folder {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("SlatedSecrets-\(UUID().uuidString)")
  var config: URL { url.appendingPathComponent("config.json") }
  var secrets: URL { url.appendingPathComponent("secrets.json") }

  init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
  deinit { try? FileManager.default.removeItem(at: url) }

  func store() -> ConfigFileStore { ConfigFileStore(configURL: config, home: url.path) }
  func write(_ text: String, to file: URL) throws { try Data(text.utf8).write(to: file) }
  func read(_ file: URL) -> String { (try? String(contentsOf: file, encoding: .utf8)) ?? "" }
  func mode(_ file: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
  }
  func names() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.sorted() ?? [] }
}

private func onMain(_ body: @MainActor () throws -> Void) throws { try MainActor.assumeIsolated(body) }

private let sensitiveConfig = #"""
  {"version": 2, "hotstrings": [{"id": "D0000000-0000-4000-8000-000000000001", "trigger": ";pw", "replacement": {"secret": "pw"}}]}
  """#

let secretsFileTests = Suite(
  "SecretsFile",
  [
    (
      "read beside config.json; missing means no secrets; a hand edit is picked up",
      {
        try onMain {
          let folder = try Folder()
          try folder.write(sensitiveConfig, to: folder.config)
          let store = folder.store()
          var reloads: [ConfigFile] = []
          store.onReload = { file, _ in reloads.append(file) }
          expectEqual(store.load().kind, .loaded)
          expect(store.configuration.isMissingSecret(store.configuration.hotstrings[0]))
          expect(!FileManager.default.fileExists(atPath: folder.secrets.path), "loading never creates it")
          try folder.write(#"{"version": 1, "secrets": {"pw": "hunter2"}}"#, to: folder.secrets)
          expect(store.checkForChanges(comparingContents: true))
          expectEqual(reloads, [.secrets])
          expectEqual(store.configuration.text(of: store.configuration.hotstrings[0]), "hunter2")
          // Deleted by hand: the text is gone, the hotstring waits for it again.
          try FileManager.default.removeItem(at: folder.secrets)
          expect(store.checkForChanges(comparingContents: true))
          expectEqual(store.configuration.secrets, [:])
          expectEqual(store.loadError, nil)
        }
      }
    ),
    (
      "a new secret goes to secrets.json first, mode 0600, and config.json gets only the reference",
      {
        try onMain {
          let folder = try Folder()
          try folder.write(
            #"{"version": 2, "hotstrings": [{"trigger": ";pw", "replacement": "hunter2"}]}"#, to: folder.config)
          let store = folder.store()
          store.load()
          var config = store.configuration
          config.makeSensitive(hotstringAt: 0)
          expectEqual(try store.save(config), [.secrets, .config])
          expectEqual(folder.mode(folder.secrets) & 0o777, 0o600)
          expect(folder.read(folder.secrets).contains("hunter2"))
          expect(!folder.read(folder.config).contains("hunter2"), folder.read(folder.config))
          expect(folder.read(folder.config).contains(#""secret" : "pw""#))
          expect(folder.names().allSatisfy { !$0.hasPrefix(".") }, "no temporary file left: \(folder.names())")
          // Editing the text rewrites only secrets.json, still private.
          config.setSecretText("changed", forHotstringAt: 0)
          expectEqual(try store.save(config), [.secrets])
          expectEqual(folder.mode(folder.secrets) & 0o777, 0o600)
          // Off: config.json takes the text back before secrets.json lets it go.
          config.makeNotSensitive(hotstringAt: 0)
          expectEqual(try store.save(config), [.config, .secrets])
          expect(folder.read(folder.config).contains("changed"))
          expect(!folder.read(folder.secrets).contains("changed"))
          expectEqual(folder.mode(folder.secrets) & 0o777, 0o600)
        }
      }
    ),
    (
      "a secrets.json others can read is made private when it's read",
      {
        try onMain {
          let folder = try Folder()
          try folder.write(sensitiveConfig, to: folder.config)
          try folder.write(#"{"secrets": {"pw": "hunter2"}}"#, to: folder.secrets)
          try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.secrets.path)
          let result = folder.store().load()
          expect(result.secretsPermissionsFixed)
          expectEqual(folder.mode(folder.secrets) & 0o777, 0o600)
          expect(!folder.store().load().secretsPermissionsFixed, "already private")
        }
      }
    ),
    (
      "a broken secrets.json is named, quotes nothing from the file, and is never saved over",
      {
        try onMain {
          let folder = try Folder()
          try folder.write(sensitiveConfig, to: folder.config)
          let broken = #"{"secrets": {"pw": hunter2}}"#
          try folder.write(broken, to: folder.secrets)
          let store = folder.store()
          let result = store.load()
          expectEqual(result.kind, .failed)
          expectEqual(result.failedFile, .secrets)
          let message = try require(store.loadError)
          expect(message.contains("secrets.json"), message)
          expect(!message.contains("'h'") && !message.contains("hunter"), message)
          expectThrows { try store.save(store.configuration) }
          expectEqual(folder.read(folder.secrets), broken)
          // A text that isn't text: the path names the secret, never its value.
          try folder.write(#"{"secrets": {"pw": 12345}}"#, to: folder.secrets)
          store.load()
          let typed = try require(store.loadError)
          expect(typed.contains("secrets.pw") && !typed.contains("12345"), typed)
        }
      }
    ),
    (
      "through a dotfiles link, the file it links to is written, still private, and the link stays",
      {
        try onMain {
          let folder = try Folder()
          let dotfiles = folder.url.appendingPathComponent("dotfiles", isDirectory: true)
          try FileManager.default.createDirectory(at: dotfiles, withIntermediateDirectories: true)
          let target = dotfiles.appendingPathComponent("secrets.json")
          try folder.write(#"{"secrets": {"pw": "old"}}"#, to: target)
          try FileManager.default.createSymbolicLink(at: folder.secrets, withDestinationURL: target)
          try folder.write(sensitiveConfig, to: folder.config)
          let store = folder.store()
          store.load()
          var config = store.configuration
          config.setSecretText("new", forHotstringAt: 0)
          expectEqual(try store.save(config), [.secrets])
          expectEqual(try FileManager.default.destinationOfSymbolicLink(atPath: folder.secrets.path), target.path)
          expect(folder.read(target).contains("new"))
          expectEqual(folder.mode(target) & 0o777, 0o600)
        }
      }
    ),
    (
      "private writes replace the file whole and leave nothing behind",
      {
        try onMain {
          let folder = try Folder()
          let file = folder.url.appendingPathComponent("x.json")
          try ConfigFileStore.writePrivately(Data("one".utf8), to: file)
          try ConfigFileStore.writePrivately(Data("two".utf8), to: file)
          expectEqual(folder.read(file), "two")
          expectEqual(folder.mode(file) & 0o777, 0o600)
          expectEqual(folder.names(), ["x.json"])
          expectThrows {
            try ConfigFileStore.writePrivately(Data("x".utf8), to: folder.url.appendingPathComponent("no/such/dir/x"))
          }
        }
      }
    ),
    (
      "error messages about secrets.json leave out what they quote",
      {
        expectEqual(
          ConfigFileStore.redactingQuotes("Unexpected character 'h' around line 1, column 21."),
          "Unexpected character around line 1, column 21.")
        expectEqual(ConfigFileStore.redactingQuotes(#"Invalid value "abc" here"#), "Invalid value here")
        expectEqual(ConfigFileStore.redactingQuotes("Nothing quoted (at secrets.pw)"), "Nothing quoted (at secrets.pw)")
      }
    ),
  ])
