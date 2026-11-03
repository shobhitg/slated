import Foundation

@testable import SlatedCore

// Secrets in the model: clipboard items kept in memory only (never encoded) and forgotten on time;
// clipboard settings and the migration of `ignoreConcealed`; sensitive hotstrings' references and
// secrets.json; the Sensitive switch moving text in and out.

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func decodeSettings(_ json: String) throws -> ClipboardSettings {
  try JSONDecoder().decode(ClipboardSettings.self, from: Data(json.utf8))
}

private func hotstring(_ json: String) throws -> Hotstring {
  try JSONDecoder().decode(Hotstring.self, from: Data(json.utf8))
}

private func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

let clipboardSecretTests = Suite(
  "ClipboardSecrets",
  [
    (
      "secrets are never encoded: clipboard.json gets every other item",
      {
        var h = ClipboardHistory()
        h.add("ordinary", at: t0, limit: 10)
        h.add("hunter2", from: "com.1password.1password", at: t0, limit: 10, secret: .app)
        h.add("Zq9vLm4TxB2wKp7R", at: t0, limit: 10, secret: .pattern)
        expectEqual(h.items.count, 3)
        let json = text(try JSONEncoder().encode(h))
        expect(!json.contains("hunter2") && !json.contains("Zq9vLm4TxB2wKp7R"), json)
        expect(!json.contains("secret"), "an item's reason isn't written either")
        let back = try JSONDecoder().decode(ClipboardHistory.self, from: Data(json.utf8))
        expectEqual(back.items.map(\.text), ["ordinary"])
        // A file never makes an item a secret.
        let file =
          #"{"items": [{"id": "11111111-1111-4111-8111-111111111111", "text": "x", "copiedAt": 0, "pinned": false, "secret": "manual"}]}"#
        expectEqual(try JSONDecoder().decode(ClipboardHistory.self, from: Data(file.utf8)).items.first?.secret, nil)
      }
    ),
    (
      "a copy of a secret already there stays one, for the more certain reason",
      {
        var h = ClipboardHistory()
        h.add("hunter2", at: t0, limit: 10, secret: .manual)
        h.add("hunter2", from: "com.apple.TextEdit", at: t0.addingTimeInterval(1), limit: 10)
        expectEqual(h.items.map(\.secret), [.manual])
        h.add("hunter2", from: "com.1password.1password", at: t0.addingTimeInterval(2), limit: 10, secret: .app)
        expectEqual(h.items.map(\.secret), [.app])
        h.add("hunter2", at: t0.addingTimeInterval(3), limit: 10, secret: .pattern)
        expectEqual(h.items.map(\.secret), [.app])
        h.add("plain", at: t0, limit: 10)
        h.add("plain", at: t0, limit: 10, secret: .pattern)
        expectEqual(h.items.first?.secret, .pattern)
        expectEqual(ClipboardSecretReason.stronger(.marked, .app), .marked)
        expectEqual(ClipboardSecretReason.stronger(nil, .pattern), .pattern)
        expectEqual(ClipboardSecretReason.stronger(.pattern, .manual), .manual)
      }
    ),
    (
      "Hide Contents makes text a secret; Show Contents undoes only what the look or you decided",
      {
        var h = ClipboardHistory()
        h.add("marked", at: t0, limit: 10, secret: .marked)
        h.add("manager", at: t0, limit: 10, secret: .app)
        h.add("looks", at: t0, limit: 10, secret: .pattern)
        h.add("mine", at: t0, limit: 10)
        h.add(files: ["/tmp/a.txt"], at: t0, limit: 10)
        let id = { (text: String) in h.items.first { $0.text == text }!.id }
        expect(h.hide(id: id("mine")))
        expect(!h.hide(id: id("mine")), "already hidden")
        expect(!h.hide(id: id("a.txt")), "files aren't text")
        expectEqual(h.items.first { $0.text == "mine" }?.secret, .manual)
        expect(h.unhide(id: id("mine")))
        expect(h.unhide(id: id("looks")))
        expect(!h.unhide(id: id("marked")))
        expect(!h.unhide(id: id("manager")))
        expect(!h.unhide(id: id("mine")), "not a secret any more")
        expectEqual(h.items.filter(\.isSecret).map(\.text), ["manager", "marked"])
        expect(ClipboardSecretReason.marked.isLocked && ClipboardSecretReason.app.isLocked)
        expect(!ClipboardSecretReason.pattern.isLocked && !ClipboardSecretReason.manual.isLocked)
      }
    ),
    (
      "secrets expire after secretMinutes, pinned or not; others stay; 0 waits for quitting",
      {
        var h = ClipboardHistory()
        h.add("old secret", at: t0, limit: 10, secret: .app)
        h.togglePin(id: h.items[0].id)
        h.add("new secret", at: t0.addingTimeInterval(50 * 60), limit: 10, secret: .pattern)
        h.add("old ordinary", at: t0, limit: 10)
        expectEqual(h.nextSecretExpiry(afterMinutes: 60), t0.addingTimeInterval(3600))
        expectEqual(h.nextSecretExpiry(afterMinutes: 0), nil)
        expectEqual(h.expireSecrets(olderThanMinutes: 0, now: t0.addingTimeInterval(86_400)), 0)
        expectEqual(h.expireSecrets(olderThanMinutes: 60, now: t0.addingTimeInterval(59 * 60)), 0)
        expectEqual(h.expireSecrets(olderThanMinutes: 60, now: t0.addingTimeInterval(61 * 60)), 1)
        expectEqual(h.items.map(\.text), ["old ordinary", "new secret"])
        expectEqual(h.nextSecretExpiry(afterMinutes: 60), t0.addingTimeInterval(110 * 60))
        expectEqual(h.forgetSecrets(), 1)
        expectEqual(h.items.map(\.text), ["old ordinary"])
        expectEqual(h.nextSecretExpiry(afterMinutes: 60), nil)
      }
    ),
    (
      "search matches a secret by its app's name, never its text",
      {
        var h = ClipboardHistory()
        h.add("hunter2", from: "com.1password.1password", at: t0, limit: 10, secret: .app)
        h.add("hunter2 is my password", from: "com.apple.Notes", at: t0, limit: 10)
        h.add("Zq9vLm4TxB2wKp7R", at: t0, limit: 10, secret: .pattern)
        let names = ["com.1password.1password": "1Password", "com.apple.Notes": "Notes"]
        let search = { (query: String) in h.search(query) { names[$0] ?? $0 }.map(\.text) }
        expectEqual(search("hunter"), ["hunter2 is my password"])
        expectEqual(search("Zq9v"), [])
        expectEqual(search("1pass"), ["hunter2"])
        expectEqual(search("notes"), [])  // an ordinary item matches by text only
        expectEqual(h.search("1password").map(\.text), ["hunter2"])  // by id, without names
        expectEqual(search("").count, 3)
      }
    ),
  ])

let clipboardSecretSettingsTests = Suite(
  "ClipboardSecretSettings",
  [
    (
      "secrets are kept masked for an hour, patterns on, nothing excluded, by default",
      {
        let d = ClipboardSettings()
        expectEqual(d.secrets, .masked)
        expectEqual(d.secretMinutes, 60)
        expect(d.secretPatterns)
        expectEqual(d.excludedApps, [])
        let json = text(try JSONEncoder().encode(d))
        expect(json.contains(#""secrets":"masked""#) && json.contains(#""secretMinutes":60"#), json)
        expect(!json.contains("ignoreConcealed"), json)
      }
    ),
    (
      "read and written as set",
      {
        let s = try decodeSettings(#"{"secrets": "skip", "secretMinutes": 5, "secretPatterns": false}"#)
        expectEqual(s.secrets, .skip)
        expectEqual(s.secretMinutes, 5)
        expect(!s.secretPatterns)
        expectEqual(try JSONDecoder().decode(ClipboardSettings.self, from: JSONEncoder().encode(s)), s)
        expectThrows { _ = try decodeSettings(#"{"secrets": "hidden"}"#) }
        expectThrows { _ = try decodeSettings(#"{"secretMinutes": "1h"}"#) }
      }
    ),
    (
      "ignoreConcealed from before becomes masked, and the old default exclusions go",
      {
        let old = ClipboardSettings.legacyExcludedApps
        let list = old.map { "\"\($0)\"" }.joined(separator: ", ")
        for value in ["true", "false"] {
          let s = try decodeSettings(
            #"{"ignoreConcealed": \#(value), "excludedApps": [\#(list), "com.tinyspeck.slackmacgap"]}"#)
          expectEqual(s.secrets, .masked)
          expectEqual(s.excludedApps, ["com.tinyspeck.slackmacgap"])
        }
        // A file that has `secrets` is current: its list is kept as it is.
        let current = try decodeSettings(#"{"ignoreConcealed": true, "secrets": "skip", "excludedApps": [\#(list)]}"#)
        expectEqual(current.excludedApps, old)
        expectEqual(current.secrets, .skip)
        // Without the old key, the list is the user's.
        expectEqual(try decodeSettings(#"{"excludedApps": ["com.1password.1password"]}"#).excludedApps, [old[0]])
      }
    ),
  ])

let hotstringSecretTests = Suite(
  "HotstringSecrets",
  [
    (
      "a sensitive hotstring's replacement is a reference to secrets.json",
      {
        let h = try hotstring(#"{"trigger": ";pw", "replacement": {"secret": "pw"}}"#)
        expectEqual(h.secret, "pw")
        expectEqual(h.replacement, "")
        expect(h.isSensitive)
        let json = text(try JSONEncoder().encode(h))
        expect(json.contains(#""replacement":{"secret":"pw"}"#), json)
        expectEqual(try hotstring(json), h)
        let plain = try hotstring(#"{"trigger": ";a", "replacement": "text"}"#)
        expect(!plain.isSensitive && plain.replacement == "text")
        expectEqual(try hotstring(#"{"trigger": ";a", "replacement": null}"#).replacement, "")
        expectEqual(try hotstring(#"{"trigger": ";a"}"#).replacement, "")
        for bad in [#"{"secret": ""}"#, #"{"secret": 5}"#, "{}", "[1]", "5"] {
          expectThrows { _ = try hotstring(#"{"trigger": ";a", "replacement": \#(bad)}"#) }
        }
      }
    ),
    (
      "secrets.json: read, written 0600-ready as sorted JSON, missing means none",
      {
        let config = Data(
          #"{"version": 2, "hotstrings": [{"id": "11111111-1111-4111-8111-111111111111", "trigger": ";pw", "replacement": {"secret": "pw"}}]}"#
            .utf8)
        let secrets = Data(
          #"{"version": 1, "secrets": {"pw": "hunter2 ✓\n", "b": "x"}, "later": true} // comment"#.utf8)
        let files = try SlatedConfiguration.decodeFiles(config: config, settings: nil, secrets: secrets)
        expectEqual(files.configuration.secrets, ["pw": "hunter2 ✓\n", "b": "x"])
        expectEqual(files.configuration.text(of: files.configuration.hotstrings[0]), "hunter2 ✓\n")
        expectEqual(
          text(try files.configuration.encodedSecretsFile()),
          "{\n  \"secrets\" : {\n    \"b\" : \"x\",\n    \"pw\" : \"hunter2 ✓\\n\"\n  },\n  \"version\" : 1\n}")
        // The text is never in config.json.
        expect(!text(try files.configuration.encodedConfigFile()).contains("hunter2"))
        let none = try SlatedConfiguration.decodeFiles(config: config, settings: nil, secrets: nil).configuration
        expectEqual(none.secrets, [:])
        expect(none.isMissingSecret(none.hotstrings[0]))
        expectEqual(none.text(of: none.hotstrings[0]), nil)
        expectEqual(none.hotstringsMissingSecrets.map(\.trigger), [";pw"])
        for bad in [#"{"secrets": []}"#, #"{"secrets": {"pw": 5}}"#, #"{"secrets": {"#, "[]"] {
          do {
            _ = try SlatedConfiguration.decodeFiles(config: config, settings: nil, secrets: Data(bad.utf8))
            expect(false, "\(bad) read")
          } catch let error as ConfigFileError {
            expectEqual(error.file, .secrets)
          }
        }
      }
    ),
    (
      "names come from the trigger, unique among the names in use",
      {
        let cases: [(String, Set<String>, String)] = [
          (";pw", [], "pw"), (";pw", ["pw"], "pw-2"), (";pw", ["pw", "pw-2"], "pw-3"), ("//sig", [], "sig"),
          (";my.pass", [], "my-pass"), (";;", [], "secret"), ("", ["secret"], "secret-2"), (";café", [], "caf"),
          (";Work PW", [], "Work-PW"), (";pw_home", [], "pw_home"), ("--x--", [], "x"), (";🔑key", [], "key"),
          ("abc;;;def", [], "abc-def"), (String(repeating: "a", count: 50), [], String(repeating: "a", count: 40)),
          (String(repeating: "a", count: 39) + ".bcd", [], String(repeating: "a", count: 39)),
        ]
        for (trigger, taken, name) in cases {
          expectEqual(SlatedConfiguration.secretName(forTrigger: trigger, taken: taken), name)
        }
      }
    ),
    (
      "the Sensitive switch moves the text into secrets.json and back",
      {
        var config = SlatedConfiguration()
        config.hotstrings = [
          Hotstring(trigger: ";pw", replacement: "hunter2"), Hotstring(trigger: ";pw", replacement: "other"),
          Hotstring(trigger: ";x", replacement: "plain"),
        ]
        config.makeSensitive(hotstringAt: 0)
        config.makeSensitive(hotstringAt: 1)
        expectEqual(config.hotstrings.map(\.secret), ["pw", "pw-2", nil])
        expectEqual(config.hotstrings.map(\.replacement), ["", "", "plain"])
        expectEqual(config.secrets, ["pw": "hunter2", "pw-2": "other"])
        config.makeSensitive(hotstringAt: 0)
        expectEqual(config.secrets.count, 2)  // already sensitive
        config.setSecretText("new", forHotstringAt: 0)
        config.setSecretText("ignored", forHotstringAt: 2)
        expectEqual(config.secrets["pw"], "new")
        expectEqual(config.hotstrings[2].replacement, "plain")
        config.makeNotSensitive(hotstringAt: 0)
        expectEqual(config.hotstrings[0].replacement, "new")
        expectEqual(config.hotstrings[0].secret, nil)
        expectEqual(config.secrets, ["pw-2": "other"])
        // A missing text comes back empty.
        config.secrets = [:]
        config.makeNotSensitive(hotstringAt: 1)
        expectEqual(config.hotstrings[1].replacement, "")
        // config.json then has the text and no reference; secrets.json is empty.
        expect(text(try config.encodedConfigFile()).contains("\"new\""))
        expectEqual(text(try config.encodedSecretsFile()), "{\n  \"secrets\" : {\n\n  },\n  \"version\" : 1\n}")
      }
    ),
    (
      "a duplicate gets a secret of its own; deleting forgets a secret no one uses",
      {
        var config = SlatedConfiguration()
        config.hotstrings = [Hotstring(trigger: ";pw", replacement: "hunter2")]
        config.makeSensitive(hotstringAt: 0)
        var copy = config.hotstrings[0]
        copy.id = UUID()
        config.hotstrings.append(copy)
        config.giveOwnSecret(toHotstringAt: 1)
        expectEqual(config.hotstrings.map(\.secret), ["pw", "pw-2"])
        expectEqual(config.secrets, ["pw": "hunter2", "pw-2": "hunter2"])
        config.setSecretText("changed", forHotstringAt: 1)
        expectEqual(config.secrets["pw"], "hunter2")
        config.forgetSecret("pw")
        expectEqual(config.secrets["pw"], "hunter2")  // still used
        config.hotstrings.remove(at: 0)
        config.forgetSecret("pw")
        expectEqual(config.secrets, ["pw-2": "changed"])
        expectEqual(config.secretNamesInUse, ["pw-2"])
      }
    ),
    (
      "the starter and the Slate importer never make secrets",
      {
        let starter = SlatedConfiguration.starter
        expect(starter.secrets.isEmpty && starter.hotstrings.allSatisfy { !$0.isSensitive })
        expect(text(try starter.encodedSecretsFile()).contains("\"secrets\" : {\n\n  }"))
      }
    ),
  ])
