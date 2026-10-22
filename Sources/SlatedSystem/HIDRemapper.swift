import Foundation

/// Remaps Caps Lock to F18 at the HID level with Apple's `hidutil` (Technical Note TN2450), the same
/// mechanism as System Settings → Keyboard → Modifier Keys. No driver or system extension needed.
///
/// The mapping lasts until reboot, so Slated removes it on quit; other mappings are preserved.
public enum HIDRemapper {
  static let capsLockUsage: UInt64 = 0x7_0000_0039
  static let f18Usage: UInt64 = 0x7_0000_006D
  private static let srcKey = "HIDKeyboardModifierMappingSrc"
  private static let dstKey = "HIDKeyboardModifierMappingDst"

  /// Turns the Caps Lock → F18 mapping on or off. Returns false if `hidutil` failed.
  @discardableResult
  public static func setCapsLockRemapped(_ enabled: Bool) -> Bool {
    var mappings = currentMappings().filter { ($0[srcKey] as? NSNumber)?.uint64Value != capsLockUsage }
    if enabled {
      mappings.append([srcKey: NSNumber(value: capsLockUsage), dstKey: NSNumber(value: f18Usage)])
    }
    let entries = mappings.compactMap { m -> String? in
      guard let src = (m[srcKey] as? NSNumber)?.uint64Value, let dst = (m[dstKey] as? NSNumber)?.uint64Value else {
        return nil
      }
      return "{\"\(srcKey)\":\(src),\"\(dstKey)\":\(dst)}"
    }
    let json = "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"
    return run(["property", "--set", json]) != nil
  }

  /// Whether Caps Lock is currently mapped to F18.
  public static var isCapsLockRemapped: Bool {
    currentMappings().contains {
      ($0[srcKey] as? NSNumber)?.uint64Value == capsLockUsage && ($0[dstKey] as? NSNumber)?.uint64Value == f18Usage
    }
  }

  private static func currentMappings() -> [[String: Any]] {
    // `hidutil property --get` prints an old-style (OpenStep) plist, or "(null)".
    guard let output = run(["property", "--get", "UserKeyMapping"]),
      let data = output.data(using: .utf8),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
    else { return [] }
    return plist
  }

  private static func run(_ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
  }
}
