import Foundation

@testable import SlatedCore

// Four displays, in top-left global coordinates:
//
//               [ above: 1920×1080 at (-240, -1080) ]
//   [ portrait ][ main: 1440×900 at (0, 0)         ][ right: 2560×1440 at (1440, 0) ]
//   [ 1080×1920 at (-1080, 0)                      ]
//
// Each visible frame loses a 25-point menu bar; the main display also loses a 60-point Dock.
// OS order: main, right, above, portrait. Left to right: portrait, above, main, right.
private let main = ScreenInfo(
  displayID: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
  visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 815), isMain: true)
private let right = ScreenInfo(
  displayID: 2, name: "Right", frame: CGRect(x: 1440, y: 0, width: 2560, height: 1440),
  visibleFrame: CGRect(x: 1440, y: 25, width: 2560, height: 1415), isMain: false)
private let above = ScreenInfo(
  displayID: 3, name: "Above", frame: CGRect(x: -240, y: -1080, width: 1920, height: 1080),
  visibleFrame: CGRect(x: -240, y: -1055, width: 1920, height: 1055), isMain: false)
private let portrait = ScreenInfo(
  displayID: 4, name: "Portrait", frame: CGRect(x: -1080, y: 0, width: 1080, height: 1920),
  visibleFrame: CGRect(x: -1080, y: 25, width: 1080, height: 1895), isMain: false)
private let screens = [main, right, above, portrait]

private let onMain = CGRect(x: 100, y: 100, width: 800, height: 600)
private let onRight = CGRect(x: 2000, y: 100, width: 800, height: 600)
private let onPortrait = CGRect(x: -1000, y: 300, width: 600, height: 800)
private let onAbove = CGRect(x: 0, y: -900, width: 800, height: 600)

private func frame(
  _ operation: String, window: CGRect = onMain, settings: [String: SettingValue] = [:]
) throws -> CGRect {
  let context = WindowContext(frame: window, screens: screens, settings: SlateSettings(settings))
  return try FrameCalculator.targetFrame(for: SlateSyntax.parseOperation(operation), in: context)
}

private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
  CGRect(x: x, y: y, width: width, height: height)
}

private func resolve(_ ref: ScreenRef?, from window: CGRect = onMain, settings: [String: SettingValue] = [:])
  -> String?
{
  ScreenResolver.screen(for: ref, windowFrame: window, screens: screens, settings: SlateSettings(settings))?.name
}

let frameCalculatorTests = Suite(
  "FrameCalculator",
  [
    (
      "move evaluates expressions against the target screen's visible frame",
      {
        expectEqual(try frame("move screenOriginX;screenOriginY screenSizeX/2;screenSizeY"), rect(0, 25, 720, 815))
        expectEqual(
          try frame("move screenOriginX+screenSizeX/4;screenOriginY+screenSizeY/4 screenSizeX/2;screenSizeY/2"),
          rect(360, 228.75, 720, 407.5))
        // Screen 1, left to right, is the one above, with negative coordinates.
        expectEqual(
          try frame("move screenOriginX;screenOriginY screenSizeX/2;screenSizeY 1"), rect(-240, -1055, 960, 1055))
        // Without screenOrigin offsets, a move is relative to the main screen's origin, as in Slate.
        expectEqual(try frame("move 0;0 100;100 1"), rect(0, 0, 100, 100))
        expectEqual(
          try frame("move windowTopLeftX+10;windowTopLeftY windowSizeX;windowSizeY"), rect(110, 100, 800, 600))
        // The author's "centerpad", on the portrait screen.
        let centerpad = Action.move(
          x: "screenOriginX+screenSizeX/8", y: "screenOriginY+screenSizeY/8", width: "screenSizeX/1.3",
          height: "screenSizeY/1.3", screen: nil)
        let result = try FrameCalculator.targetFrame(
          for: centerpad, in: WindowContext(frame: onPortrait, screens: screens))
        expectEqual(result.origin, CGPoint(x: -945, y: 261.875))
        expectClose(result.width, 830.7692307692307)
        expectClose(result.height, 1457.6923076923076)
        // Expressions from JavaScript configs may contain spaces.
        let spaced = Action.move(
          x: "screenOriginX + screenSizeX / 2", y: "screenOriginY", width: "screenSizeX / 2", height: "screenSizeY",
          screen: nil)
        expectEqual(
          try FrameCalculator.targetFrame(for: spaced, in: WindowContext(frame: onMain, screens: screens)),
          rect(720, 25, 720, 815))
        // Screen -1 is the window's own screen, as in Slate.
        expectEqual(try frame("move screenOriginX;screenOriginY 10;10 -1", window: onRight), rect(1440, 25, 10, 10))
        // Window values are whole numbers, like Slate's.
        expectEqual(
          try frame(
            "move windowTopLeftX;windowTopLeftY windowSizeX;windowSizeY", window: rect(10.7, -20.5, 300.9, 200)),
          rect(10, -20, 300, 200))
      }
    ),
    (
      "the position can depend on the size the window actually took",
      {
        let action = try SlateSyntax.parseOperation(
          "move screenOriginX+screenSizeX-newWindowSizeX;screenOriginY 400;300")
        let context = WindowContext(frame: onMain, screens: screens)
        expectEqual(try FrameCalculator.targetFrame(for: action, in: context), rect(1040, 25, 400, 300))
        expectEqual(
          try FrameCalculator.targetOrigin(for: action, in: context, actualSize: CGSize(width: 500, height: 300)),
          CGPoint(x: 940, y: 25))
        // In the size expressions, newWindowSize* is still the current size.
        expectEqual(try frame("move 0;0 newWindowSizeX/2;newWindowSizeY/2"), rect(0, 0, 400, 300))
      }
    ),
    (
      "push in every direction and style",
      {
        expectEqual(try frame("push up"), rect(100, 25, 800, 600))
        expectEqual(try frame("push down"), rect(100, 240, 800, 600))
        expectEqual(try frame("push left"), rect(0, 100, 800, 600))
        expectEqual(try frame("push right"), rect(640, 100, 800, 600))
        expectEqual(try frame("push up center"), rect(320, 25, 800, 600))
        expectEqual(try frame("push down center"), rect(320, 240, 800, 600))
        expectEqual(try frame("push left center"), rect(0, 132.5, 800, 600))
        expectEqual(try frame("push right center"), rect(640, 132.5, 800, 600))
        expectEqual(try frame("push up bar"), rect(0, 25, 1440, 600))
        expectEqual(try frame("push down bar"), rect(0, 240, 1440, 600))
        expectEqual(try frame("push left bar"), rect(0, 25, 800, 815))
        expectEqual(try frame("push right bar"), rect(640, 25, 800, 815))
        expectEqual(try frame("push top bar-resize:screenSizeY/2"), rect(0, 25, 1440, 407.5))
        expectEqual(try frame("push bottom bar-resize:screenSizeY/2"), rect(0, 432.5, 1440, 407.5))
        expectEqual(try frame("push left bar-resize:screenSizeX/3"), rect(0, 25, 480, 815))
        expectEqual(try frame("push right bar-resize:screenSizeX/3"), rect(960, 25, 480, 815))
        // The bar-resize expression is one unit (Slate's string form forgot the parentheses).
        expectEqual(try frame("push down bar-resize:screenSizeY-100"), rect(0, 125, 1440, 715))
        expectEqual(try frame("push right bar-resize:screenSizeX/2+100"), rect(620, 25, 820, 815))
      }
    ),
    (
      "push onto another screen",
      {
        expectEqual(try frame("push up bar 1"), rect(-240, -1055, 1920, 600))
        expectEqual(try frame("push up bar-resize:screenSizeY/2 right"), rect(1440, 25, 2560, 707.5))
        // `none` keeps the window's x even on another screen, like Slate.
        expectEqual(try frame("push down none right"), rect(100, 840, 800, 600))
        expectEqual(try frame("push right bar-resize:screenSizeX/2", window: onPortrait), rect(-540, 25, 540, 1895))
        expectEqual(try frame("push down bar", window: onPortrait), rect(-1080, 1120, 1080, 800))
      }
    ),
    (
      "nudge by points or percentages",
      {
        expectEqual(try frame("nudge +10% +0"), rect(244, 100, 800, 600))
        expectEqual(try frame("nudge -100 +0"), rect(0, 100, 800, 600))
        expectEqual(try frame("nudge +0 -10%"), rect(100, 18.5, 800, 600))
        expectEqual(try frame("nudge +screenSizeX/10 -screenSizeY/10"), rect(244, 18.5, 800, 600))
        expectEqual(try frame("nudge 50 0"), rect(150, 100, 800, 600))
        expectEqual(
          try frame("nudge +10% +10%", settings: ["nudgePercentOf": .string("windowSize")]), rect(180, 160, 800, 600))
        // Percentages are of the window's own screen.
        expectEqual(try frame("nudge -10% +0", window: onRight), rect(1744, 100, 800, 600))
      }
    ),
    (
      "resize by percentages or points, keeping the anchor in place",
      {
        // Percentages are of the screen's visible size by default: 10% of 1440 is 144; 10% of 815 is 81.
        expectEqual(try frame("resize +10% +0"), rect(100, 100, 944, 600))
        expectEqual(try frame("resize -10% +0 bottom-right"), rect(244, 100, 656, 600))
        expectEqual(try frame("resize +0 +10% bottom-right"), rect(100, 19, 800, 681))
        expectEqual(try frame("resize +10% -100 bottom-right"), rect(-44, 200, 944, 500))
        expectEqual(try frame("resize -10% +0 top-right"), rect(244, 100, 656, 600))
        expectEqual(try frame("resize +0 -10% bottom-left"), rect(100, 181, 800, 519))
        expectEqual(try frame("resize +100 +50"), rect(100, 100, 900, 650))
        expectEqual(
          try frame("resize +10% +10%", settings: ["resizePercentOf": .string("windowSize")]), rect(100, 100, 880, 660))
        // Slated extensions: signed expressions and absolute sizes.
        expectEqual(try frame("resize +screenSizeX/10 +0"), rect(100, 100, 944, 600))
        expectEqual(try frame("resize screenSizeX/2 50%"), rect(100, 100, 720, 407))
        // An unchanged size leaves the window exactly where it is.
        let fractional = CGRect(x: 100.5, y: 100.5, width: 800, height: 600)
        expectEqual(try frame("resize +0 +0 bottom-right", window: fractional), fractional)
        // The anchor uses the size the window really took.
        let action = try SlateSyntax.parseOperation("resize +10% +0 top-right")
        expectEqual(
          try FrameCalculator.targetOrigin(
            for: action, in: WindowContext(frame: onMain, screens: screens), actualSize: CGSize(width: 900, height: 600)
          ),
          CGPoint(x: 0, y: 100))
      }
    ),
    (
      "throw to a screen, with or without resizing",
      {
        expectEqual(try frame("throw left resize", window: onRight), main.visibleFrame)
        expectEqual(try frame("throw left", window: onRight), rect(0, 25, 800, 600))
        expectEqual(try frame("throw right resize"), right.visibleFrame)
        expectEqual(try frame("throw left  resize"), portrait.visibleFrame)
        expectEqual(try frame("throw up  resize"), above.visibleFrame)
        expectEqual(try frame("throw 1  resize"), above.visibleFrame)
        expectEqual(try frame("throw 0 resize"), portrait.visibleFrame)
        expectEqual(try frame("throw 3 resize"), right.visibleFrame)
        expectEqual(try frame("throw 1 resize:screenSizeX/2;screenSizeY"), rect(-240, -1055, 960, 1055))
        expectEqual(try frame("throw 2560x1440 resize"), right.visibleFrame)
        expectEqual(try frame("throw next"), rect(1440, 25, 800, 600))
        expectEqual(try frame("throw previous"), rect(-1080, 25, 800, 600))
        expectEqual(try frame("throw down resize", window: onAbove), main.visibleFrame)
        expectEqual(
          try frame("throw 1 resize", settings: ["orderScreensLeftToRight": .bool(false)]), right.visibleFrame)
        expectEqual(
          try frame("throw ordered:1 resize", settings: ["orderScreensLeftToRight": .bool(false)]), above.visibleFrame)
      }
    ),
    (
      "a missing screen leaves the window alone unless defaultToCurrentScreen is set",
      {
        expectEqual(errorMessage { _ = try frame("throw down resize") }, "No screen matches \"down\"")
        expectEqual(errorMessage { _ = try frame("throw 9 resize") }, "No screen matches \"9\"")
        expectEqual(errorMessage { _ = try frame("throw 1680x1050 resize") }, "No screen matches \"1680x1050\"")
        let lenient: [String: SettingValue] = ["defaultToCurrentScreen": .bool(true)]
        expectEqual(try frame("throw 9 resize", settings: lenient), main.visibleFrame)
        expectEqual(try frame("throw 1680x1050 resize", settings: lenient), main.visibleFrame)
        expectEqual(try frame("move 0;0 10;10 ordered:7", settings: lenient), rect(0, 0, 10, 10))
        // Directions never fall back, as in Slate.
        expectThrows { _ = try frame("throw down resize", settings: lenient) }
        do {
          _ = try frame("push up bar 9")
          expect(false, "should have thrown")
        } catch let error as SlatedError {
          expectEqual(error, .screenNotFound("9"))
        }
      }
    ),
    (
      "corner, with and without resizing",
      {
        expectEqual(try frame("corner top-left"), rect(0, 25, 800, 600))
        expectEqual(try frame("corner top-right"), rect(640, 25, 800, 600))
        expectEqual(try frame("corner bottom-left"), rect(0, 240, 800, 600))
        expectEqual(try frame("corner bottom-right"), rect(640, 240, 800, 600))
        expectEqual(
          try frame("corner bottom-right resize:screenSizeX/2;screenSizeY/2"), rect(720, 432.5, 720, 407.5))
        expectEqual(try frame("corner top-left resize:screenSizeX/2;screenSizeY/2"), rect(0, 25, 720, 407.5))
        // The width is one unit in the position (Slate's string form forgot the parentheses).
        expectEqual(try frame("corner top-right resize:screenSizeX/2-10;screenSizeY"), rect(730, 25, 710, 815))
        expectEqual(
          try frame("corner bottom-right resize:screenSizeX/2;screenSizeY/2 1"), rect(720, -527.5, 960, 527.5))
        expectEqual(try frame("corner bottom-left noresize right"), rect(1440, 840, 800, 600))
        // The author's corner operations, as JavaScript builds them.
        let bottomLeft = Action.corner(.bottomLeft, width: "screenSizeX/2", height: "screenSizeY/2", screen: nil)
        expectEqual(
          try FrameCalculator.targetFrame(for: bottomLeft, in: WindowContext(frame: onRight, screens: screens)),
          rect(1440, 732.5, 1280, 707.5))
      }
    ),
    (
      "only window geometry has a frame",
      {
        expectMessage(
          errorMessage { _ = try frame("focus left") }, contains: "\"focus\" doesn't move or resize a window")
        expectThrows { _ = try frame("chain push up | push down") }
        expectThrows { _ = try frame("undo") }
        expectThrows {
          _ = try FrameCalculator.targetFrame(
            for: .push(direction: .up, style: .barResize("1/(windowSizeX-800)"), screen: nil),
            in: WindowContext(frame: onMain, screens: screens))
        }
        expectThrows {
          _ = try FrameCalculator.targetFrame(
            for: .push(direction: .up, style: .none, screen: nil), in: WindowContext(frame: onMain, screens: []))
        }
      }
    ),
  ])

let screenResolverTests = Suite(
  "ScreenResolver",
  [
    (
      "the window's own screen is the one with most of the window",
      {
        expectEqual(resolve(nil), "Built-in")
        expectEqual(resolve(nil, from: rect(1300, 100, 800, 600)), "Right")  // mostly on the right screen
        expectEqual(resolve(nil, from: rect(-200, -500, 400, 300)), "Above")
        expectEqual(resolve(nil, from: rect(-300, -100, 400, 300)), "Portrait")  // 300×200 beats 340×100
        expectEqual(resolve(nil, from: rect(5000, 5000, 100, 100)), "Built-in")  // off-screen falls back to main
        expectEqual(resolve(.index(-1), from: onRight), "Right")
        expectEqual(resolve(.index(-2)), nil)
      }
    ),
    (
      "indexes count left to right unless orderScreensLeftToRight is off",
      {
        expectEqual([0, 1, 2, 3].map { resolve(.index($0)) }, ["Portrait", "Above", "Built-in", "Right"])
        let osOrder: [String: SettingValue] = ["orderScreensLeftToRight": .bool(false)]
        expectEqual(
          [0, 1, 2, 3].map { resolve(.index($0), settings: osOrder) }, ["Built-in", "Right", "Above", "Portrait"])
        expectEqual(
          [0, 1, 2, 3].map { resolve(.orderedIndex($0), settings: osOrder) },
          ["Portrait", "Above", "Built-in", "Right"])
        expectEqual(resolve(.index(4)), nil)
        expectEqual(resolve(.orderedIndex(4)), nil)
        // Screens sharing an x are numbered lower one first, like Slate.
        let top = ScreenInfo(
          displayID: 10, name: "Top", frame: rect(0, -1080, 1440, 1080), visibleFrame: rect(0, -1055, 1440, 1055),
          isMain: false)
        expectEqual([main, top].orderedLeftToRight().map(\.name), ["Built-in", "Top"])
        expectEqual([top, main].orderedLeftToRight().map(\.name), ["Built-in", "Top"])
      }
    ),
    (
      "resolutions match the full screen size",
      {
        expectEqual(resolve(.resolution(width: 2560, height: 1440)), "Right")
        expectEqual(resolve(.resolution(width: 1080, height: 1920)), "Portrait")
        expectEqual(resolve(.resolution(width: 1440, height: 815)), nil)  // the visible size doesn't count
        expectEqual(
          resolve(.resolution(width: 800, height: 600), settings: ["defaultToCurrentScreen": .bool(true)]), "Built-in")
      }
    ),
    (
      "directions find the screen across that edge",
      {
        expectEqual(resolve(.relative(.right)), "Right")
        expectEqual(resolve(.relative(.left)), "Portrait")
        expectEqual(resolve(.relative(.up)), "Above")
        expectEqual(resolve(.relative(.down)), nil)
        expectEqual(resolve(.relative(.left), from: onRight), "Built-in")
        expectEqual(resolve(.relative(.up), from: onRight), "Above")  // shares 240 points of edge
        expectEqual(resolve(.relative(.right), from: onRight), nil)
        expectEqual(resolve(.relative(.down), from: onAbove), "Built-in")  // the most shared edge wins
        expectEqual(resolve(.relative(.left), from: onAbove), nil)
        expectEqual(resolve(.relative(.right), from: onPortrait), "Built-in")
        expectEqual(resolve(.relative(.up), from: onPortrait), "Above")
        expectEqual(ScreenRef(slate: "below").map { resolve($0, from: onAbove) }, "Built-in")
      }
    ),
    (
      "directions fall back to the nearest screen when screens only meet at a corner",
      {
        let corner = ScreenInfo(
          displayID: 20, name: "Corner", frame: rect(1440, 900, 1920, 1080), visibleFrame: rect(1440, 925, 1920, 1055),
          isMain: false)
        let far = ScreenInfo(
          displayID: 21, name: "Far", frame: rect(3360, 1980, 1920, 1080), visibleFrame: rect(3360, 2005, 1920, 1055),
          isMain: false)
        let layout = [main, corner, far]
        func find(_ direction: Direction, from window: CGRect) -> String? {
          ScreenResolver.screen(for: .relative(direction), windowFrame: window, screens: layout)?.name
        }
        expectEqual(find(.right, from: onMain), "Corner")
        expectEqual(find(.down, from: onMain), "Corner")
        expectEqual(find(.left, from: onMain), nil)
        expectEqual(find(.up, from: rect(2000, 1000, 400, 300)), "Built-in")
        expectEqual(find(.right, from: rect(2000, 1000, 400, 300)), "Far")
      }
    ),
    (
      "next and previous follow the OS order and wrap",
      {
        expectEqual(resolve(.next), "Right")
        expectEqual(resolve(.next, from: onRight), "Above")
        expectEqual(resolve(.next, from: onPortrait), "Built-in")
        expectEqual(resolve(.previous), "Portrait")
        expectEqual(resolve(.previous, from: onRight), "Built-in")
        let single = [main]
        expectEqual(ScreenResolver.screen(for: .next, windowFrame: onMain, screens: single)?.name, "Built-in")
        expectEqual(ScreenResolver.screen(for: .relative(.left), windowFrame: onMain, screens: single)?.name, nil)
        expectEqual(ScreenResolver.screen(for: nil, windowFrame: onMain, screens: []), nil)
      }
    ),
  ])
