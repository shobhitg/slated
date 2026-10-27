import CoreGraphics
import Foundation
import SlatedCore

/// The system-wide keyboard event tap behind the Hyper key and hotstrings.
///
/// - **Hyper:** `HIDRemapper` turns Caps Lock into F18 at the HID level. While F18 is held, this tap
///   swallows it and adds the Hyper modifiers to every other key and click, so all apps (and our own
///   Carbon hotkeys) see ⌃⌥⇧⌘ shortcuts.
/// - **Hotstrings:** typed characters feed a `HotstringMatcher`. When a trigger completes, the key
///   that completed it is swallowed and `onHotstring` runs on the main actor to do the replacement.
///
/// The tap runs on its own thread so a busy main thread can never delay typing; macOS disables taps
/// that respond too slowly. Keystrokes live only in the matcher's short buffer and are never logged.
public final class KeyboardTap: @unchecked Sendable {
  public struct Options: Equatable, Sendable {
    public var hyperEnabled = false
    public var hyperModifiers: Modifiers = .hyper
    public var capsLockAloneSendsEscape = false
    /// Caps Lock held longer than this isn't a tap: releasing it sends nothing (like Karabiner's
    /// `to_if_alone` timeout). Kept below the cheat-sheet delay, so looking at the cheat sheet never
    /// sends Escape.
    public var aloneTimeout: TimeInterval = 1
    public var hotstringsEnabled = false
    /// Pass everything through untouched (e.g. while the UI records a shortcut).
    public var suspended = false

    public init() {}
  }

  /// A mouse button shortcut: button 3 (middle), 4 (back) or 5 (forward) with modifiers.
  public struct MouseHotkey: Hashable, Sendable {
    public var button: Int
    public var modifiers: Modifiers

    public init(button: Int, modifiers: Modifiers) {
      self.button = button
      self.modifiers = modifiers
    }
  }

  /// The Hyper key went down, was first used with another key or click, or went up.
  public enum HyperEvent: Sendable {
    case pressed, used, released
  }

  /// Whether a key (virtual key code) or mouse button (numbered from 1, so mouse4 is 4) is physically
  /// down right now, according to the HID system. Tests replace it: the events they feed the tap never
  /// reach the HID system.
  struct PhysicalState: Sendable {
    var isKeyDown: @Sendable (CGKeyCode) -> Bool
    var isMouseButtonDown: @Sendable (Int) -> Bool

    static let hidSystem = PhysicalState(
      isKeyDown: { CGEventSource.keyState(.hidSystemState, key: $0) },
      isMouseButtonDown: { button in
        CGMouseButton(rawValue: UInt32(button - 1)).map { CGEventSource.buttonState(.hidSystemState, button: $0) }
          ?? false
      })
  }

  /// Value written into `eventSourceUserData` of events Slated posts, so the tap ignores them.
  public static let syntheticEventMarker: Int64 = 0x534C_4154_4544
  /// The virtual key code Caps Lock is remapped to (F18).
  public static let hyperKeyCode: Int64 = 79

  /// Runs on the main actor when a hotstring trigger completes.
  public var onHotstring: (@MainActor @Sendable (HotstringMatch) -> Void)?
  /// Runs on the main actor for a Hyper combo Slated binds (key code, true = down / false = up).
  /// These are handled here rather than by Carbon so they work even if the window server matched
  /// hotkeys before our injected modifiers.
  public var onHyperHotkey: (@MainActor @Sendable (UInt16, Bool) -> Void)?
  /// Runs on the main actor for tap lifecycle events worth logging: "reenabled_after_timeout",
  /// "reenabled_after_user_input" (macOS disables slow taps), "started", "stopped".
  public var onEvent: (@MainActor @Sendable (String) -> Void)?
  /// Runs on the main actor for a bound mouse button shortcut (true = down, false = up).
  public var onMouseHotkey: (@MainActor @Sendable (MouseHotkey, Bool) -> Void)?
  /// Runs on the main actor as the Hyper key is pressed, first used and released (the island's
  /// cheat sheet). Never says which key was used.
  public var onHyperEvent: (@MainActor @Sendable (HyperEvent) -> Void)?

  private let lock = NSLock()
  private var options = Options()
  private var matcher = HotstringMatcher()
  private var frontmostBundleID: String?
  private var hyperDown = false
  private var hyperUsed = false
  /// When Caps Lock went down (monotonic nanoseconds), for `aloneTimeout`. Event timestamps aren't
  /// used: their unit differs between Intel and Apple silicon.
  private var hyperDownAt: UInt64 = 0
  private var hyperHotkeyCodes: Set<Int64> = []
  private var hyperHotkeyHeld: Set<Int64> = []
  private var mouseHotkeys: Set<MouseHotkey> = []
  /// Mouse buttons whose press we swallowed, so their release is swallowed too.
  private var mouseHotkeyHeld: [Int: MouseHotkey] = [:]
  private var machPort: CFMachPort?
  private var runLoop: CFRunLoop?
  /// Set before the tap starts; tests replace both.
  var physicalState = PhysicalState.hidSystem
  var postEscape: @Sendable () -> Void = { KeyboardTap.postKey(53) }

  public init() {}

  public var isRunning: Bool { lock.withLock { machPort != nil } }

  /// Installs the tap. Fails (returns false) without Accessibility permission.
  public func start() -> Bool {
    if isRunning { return true }
    let types: [CGEventType] = [
      .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
      .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
    ]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    guard
      let port = CGEvent.tapCreate(
        tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
        callback: keyboardTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque())
    else { return false }

    // CF handles aren't Sendable; they're handed to the tap thread once and only used there.
    let handles = TapHandles(port: port, source: CFMachPortCreateRunLoopSource(nil, port, 0))
    let ready = DispatchSemaphore(value: 0)
    let thread = Thread { [self] in
      let loop = CFRunLoopGetCurrent()
      lock.withLock { runLoop = loop }
      CFRunLoopAddSource(loop, handles.source, .commonModes)
      CGEvent.tapEnable(tap: handles.port, enable: true)
      ready.signal()
      CFRunLoopRun()
    }
    thread.name = "Slated keyboard tap"
    thread.qualityOfService = .userInteractive
    lock.withLock { machPort = port }
    thread.start()
    ready.wait()
    notify("started")
    return true
  }

  private func notify(_ event: String) {
    guard let handler = onEvent else { return }
    DispatchQueue.main.async { MainActor.assumeIsolated { handler(event) } }
  }

  public func stop() {
    let (port, loop, held) = lock.withLock { () -> (CFMachPort?, CFRunLoop?, Held) in
      defer {
        machPort = nil
        runLoop = nil
      }
      return (machPort, runLoop, forgetHeld())
    }
    if let port {
      CGEvent.tapEnable(tap: port, enable: false)
      CFMachPortInvalidate(port)
    }
    if let loop { CFRunLoopStop(loop) }
    if port != nil { notify("stopped") }
    release(held)
  }

  /// Hyper, Hyper combos and mouse button shortcuts that were down when the tap lost track of input.
  private struct Held {
    var hyper = false
    var keys: [Int64] = []
    var mouse: [MouseHotkey] = []
  }

  /// Forgets every press in progress. Must be called with `lock` held. Otherwise a release the tap
  /// never saw would leave Hyper on for every key, or swallow the next, unrelated release of that
  /// key or button (leaving it down in the app).
  private func forgetHeld() -> Held {
    defer {
      hyperDown = false
      hyperUsed = false
      hyperHotkeyHeld = []
      mouseHotkeyHeld = [:]
      matcher.reset()
    }
    return Held(hyper: hyperDown, keys: Array(hyperHotkeyHeld), mouse: Array(mouseHotkeyHeld.values))
  }

  /// Forgets the presses in progress that are no longer physically down. Must be called with `lock`
  /// held. What is still held carries on as if the tap had never been off: Hyper stays on (and a long
  /// hold still isn't a tap that sends Escape), and a swallowed combo's repeats and release stay
  /// swallowed.
  private func forgetReleased() -> Held {
    matcher.reset()  // typing went by unseen
    var released = Held()
    if hyperDown && !physicalState.isKeyDown(CGKeyCode(Self.hyperKeyCode)) {
      released.hyper = true
      hyperDown = false
      hyperUsed = false
    }
    for code in hyperHotkeyHeld where !physicalState.isKeyDown(CGKeyCode(code)) {
      hyperHotkeyHeld.remove(code)
      released.keys.append(code)
    }
    for (button, hotkey) in mouseHotkeyHeld where !physicalState.isMouseButtonDown(button) {
      mouseHotkeyHeld[button] = nil
      released.mouse.append(hotkey)
    }
    return released
  }

  /// Reports everything in `held` as released, so nothing it started (a while-held repeat, the cheat
  /// sheet) keeps going.
  private func release(_ held: Held) {
    if held.hyper, let handler = onHyperEvent {
      DispatchQueue.main.async { MainActor.assumeIsolated { handler(.released) } }
    }
    if let handler = onHyperHotkey {
      for code in held.keys {
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(UInt16(code), false) } }
      }
    }
    if let handler = onMouseHotkey {
      for hotkey in held.mouse {
        DispatchQueue.main.async { MainActor.assumeIsolated { handler(hotkey, false) } }
      }
    }
  }

  /// `hyperHotkeys`: key codes bound with exactly the Hyper modifiers.
  public func update(
    options: Options, hotstrings: [Hotstring], hyperHotkeys: Set<UInt16> = [], mouseHotkeys: Set<MouseHotkey> = []
  ) {
    lock.withLock {
      self.options = options
      matcher.update(hotstrings)
      hyperHotkeyCodes = Set(hyperHotkeys.map(Int64.init))
      self.mouseHotkeys = mouseHotkeys
      if !options.hyperEnabled { hyperDown = false }
    }
  }

  /// Tell the tap which app is frontmost (for hotstring app filters). Also clears the buffer.
  public func setFrontmostApp(bundleID: String?) {
    lock.withLock {
      frontmostBundleID = bundleID
      matcher.reset()
    }
  }

  // MARK: - Event handling (tap thread)

  /// Decides what happens to one event: nil swallows it. Internal for tests.
  func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    let pass = Unmanaged.passUnretained(event)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let port = lock.withLock({ machPort }) { CGEvent.tapEnable(tap: port, enable: true) }
      notify(type == .tapDisabledByTimeout ? "reenabled_after_timeout" : "reenabled_after_user_input")
      // Events went by unseen while macOS had the tap off, perhaps Caps Lock's release among them:
      // release what is no longer down, and keep what still is.
      release(lock.withLock { forgetReleased() })
      return pass
    }
    if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker { return pass }

    var sendEscape = false
    var match: HotstringMatch?
    var hyperHotkey: (code: UInt16, down: Bool)?
    var mouseHotkey: (hotkey: MouseHotkey, down: Bool)?
    var hyperEvent: HyperEvent?
    let result: Unmanaged<CGEvent>? = lock.withLock {
      let (wasDown, wasUsed) = (hyperDown, hyperUsed)
      defer {
        if hyperDown != wasDown {
          hyperEvent = hyperDown ? .pressed : .released
        } else if hyperDown && hyperUsed && !wasUsed {
          hyperEvent = .used
        }
      }
      if options.suspended { return pass }
      let hyperFlags = Self.flags(for: options.hyperModifiers)
      switch type {
      case .keyDown, .keyUp:
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if options.hyperEnabled && keyCode == Self.hyperKeyCode {
          if type == .keyDown {
            if !hyperDown {
              hyperDown = true
              hyperUsed = false
              hyperDownAt = DispatchTime.now().uptimeNanoseconds
              matcher.reset()
            }
          } else {
            let wasDown = hyperDown
            hyperDown = false
            let held = TimeInterval(DispatchTime.now().uptimeNanoseconds &- hyperDownAt) / 1_000_000_000
            sendEscape = wasDown && options.capsLockAloneSendsEscape && !hyperUsed && held < options.aloneTimeout
          }
          return nil  // the stand-in key itself never reaches apps
        }
        // Finish a Hyper combo we swallowed even if Caps Lock was released first.
        if type == .keyUp && hyperHotkeyHeld.remove(keyCode) != nil {
          hyperHotkey = (UInt16(keyCode), false)
          return nil
        }
        if hyperDown {
          if type == .keyDown { hyperUsed = true }
          let extra = event.flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand])
          if type == .keyDown && extra.isEmpty && hyperHotkeyCodes.contains(keyCode) {
            // Key repeat is handled by Slated's own repeat timer.
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
              hyperHotkeyHeld.insert(keyCode)
              hyperHotkey = (UInt16(keyCode), true)
            }
            return nil
          }
          event.flags.formUnion(hyperFlags)
          return pass
        }
        if type == .keyDown && options.hotstringsEnabled {
          match = feedHotstring(event)
          return match == nil ? pass : nil
        }
        return pass
      case .flagsChanged:
        if hyperDown { event.flags.formUnion(hyperFlags) }
        return pass
      case .otherMouseDown, .otherMouseUp:
        // Button numbers start at 0 (left); Slate-style names start at 1 ("mouse4" is number 3).
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber)) + 1
        if type == .otherMouseUp, let held = mouseHotkeyHeld.removeValue(forKey: button) {
          mouseHotkey = (held, false)
          return nil
        }
        if type == .otherMouseDown && !mouseHotkeys.isEmpty {
          var modifiers = Self.modifiers(from: event.flags)
          if hyperDown { modifiers.formUnion(options.hyperModifiers) }
          let candidate = MouseHotkey(button: button, modifiers: modifiers)
          if mouseHotkeys.contains(candidate) {
            if hyperDown { hyperUsed = true }
            mouseHotkeyHeld[button] = candidate
            mouseHotkey = (candidate, true)
            return nil
          }
        }
        if hyperDown {
          hyperUsed = true
          event.flags.formUnion(hyperFlags)
        }
        if type == .otherMouseDown { matcher.reset() }
        return pass
      default:  // mouse buttons and drags
        if hyperDown {
          hyperUsed = true
          event.flags.formUnion(hyperFlags)
        }
        if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown { matcher.reset() }
        return pass
      }
    }

    if sendEscape { postEscape() }
    if let hyperEvent, let handler = onHyperEvent {
      DispatchQueue.main.async { MainActor.assumeIsolated { handler(hyperEvent) } }
    }
    if let mouseHotkey, let handler = onMouseHotkey {
      DispatchQueue.main.async { MainActor.assumeIsolated { handler(mouseHotkey.hotkey, mouseHotkey.down) } }
    }
    if let hyperHotkey, let handler = onHyperHotkey {
      DispatchQueue.main.async { MainActor.assumeIsolated { handler(hyperHotkey.code, hyperHotkey.down) } }
    }
    if let match, let handler = onHotstring {
      DispatchQueue.main.async { MainActor.assumeIsolated { handler(match) } }
    }
    return result
  }

  /// Must be called with `lock` held.
  private func feedHotstring(_ event: CGEvent) -> HotstringMatch? {
    let flags = event.flags
    if flags.contains(.maskCommand) || flags.contains(.maskControl) {
      matcher.reset()
      return nil
    }
    let text: String
    switch event.getIntegerValueField(.keyboardEventKeycode) {
    case 51:  // delete
      matcher.backspace()
      return nil
    case 36, 76: text = "\n"  // return, keypad enter
    case 48: text = "\t"
    case 53, 115, 116, 117, 119, 121, 123, 124, 125, 126:  // esc, navigation, forward delete
      matcher.reset()
      return nil
    default:
      var length = 0
      var chars = [UniChar](repeating: 0, count: 8)
      event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
      text = String(utf16CodeUnits: chars, count: length)
    }
    return matcher.feed(text, appBundleID: frontmostBundleID)
  }

  static func modifiers(from flags: CGEventFlags) -> Modifiers {
    var modifiers: Modifiers = []
    if flags.contains(.maskControl) { modifiers.insert(.control) }
    if flags.contains(.maskAlternate) { modifiers.insert(.option) }
    if flags.contains(.maskShift) { modifiers.insert(.shift) }
    if flags.contains(.maskCommand) { modifiers.insert(.command) }
    return modifiers
  }

  static func flags(for modifiers: Modifiers) -> CGEventFlags {
    var flags: CGEventFlags = []
    if modifiers.contains(.control) { flags.insert(.maskControl) }
    if modifiers.contains(.option) { flags.insert(.maskAlternate) }
    if modifiers.contains(.shift) { flags.insert(.maskShift) }
    if modifiers.contains(.command) { flags.insert(.maskCommand) }
    return flags
  }

  /// Posts a key press (down + up), marked as synthetic.
  static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
    let source = CGEventSource(stateID: .privateState)
    for down in [true, false] {
      guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { continue }
      event.flags = flags
      event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
      event.post(tap: .cghidEventTap)
    }
  }
}

private struct TapHandles: @unchecked Sendable {
  let port: CFMachPort
  let source: CFRunLoopSource?
}

private func keyboardTapCallback(
  proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
  guard let refcon else { return Unmanaged.passUnretained(event) }
  return Unmanaged<KeyboardTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
