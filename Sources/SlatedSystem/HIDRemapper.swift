import Foundation

/// Remaps Caps Lock to F18 at the HID level with Apple's `hidutil` (Technical Note TN2450), the same
/// mechanism as System Settings → Keyboard → Modifier Keys. No driver or system extension needed.
///
/// The mapping lasts until reboot, so Slated removes it on quit. The user's other mappings are kept,
/// and so is a Caps Lock mapping of their own: Slated remembers the one it replaces and puts it back.
/// That memory, a small file (`record`), is also how Slated knows a Caps Lock → F18 entry is its own:
/// another tool (a Hammerspoon setup, say) may map Caps Lock to F18 too, and that one is left alone.
/// `scripts/restore-caps-lock.py` applies the same rule for `install.sh` after it force-quits Slated.
public enum HIDRemapper {
  static let capsLockUsage: UInt64 = 0x7_0000_0039
  static let f18Usage: UInt64 = 0x7_0000_006D
  /// Slated's entry.
  static let capsLockToF18 = Mapping(src: capsLockUsage, dst: f18Usage)

  /// One `UserKeyMapping` entry: the key with HID usage `src` produces usage `dst`. Coded with
  /// hidutil's own keys, so a remembered entry can be handed back to it as it is.
  struct Mapping: Equatable, Codable {
    var src: UInt64
    var dst: UInt64

    enum CodingKeys: String, CodingKey {
      case src = "HIDKeyboardModifierMappingSrc"
      case dst = "HIDKeyboardModifierMappingDst"
    }
  }

  /// Kept on disk while Slated's Caps Lock → F18 entry is in place: proof that the entry is Slated's,
  /// and the Caps Lock entry it replaced, if there was one.
  struct Record: Equatable, Codable {
    var replaced: Mapping?
  }

  /// Who put Caps Lock → F18 in place, as far as Slated can tell.
  public enum CapsLockOwner: Sendable {
    /// Slated, in a run that didn't quit cleanly: adopt it (and remove it if Hyper is now off).
    case slated
    /// Another tool: leave it alone.
    case otherTool
    /// Caps Lock isn't mapped to F18.
    case nobody
  }

  /// Turns Slated's Caps Lock → F18 entry on or off (see `plan`), keeping `record` up to date.
  /// Returns false if `hidutil` (or writing the record) failed; then nothing was changed.
  @discardableResult
  public static func setCapsLockRemapped(_ enabled: Bool, record url: URL) -> Bool {
    // Without the current mappings, setting new ones would wipe the user's.
    guard let output = run(["property", "--get", "UserKeyMapping"]) else { return false }
    let existing = readRecord(url)
    let (mappings, record) = plan(current: parseMappings(output), record: existing, enable: enabled)
    // Written first: if Slated dies right after, its next launch still knows the entry is its own.
    if let record, record != existing {
      guard writeRecord(record, to: url) else { return false }
    }
    guard run(["property", "--set", settingJSON(mappings)]) != nil else {
      if existing == nil { try? FileManager.default.removeItem(at: url) }
      return false
    }
    if record == nil { try? FileManager.default.removeItem(at: url) }
    return true
  }

  /// Whose Caps Lock → F18 entry is in place, if any. A record left without the entry (mappings
  /// don't survive a restart) is out of date, and is removed.
  public static func capsLockOwner(record url: URL) -> CapsLockOwner {
    let current = run(["property", "--get", "UserKeyMapping"]).map(parseMappings) ?? []
    let owner = owner(of: current, record: readRecord(url))
    if owner == .nobody { try? FileManager.default.removeItem(at: url) }
    return owner
  }

  static func owner(of current: [Mapping], record: Record?) -> CapsLockOwner {
    guard current.contains(capsLockToF18) else { return .nobody }
    return record == nil ? .otherTool : .slated
  }

  /// The mappings to set, and the record to keep (nil: delete it), to turn Slated's entry on or off.
  /// - On: Caps Lock's entry, if any, is replaced by Caps Lock → F18 and remembered. When Slated's
  ///   entry is already in place with a record (left by a crash, or re-applied after waking up), the
  ///   record already says what to put back.
  /// - Off: only Slated's entry goes, and what it replaced comes back. Anything else, including a
  ///   Caps Lock entry someone put there since, stays.
  static func plan(current: [Mapping], record: Record?, enable: Bool) -> (mappings: [Mapping], record: Record?) {
    if enable {
      if let record, current.contains(capsLockToF18) { return (current, record) }
      let replaced = current.first { $0.src == capsLockUsage }
      return (current.filter { $0.src != capsLockUsage } + [capsLockToF18], Record(replaced: replaced))
    }
    guard current.contains(capsLockToF18) else { return (current, nil) }
    var mappings = current.filter { $0 != capsLockToF18 }
    if let replaced = record?.replaced, !mappings.contains(where: { $0.src == replaced.src }) {
      mappings.append(replaced)
    }
    return (mappings, nil)
  }

  /// The `hidutil property --set` argument.
  static func settingJSON(_ mappings: [Mapping]) -> String {
    let (src, dst) = (Mapping.CodingKeys.src.rawValue, Mapping.CodingKeys.dst.rawValue)
    let entries = mappings.map { "{\"\(src)\":\($0.src),\"\(dst)\":\($0.dst)}" }
    return "{\"UserKeyMapping\":[\(entries.joined(separator: ","))]}"
  }

  /// Reads `hidutil property --get UserKeyMapping` output: an old-style (OpenStep) plist, or "(null)".
  /// That format has no number type, so the usages come back as strings.
  static func parseMappings(_ output: String) -> [Mapping] {
    guard let data = output.data(using: .utf8),
      let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [Any]
    else { return [] }
    return list.compactMap { item in
      guard let entry = item as? [String: Any], let src = usage(entry[Mapping.CodingKeys.src.rawValue]),
        let dst = usage(entry[Mapping.CodingKeys.dst.rawValue])
      else {
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

  static func readRecord(_ url: URL) -> Record? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return decodeRecord(data)
  }

  /// A record that can't be decoded still says Slated put its entry in place; it just can't say what
  /// to put back.
  static func decodeRecord(_ data: Data) -> Record {
    (try? JSONDecoder().decode(Record.self, from: data)) ?? Record(replaced: nil)
  }

  static func writeRecord(_ record: Record, to url: URL) -> Bool {
    guard let data = try? JSONEncoder().encode(record) else { return false }
    do {
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url, options: .atomic)
      return true
    } catch {
      return false
    }
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
