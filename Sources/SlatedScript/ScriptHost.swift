import Foundation
import SlatedCore

// The contract between the script engine and the app. The app owns the real Accessibility layer and
// implements `ScriptHost`; tests implement it with plain dictionaries. Everything crossing this
// boundary is a value type or an opaque handle, so a fake host is a few lines of code.

/// Opaque identifier the host assigns to a window. The engine never interprets it, only hands it back.
///
/// It should stay valid while the window exists and not be reused soon after the window closes,
/// because scripts may hold on to window objects. Scripts see it as a JavaScript number, so keep it
/// within ±2^53.
public struct WindowHandle: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
  public var rawValue: Int

  public init(rawValue: Int) { self.rawValue = rawValue }
  public init(_ rawValue: Int) { self.rawValue = rawValue }

  public var description: String { "window #\(rawValue)" }
}

/// A window's current state. The engine asks for it every time a script reads a property, so a
/// script that moves a window and then reads `win.rect()` sees the new frame.
public struct ScriptWindowInfo: Hashable, Sendable {
  public var handle: WindowHandle
  public var title: String
  /// Top-left-origin global coordinates.
  public var frame: CGRect
  /// Process identifier of the window's app.
  public var pid: Int32
  public var isMinimizedOrHidden: Bool
  /// True for the main window of its app.
  public var isMain: Bool
  public var isMovable: Bool
  public var isResizable: Bool

  public init(
    handle: WindowHandle, title: String, frame: CGRect, pid: Int32, isMinimizedOrHidden: Bool = false,
    isMain: Bool = false, isMovable: Bool = true, isResizable: Bool = true
  ) {
    self.handle = handle
    self.title = title
    self.frame = frame
    self.pid = pid
    self.isMinimizedOrHidden = isMinimizedOrHidden
    self.isMain = isMain
    self.isMovable = isMovable
    self.isResizable = isResizable
  }
}

/// A running application.
public struct ScriptAppInfo: Hashable, Sendable {
  public var pid: Int32
  /// Localized name, e.g. "Safari". Slate configs match apps by this name.
  public var name: String
  public var bundleID: String?

  public init(pid: Int32, name: String, bundleID: String? = nil) {
    self.pid = pid
    self.name = name
    self.bundleID = bundleID
  }
}

/// What the JavaScript API needs from the app. All calls happen on the main actor, synchronously,
/// while a script runs.
@MainActor
public protocol ScriptHost: AnyObject {
  // MARK: Windows and apps

  /// The focused window of the frontmost app, if any. Bound functions receive it as their argument.
  func focusedWindow() -> WindowHandle?
  /// Current state of `window`, or nil once it has closed.
  func windowInfo(_ window: WindowHandle) -> ScriptWindowInfo?
  /// The app's windows, front to back (`app.eachWindow`).
  func windows(ofApp pid: Int32) -> [WindowHandle]
  /// The app's main window (`app.mainWindow()`). Defaults to the first window marked main.
  func mainWindow(ofApp pid: Int32) -> WindowHandle?
  /// The topmost window under `point` (`slate.windowUnderPoint`). Defaults to a search through
  /// `runningApps()` and `windows(ofApp:)`.
  func window(at point: CGPoint) -> WindowHandle?
  /// The frontmost app (`slate.app()` when no window is focused). Defaults to the focused window's app.
  func frontmostApp() -> ScriptAppInfo?
  /// Regular (Dock) apps, most recently active first (`slate.eachApp`).
  func runningApps() -> [ScriptAppInfo]
  /// The app with process identifier `pid`. Defaults to a lookup in `runningApps()`.
  func app(pid: Int32) -> ScriptAppInfo?

  // MARK: Screens

  /// All displays in OS order (the main display first), in top-left-origin coordinates. The engine
  /// applies Slate's `orderScreensLeftToRight` itself when scripts number screens.
  func screens() -> [ScreenInfo]

  // MARK: Doing things

  /// Moves and resizes `window` (`win.move`, `win.resize`). Returns false if the window refused.
  func setFrame(_ frame: CGRect, of window: WindowHandle) -> Bool
  /// Raises and focuses `window` (`win.focus()`).
  func focus(_ window: WindowHandle) -> Bool
  /// Runs a Slate operation. `window` is the window to act on: the focused window for bindings, or a
  /// specific window for `win.doOperation` and `app.eachWindow`. It is nil when nothing is focused;
  /// operations that need a window should then fail, others (`focus` an app, `hide`, `shell`,
  /// `layout`…) still run. Layouts defined in JavaScript are in `SlateScriptEngine.result.layouts`;
  /// run their callback steps with `SlateScriptEngine.run(_:on:)`.
  func perform(_ action: Action, on window: WindowHandle?) -> Bool

  // MARK: Side effects

  /// Runs `command` (a command line, split like a shell would) in `path` (default: home). When
  /// `wait` is true, blocks until it exits and returns its standard output; otherwise returns nil
  /// immediately.
  func runShell(_ command: String, wait: Bool, path: String?) -> String?
  /// `slate.log(...)` output.
  func log(_ message: String)
}

extension ScriptHost {
  public func mainWindow(ofApp pid: Int32) -> WindowHandle? {
    let windows = windows(ofApp: pid)
    return windows.first { windowInfo($0)?.isMain == true } ?? windows.first
  }

  public func window(at point: CGPoint) -> WindowHandle? {
    for app in runningApps() {
      for window in windows(ofApp: app.pid) {
        guard let info = windowInfo(window), !info.isMinimizedOrHidden else { continue }
        if info.frame.contains(point) { return window }
      }
    }
    return nil
  }

  public func frontmostApp() -> ScriptAppInfo? {
    if let window = focusedWindow(), let info = windowInfo(window), let app = app(pid: info.pid) {
      return app
    }
    return runningApps().first
  }

  public func app(pid: Int32) -> ScriptAppInfo? {
    runningApps().first { $0.pid == pid }
  }
}
