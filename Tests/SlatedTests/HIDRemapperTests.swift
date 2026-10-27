import Foundation

@testable import SlatedSystem

/// `hidutil property --get UserKeyMapping` with Slated's Caps Lock → F18 mapping and a common ISO
/// keyboard fix (§ → `), in the exact format hidutil prints: an old-style plist with bare numbers.
private let hidutilOutput = """
  (
          {
          HIDKeyboardModifierMappingDst = 30064771181;
          HIDKeyboardModifierMappingSrc = 30064771129;
      },
          {
          HIDKeyboardModifierMappingDst = 30064771125;
          HIDKeyboardModifierMappingSrc = 30064771172;
      }
  )

  """

private typealias Mapping = HIDRemapper.Mapping
private typealias Record = HIDRemapper.Record

private let capsToF18 = Mapping(src: 0x7_0000_0039, dst: 0x7_0000_006D)
private let capsToEscape = Mapping(src: 0x7_0000_0039, dst: 0x7_0000_0029)
private let capsToControl = Mapping(src: 0x7_0000_0039, dst: 0x7_0000_00E0)
private let sectionToGrave = Mapping(src: 0x7_0000_0064, dst: 0x7_0000_0035)

/// One case of Tests/Installer/caps-lock-cases.json, which scripts/restore-caps-lock.py (install.sh)
/// is checked against too.
private struct RestoreCase: Decodable {
  var name: String
  var current: [[UInt64]]
  var recordText: String?
  var expected: [[UInt64]]?
}

let hidRemapperTests = Suite(
  "HIDRemapper",
  [
    (
      "reads hidutil's output, whose numbers come back as strings",
      {
        // The format has no number type: this is why a plain `as? NSNumber` read nothing at all.
        let plist = try PropertyListSerialization.propertyList(from: Data(hidutilOutput.utf8), format: nil)
        let first = try require((plist as? [[String: Any]])?.first)
        expect(first["HIDKeyboardModifierMappingSrc"] is String)
        expectEqual(HIDRemapper.parseMappings(hidutilOutput), [capsToF18, sectionToGrave])
      }
    ),
    (
      "no mapping at all is \"(null)\"",
      {
        expectEqual(HIDRemapper.parseMappings("(null)\n"), [])
        expectEqual(HIDRemapper.parseMappings(""), [])
      }
    ),
    (
      "turning Caps Lock on and off keeps the other mappings",
      {
        let on = HIDRemapper.plan(current: [sectionToGrave], record: nil, enable: true)
        expectEqual(on.mappings, [sectionToGrave, capsToF18])
        expectEqual(on.record, Record(replaced: nil))
        let section = "{\"HIDKeyboardModifierMappingSrc\":30064771172,\"HIDKeyboardModifierMappingDst\":30064771125}"
        let caps = "{\"HIDKeyboardModifierMappingSrc\":30064771129,\"HIDKeyboardModifierMappingDst\":30064771181}"
        expectEqual(HIDRemapper.settingJSON(on.mappings), "{\"UserKeyMapping\":[\(section),\(caps)]}")
        let off = HIDRemapper.plan(current: on.mappings, record: on.record, enable: false)
        expectEqual(off.mappings, [sectionToGrave])
        expect(off.record == nil, "the record goes with the mapping")
        expectEqual(HIDRemapper.settingJSON([]), "{\"UserKeyMapping\":[]}")
      }
    ),
    (
      "the user's own Caps Lock mapping (Caps Lock → Escape) comes back when Slated's Hyper goes off",
      {
        let on = HIDRemapper.plan(current: [capsToEscape, sectionToGrave], record: nil, enable: true)
        expectEqual(on.mappings, [sectionToGrave, capsToF18])
        expectEqual(on.record, Record(replaced: capsToEscape))
        let off = HIDRemapper.plan(current: on.mappings, record: on.record, enable: false)
        expectEqual(off.mappings, [sectionToGrave, capsToEscape])
      }
    ),
    (
      "a Caps Lock → F18 mapping another tool made isn't Slated's: never adopted or removed",
      {
        // At launch, without Slated's record, the entry is someone else's (a Hammerspoon setup, say).
        expect(HIDRemapper.owner(of: [capsToF18], record: nil) == .otherTool)
        expect(HIDRemapper.owner(of: [sectionToGrave], record: nil) == .nobody)
        // With Slated's Hyper on meanwhile, the other tool's mapping is what comes back afterwards.
        let on = HIDRemapper.plan(current: [capsToF18], record: nil, enable: true)
        expectEqual(on.record, Record(replaced: capsToF18))
        expectEqual(HIDRemapper.plan(current: on.mappings, record: on.record, enable: false).mappings, [capsToF18])
      }
    ),
    (
      "Slated's mapping left by a crash is adopted, and still knows what to put back",
      {
        let record = Record(replaced: capsToEscape)
        expect(HIDRemapper.owner(of: [sectionToGrave, capsToF18], record: record) == .slated)
        expect(HIDRemapper.owner(of: [sectionToGrave], record: record) == .nobody)  // out of date
        // Turning it on again (Hyper still on, or after waking up) doesn't forget Caps Lock → Escape.
        let again = HIDRemapper.plan(current: [sectionToGrave, capsToF18], record: record, enable: true)
        expectEqual(again.mappings, [sectionToGrave, capsToF18])
        expectEqual(again.record, record)
        let off = HIDRemapper.plan(current: again.mappings, record: again.record, enable: false)
        expectEqual(off.mappings, [sectionToGrave, capsToEscape])
      }
    ),
    (
      "turning Slated's mapping off leaves a Caps Lock mapping someone made since",
      {
        let off = HIDRemapper.plan(
          current: [capsToControl, sectionToGrave], record: Record(replaced: capsToEscape), enable: false)
        expectEqual(off.mappings, [capsToControl, sectionToGrave])
        expect(off.record == nil)
      }
    ),
    (
      "the record on disk uses hidutil's own keys, and an unreadable one still counts as Slated's",
      {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SlatedTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("caps-lock-mapping.json")
        expect(HIDRemapper.readRecord(url) == nil)
        expect(HIDRemapper.writeRecord(Record(replaced: capsToEscape), to: url))
        let text = try String(contentsOf: url, encoding: .utf8)
        expect(text.contains("\"HIDKeyboardModifierMappingDst\":30064771113"), text)
        expectEqual(HIDRemapper.readRecord(url), Record(replaced: capsToEscape))
        try Data("not json".utf8).write(to: url)
        expectEqual(HIDRemapper.readRecord(url), Record(replaced: nil))
      }
    ),
    (
      "after a Slated that didn't quit cleanly: the same result as install.sh's restore-caps-lock.py",
      {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
          .appendingPathComponent("Installer/caps-lock-cases.json")
        struct Cases: Decodable { var cases: [RestoreCase] }
        let cases = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: file)).cases
        expect(cases.count >= 7, "cases: \(cases.count)")
        for test in cases {
          let current = test.current.map { Mapping(src: $0[0], dst: $0[1]) }
          let record = test.recordText.map { HIDRemapper.decodeRecord(Data($0.utf8)) }
          // What a launch of Slated does with it: adopt only its own, then take it off.
          let result: [Mapping]? =
            HIDRemapper.owner(of: current, record: record) == .slated
            ? HIDRemapper.plan(current: current, record: record, enable: false).mappings : nil
          let expected = test.expected.map { $0.map { Mapping(src: $0[0], dst: $0[1]) } }
          if result != expected { expect(false, "\(test.name): got \(String(describing: result))") }
        }
      }
    ),
    (
      "contract: hidutil reports the current mapping in a form we can read",
      {
        // Read-only. Prints "(null)" when nothing is mapped (CI); on a Mac running Slated with the Hyper
        // key on, the Caps Lock → F18 entry must come back.
        let output = try require(HIDRemapper.run(["property", "--get", "UserKeyMapping"]), "hidutil failed")
        let mappings = HIDRemapper.parseMappings(output)
        expect(
          output.trimmingCharacters(in: .whitespacesAndNewlines) == "(null)" || !mappings.isEmpty,
          "unreadable hidutil output: \(output)")
      }
    ),
  ])
