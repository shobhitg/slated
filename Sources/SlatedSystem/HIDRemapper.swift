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

  /// One `UserKeyMapping` entry: the key with HID usage `src` produces usage `dst`.
  struct Mapping: Equatable {
    var src: UInt64
    var dst: UInt64
  }

  /// Turns the Caps Lock → F18 mapping on or off. Returns false if `hidutil` failed.
  @discardableResult
  public static func setCapsLockRemapped(_ enabled: Bool) -> Bool {
    run(["property", "--set", settingJSON(keeping: currentMappings(), capsLockRemapped: enabled)]) != nil
  }

  /// Whether Caps Lock is currently mapped to F18.
  public static var isCapsLockRemapped: Bool {
    currentMappings().contains(Mapping(src: capsLockUsage, dst: f18Usage))
  }

  /// The `hidutil property --set` argument: `current` with Caps Lock's entry replaced or removed.
  static func settingJSON(keeping current: [Mapping], capsLockRemapped: Bool) -> String {
    var mappings = current.filter { $0.src != capsLockUsage }
    if capsLockRemapped { mappings.append(Mapping(src: capsLockUsage, dst: f18Usage)) }
    let entries = mappings.map { "{\"\(srcKey)\":\($0.src),\"\(dstKey)\":\($0.dst)}" }
    return "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"
  }

  /// Reads `hidutil property --get UserKeyMapping` output: an old-style (OpenStep) plist, or "(null)".
  /// That format has no number type, so the usages come back as strings.
  static func parseMappings(_ output: String) -> [Mapping] {
    guard let data = output.data(using: .utf8),
      let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [Any]
    else { return [] }
    return list.compactMap { item in
      guard let entry = item as? [String: Any], let src = usage(entry[srcKey]), let dst = usage(entry[dstKey]) else {
        return nil
      }
      return Mapping(src: src, dst: dst)
    }
  }

  private static func usage(_ value: Any?) -> UInt64? {
    switch value {
    case let number as NSNumber: return number.uint64Value
    case let text as String: return UInt64(text.trimmingCharacters(in: .whitespaces))
    default: return nil
    }
  }

  private static func currentMappings() -> [Mapping] {
    run(["property", "--get", "UserKeyMapping"]).map(parseMappings) ?? []
  }

  /// Runs `hidutil` and returns what it printed, or nil if it failed.
  static func run(_ arguments: [String]) -> String? {
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
