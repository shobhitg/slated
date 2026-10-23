import Foundation

extension SlatedConfiguration {
  /// The configuration a new install starts with: the author's long-standing Slate setup, with every
  /// window binding on the Hyper key (Caps Lock).
  ///
  /// Used only when there's no config file yet and no Slate config to load instead.
  public static var starter: SlatedConfiguration {
    var config = SlatedConfiguration()
    config.keyboard.capsLock = .hyper
    config.bindings = StarterBindings.all
    return config
  }
}

/// The starter bindings, also offered as presets in the UI.
public enum StarterBindings {
  private static let x = "screenOriginX"
  private static let y = "screenOriginY"
  private static let w = "screenSizeX"
  private static let h = "screenSizeY"

  private static func move(_ mx: String, _ my: String, _ mw: String, _ mh: String) -> Action {
    .move(x: mx, y: my, width: mw, height: mh, screen: nil)
  }

  private static func quarter(_ corner: Corner) -> Action {
    .corner(corner, width: "\(w)/2", height: "\(h)/2", screen: nil)
  }

  /// Thirds sit side by side on a wide screen and stack on a vertical one.
  private static func third(_ index: Int, span: Int = 1) -> Action {
    let offset = index == 0 ? "" : (index == 1 ? "/3" : "*2/3")
    let size = span == 1 ? "/3" : "*2/3"
    // Slate configs commonly write the 1/3 offset of a two-thirds span as "*1/3".
    let twoThirdsOffset = span == 2 && index == 1 ? "*1/3" : offset
    return .byOrientation(
      landscape: move(index == 0 ? x : "\(x)+\(w)\(twoThirdsOffset)", y, "\(w)\(size)", h),
      portrait: move(x, index == 0 ? y : "\(y)+\(h)\(twoThirdsOffset)", w, "\(h)\(size)"))
  }

  public static let all: [HotkeyBinding] = [
    ("Center", "'", move("\(x)+\(w)/4", "\(y)+\(h)/4", "\(w)/2", "\(h)/2")),
    ("Left half", "a", move(x, y, "\(w)/2", h)),
    ("Right half", "d", move("\(x)+\(w)/2", y, "\(w)/2", h)),
    ("Top half", "w", .push(direction: .up, style: .barResize("\(h)/2"), screen: nil)),
    ("Bottom half", "x", .push(direction: .down, style: .barResize("\(h)/2"), screen: nil)),
    ("Top-left quarter", "q", quarter(.topLeft)),
    ("Top-right quarter", "e", quarter(.topRight)),
    ("Bottom-left quarter", "z", quarter(.bottomLeft)),
    ("Bottom-right quarter", "c", quarter(.bottomRight)),
    ("First third", "f", third(0)),
    ("Middle third", "g", third(1)),
    ("Last third", "h", third(2)),
    ("First two-thirds", "v", third(0, span: 2)),
    ("Last two-thirds", "b", third(1, span: 2)),
    ("Large center", "return", move("\(x)+\(w)/8", "\(y)+\(h)/8", "\(w)/1.3", "\(h)/1.3")),
    ("Maximize", "s", move(x, y, w, h)),
    ("Grid", "tab", .grid(padding: 4, grids: (0...2).map { GridScreen(screen: String($0), width: 6, height: 6) })),
    ("Throw to the screen on the right", "right", .throwWindow(screen: .relative(.right), width: w, height: h)),
    ("Throw to the screen on the left", "left", .throwWindow(screen: .relative(.left), width: w, height: h)),
    ("Throw to the screen above", "up", .throwWindow(screen: .relative(.up), width: w, height: h)),
    ("Throw to the second screen", "down", .throwWindow(screen: .index(1), width: w, height: h)),
  ].map { name, key, action in
    HotkeyBinding(name: name, keys: KeyCombo(key: key, modifiers: .hyper), action: action)
  }
}
