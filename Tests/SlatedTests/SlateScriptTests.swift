import Foundation
import SlatedCore
import SlatedScript

// MARK: - Fake host

/// A pretend Mac: a landscape main display with a portrait display to its left, Safari with two
/// windows and Terminal with one. Records everything scripts ask it to do.
@MainActor
final class FakeScriptHost: ScriptHost {
  struct Performed: Equatable {
    var action: Action
    var window: WindowHandle?
  }

  static let safariFront = WindowHandle(1)
  static let terminal = WindowHandle(2)
  static let safariBack = WindowHandle(3)
  static let safari = ScriptAppInfo(pid: 100, name: "Safari", bundleID: "com.apple.Safari")
  static let terminalApp = ScriptAppInfo(pid: 200, name: "Terminal", bundleID: "com.apple.Terminal")

  var screenList = [
    ScreenInfo(
      displayID: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
      visibleFrame: CGRect(x: 0, y: 25, width: 1920, height: 1055), isMain: true),
    ScreenInfo(
      displayID: 2, name: "Portrait", frame: CGRect(x: -1080, y: -420, width: 1080, height: 1920),
      visibleFrame: CGRect(x: -1080, y: -420, width: 1080, height: 1920), isMain: false),
  ]
  var windows: [WindowHandle: ScriptWindowInfo] = [
    safariFront: ScriptWindowInfo(
      handle: safariFront, title: "Apple", frame: CGRect(x: 100, y: 100, width: 800, height: 600), pid: 100,
      isMain: true),
    terminal: ScriptWindowInfo(
      handle: terminal, title: "zsh", frame: CGRect(x: -1000, y: 100, width: 700, height: 500), pid: 200, isMain: true),
    safariBack: ScriptWindowInfo(
      handle: safariBack, title: "Docs", frame: CGRect(x: 300, y: 200, width: 600, height: 400), pid: 100),
  ]
  var apps = [safari, terminalApp]
  var appWindows: [Int32: [WindowHandle]] = [100: [safariFront, safariBack], 200: [terminal]]
  var focused: WindowHandle? = safariFront

  var performed: [Performed] = []
  /// Runs inside `perform`, like an app that reacts to an operation synchronously.
  var onPerform: (@MainActor (Action) -> Void)?
  var focusRequests: [WindowHandle] = []
  var shellCommands: [String] = []
  var shellOptions: [(wait: Bool, path: String?)] = []
  var logs: [String] = []

  func focusedWindow() -> WindowHandle? { focused }
  func windowInfo(_ window: WindowHandle) -> ScriptWindowInfo? { windows[window] }
  func windows(ofApp pid: Int32) -> [WindowHandle] { appWindows[pid] ?? [] }
  func runningApps() -> [ScriptAppInfo] { apps }
  func screens() -> [ScreenInfo] { screenList }

  func setFrame(_ frame: CGRect, of window: WindowHandle) -> Bool {
    guard windows[window] != nil else { return false }
    windows[window]?.frame = frame
    return true
  }

  func focus(_ window: WindowHandle) -> Bool {
    focusRequests.append(window)
    focused = window
    return true
  }

  func perform(_ action: Action, on window: WindowHandle?) -> Bool {
    performed.append(Performed(action: action, window: window))
    onPerform?(action)
    return true
  }

  func runShell(_ command: String, wait: Bool, path: String?) -> String? {
    shellCommands.append(command)
    shellOptions.append((wait, path))
    return wait ? "output of \(command)" : nil
  }

  func log(_ message: String) { logs.append(message) }
}

// MARK: - Helpers

/// The harness runs tests on the main thread; the engine and host are main-actor objects.
private func onMain(_ body: @MainActor () throws -> Void) throws {
  try MainActor.assumeIsolated(body)
}

/// 1-based line of the first line in `text` containing `needle`.
private func line(of needle: String, in text: String) -> Int? {
  text.components(separatedBy: "\n").firstIndex { $0.contains(needle) }.map { $0 + 1 }
}

/// `SlateSyntax.parseOperation` is being written in parallel; until it exists, it throws.
private var operationParserReady: Bool { (try? SlateSyntax.parseOperation("undo")) != nil }

private func binding(_ result: ScriptLoadResult, _ key: String) -> ScriptBinding? {
  result.bindings.first { $0.keys.key == key }
}

private let full = Action.move(
  x: "screenOriginX", y: "screenOriginY", width: "screenSizeX", height: "screenSizeY", screen: nil)
private let pushLeft = Action.push(direction: .left, style: .none, screen: nil)
private let pushRight = Action.push(direction: .right, style: .none, screen: nil)

// MARK: - Fixtures

/// The constructs the author's ~/.slate.js uses: operations in variables, bound arrow functions that
/// branch on the screen's orientation, `win.doOperation` and `slate.operationFromString`.
private let authorStyleConfig = """
  // Create Operations
  let full = slate.operation("move", {
    "x" : "screenOriginX",
    "y" : "screenOriginY",
    "width" : "screenSizeX",
    "height" : "screenSizeY",
  });
  let topright = slate.operation("corner", {
    "direction" : "top-right",
    "width" : "screenSizeX/2",
    "height" : "screenSizeY/2",
  });
  let tophalf = slate.operation("push", {
    "direction" : "top",
    "style" : "bar-resize:screenSizeY/2"
  });
  let horizontalonethird = slate.operation("move", {
    "x": "screenOriginX",
    "y": "screenOriginY",
    "width": "screenSizeX/3",
    "height": "screenSizeY",
  });
  let verticalonethird = slate.operation("move", {
    "x": "screenOriginX",
    "y": "screenOriginY",
    "width": "screenSizeX",
    "height": "screenSizeY/3",
  });

  slate.bind("s:ctrl,shift,alt,cmd", (win) => {
      win.doOperation(full);
  });
  slate.bind("f:ctrl,shift,alt,cmd", (win) => {
      let rect = slate.screen().rect();
      let isHorizontalScreen = rect.width > rect.height;
      if (isHorizontalScreen) {
          win.doOperation(horizontalonethird);
      } else {
          win.doOperation(verticalonethird);
      }
  });
  slate.bind("w:ctrl,shift,alt,cmd", (win) => {
      win.doOperation(slate.operationFromString("push top bar-resize:screenSizeY/2"));
  });
  slate.bind("right:ctrl,shift,alt,cmd", (win) => {
      win.doOperation(slate.operationFromString("throw right resize"));
  });
  slate.bind("e:ctrl,shift,alt,cmd", topright);
  slate.bind("x:ctrl,shift,alt,cmd", tophalf, true);
  """

private let diagnosticsConfig = """
  slate.bind("a:ctrl", slate.operation("teleport", {"to": "mars"}));
  slate.bind("bogus-key:ctrl", S.op("push", {"direction": "left"}));
  S.op("move", {"x": 0, "y": 0});
  S.op("push", {"direction": "left", "colour": "red"});
  slate.bind("b:ctrl", (win) => { win.doOperation(S.op("push", {"direction": "sideways"})); });
  undefinedFunction();
  slate.bind("c:ctrl", (win) => {});
  """

// MARK: - Tests

let slateScriptTests = Suite(
  "SlateScript",
  [
    (
      "runs a config written like the author's",
      {
        try onMain {
          let host = FakeScriptHost()
          let engine = SlateScriptEngine(host: host)
          let result = engine.load(source: authorStyleConfig, path: "/tmp/author.slate.js")
          expectEqual(result.diagnostics, [])
          expectEqual(result.bindings.map(\.keys.key), ["s", "f", "w", "right", "e", "x"])
          expect(result.bindings.allSatisfy { $0.keys.modifiers == .hyper && $0.modal == nil })

          let s = try require(binding(result, "s"))
          expectEqual(s.keystroke, "s:ctrl,shift,alt,cmd")
          expectEqual(s.summary, "JavaScript function")
          expectEqual(s.file, "/tmp/author.slate.js")
          expectEqual(s.line, line(of: "slate.bind(\"s:", in: authorStyleConfig))
          expect(s.target.action == nil)
          expect(!s.repeats)

          // A bound operation object is a static action the app can run without JavaScript.
          let e = try require(binding(result, "e"))
          expectEqual(
            e.target, .action(.corner(.topRight, width: "screenSizeX/2", height: "screenSizeY/2", screen: nil)))
          let x = try require(binding(result, "x"))
          expectEqual(x.target, .action(.push(direction: .up, style: .barResize("screenSizeY/2"), screen: nil)))
          expect(x.repeats)

          // Bound functions get the focused window and act on it.
          expect(engine.invoke(s).success)
          expectEqual(host.performed.last, .init(action: full, window: FakeScriptHost.safariFront))

          // The landscape main screen gets thirds across, the portrait screen thirds down.
          let f = try require(binding(result, "f"))
          expect(engine.invoke(f).success)
          expectEqual(
            host.performed.last?.action,
            .move(x: "screenOriginX", y: "screenOriginY", width: "screenSizeX/3", height: "screenSizeY", screen: nil))
          expectEqual(host.performed.last?.window, FakeScriptHost.safariFront)
          host.focused = FakeScriptHost.terminal
          expect(engine.invoke(f).success)
          expectEqual(
            host.performed.last,
            .init(
              action: .move(
                x: "screenOriginX", y: "screenOriginY", width: "screenSizeX", height: "screenSizeY/3", screen: nil),
              window: FakeScriptHost.terminal))

          expect(engine.invoke(e).success)
          expectEqual(host.performed.last?.window, FakeScriptHost.terminal)

          let w = try require(binding(result, "w"))
          let count = host.performed.count
          let run = engine.invoke(w)
          if operationParserReady {
            expect(run.success, "\(run.diagnostics)")
            expectEqual(
              host.performed.last?.action, .push(direction: .up, style: .barResize("screenSizeY/2"), screen: nil))
          } else {
            expect(!run.success)
            expectEqual(host.performed.count, count)
            expect(run.diagnostics.contains { $0.message.contains("parseOperation") }, "\(run.diagnostics)")
          }
        }
      }
    ),
    (
      "reports JavaScript errors in bound functions without crashing",
      {
        try onMain {
          let host = FakeScriptHost()
          let engine = SlateScriptEngine(host: host)
          let result = engine.load(source: authorStyleConfig, path: "/tmp/author.slate.js")
          host.focused = nil
          let run = engine.invoke(try require(binding(result, "s")))
          expect(!run.success)
          let error = try require(run.diagnostics.first)
          expectEqual(error.severity, .error)
          expect(error.message.contains("TypeError"), error.message)
          expectEqual(error.file, "/tmp/author.slate.js")
          expectEqual(error.line, line(of: "win.doOperation(full)", in: authorStyleConfig))
          expectEqual(host.performed, [])
          // Errors at run time don't leak into the load result.
          expectEqual(engine.result.diagnostics, [])
        }
      }
    ),
    (
      "defines slate, S and Slate's short aliases",
      {
        try onMain {
          let host = FakeScriptHost()
          let engine = SlateScriptEngine(host: host)
          let result = engine.load(
            source: """
              const names = ["operation", "op", "operationFromString", "opstr", "bind", "bnd", "bindAll", "bnda",
                "config", "cfg", "configAll", "cfga", "layout", "lay", "default", "def", "source", "src", "log",
                "shell", "sh", "doOperation", "doop", "on", "window", "app", "screen", "eachApp", "eapp",
                "eachScreen", "escreen", "screenForRef", "screenr", "screenCount", "screenc", "isRectOffScreen",
                "rectoff", "isPointOffScreen", "pntoff", "windowUnderPoint", "wup", "screenUnderPoint", "sup"];
              slate.log("missing:" + names.filter((n) => typeof S[n] !== "function" || S[n] !== slate[n]).join(","));
              slate.log([S === slate, window.slate === slate, typeof S.info.screenCount, typeof _.each].join(" "));
              const op = S.op("push", {"direction": "left"});
              slate.log([op.name, typeof op.run, typeof op.dup, String(op)].join(" "));
              const win = slate.window();
              const methods = ["title", "topLeft", "tl", "size", "rect", "pid", "focus", "isMinimizedOrHidden",
                "hidden", "isMain", "main", "isMovable", "movable", "isResizable", "resizable", "move", "resize",
                "doOperation", "doop", "screen", "app"];
              slate.log("window:" + methods.filter((m) => typeof win[m] !== "function").join(","));
              const app = slate.app();
              slate.log("app:" + ["pid", "name", "eachWindow", "ewindow", "mainWindow", "mwindow"]
                .filter((m) => typeof app[m] !== "function").join(","));
              const screen = slate.screen();
              slate.log("screen:" + ["id", "rect", "visibleRect", "vrect", "isMain", "main"]
                .filter((m) => typeof screen[m] !== "function").join(","));
              slate.log(_.map([1, 2, 3], (n) => n * 2).join(",") + " " + _.keys({a: 1, b: 2}).join(","));
              """)
          expectEqual(result.diagnostics, [])
          expectEqual(
            host.logs,
            [
              "missing:", "true true function function", "push function function [SlateOperation push]", "window:",
              "app:", "screen:", "2,4,6 a,b",
            ])
        }
      }
    ),
    (
      "window objects read and change the window",
      {
        try onMain {
          let host = FakeScriptHost()
          let engine = SlateScriptEngine(host: host)
          let result = engine.load(
            source: """
              slate.bind("1:ctrl", (win) => {
                const r = win.rect(), tl = win.topLeft(), s = win.size();
                slate.log([win.title(), r.x, r.y, r.width, r.height, tl.x, tl.y, s.width, s.height].join(" "));
                slate.log([win.pid(), win.isMain(), win.main(), win.isMovable(), win.isResizable(),
                  win.isMinimizedOrHidden(), win.hidden()].join(" "));
                slate.log([win.screen().id(), win.app().name(), win.app().pid(), slate.window().title(),
                  slate.app().name()].join(" "));
                slate.log([win.move({"x": 10, "y": 20}), win.resize({"width": 300, "height": 200}),
                  JSON.stringify(win.rect())].join(" "));
                slate.log([win.doOperation("push", {"direction": "left"}),
                  win.doop(S.op("nudge", {"x": "+10%"}))].join(" "));
                slate.log(String(win.focus()));
              });
              """)
          expectEqual(result.diagnostics, [])
          let run = engine.invoke(try require(result.bindings.first))
          expect(run.success, "\(run.diagnostics)")
          expectEqual(
            host.logs,
            [
              "Apple 100 100 800 600 100 100 800 600",
              "100 true true true true false false",
              // Screens are numbered left to right: the portrait screen is 0, the main screen 1.
              "1 Safari 100 Apple Safari",
              #"true true {"x":10,"y":20,"width":300,"height":200}"#,
              "true true",
              "true",
            ])
          expectEqual(host.windows[FakeScriptHost.safariFront]?.frame, CGRect(x: 10, y: 20, width: 300, height: 200))
          expectEqual(
            host.performed,
            [
              .init(action: pushLeft, window: FakeScriptHost.safariFront),
              .init(action: .nudge(x: "+10%", y: "+0"), window: FakeScriptHost.safariFront),
            ])
          expectEqual(host.focusRequests, [FakeScriptHost.safariFront])
        }
      }
    ),
    (
      "app objects list windows and run operations on them",
      {
        try onMain {
          let host = FakeScriptHost()
          let engine = SlateScriptEngine(host: host)
          let result = engine.load(
            source: """
              slate.eachApp((app) => {
                const titles = [];
                app.eachWindow((win) => titles.push(win.title()));
                slate.log(app.name() + ": " + titles.join(", ") + " (main: " + app.mainWindow().title() + ")");
              });
              slate.app().eachWindow(S.op("push", {"direction": "right"}));
              """)
          expectEqual(result.diagnostics, [])
          expectEqual(host.logs, ["Safari: Apple, Docs (main: Apple)", "Terminal: zsh (main: zsh)"])
          expectEqual(
            host.performed,
            [
              .init(action: pushRight, window: FakeScriptHost.safariFront),
              .init(action: pushRight, window: FakeScriptHost.safariBack),
            ])
        }
      }
    ),
    (
      "screen objects and screen queries",
      {
        try onMain {
          let host = FakeScriptHost()
          let engine = SlateScriptEngine(host: host)
          let result = engine.load(
            source: """
              slate.log(String(slate.screenCount()));
              slate.eachScreen((screen) => {
                const r = screen.rect(), v = screen.visibleRect();
                slate.log([screen.id(), screen.isMain(), r.width > r.height ? "landscape" : "portrait", v.y,
                  v.height].join(" "));
              });
              slate.log([S.screenForRef("0").id(), S.screenForRef(1).isMain(), slate.screen().id()].join(" "));
              slate.log([S.isPointOffScreen({"x": 5000, "y": 5000}), S.isPointOffScreen({"x": 10, "y": 10}),
                S.isRectOffScreen({"x": 1800, "y": 10, "width": 300, "height": 100}),
                S.isRectOffScreen({"x": 10, "y": 30, "width": 100, "height": 100})].join(" "));
              slate.log([S.screenUnderPoint({"x": -500, "y": 0}).id(),
                S.windowUnderPoint({"x": 150, "y": 150}).title()].join(" "));
              slate.log(JSON.stringify(slate.screen().rect()));
              """)
          expectEqual(result.diagnostics, [])
          expectEqual(
            host.logs,
            [
              "2",
              "0 false portrait -420 1920",
              "1 true landscape 25 1055",
              "0 true 1",
              "true false true false",
              "0 Apple",
              #"{"x":0,"y":0,"width":1920,"height":1080}"#,
            ])

          // With orderScreensLeftToRight off, screens use the OS order (main first).
          host.logs = []
          let osOrder = engine.load(
            source: """
              S.cfg("orderScreensLeftToRight", false);
              slate.log([slate.screen().id(), S.screenForRef("0").isMain()].join(" "));
              """)
          expectEqual(osOrder.diagnostics, [])
          expectEqual(host.logs, ["0 true"])
        }
      }
    ),
    (
      "collects config values and resolves repeat flags",
      {
        try onMain {
          let host = FakeScriptHost()
          let engine = SlateScriptEngine(host: host)
          let result = engine.load(
            source: """
              slate.configAll({"defaultToCurrentScreen": true, "secondsBetweenRepeat": 0.1});
              S.cfg("windowHintsIgnoreHiddenWindows", ["a", "b"]);
              S.cfg("nudgePercentOf", () => "windowSize");
              slate.bind("right:ctrl", slate.operation("resize", {"width": "+10%", "height": "+0"}));
              slate.bind("p:ctrl", slate.operation("push", {"direction": "left"}));
              slate.bind("u:ctrl", slate.operation("undo"));
              slate.bind("o:ctrl", (win) => {}, "true");
              slate.bindAll({"y:ctrl": [S.op("undo"), true], "z:ctrl": S.op("hint")});
              S.cfg("repeatOnHoldOps", "resize,nudge,push");
              S.cfg("bogus", {});
              """)
          expectEqual(result.diagnostics.map(\.severity), [.error])
          expectEqual(result.diagnostics.first?.line, 10)
          expectEqual(result.settings["defaultToCurrentScreen"], .bool(true))
          expectEqual(result.settings["secondsBetweenRepeat"], .number(0.1))
          expectEqual(result.settings["windowHintsIgnoreHiddenWindows"], .string("a;b"))
          expectEqual(result.settings.nudgePercentOf, "windowSize")
          expectEqual(engine.evaluatedSettings().nudgePercentOf, "windowSize")
          // Repeat flags use the final settings, so a later repeatOnHoldOps still applies.
          expectEqual(result.bindings.map(\.keys.key), ["right", "p", "u", "o", "y", "z"])
          expectEqual(result.bindings.map(\.repeats), [true, true, false, true, true, false])
          expectEqual(binding(result, "z")?.target, .action(.hint(characters: nil)))
        }
      }
    ),
    (
      "collects layouts and defaults, including JavaScript steps",
      {
        try onMain {
          let host = FakeScriptHost()
          let engine = SlateScriptEngine(host: host)
          let result = engine.load(
            source: """
              const full = S.op("move", {"x": "screenOriginX", "y": "screenOriginY", "width": "screenSizeX",
                "height": "screenSizeY"});
              const work = S.lay("work", {
                "_before_": {"operations": [S.op("hide", {"app": ["Mail"]})]},
                "Safari": {"operations": [full, (win) => win.doOperation(S.op("push", {"direction": "right"}))],
                  "ignore-fail": true, "repeat": true, "title-order": ["Apple"]},
                "Terminal": {"operations": full, "main-first": true},
                "_after_": {"operations": S.op("focus", {"app": "Safari"})},
              });
              S.lay("simple", {"Terminal": {"operations": [full]}});
              S.def(2, work);
              S.def(["1920x1080", "1080x1920"], (win) => slate.log("default ran on " + win.title()));
              S.def(1, S.op("layout", {"name": "simple"}));
              S.bnd("l:ctrl", S.op("layout", {"name": work}));
              """)
          expectEqual(result.diagnostics, [])
          expectEqual(result.layouts.map(\.name), ["work", "simple"])
          let work = try require(engine.layout(named: "work"))
          expectEqual(work.before, [.action(.hide(.apps(["Mail"])))])
          expectEqual(work.after, [.action(.focusApp("Safari"))])
          expectEqual(work.apps.map(\.app), ["Safari", "Terminal"])
          expectEqual(work.apps[0].operations.first, .action(full))
          expect(work.apps[0].options.ignoreFail && work.apps[0].options.repeat)
          expectEqual(work.apps[0].options.titleOrder, ["Apple"])
          expectEqual(work.apps[1].operations, [.action(full)])
          expect(work.apps[1].options.mainFirst)
          expect(work.staticLayout == nil)
          expectEqual(
            engine.layout(named: "simple")?.staticLayout,
            Layout(name: "simple", apps: [LayoutApp(app: "Terminal", operations: [full])]))
          expectEqual(result.bindings.first?.target, .action(.layout(name: "work")))

          // The app runs JavaScript layout steps through the engine, one window at a time.
          let step = try require(work.apps[0].operations.last)
          expect(engine.run(step, on: FakeScriptHost.safariBack).success)
          expectEqual(host.performed.last, .init(action: pushRight, window: FakeScriptHost.safariBack))

          expectEqual(result.defaults.count, 3)
          expectEqual(result.defaults[0], ScriptDefault(condition: .count(2), target: .name("work")))
          expectEqual(result.defaults[1].condition, .resolutions(["1080x1920", "1920x1080"]))
          expectEqual(result.defaults[2].screenDefault, ScreenDefault(target: "simple", condition: .count(1)))
          guard case .callback(let id) = result.defaults[1].target else {
            expect(false, "expected a callback default")
            return
          }
          expect(engine.run(.callback(id), on: FakeScriptHost.terminal).success)
          expectEqual(host.logs, ["default ran on zsh"])
        }
      }
    ),
    (
      "records which events have handlers, for the import to list, without running them",
      {
        try onMain {
          let host = FakeScriptHost()
          let engine = SlateScriptEngine(host: host)
          let result = engine.load(
            source: """
              slate.on("windowFocused", (event, win) => slate.log(event + " " + win.title()));
              slate.on("appActivated", (event, app) => slate.log(event + " " + app.name()));
              slate.on("windowMoved", (event, app) => slate.log(event + " " + app.name()));
              slate.on("screenConfigurationChanged", (event, payload) => slate.log(event + " " + typeof payload));
              slate.on("bogus", () => {});
              """)
          expectEqual(result.events, [.windowFocused, .appActivated, .windowMoved, .screenConfigurationChanged])
          expectEqual(result.diagnostics.map(\.line), [5])
          expectEqual(host.logs, [])
        }
      }
    ),
    (
      "operations: dup, chains, sequences and computed parameters",
      {
        try onMain {
          let host = FakeScriptHost()
          let engine = SlateScriptEngine(host: host)
          let result = engine.load(
            source: """
              const corner = S.op("corner", {"direction": "top-left", "width": "screenSizeX/2",
                "height": "screenSizeY/2"});
              const left = S.op("push", {"direction": "left"});
              const right = S.op("push", {"direction": "right"});
              S.bnd("1:ctrl", S.op("chain", {"operations": [left, right]}));
              S.bnd("2:ctrl", S.op("chain", {"operations": [left, (win) => slate.log("step two on " + win.title())]}));
              S.bnd("3:ctrl", S.op("sequence", {"operations": [left, [right, {"op": "nudge", "x": "+5"}]]}));
              S.bnd("4:ctrl", S.op("move", {"x": () => (slate.window().title() === "Apple" ? 1 : 2), "y": 0,
                "width": 10, "height": 10}));
              S.bnd("5:ctrl", corner.dup({"width": "screenSizeX*2/3"}));
              S.bnd("6:ctrl", S.op("grid", {"padding": "4", "grids": {"0": {"width": "6", "height": 6}}}));
              S.bnd("7:ctrl", S.op("shell", {"command": "/usr/bin/true", "wait": "true"}));
              slate.log(corner.dup({}).name);
              left.run();
              """)
          expectEqual(result.diagnostics, [])
          expectEqual(host.logs, ["corner"])
          expectEqual(host.performed, [.init(action: pushLeft, window: FakeScriptHost.safariFront)])
          host.performed = []

          expectEqual(binding(result, "1")?.target, .action(.chain([pushLeft, pushRight])))
          expectEqual(
            binding(result, "3")?.target,
            .action(
              .sequence([
                SequenceStep(pushLeft), SequenceStep(pushRight),
                SequenceStep(.nudge(x: "+5", y: "+0"), keepWindow: true),
              ])))
          expectEqual(
            binding(result, "5")?.target,
            .action(.corner(.topLeft, width: "screenSizeX*2/3", height: "screenSizeY/2", screen: nil)))
          expectEqual(
            binding(result, "6")?.target,
            .action(.grid(padding: 4, grids: [GridScreen(screen: "0", width: 6, height: 6)])))
          expectEqual(binding(result, "7")?.target, .action(.shell(command: "/usr/bin/true", wait: true, path: nil)))

          // A chain with a function cycles through its steps in the engine.
          let chain = try require(binding(result, "2"))
          expectEqual(chain.summary, "chain (with JavaScript)")
          for _ in 0..<3 { expect(engine.invoke(chain).success) }
          expectEqual(host.logs, ["corner", "step two on Apple"])
          expectEqual(host.performed.map(\.action), [pushLeft, pushLeft])

          // Function parameters are evaluated each time the operation runs.
          host.performed = []
          let computed = try require(binding(result, "4"))
          expect(engine.invoke(computed).success)
          host.focused = FakeScriptHost.terminal
          expect(engine.invoke(computed).success)
          expectEqual(
            host.performed,
            [
              .init(
                action: .move(x: "1", y: "0", width: "10", height: "10", screen: nil),
                window: FakeScriptHost.safariFront),
              .init(
                action: .move(x: "2", y: "0", width: "10", height: "10", screen: nil), window: FakeScriptHost.terminal),
            ])
        }
      }
    ),
    (
      "turns mistakes into diagnostics with line numbers",
      {
        try onMain {
          let host = FakeScriptHost()
          let engine = SlateScriptEngine(host: host)
          let result = engine.load(source: diagnosticsConfig, path: "/tmp/broken.slate.js")
          // One message per mistake: the failed operation on line 1, not also the bind that got nothing.
          let found = result.diagnostics.map { "\($0.severity) \($0.line ?? 0)" }
          expectEqual(found, ["error 1", "error 2", "error 3", "warning 4", "error 6"])
          let messages = result.diagnostics.map(\.message)
          expect(messages[0].contains("Unknown operation \"teleport\""), messages[0])
          expect(messages[1].contains("bogus-key"), messages[1])
          expect(messages[2].contains("needs \"width\""), messages[2])
          expect(messages[3].contains("colour"), messages[3])
          expect(messages[4].contains("undefinedFunction"), messages[4])
          expect(result.diagnostics.allSatisfy { $0.file == "/tmp/broken.slate.js" })
          expect(result.hasErrors)
          // Everything before the exception still counts; nothing after it ran.
          expectEqual(result.bindings.map(\.keys.key), ["b"])

          let run = engine.invoke(try require(result.bindings.first))
          expect(!run.success)
          expectEqual(run.diagnostics.map(\.line), [5])
          expect(run.diagnostics.first?.message.contains("sideways") == true, "\(run.diagnostics)")

          let syntax = engine.load(source: "let x = ;\n", path: "/tmp/syntax.js")
          expectEqual(syntax.diagnostics.map(\.line), [1])
          expect(syntax.diagnostics.first?.message.contains("SyntaxError") == true, "\(syntax.diagnostics)")

          let missing = engine.load(path: "/nonexistent/slated-test/.slate.js")
          expect(missing.hasErrors)
          expect(missing.bindings.isEmpty)
        }
      }
    ),
    (
      "exceptions in callbacks propagate like in JavaScript and are reported once",
      {
        try onMain {
          let host = FakeScriptHost()
          let engine = SlateScriptEngine(host: host)
          let result = engine.load(
            source: """
              try {
                slate.app().eachWindow((win) => { throw new Error("stop at " + win.title()); });
              } catch (e) { slate.log("caught " + e.message); }
              slate.bind("k:ctrl", (win) => { slate.bind("j:ctrl", S.op("undo")); });
              slate.app().eachWindow((win) => { null.boom; });
              slate.log("unreachable");
              """)
          expectEqual(host.logs, ["caught stop at Apple"])
          expectEqual(result.diagnostics.map(\.line), [5])
          expect(result.diagnostics.first?.message.contains("TypeError") == true, "\(result.diagnostics)")

          // Bindings can't be added after loading.
          let run = engine.invoke(try require(result.bindings.first))
          expect(run.success)
          expectEqual(run.diagnostics.map(\.severity), [.warning])
          expectEqual(engine.result.bindings.count, 1)
        }
      }
    ),
    (
      "hostile values become diagnostics, never crashes",
      {
        try onMain {
          let host = FakeScriptHost()
          let engine = SlateScriptEngine(host: host)
          let result = engine.load(
            source: """
              S.op("move", {"x": 1e21, "y": 0, "width": 1, "height": 1});
              S.op("move", {"x": NaN, "y": 0, "width": 1, "height": 1});
              slate.log(String(S.screenForRef(Infinity)));
              slate.log(String(new (slate.window().constructor)(NaN).title()));
              const sparse = [];
              sparse.length = 1e9;
              S.op("chain", {"operations": sparse});
              slate.bind("1:ctrl", (win) => {
                win.move({"x": Infinity, "y": 0});
                win.move({"x": 1e300, "y": -1e300});
                slate.log(JSON.stringify(win.topLeft()));
              });
              function recurse(win) { win.doOperation(recurse); }
              slate.bind("2:ctrl", recurse);
              """)
          expectEqual(result.diagnostics.map(\.line), [1, 2, 3, 7])
          expectEqual(host.logs, ["undefined", "undefined"])
          let run = engine.invoke(try require(binding(result, "1")))
          expectEqual(run.diagnostics.map(\.line), [9])
          expectEqual(host.logs.last, #"{"x":1000000000000000,"y":-1000000000000000}"#)
          // Runaway recursion through native code ends in a JavaScript RangeError.
          let recursion = engine.invoke(try require(binding(result, "2")))
          expect(!recursion.success)
          expect(recursion.diagnostics.contains { $0.message.contains("RangeError") }, "\(recursion.diagnostics)")
        }
      }
    ),
    (
      "refuses to reload while a script is running",
      {
        try onMain {
          let host = FakeScriptHost()
          let engine = SlateScriptEngine(host: host)
          var nested: ScriptLoadResult?
          host.onPerform = { [weak engine] _ in nested = engine?.load(source: "slate.log('reloaded');") }
          let result = engine.load(
            source: """
              slate.bind("r:ctrl", (win) => {
                win.doOperation(S.op("relaunch"));
                slate.log("still running");
              });
              """)
          expect(engine.invoke(try require(result.bindings.first)).success)
          expect(nested?.hasErrors == true)
          expectEqual(host.logs, ["still running"])
          expectEqual(engine.result.bindings.count, 1)
        }
      }
    ),
    (
      "source loads other files into the same config",
      {
        try onMain {
          let host = FakeScriptHost()
          let files = [
            "/tmp/slated/extra.js": "slate.bind(\"9:ctrl\", S.op(\"push\", {\"direction\": \"up\"}));\nnope();\n",
            "/tmp/slated/main.js": """
            slate.source("/tmp/slated/extra.js");
            slate.source("slated-test-missing.js");
            slate.bind("8:ctrl", S.op("undo"));
            """,
          ]
          let engine = SlateScriptEngine(host: host, readFile: { files[$0] })
          let result = engine.load(path: "/tmp/slated/main.js")
          expectEqual(result.bindings.map(\.keys.key), ["9", "8"])
          expectEqual(result.bindings.first?.file, "/tmp/slated/extra.js")
          expectEqual(result.sourcedFiles, ["/tmp/slated/extra.js"])
          expectEqual(result.diagnostics.map(\.severity), [.error, .warning])
          expectEqual(result.diagnostics.first?.file, "/tmp/slated/extra.js")
          expectEqual(result.diagnostics.first?.line, 2)
          expectEqual(result.diagnostics.last?.file, "/tmp/slated/main.js")
          expectEqual(result.diagnostics.last?.line, 2)
        }
      }
    ),
    (
      "log, shell and doOperation reach the host",
      {
        try onMain {
          let host = FakeScriptHost()
          let engine = SlateScriptEngine(host: host)
          let result = engine.load(
            source: """
              slate.log("hello", 42, {"a": 1}, null);
              slate.log("got " + slate.shell("echo hi", true, "~/tmp"));
              S.sh("open -a Safari");
              slate.doOperation("focus", {"app": "Terminal"});
              S.shell(42);
              """)
          expectEqual(result.diagnostics.map(\.line), [5])
          expectEqual(host.logs, ["hello 42 [object Object] ", "got output of echo hi"])
          expectEqual(host.shellCommands, ["echo hi", "open -a Safari"])
          expectEqual(host.shellOptions.map(\.wait), [true, false])
          expectEqual(host.shellOptions.first?.path, NSHomeDirectory() + "/tmp")
          expectEqual(host.performed, [.init(action: .focusApp("Terminal"), window: FakeScriptHost.safariFront)])
        }
      }
    ),
    (
      "operationFromString uses Slate's operation syntax",
      {
        try onMain {
          let host = FakeScriptHost()
          let engine = SlateScriptEngine(host: host)
          let result = engine.load(
            source: """
              S.bnd("t:ctrl", S.opstr("push top bar-resize:screenSizeY/2"));
              S.bnd("u:ctrl", slate.operationFromString("undo"));
              """)
          if operationParserReady {
            expectEqual(result.diagnostics, [])
            expectEqual(
              result.bindings.map(\.target),
              [.action(.push(direction: .up, style: .barResize("screenSizeY/2"), screen: nil)), .action(.undo)])
          } else {
            // Until the parser lands, each call says why and nothing is bound.
            expectEqual(result.bindings.count, 0)
            expectEqual(result.diagnostics.map(\.line), [1, 2])
            expect(
              result.diagnostics.allSatisfy { $0.message.contains("Not implemented yet: SlateSyntax.parseOperation") })
          }
        }
      }
    ),
    (
      "loads ~/.slate.js",
      {
        let path = (NSHomeDirectory() as NSString).appendingPathComponent(".slate.js")
        guard FileManager.default.fileExists(atPath: path) else { return }
        try onMain {
          let host = FakeScriptHost()
          let engine = SlateScriptEngine(host: host)
          let result = engine.load(path: path)
          expectEqual(result.bindings.count, 21)
          expect(!result.hasErrors, "\(result.diagnostics)")
          // Every bound function runs cleanly on both screens (operationFromString aside, until its
          // parser lands).
          for focused in [FakeScriptHost.safariFront, FakeScriptHost.terminal] {
            host.focused = focused
            for binding in result.bindings {
              let run = engine.invoke(binding)
              let parserPending = run.diagnostics.allSatisfy { $0.message.contains("SlateSyntax.parseOperation") }
              expect(
                run.success || (!operationParserReady && parserPending), "\(binding.keystroke): \(run.diagnostics)")
            }
          }
        }
      }
    ),
  ])
