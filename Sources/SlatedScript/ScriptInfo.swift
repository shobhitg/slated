import Foundation
import JavaScriptCore
import SlatedCore

// The query half of the API: `slate.window()`, `slate.screen()`, `slate.eachApp`…, and the methods of
// window, app and screen objects. Objects hold only a handle (window), pid (app) or screen ID; every
// method asks the host again, so values are always current.
extension SlateScriptEngine {
  func installInfoAPI(on native: JSValue) {
    define(native, "currentWindow") { engine, _ in engine.currentWindow().flatMap(engine.windowObject) }
    define(native, "currentApp") { engine, _ in engine.currentApp().flatMap(engine.appObject) }
    define(native, "currentScreen") { engine, _ in
      engine.screenObject(containing: engine.currentWindow().flatMap(engine.host.windowInfo)?.frame)
    }
    define(native, "eachApp") { $0.nativeEachApp($1) }
    define(native, "windowUnderPoint") { $0.nativeWindowUnderPoint($1) }
    define(native, "screenUnderPoint") { $0.nativeScreenUnderPoint($1) }
    define(native, "isRectOffScreen") { $0.nativeIsRectOffScreen($1) }
    define(native, "isPointOffScreen") { $0.nativeIsPointOffScreen($1) }
    define(native, "screenForRef") { $0.nativeScreenForRef($1) }
    define(native, "screenCount") { engine, _ in engine.host.screens().count }
    define(native, "eachScreen") { $0.nativeEachScreen($1) }

    define(native, "windowTitle") { engine, args in engine.windowInfo(args[0])?.title }
    define(native, "windowTopLeft") { engine, args in
      engine.windowInfo(args[0]).flatMap { engine.object(["x": integer($0.frame.minX), "y": integer($0.frame.minY)]) }
    }
    define(native, "windowSize") { engine, args in
      engine.windowInfo(args[0]).flatMap {
        engine.object(["width": integer($0.frame.width), "height": integer($0.frame.height)])
      }
    }
    define(native, "windowRect") { engine, args in engine.windowInfo(args[0]).flatMap { engine.rectObject($0.frame) } }
    define(native, "windowPid") { engine, args in engine.windowInfo(args[0]).map { Int($0.pid) } }
    define(native, "windowFocus") { engine, args in
      engine.windowHandle(args[0]).map { engine.host.focus($0) } ?? false
    }
    define(native, "windowFlag") { engine, args in
      guard let info = engine.windowInfo(args[0]) else { return false }
      switch args.string(1) {
      case "minimizedOrHidden": return info.isMinimizedOrHidden
      case "main": return info.isMain
      case "movable": return info.isMovable
      case "resizable": return info.isResizable
      default: return false
      }
    }
    define(native, "windowMove") { $0.nativeWindowMove($1) }
    define(native, "windowResize") { $0.nativeWindowResize($1) }
    define(native, "windowScreen") { engine, args in
      engine.windowInfo(args[0]).flatMap { engine.screenObject(containing: $0.frame) }
    }
    define(native, "windowApp") { engine, args in
      engine.windowInfo(args[0]).flatMap { info in
        engine.appObject(engine.host.app(pid: info.pid) ?? ScriptAppInfo(pid: info.pid, name: ""))
      }
    }
    define(native, "windowDoOperation") { $0.nativeWindowDoOperation($1) }

    define(native, "appName") { engine, args in
      guard args[0].isNumber else { return nil }
      return engine.host.app(pid: args[0].toInt32())?.name ?? args.string(1)
    }
    define(native, "appEachWindow") { $0.nativeAppEachWindow($1) }
    define(native, "appMainWindow") { engine, args in
      guard args[0].isNumber else { return nil }
      return engine.host.mainWindow(ofApp: args[0].toInt32()).flatMap(engine.windowObject)
    }

    define(native, "screenRect") { engine, args in
      engine.screen(withID: args[0]).flatMap { engine.rectObject(engine.truthy(args[1]) ? $0.visibleFrame : $0.frame) }
    }
    define(native, "screenIsMain") { engine, args in engine.screen(withID: args[0])?.isMain ?? false }
  }

  // MARK: Wrapper objects

  func windowObject(_ handle: WindowHandle) -> JSValue? {
    classes?.window.construct(withArguments: [handle.rawValue])
  }

  func appObject(_ app: ScriptAppInfo) -> JSValue? {
    classes?.app.construct(withArguments: [Int(app.pid), app.name])
  }

  func screenObject(_ id: Int) -> JSValue? {
    classes?.screen.construct(withArguments: [id])
  }

  func rectObject(_ rect: CGRect) -> JSValue? {
    object([
      "x": integer(rect.minX), "y": integer(rect.minY), "width": integer(rect.width), "height": integer(rect.height),
    ])
  }

  func windowHandle(_ value: JSValue) -> WindowHandle? {
    intValue(value).map(WindowHandle.init(rawValue:))
  }

  func windowInfo(_ value: JSValue) -> ScriptWindowInfo? {
    windowHandle(value).flatMap { host.windowInfo($0) }
  }

  /// `slate.app()`: the current window's app, else the frontmost app.
  func currentApp() -> ScriptAppInfo? {
    if let window = currentWindow(), let info = host.windowInfo(window), let app = host.app(pid: info.pid) {
      return app
    }
    return host.frontmostApp()
  }

  // MARK: Screens

  /// Screens numbered the way scripts see them: left to right unless `orderScreensLeftToRight` is off.
  func orderedScreens() -> [ScreenInfo] {
    let screens = host.screens()
    return settings.orderScreensLeftToRight ? screens.orderedLeftToRight() : screens
  }

  func screen(withID value: JSValue) -> ScreenInfo? {
    guard let id = intValue(value) else { return nil }
    let screens = orderedScreens()
    return screens.indices.contains(id) ? screens[id] : nil
  }

  func screenObject(for screen: ScreenInfo) -> JSValue? {
    orderedScreens().firstIndex { $0.displayID == screen.displayID }.flatMap(screenObject)
  }

  /// The screen holding most of `frame`; the main screen when there is no frame.
  func screenObject(containing frame: CGRect?) -> JSValue? {
    let screens = host.screens()
    let screen = frame.flatMap { screens.screen(containing: $0) } ?? screens.first { $0.isMain } ?? screens.first
    return screen.flatMap { screenObject(for: $0) }
  }

  private static func isOnScreen(_ point: CGPoint, _ screens: [ScreenInfo]) -> Bool {
    // Edges count as on screen, as in Slate.
    screens.contains {
      point.x >= $0.frame.minX && point.x <= $0.frame.maxX && point.y >= $0.frame.minY && point.y <= $0.frame.maxY
    }
  }

  func nativeEachScreen(_ args: Arguments) -> Any? {
    guard isFunction(args[0]) else {
      report(.error, "slate.eachScreen needs a function, got \(describe(args[0])).")
      return nil
    }
    for id in orderedScreens().indices {
      guard let screen = screenObject(id), !callJS(args[0], [screen]).threw else { break }
    }
    return nil
  }

  func nativeScreenForRef(_ args: Arguments) -> Any? {
    let value = args[0]
    let text: String
    if let number = intValue(value) {
      text = String(number)
    } else if let string = args.string(0) {
      text = string
    } else {
      report(
        .error,
        "slate.screenForRef needs a screen reference like \"0\", \"right\" or \"1920x1080\", got \(describe(value)).")
      return nil
    }
    guard let ref = ScreenRef(slate: text) else {
      report(
        .error,
        "\"\(text)\" isn't a screen reference. Use an index (\"0\"), a direction (\"right\") or a resolution (\"1920x1080\")."
      )
      return nil
    }
    let frame = currentWindow().flatMap(host.windowInfo)?.frame ?? .zero
    let screen = ScreenResolver.screen(for: ref, windowFrame: frame, screens: host.screens(), settings: settings)
    return screen.flatMap { screenObject(for: $0) }
  }

  func nativeWindowUnderPoint(_ args: Arguments) -> Any? {
    let window = currentWindow().flatMap { host.windowInfo($0) }
    guard let (x, y) = numbers(args[0], ("x", "y"), window: window, for: "slate.windowUnderPoint") else { return nil }
    return host.window(at: CGPoint(x: x, y: y)).flatMap { windowObject($0) }
  }

  func nativeScreenUnderPoint(_ args: Arguments) -> Any? {
    guard
      let (x, y) = numbers(
        args[0], ("x", "y"), window: currentWindow().flatMap(host.windowInfo), for: "slate.screenUnderPoint")
    else { return nil }
    let point = CGPoint(x: x, y: y)
    let screens = host.screens()
    return screens.first { Self.isOnScreen(point, [$0]) }.flatMap { screenObject(for: $0) }
  }

  func nativeIsPointOffScreen(_ args: Arguments) -> Any? {
    guard
      let (x, y) = numbers(
        args[0], ("x", "y"), window: currentWindow().flatMap(host.windowInfo), for: "slate.isPointOffScreen")
    else { return false }
    return !Self.isOnScreen(CGPoint(x: x, y: y), host.screens())
  }

  func nativeIsRectOffScreen(_ args: Arguments) -> Any? {
    let window = currentWindow().flatMap(host.windowInfo)
    guard let (x, y) = numbers(args[0], ("x", "y"), window: window, for: "slate.isRectOffScreen"),
      let (width, height) = numbers(args[0], ("width", "height"), window: window, for: "slate.isRectOffScreen")
    else { return false }
    let screens = host.screens()
    // Off screen when any corner is outside every screen.
    let corners = [
      CGPoint(x: x, y: y), CGPoint(x: x + width, y: y), CGPoint(x: x, y: y + height),
      CGPoint(x: x + width, y: y + height),
    ]
    return corners.contains { !Self.isOnScreen($0, screens) }
  }

  // MARK: Apps

  func nativeEachApp(_ args: Arguments) -> Any? {
    guard isFunction(args[0]) else {
      report(.error, "slate.eachApp needs a function, got \(describe(args[0])).")
      return nil
    }
    for app in host.runningApps() {
      guard let object = appObject(app), !callJS(args[0], [object]).threw else { break }
    }
    return nil
  }

  func nativeAppEachWindow(_ args: Arguments) -> Any? {
    guard args[0].isNumber else { return nil }
    let windows = host.windows(ofApp: args[0].toInt32())
    guard let operation = operationObject(args[1], for: "app.eachWindow") else { return nil }
    for window in windows {
      runOperation(operation, on: window)
      if shouldStop { break }
    }
    return nil
  }

  // MARK: Windows

  func nativeWindowMove(_ args: Arguments) -> Any? {
    guard let info = windowInfo(args[0]),
      let (x, y) = numbers(args[1], ("x", "y"), window: info, for: "win.move")
    else { return false }
    return host.setFrame(CGRect(origin: CGPoint(x: x, y: y), size: info.frame.size), of: info.handle)
  }

  func nativeWindowResize(_ args: Arguments) -> Any? {
    guard let info = windowInfo(args[0]),
      let (width, height) = numbers(args[1], ("width", "height"), window: info, for: "win.resize")
    else { return false }
    return host.setFrame(CGRect(origin: info.frame.origin, size: CGSize(width: width, height: height)), of: info.handle)
  }

  func nativeWindowDoOperation(_ args: Arguments) -> Any? {
    guard let handle = windowHandle(args[0]),
      let operation = operationArgument(args[1], params: args[2], for: "win.doOperation")
    else { return false }
    return runOperation(operation, on: handle)
  }

  // MARK: Points and sizes

  /// Reads two numbers from an object like `{x: 10, y: "screenOriginY+20"}`: numbers, or Slate
  /// expressions evaluated against `window` and its screen (or the object's `screen` reference).
  func numbers(_ value: JSValue, _ keys: (String, String), window: ScriptWindowInfo?, for caller: String) -> (
    Double, Double
  )? {
    guard isPlainObject(value) else {
      report(.error, "\(caller) needs an object like {\(keys.0): 0, \(keys.1): 0}, got \(describe(value)).")
      return nil
    }
    var variables: [String: Double]?
    func number(_ key: String) -> Double? {
      let item = value.forProperty(key)!
      var result: Double?
      if item.isNumber {
        result = item.toDouble()
      } else if item.isString, let expression = item.toString() {
        let values = variables ?? expressionVariables(window: window, screenRef: value.forProperty("screen"))
        variables = values
        do {
          result = try SlateExpression.evaluate(expression, variables: values)
        } catch {
          report(.error, "\(caller): can't evaluate \"\(expression)\": \(error)")
          return nil
        }
      }
      guard let result, result.isFinite else {
        report(.error, "\(caller) needs \"\(key)\" as a number or an expression, got \(describe(item)).")
        return nil
      }
      return result
    }
    guard let first = number(keys.0), let second = number(keys.1) else { return nil }
    return (first, second)
  }

  /// Slate's expression variables: the screen's visible frame and the window's frame.
  private func expressionVariables(window: ScriptWindowInfo?, screenRef: JSValue?) -> [String: Double] {
    let screens = host.screens()
    let frame = window?.frame ?? .zero
    var screen = screens.screen(containing: frame)
    if let screenRef, !isNullish(screenRef) {
      let text = intValue(screenRef).map(String.init) ?? (screenRef.toString() ?? "")
      if let ref = ScreenRef(slate: text) {
        screen = ScreenResolver.screen(for: ref, windowFrame: frame, screens: screens, settings: settings) ?? screen
      }
    }
    let visible = screen?.visibleFrame ?? .zero
    func value(_ number: CGFloat) -> Double { Double(integer(number)) }
    return [
      "screenOriginX": value(visible.minX), "screenOriginY": value(visible.minY),
      "screenSizeX": value(visible.width), "screenSizeY": value(visible.height),
      "windowTopLeftX": value(frame.minX), "windowTopLeftY": value(frame.minY),
      "windowSizeX": value(frame.width), "windowSizeY": value(frame.height),
      "newWindowSizeX": value(frame.width), "newWindowSizeY": value(frame.height),
    ]
  }
}
