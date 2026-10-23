import AppKit
import SlatedCore
import SlatedScript
import SlatedSystem

/// Gives Slate JavaScript configs access to real windows, apps and screens.
///
/// Scripts refer to windows by opaque handles. Accessibility elements are recreated on every query,
/// so the host keeps a small registry and hands out the same handle for the same window — Slate's
/// per-window chain cycling depends on that.
final class AppScriptHost: ScriptHost {
  weak var runner: ActionRunner?

  private var windowsByHandle: [Int: AXWindow] = [:]
  private var nextHandle = 1

  func handle(for window: AXWindow) -> WindowHandle {
    if let existing = windowsByHandle.first(where: { $0.value.isSame(as: window) }) {
      return WindowHandle(existing.key)
    }
    let id = nextHandle
    nextHandle += 1
    windowsByHandle[id] = window
    return WindowHandle(id)
  }

  func window(_ handle: WindowHandle) -> AXWindow? { windowsByHandle[handle.rawValue] }

  // MARK: ScriptHost

  func focusedWindow() -> WindowHandle? { Accessibility.focusedWindow().map(handle(for:)) }

  func windowInfo(_ handle: WindowHandle) -> ScriptWindowInfo? {
    guard let window = window(handle), let frame = window.frame else {
      windowsByHandle[handle.rawValue] = nil  // closed
      return nil
    }
    return ScriptWindowInfo(
      handle: handle, title: window.title ?? "", frame: frame, pid: window.pid,
      isMinimizedOrHidden: window.isMinimized || (window.app?.isHidden ?? false), isMain: window.isMain,
      isMovable: window.isMovable, isResizable: window.isResizable)
  }

  func windows(ofApp pid: Int32) -> [WindowHandle] {
    Accessibility.windows(of: pid).filter(\.isStandard).map(handle(for:))
  }

  func frontmostApp() -> ScriptAppInfo? {
    NSWorkspace.shared.frontmostApplication.map(Self.info)
  }

  func runningApps() -> [ScriptAppInfo] {
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    // Most recently active first: the frontmost app leads.
    let front = NSWorkspace.shared.frontmostApplication
    return (apps.filter { $0 == front } + apps.filter { $0 != front }).map(Self.info)
  }

  func screens() -> [ScreenInfo] { Screens.current() }

  func setFrame(_ frame: CGRect, of handle: WindowHandle) -> Bool {
    window(handle)?.setFrame(frame) ?? false
  }

  func focus(_ handle: WindowHandle) -> Bool {
    guard let window = window(handle) else { return false }
    window.focus()
    return true
  }

  func perform(_ action: Action, on handle: WindowHandle?) -> Bool {
    runner?.perform(action, on: handle.flatMap(window), chainKey: "js:\(action.hashValue)") ?? false
  }

  func runShell(_ command: String, wait: Bool, path: String?) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.currentDirectoryURL = URL(fileURLWithPath: NSString(string: path ?? "~").expandingTildeInPath)
    let pipe = Pipe()
    process.standardOutput = pipe
    do { try process.run() } catch { return nil }
    guard wait else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(data: data, encoding: .utf8)
  }

  func log(_ message: String) {
    SlatedLog.script.info("\(message, privacy: .public)")
  }

  private static func info(_ app: NSRunningApplication) -> ScriptAppInfo {
    ScriptAppInfo(pid: app.processIdentifier, name: app.localizedName ?? "", bundleID: app.bundleIdentifier)
  }
}
