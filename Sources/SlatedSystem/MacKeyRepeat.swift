import Foundation
import SlatedCore

/// The Mac's key repeat (see `MacKeyRepeatTicks`): read to capture it, and set from config.json's
/// `keyboard.keyRepeat` in both places macOS keeps it.
///
/// - The global defaults `InitialKeyRepeat` and `KeyRepeat` (CFPreferences, ticks): the saved setting,
///   what macOS reads at login. System Settings' sliders stop at 15 and 2 ticks; macOS honors lower.
/// - The HID event system's `HIDInitialKeyRepeat` and `HIDKeyRepeat` (`hidutil`, nanoseconds): what
///   the keyboard does now. Setting them makes the change live without logging out, when macOS allows
///   it; reading them back says whether it did.
///
/// Nothing is undone when Slated quits: it's the user's preference, not a temporary mapping.
public struct MacKeyRepeat {
  /// Where the values are read and written. Tests pass fakes: the real ones change the user's Mac.
  public struct IO {
    /// The global defaults in ticks; nil for one that isn't set (macOS then uses its default).
    public var readDefaults: () -> (initial: Int?, repeat: Int?)
    /// Writes both defaults. False when they couldn't be saved.
    public var writeDefaults: (MacKeyRepeatTicks) -> Bool
    /// The HID event system's values in nanoseconds; nil when they can't be read.
    public var readLive: () -> (initial: Int64, repeat: Int64)?
    /// Sets both HID values. False when hidutil failed.
    public var writeLive: (_ initial: Int64, _ repeat: Int64) -> Bool

    public init(
      readDefaults: @escaping () -> (initial: Int?, repeat: Int?),
      writeDefaults: @escaping (MacKeyRepeatTicks) -> Bool,
      readLive: @escaping () -> (initial: Int64, repeat: Int64)?,
      writeLive: @escaping (_ initial: Int64, _ repeat: Int64) -> Bool
    ) {
      self.readDefaults = readDefaults
      self.writeDefaults = writeDefaults
      self.readLive = readLive
      self.writeLive = writeLive
    }
  }

  /// What `apply` did.
  public struct Result: Equatable, Sendable {
    public var state: KeyRepeatState
    /// The defaults were written (they differed).
    public var wroteDefaults: Bool
    /// hidutil was asked to change the live values (they differed).
    public var wroteLive: Bool
  }

  let io: IO

  public init(io: IO = .system) { self.io = io }

  /// This Mac's key repeat as a setting: the saved defaults, or for one that isn't set, the live value
  /// (macOS's default). Nil when neither can be read.
  public func current() -> KeyRepeat? {
    let defaults = io.readDefaults()
    var initial = defaults.initial
    var repeatTicks = defaults.repeat
    if initial == nil || repeatTicks == nil, let live = io.readLive() {
      initial = initial ?? MacKeyRepeatTicks.ticks(nanoseconds: live.initial)
      repeatTicks = repeatTicks ?? MacKeyRepeatTicks.ticks(nanoseconds: live.repeat)
    }
    guard let initial, let repeatTicks, initial > 0, repeatTicks > 0 else { return nil }
    return KeyRepeat(macTicks: MacKeyRepeatTicks(initial: initial, repeat: repeatTicks))
  }

  /// Saves `setting` in the defaults and sets it live, writing only what differs, then reads the live
  /// values back: `.applied` when they match, `.afterLogout` when macOS kept the old ones.
  public func apply(_ setting: KeyRepeat) -> Result {
    let ticks = setting.macTicks
    let defaults = io.readDefaults()
    var wroteDefaults = false
    if defaults.initial != ticks.initial || defaults.repeat != ticks.repeat {
      guard io.writeDefaults(ticks) else {
        return Result(
          state: .failed("macOS didn't save the key repeat setting"), wroteDefaults: false, wroteLive: false)
      }
      wroteDefaults = true
    }
    var wroteLive = false
    if !Self.matches(io.readLive(), ticks) {
      let ns = ticks.nanoseconds
      wroteLive = true
      _ = io.writeLive(ns.initial, ns.repeat)
    }
    let live = wroteLive ? Self.matches(io.readLive(), ticks) : true
    return Result(state: live ? .applied : .afterLogout, wroteDefaults: wroteDefaults, wroteLive: wroteLive)
  }

  /// Live values within half a tick of `ticks` (whatever set them, the same timing).
  static func matches(_ live: (initial: Int64, repeat: Int64)?, _ ticks: MacKeyRepeatTicks) -> Bool {
    guard let live else { return false }
    return MacKeyRepeatTicks.ticks(nanoseconds: live.initial) == ticks.initial
      && MacKeyRepeatTicks.ticks(nanoseconds: live.repeat) == ticks.repeat
  }

  /// `hidutil property --set`'s argument.
  static func settingJSON(initial: Int64, repeat: Int64) -> String {
    "{\"HIDInitialKeyRepeat\":\(initial),\"HIDKeyRepeat\":\(`repeat`)}"
  }

  /// `hidutil property --get <key>` prints a bare number, or "(null)".
  static func parseNumber(_ output: String?) -> Int64? {
    output.flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }
}

extension MacKeyRepeat.IO {
  static var initialKey: CFString { "InitialKeyRepeat" as CFString }
  static var repeatKey: CFString { "KeyRepeat" as CFString }

  /// The real global defaults and HID event system.
  public static var system: MacKeyRepeat.IO {
    MacKeyRepeat.IO(
      readDefaults: {
        (readGlobalInt(initialKey), readGlobalInt(repeatKey))
      },
      writeDefaults: { ticks in
        CFPreferencesSetValue(
          initialKey, ticks.initial as CFNumber, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
          kCFPreferencesAnyHost)
        CFPreferencesSetValue(
          repeatKey, ticks.repeat as CFNumber, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser,
          kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        else { return false }
        return readGlobalInt(initialKey) == ticks.initial && readGlobalInt(repeatKey) == ticks.repeat
      },
      readLive: {
        guard let initial = MacKeyRepeat.parseNumber(HIDRemapper.run(["property", "--get", "HIDInitialKeyRepeat"])),
          let repeatNs = MacKeyRepeat.parseNumber(HIDRemapper.run(["property", "--get", "HIDKeyRepeat"]))
        else { return nil }
        return (initial, repeatNs)
      },
      writeLive: { initial, repeatNs in
        HIDRemapper.run(["property", "--set", MacKeyRepeat.settingJSON(initial: initial, repeat: repeatNs)]) != nil
      })
  }

  /// The global domain's value, as `defaults read -g` reads it.
  static func readGlobalInt(_ key: CFString) -> Int? {
    let value = CFPreferencesCopyValue(
      key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    switch value {
    case let number as NSNumber: return number.intValue
    case let text as String: return Int(text)
    default: return nil
    }
  }
}
