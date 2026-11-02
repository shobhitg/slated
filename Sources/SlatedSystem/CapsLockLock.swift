import Foundation
import IOKit
import IOKit.hidsystem

/// The Caps Lock *lock* (capitals on, the key's light lit), as opposed to the key.
///
/// Once the Hyper key maps Caps Lock to F18, no key can turn the lock off, so a lock that was on
/// stays on. Slated turns it off when the Hyper key comes on (before mapping the key) and whenever
/// it comes on while the Hyper key is active (nothing physical can do that then). IOKit's public
/// `IOHIDGetModifierLockState`/`IOHIDSetModifierLockState` read and set it, as the key itself would.
public struct CapsLockLock {
  /// Whether the lock is on; nil when it can't be read.
  public var isOn: () -> Bool?
  /// Turns the lock off. False when IOKit refused.
  public var turnOff: () -> Bool

  public init(isOn: @escaping () -> Bool?, turnOff: @escaping () -> Bool) {
    self.isOn = isOn
    self.turnOff = turnOff
  }

  /// What `clearIfOn` did.
  public enum Outcome: Equatable, Sendable {
    /// The lock was off already.
    case wasOff
    case cleared
    /// The lock is on and couldn't be turned off (or couldn't be read).
    case failed
  }

  /// Turns the lock off if it's on.
  public func clearIfOn() -> Outcome {
    guard let on = isOn() else { return .failed }
    guard on else { return .wasOff }
    return turnOff() && isOn() == false ? .cleared : .failed
  }

  /// The real lock, through IOHIDSystem.
  public static var system: CapsLockLock {
    CapsLockLock(
      isOn: {
        withConnection { connect in
          var state = false
          guard IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state) == KERN_SUCCESS else {
            return nil
          }
          return state
        } ?? nil
      },
      turnOff: {
        withConnection { connect in
          IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false) == KERN_SUCCESS
        } ?? false
      })
  }

  /// Runs `body` with a connection to IOHIDSystem's parameter interface; nil when there's none.
  private static func withConnection<T>(_ body: (io_connect_t) -> T) -> T? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }
    var connect: io_connect_t = 0
    guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else {
      return nil
    }
    defer { IOServiceClose(connect) }
    return body(connect)
  }
}
