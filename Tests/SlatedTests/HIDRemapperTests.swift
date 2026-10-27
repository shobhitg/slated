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

private let capsToF18 = HIDRemapper.Mapping(src: 0x7_0000_0039, dst: 0x7_0000_006D)
private let sectionToGrave = HIDRemapper.Mapping(src: 0x7_0000_0064, dst: 0x7_0000_0035)

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
        let others = HIDRemapper.parseMappings(hidutilOutput).filter { $0 != capsToF18 }
        expectEqual(others, [sectionToGrave])
        let section = "{\"HIDKeyboardModifierMappingSrc\":30064771172,\"HIDKeyboardModifierMappingDst\":30064771125}"
        let caps = "{\"HIDKeyboardModifierMappingSrc\":30064771129,\"HIDKeyboardModifierMappingDst\":30064771181}"
        expectEqual(
          HIDRemapper.settingJSON(keeping: HIDRemapper.parseMappings(hidutilOutput), capsLockRemapped: false),
          "{\"UserKeyMapping\":[\(section)]}")
        expectEqual(
          HIDRemapper.settingJSON(keeping: others, capsLockRemapped: true), "{\"UserKeyMapping\":[\(section),\(caps)]}")
        // Already on: replaced, not duplicated.
        expectEqual(
          HIDRemapper.settingJSON(keeping: [capsToF18], capsLockRemapped: true), "{\"UserKeyMapping\":[\(caps)]}")
        expectEqual(HIDRemapper.settingJSON(keeping: [], capsLockRemapped: false), "{\"UserKeyMapping\":[]}")
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
        expectEqual(HIDRemapper.isCapsLockRemapped, mappings.contains(capsToF18))
      }
    ),
  ])
