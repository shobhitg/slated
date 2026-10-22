import Carbon.HIToolbox
import SlatedCore

/// Global hotkeys via Carbon's `RegisterEventHotKey`.
///
/// Carbon is old but remains the standard way to register system-wide shortcuts: it needs no
/// permission, and the window server delivers the key to us even when another app is focused.
@MainActor
public final class HotKeyCenter {
  public enum Phase: Sendable { case pressed, released }
  public typealias Handler = @MainActor (Phase) -> Void

  public struct RegistrationError: Error, CustomStringConvertible {
    public let combo: KeyCombo
    public let status: OSStatus

    public var description: String {
      switch status {
      case OSStatus(eventHotKeyExistsErr): return "Another app already uses \(combo.display())"
      case OSStatus(eventHotKeyInvalidErr): return "macOS rejected \(combo.display()) as a hotkey"
      case -1: return "\(combo.key) isn't a key on this keyboard layout"
      default: return "Couldn't register \(combo.display()) (error \(status))"
      }
    }
  }

  public static let shared = HotKeyCenter()

  private var handlers: [UInt32: Handler] = [:]
  private var refs: [UInt32: EventHotKeyRef] = [:]
  private var nextID: UInt32 = 1
  private var eventHandler: EventHandlerRef?
  private static let signature: OSType = 0x534C_5444  // "SLTD"

  private init() {}

  /// Registers `combo`; `handler` runs on key down and key up. Returns a token for `unregister`.
  @discardableResult
  public func register(_ combo: KeyCombo, handler: @escaping Handler) throws(RegistrationError) -> UInt32 {
    installEventHandlerIfNeeded()
    guard let code = KeyCodes.code(for: combo.key) else { throw RegistrationError(combo: combo, status: -1) }
    let id = nextID
    nextID += 1
    var ref: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(code), Self.carbonModifiers(combo.modifiers), EventHotKeyID(signature: Self.signature, id: id),
      GetEventDispatcherTarget(), 0, &ref)
    guard status == noErr, let ref else { throw RegistrationError(combo: combo, status: status) }
    refs[id] = ref
    handlers[id] = handler
    return id
  }

  public func unregister(_ token: UInt32) {
    if let ref = refs.removeValue(forKey: token) { UnregisterEventHotKey(ref) }
    handlers[token] = nil
  }

  public func unregisterAll() {
    for ref in refs.values { UnregisterEventHotKey(ref) }
    refs.removeAll()
    handlers.removeAll()
  }

  fileprivate func handle(id: UInt32, phase: Phase) {
    handlers[id]?(phase)
  }

  private func installEventHandlerIfNeeded() {
    guard eventHandler == nil else { return }
    var specs = [
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
      EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
    ]
    InstallEventHandler(GetEventDispatcherTarget(), hotKeyEventCallback, specs.count, &specs, nil, &eventHandler)
  }

  static func carbonModifiers(_ modifiers: Modifiers) -> UInt32 {
    var flags: UInt32 = 0
    if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
    if modifiers.contains(.option) { flags |= UInt32(optionKey) }
    if modifiers.contains(.control) { flags |= UInt32(controlKey) }
    if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
    if modifiers.contains(.function) { flags |= UInt32(kEventKeyModifierFnMask) }
    return flags
  }
}

/// Carbon delivers hotkey events on the main thread's event loop.
private func hotKeyEventCallback(
  _ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event else { return OSStatus(eventNotHandledErr) }
  var hotKeyID = EventHotKeyID()
  let status = GetEventParameter(
    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
  guard status == noErr else { return status }
  let phase: HotKeyCenter.Phase = GetEventKind(event) == UInt32(kEventHotKeyReleased) ? .released : .pressed
  let id = hotKeyID.id
  MainActor.assumeIsolated { HotKeyCenter.shared.handle(id: id, phase: phase) }
  return noErr
}
