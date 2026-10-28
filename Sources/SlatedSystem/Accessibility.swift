import AppKit
import ApplicationServices
import SlatedCore

/// A window that belongs to another app, controlled through the Accessibility API.
///
/// All calls are synchronous IPC to the owning app, so they run on the main actor with a short
/// messaging timeout (see `Accessibility.configure()`): an app that hangs can't freeze Slated.
@MainActor
public final class AXWindow {
  public let element: AXUIElement
  public let pid: pid_t

  init(element: AXUIElement, pid: pid_t) {
    self.element = element
    self.pid = pid
  }

  public var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }

  public var title: String? { element.string(kAXTitleAttribute) }

  public var frame: CGRect? {
    guard let origin = element.point(kAXPositionAttribute), let size = element.size(kAXSizeAttribute) else {
      return nil
    }
    return CGRect(origin: origin, size: size)
  }

  public var isMinimized: Bool { element.bool(kAXMinimizedAttribute) ?? false }
  public var isMain: Bool { element.bool(kAXMainAttribute) ?? false }
  public var isFullScreen: Bool { element.bool("AXFullScreen") ?? false }
  public var subrole: String? { element.string(kAXSubroleAttribute) }
  /// Regular document/app windows, as opposed to panels, sheets and popovers.
  public var isStandard: Bool { subrole == (kAXStandardWindowSubrole as String) }
  public var isMovable: Bool { element.isSettable(kAXPositionAttribute) }
  public var isResizable: Bool { element.isSettable(kAXSizeAttribute) }

  /// Moves and resizes the window. Returns false when the app refused.
  ///
  /// Size is set before *and* after the position: apps clamp a window's size to the screen it is
  /// on, so moving between differently sized displays only lands right with the second resize.
  @discardableResult
  public func setFrame(_ target: CGRect) -> Bool {
    let appElement = AXUIElementCreateApplication(pid)
    // Chrome, Electron and others animate (slowly, sometimes wrongly) every Accessibility move
    // while "enhanced user interface" is on. Turn it off for the duration of the move.
    let enhanced = appElement.bool("AXEnhancedUserInterface") ?? false
    if enhanced { appElement.set("AXEnhancedUserInterface", kCFBooleanFalse) }
    defer { if enhanced { appElement.set("AXEnhancedUserInterface", kCFBooleanTrue) } }

    var size = target.size
    var origin = target.origin
    guard let sizeValue = AXValueCreate(.cgSize, &size), let originValue = AXValueCreate(.cgPoint, &origin) else {
      return false
    }
    let first = element.set(kAXSizeAttribute, sizeValue)
    let moved = element.set(kAXPositionAttribute, originValue)
    let second = element.set(kAXSizeAttribute, sizeValue)
    return moved || first || second
  }

  /// Raises the window and brings its app to the front.
  public func focus() {
    element.set(kAXMainAttribute, kCFBooleanTrue)
    AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    app?.activate()
  }

  /// Same underlying window (Accessibility elements are recreated on every query).
  public func isSame(as other: AXWindow) -> Bool { CFEqual(element, other.element) }
}

/// Entry points for querying apps and windows.
@MainActor
public enum Accessibility {
  /// Seconds to wait for an unresponsive app before giving up on an Accessibility call.
  public static let messagingTimeout: Float = 1.0

  public static func configure() {
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
  }

  /// The focused window of the frontmost app.
  public static func focusedWindow() -> AXWindow? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let appElement = AXUIElementCreateApplication(app.processIdentifier)
    if let window = appElement.element(kAXFocusedWindowAttribute) {
      return AXWindow(element: window, pid: app.processIdentifier)
    }
    if let window = appElement.element(kAXMainWindowAttribute) {
      return AXWindow(element: window, pid: app.processIdentifier)
    }
    return nil
  }

  /// The app's windows on the current Space, front to back.
  public static func windows(of pid: pid_t) -> [AXWindow] {
    let appElement = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value) == .success,
      let elements = value as? [AXUIElement]
    else { return [] }
    return elements.map { AXWindow(element: $0, pid: pid) }
  }

  /// Where typing goes in an app: the rectangle of its text caret, or of the focused element when the
  /// app doesn't say where the caret is. Top-left-origin global coordinates. Nil without
  /// Accessibility, or when the app has no focused element worth placing anything by.
  public static func typingLocation(pid: pid_t) -> TypingLocation? {
    let app = AXUIElementCreateApplication(pid)
    // A popup waits on this: a busy app gets a quarter of a second, not the usual second.
    AXUIElementSetMessagingTimeout(app, 0.25)
    guard let focused = app.element(kAXFocusedUIElementAttribute) else { return nil }
    AXUIElementSetMessagingTimeout(focused, 0.25)
    let screens = Screens.current().map(\.frame)
    if let caret = focused.caretRect(), PopupPlacement.isUsable(caret, on: screens) {
      return TypingLocation(rect: caret, source: .caret)
    }
    if let origin = focused.point(kAXPositionAttribute), let size = focused.size(kAXSizeAttribute) {
      let frame = CGRect(origin: origin, size: size)
      if PopupPlacement.isUsable(frame, maxHeight: TypingLocation.maxElementHeight, on: screens) {
        return TypingLocation(rect: frame, source: .element)
      }
    }
    return nil
  }

  /// Visible, standard windows of every regular app.
  public static func allWindows() -> [AXWindow] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular && !$0.isHidden }
      .flatMap { windows(of: $0.processIdentifier) }
      .filter { $0.isStandard && !$0.isMinimized }
  }
}

/// Where typing goes in an app (`Accessibility.typingLocation(pid:)`).
public struct TypingLocation: Equatable, Sendable {
  public enum Source: String, Sendable {
    /// The caret itself (or the selection), from the focused element's selected text range.
    case caret
    /// The focused element's frame: the app doesn't report its caret.
    case element
  }

  /// Taller focused elements (a whole editor, a web page) aren't used: they say little about where
  /// you're typing.
  public static let maxElementHeight: CGFloat = 240

  public var rect: CGRect
  public var source: Source
}

// MARK: - AXUIElement helpers

extension AXUIElement {
  fileprivate func value(_ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
    return value
  }

  fileprivate func string(_ attribute: String) -> String? { value(attribute) as? String }

  fileprivate func bool(_ attribute: String) -> Bool? { (value(attribute) as? NSNumber)?.boolValue }

  fileprivate func element(_ attribute: String) -> AXUIElement? {
    guard let value = value(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
  }

  fileprivate func point(_ attribute: String) -> CGPoint? {
    guard let value = value(attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
  }

  fileprivate func size(_ attribute: String) -> CGSize? {
    guard let value = value(attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
  }

  /// The caret's rectangle (or the selection's) from the selected text range. Some apps answer only
  /// for a range of at least one character: then the edge of the character before the caret, or of
  /// the one after it.
  fileprivate func caretRect() -> CGRect? {
    guard let value = value(kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else {
      return nil
    }
    var range = CFRange()
    guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
    if let rect = bounds(for: range), rect.height > 0 { return rect }
    guard range.length == 0 else { return nil }
    if range.location > 0, let before = bounds(for: CFRange(location: range.location - 1, length: 1)),
      before.height > 0
    {
      return CGRect(x: before.maxX, y: before.minY, width: 0, height: before.height)
    }
    if let after = bounds(for: CFRange(location: range.location, length: 1)), after.height > 0 {
      return CGRect(x: after.minX, y: after.minY, width: 0, height: after.height)
    }
    return nil
  }

  fileprivate func bounds(for range: CFRange) -> CGRect? {
    var range = range
    guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
    var result: CFTypeRef?
    guard
      AXUIElementCopyParameterizedAttributeValue(
        self, kAXBoundsForRangeParameterizedAttribute as CFString, rangeValue, &result) == .success,
      let result, CFGetTypeID(result) == AXValueGetTypeID()
    else { return nil }
    var rect = CGRect.zero
    return AXValueGetValue(result as! AXValue, .cgRect, &rect) ? rect : nil
  }

  fileprivate func isSettable(_ attribute: String) -> Bool {
    var settable: DarwinBoolean = false
    return AXUIElementIsAttributeSettable(self, attribute as CFString, &settable) == .success && settable.boolValue
  }

  @discardableResult
  fileprivate func set(_ attribute: String, _ value: CFTypeRef) -> Bool {
    AXUIElementSetAttributeValue(self, attribute as CFString, value) == .success
  }
}
