import Foundation

@testable import SlatedCore

/// Every window-geometry operation form, plus a few that aren't geometry (they must fail).
private let frameOperations: [String] = [
  // move
  "move screenOriginX;screenOriginY screenSizeX/2;screenSizeY",
  "move screenOriginX+screenSizeX/2;screenOriginY screenSizeX/2;screenSizeY",
  "move screenOriginX+screenSizeX/4;screenOriginY+screenSizeY/4 screenSizeX/2;screenSizeY/2",
  "move screenOriginX;screenOriginY screenSizeX;screenSizeY",
  "move screenOriginX+screenSizeX/8;screenOriginY+screenSizeY/8 screenSizeX/1.3;screenSizeY/1.3",
  "move screenOriginX;screenOriginY screenSizeX/2;screenSizeY 0",
  "move screenOriginX;screenOriginY screenSizeX/2;screenSizeY 1",
  "move screenOriginX;screenOriginY screenSizeX/2;screenSizeY 2",
  "move screenOriginX;screenOriginY screenSizeX/2;screenSizeY 3",
  "move screenOriginX;screenOriginY screenSizeX/2;screenSizeY 9",
  "move screenOriginX;screenOriginY screenSizeX/2;screenSizeY ordered:1",
  "move screenOriginX;screenOriginY screenSizeX/2;screenSizeY ordered:7", "move 0;0 100;100 1",
  "move 0;0 10;10 ordered:7",
  "move windowTopLeftX+10;windowTopLeftY windowSizeX;windowSizeY",
  "move windowTopLeftX;windowTopLeftY windowSizeX;windowSizeY",
  "move screenOriginX;screenOriginY 10;10 -1", "move screenOriginX;screenOriginY 10;10 -2",
  "move screenOriginX+screenSizeX-newWindowSizeX;screenOriginY 400;300", "move 0;0 newWindowSizeX/2;newWindowSizeY/2",
  "move screenOriginX;screenOriginY screenSizeX/3;screenSizeY 1920x1080",
  "move screenOriginX;screenOriginY screenSizeX/3;screenSizeY 2560x1440",
  "move screenOriginX;screenOriginY screenSizeX;screenSizeY left",
  "move screenOriginX;screenOriginY screenSizeX;screenSizeY right",
  "move screenOriginX;screenOriginY screenSizeX;screenSizeY up",
  "move screenOriginX;screenOriginY screenSizeX;screenSizeY down",
  "move screenOriginX;screenOriginY screenSizeX;screenSizeY next",
  "move screenOriginX;screenOriginY screenSizeX;screenSizeY previous",
  "move screenOriginX+(screenSizeX-windowSizeX)/2;screenOriginY+(screenSizeY-windowSizeY)/2 windowSizeX;windowSizeY",
  "move screenOriginX;screenOriginY screenSizeX/(windowSizeX-windowSizeX);screenSizeY",
  "move min({screenOriginX+100,500});max({screenOriginY,0}) floor(screenSizeX/3);ceiling(screenSizeY/3)",
  "move screenOriginX;screenOriginY 2**10;screenSizeY**1", "move -100;-100 50;50", "move 0.5;0.25 100.75;100.5",
  // resize
  "resize +10% +0", "resize -10% +0 bottom-right", "resize +0 +10% bottom-right", "resize +10% -100 bottom-right",
  "resize -10% +0 top-right", "resize +0 -10% bottom-left", "resize +100 +50", "resize +10% +10%",
  "resize +screenSizeX/10 +0", "resize screenSizeX/2 50%", "resize +0 +0 bottom-right", "resize -33% -33% bottom-right",
  "resize +1.5 +0", "resize 50% 50% top-right", "resize -100 -100 top-left", "resize +windowSizeX +0",
  "resize -2000 -2000",
  "resize 400 300 bottom-left", "resize +7% -3% top-right", "resize +10% +0 bottom-left",
  "resize +screenSizeX/(windowSizeX-windowSizeX) +0",
  // push
  "push up", "push down", "push left", "push right", "push up center", "push down center", "push left center",
  "push right center", "push up bar", "push down bar", "push left bar", "push right bar",
  "push top bar-resize:screenSizeY/2", "push bottom bar-resize:screenSizeY/2", "push left bar-resize:screenSizeX/3",
  "push right bar-resize:screenSizeX/3", "push down bar-resize:screenSizeY-100",
  "push right bar-resize:screenSizeX/2+100",
  "push up bar 1", "push up bar-resize:screenSizeY/2 right", "push down none right", "push left bar 9",
  "push up center next", "push right bar previous", "push left none 0", "push down bar-resize:windowSizeY 1920x1080",
  // nudge
  "nudge +10% +0", "nudge -100 +0", "nudge +0 -10%", "nudge +screenSizeX/10 -screenSizeY/10", "nudge 50 0",
  "nudge -10% +10%", "nudge +10%% +0", "nudge +0.5 -0.5",
  // throw
  "throw left resize", "throw left", "throw right resize", "throw up resize", "throw down resize", "throw 0 resize",
  "throw 1 resize", "throw 2", "throw 3 resize", "throw 9 resize", "throw -1 resize", "throw ordered:1 resize",
  "throw 1 resize:screenSizeX/2;screenSizeY", "throw 2560x1440 resize", "throw 1680x1050 resize", "throw 1920x1080",
  "throw next", "throw previous", "throw next resize", "throw 0 resize:windowSizeX*2;windowSizeY/2",
  // corner
  "corner top-left", "corner top-right", "corner bottom-left", "corner bottom-right",
  "corner bottom-right resize:screenSizeX/2;screenSizeY/2", "corner top-left resize:screenSizeX/2;screenSizeY/2",
  "corner top-right resize:screenSizeX/2-10;screenSizeY", "corner bottom-right resize:screenSizeX/2;screenSizeY/2 1",
  "corner bottom-left noresize right", "corner top-right resize:newWindowSizeX;screenSizeY",
  "corner bottom-left resize:400;300 next", "corner top-right 9",
  // by-orientation (Slated)
  "by-orientation 'move screenOriginX;screenOriginY screenSizeX/3;screenSizeY' 'move screenOriginX;screenOriginY screenSizeX;screenSizeY/3'",
  "by-orientation 'push left bar-resize:screenSizeX/2' 'push up bar-resize:screenSizeY/2'",
  "by-orientation 'focus left' 'push up'",
  // not window geometry
  "focus left", "undo", "chain push up | push down", "grid", "layout x", "insert-text 'x'",
]

/// Operations whose position depends on the size the window really took.
private let originOperations: [String] = [
  "move screenOriginX+screenSizeX-newWindowSizeX;screenOriginY 400;300",
  "move screenOriginX+(screenSizeX-newWindowSizeX)/2;screenOriginY+(screenSizeY-newWindowSizeY)/2 screenSizeX/2;screenSizeY/2",
  "resize +10% +0 top-right", "resize +10% +10% bottom-right", "resize -10% -10% bottom-left", "resize +10% +0",
  "resize +0 +0 bottom-right", "resize 50% 50% top-right", "corner bottom-right resize:screenSizeX/2;screenSizeY/2",
  "corner top-right", "corner bottom-left", "corner bottom-right resize:newWindowSizeX/2;newWindowSizeY/2",
  "push right bar-resize:screenSizeX/3", "push down bar-resize:screenSizeY/3", "push right", "push down center",
  "throw right resize", "nudge +10% +0", "by-orientation 'corner bottom-right' 'corner top-right'",
  "move screenOriginX;screenOriginY screenSizeX;screenSizeY 9", "focus left",
]

private let actualSizes: [CGSize] = [
  CGSize(width: 300, height: 200), CGSize(width: 2000, height: 1500), CGSize(width: 333.5, height: 222.25),
]

private func frameResult(_ body: () throws -> CGRect) -> J {
  do {
    let r = try body()
    return [
      .number(Double(r.origin.x)), .number(Double(r.origin.y)), .number(Double(r.size.width)),
      .number(Double(r.size.height)),
    ]
  } catch {
    return ["error": errorJ(error)]
  }
}

func frameFixtures() -> FixtureFile {
  var actions: [String: J] = [:]
  var parsed: [String: Action] = [:]
  for op in frameOperations + originOperations {
    let action = try! SlateSyntax.parseOperation(op)
    parsed[op] = action
    actions[op] = actionJ(action)
  }

  var frames: [J] = []
  for setup in screenSetups {
    for (windowName, window) in setup.windows {
      for settingsName in setup.settings {
        let context = WindowContext(
          frame: window, screens: setup.screens, settings: SlateSettings(settingsVariants[settingsName]!))
        var results: [String: J] = [:]
        for op in frameOperations {
          results[op] = frameResult { try FrameCalculator.targetFrame(for: parsed[op]!, in: context) }
        }
        frames.append([
          "setup": .string(setup.name), "window": .string(windowName), "settings": .string(settingsName),
          "results": .object(results),
        ])
      }
    }
  }

  var origins: [J] = []
  for setup in screenSetups where ["four", "single", "gnome"].contains(setup.name) {
    for (windowName, window) in setup.windows where windowName != "straddle" && windowName != "offscreen" {
      for settingsName in ["default", "resizePercentOfWindow"] {
        let context = WindowContext(
          frame: window, screens: setup.screens, settings: SlateSettings(settingsVariants[settingsName]!))
        for size in actualSizes {
          var results: [String: J] = [:]
          for op in originOperations {
            do {
              let p = try FrameCalculator.targetOrigin(for: parsed[op]!, in: context, actualSize: size)
              results[op] = [.number(Double(p.x)), .number(Double(p.y))]
            } catch {
              results[op] = ["error": errorJ(error)]
            }
          }
          origins.append([
            "setup": .string(setup.name), "window": .string(windowName), "settings": .string(settingsName),
            "actualSize": ["width": .number(Double(size.width)), "height": .number(Double(size.height))],
            "results": .object(results),
          ])
        }
      }
    }
  }

  return FixtureFile(
    name: "frames.json",
    description:
      "FrameCalculator.targetFrame ([x, y, width, height] or the error) for every geometry operation on every screen "
      + "setup, window and settings variation, and targetOrigin ([x, y]) once the window took a different size. "
      + "Setups and settings are defined in screens.json; `actions` holds each operation's canonical JSON.",
    sections: ["targetFrame": frames, "targetOrigin": origins],
    extra: ["actions": .object(actions)],
    depth: ["targetFrame": 3, "targetOrigin": 3, "actions": 1])
}
