import Foundation

/// Everything the frame math needs to know about the focused window and the displays.
public struct WindowContext: Sendable {
  /// The window's current frame (top-left global coordinates).
  public var frame: CGRect
  /// All displays in OS order (the main display first).
  public var screens: [ScreenInfo]
  public var settings: SlateSettings

  public init(frame: CGRect, screens: [ScreenInfo], settings: SlateSettings = .init()) {
    self.frame = frame
    self.screens = screens
    self.settings = settings
  }
}

/// Pure geometry for Slate's window operations: given a window and the screens, where should the
/// window go? No Accessibility calls happen here, so all of it is unit-testable.
///
/// Semantics follow Slate exactly, with expressions evaluated by `SlateExpression` (so `/` is
/// floating-point division). Screen variables (`screenOriginX`…) describe the target screen's visible
/// frame; window variables describe the window before the operation. Like Slate, every variable is a
/// whole number (fractions are truncated toward zero).
///
/// Slate applied an operation in two steps: resize, read back the size the window actually took (apps
/// may refuse a size), then compute the top-left corner for that size. To do the same, apply
/// `targetFrame`'s size first, then move to `targetOrigin(for:in:actualSize:)`, then set the size again.
public enum FrameCalculator {
  /// Target frame for `move`, `resize`, `push`, `nudge`, `throw` and `corner`, assuming the window takes
  /// the requested size.
  ///
  /// Throws `SlatedError.screenNotFound` when the operation names a screen that doesn't exist (Slate
  /// left the window alone then), `SlatedError.invalidExpression` for a bad expression, and
  /// `SlatedError.invalidSyntax` for operations that are not window geometry.
  public static func targetFrame(for action: Action, in context: WindowContext) throws -> CGRect {
    let plan = try self.plan(for: action, in: context)
    return CGRect(origin: try plan.origin(plan.size), size: plan.size)
  }

  /// The top-left corner for `action` once the window has been resized and turned out `actualSize`
  /// (which can differ from `targetFrame`'s size when the app constrains its windows). Resize anchors
  /// and expressions using `newWindowSizeX`/`newWindowSizeY` depend on it.
  public static func targetOrigin(for action: Action, in context: WindowContext, actualSize: CGSize) throws -> CGPoint {
    try plan(for: action, in: context).origin(actualSize)
  }

  // MARK: Plans

  /// The size to request, and the top-left corner as a function of the size the window really took.
  struct Plan {
    var size: CGSize
    var origin: (CGSize) throws -> CGPoint
  }

  static func plan(for action: Action, in context: WindowContext) throws -> Plan {
    switch action {
    case .byOrientation(let landscape, let portrait):
      let portraitScreen = context.screens.screen(containing: context.frame)?.isPortrait ?? false
      return try plan(for: portraitScreen ? portrait : landscape, in: context)

    case .move(let x, let y, let width, let height, let screen):
      return try movePlan(
        x: { try $0.evaluate(x) }, y: { try $0.evaluate(y) },
        width: { try $0.evaluate(width) }, height: { try $0.evaluate(height) },
        screen: screen, context: context)

    case .resize(let width, let height, let anchor):
      return try resizePlan(width: width, height: height, anchor: anchor, context: context)

    case .push(let direction, let style, let screen):
      return try pushPlan(direction: direction, style: style, screen: screen, context: context)

    case .nudge(let x, let y):
      // Slate builds the new corner as text, `windowTopLeftX` + amount, with `%` meaning a percentage of
      // the screen (or window, per nudgePercentOf) size.
      let percentOf = context.settings.nudgePercentOf == "windowSize" ? "windowSize" : "screenSize"
      let xExpression = "windowTopLeftX" + SlateOperationParser.nudgeExpression(x, axis: "X", percentOf: percentOf)
      let yExpression = "windowTopLeftY" + SlateOperationParser.nudgeExpression(y, axis: "Y", percentOf: percentOf)
      return try movePlan(
        x: { try $0.evaluate(xExpression) }, y: { try $0.evaluate(yExpression) },
        width: { $0.windowSizeX }, height: { $0.windowSizeY }, screen: nil, context: context)

    case .throwWindow(let screen, let width, let height):
      return try movePlan(
        x: { $0.screenOriginX }, y: { $0.screenOriginY },
        width: { try width.map($0.evaluate) ?? $0.windowSizeX },
        height: { try height.map($0.evaluate) ?? $0.windowSizeY },
        screen: screen, context: context)

    case .corner(let corner, let width, let height, let screen):
      let newWidth: (Variables) throws -> Double = { try width.map($0.evaluate) ?? $0.windowSizeX }
      let newHeight: (Variables) throws -> Double = { try height.map($0.evaluate) ?? $0.windowSizeY }
      let left: (Variables) throws -> Double = { $0.screenOriginX }
      let right: (Variables) throws -> Double = { $0.screenOriginX + $0.screenSizeX - (try newWidth($0)) }
      let top: (Variables) throws -> Double = { $0.screenOriginY }
      let bottom: (Variables) throws -> Double = { $0.screenOriginY + $0.screenSizeY - (try newHeight($0)) }
      let (x, y) =
        switch corner {
        case .topLeft: (left, top)
        case .topRight: (right, top)
        case .bottomLeft: (left, bottom)
        case .bottomRight: (right, bottom)
        }
      return try movePlan(x: x, y: y, width: newWidth, height: newHeight, screen: screen, context: context)

    default:
      throw SlatedError.invalidSyntax("\"\(action.name)\" doesn't move or resize a window")
    }
  }

  /// Slate's `move`, which `push`, `nudge`, `throw` and `corner` are built on: the size is evaluated with
  /// `newWindowSize*` equal to the current size, the position with the size the window really took.
  private static func movePlan(
    x: @escaping (Variables) throws -> Double, y: @escaping (Variables) throws -> Double,
    width: (Variables) throws -> Double, height: (Variables) throws -> Double,
    screen ref: ScreenRef?, context: WindowContext
  ) throws -> Plan {
    let screen = try targetScreen(ref, context: context)
    let window = context.frame
    let before = Variables(screen: screen, window: window, newSize: window.size)
    let size = CGSize(width: try width(before), height: try height(before))
    return Plan(size: size) { actual in
      let after = Variables(screen: screen, window: window, newSize: actual)
      return CGPoint(x: try x(after), y: try y(after))
    }
  }

  private static func pushPlan(
    direction: Direction, style: PushStyle, screen: ScreenRef?, context: WindowContext
  ) throws -> Plan {
    typealias Coordinate = (Variables) throws -> Double
    var width: Coordinate = { $0.windowSizeX }
    var height: Coordinate = { $0.windowSizeY }
    let x: Coordinate
    let y: Coordinate
    // Centered on the screen horizontally or vertically, or flush with its right or bottom edge.
    let centerX: Coordinate = { $0.screenOriginX + ($0.screenSizeX - $0.windowSizeX) / 2 }
    let centerY: Coordinate = { $0.screenOriginY + ($0.screenSizeY - $0.windowSizeY) / 2 }
    let rightX: Coordinate = { $0.screenOriginX + $0.screenSizeX - $0.windowSizeX }
    let bottomY: Coordinate = { $0.screenOriginY + $0.screenSizeY - $0.windowSizeY }

    switch (direction, style) {
    case (.up, .none): (x, y) = ({ $0.windowTopLeftX }, { $0.screenOriginY })
    case (.up, .center): (x, y) = (centerX, { $0.screenOriginY })
    case (.up, .bar):
      (x, y) = ({ $0.screenOriginX }, { $0.screenOriginY })
      width = { $0.screenSizeX }
    case (.up, .barResize(let expression)):
      (x, y) = ({ $0.screenOriginX }, { $0.screenOriginY })
      (width, height) = ({ $0.screenSizeX }, { try $0.evaluate(expression) })

    case (.down, .none): (x, y) = ({ $0.windowTopLeftX }, bottomY)
    case (.down, .center): (x, y) = (centerX, bottomY)
    case (.down, .bar):
      (x, y) = ({ $0.screenOriginX }, bottomY)
      width = { $0.screenSizeX }
    case (.down, .barResize(let expression)):
      (x, y) = ({ $0.screenOriginX }, { $0.screenOriginY + $0.screenSizeY - (try $0.evaluate(expression)) })
      (width, height) = ({ $0.screenSizeX }, { try $0.evaluate(expression) })

    case (.left, .none): (x, y) = ({ $0.screenOriginX }, { $0.windowTopLeftY })
    case (.left, .center): (x, y) = ({ $0.screenOriginX }, centerY)
    case (.left, .bar):
      (x, y) = ({ $0.screenOriginX }, { $0.screenOriginY })
      height = { $0.screenSizeY }
    case (.left, .barResize(let expression)):
      (x, y) = ({ $0.screenOriginX }, { $0.screenOriginY })
      (width, height) = ({ try $0.evaluate(expression) }, { $0.screenSizeY })

    case (.right, .none): (x, y) = (rightX, { $0.windowTopLeftY })
    case (.right, .center): (x, y) = (rightX, centerY)
    case (.right, .bar):
      (x, y) = (rightX, { $0.screenOriginY })
      height = { $0.screenSizeY }
    case (.right, .barResize(let expression)):
      (x, y) = ({ $0.screenOriginX + $0.screenSizeX - (try $0.evaluate(expression)) }, { $0.screenOriginY })
      (width, height) = ({ try $0.evaluate(expression) }, { $0.screenSizeY })
    }
    return try movePlan(x: x, y: y, width: width, height: height, screen: screen, context: context)
  }

  /// Slate's `resize`: whole-number arithmetic, percentages of the window's screen (or of the window,
  /// per `resizePercentOf`), and the anchor corner kept in place for the size the window really took.
  private static func resizePlan(width: String, height: String, anchor: Corner, context: WindowContext) throws -> Plan {
    let window = context.frame
    let base: CGSize
    if context.settings.resizePercentOf == "screenSize" {
      guard let screen = context.screens.screen(containing: window) else {
        throw SlatedError.screenNotFound("current")
      }
      base = screen.visibleFrame.size
    } else {
      base = window.size
    }
    let variables = context.screens.screen(containing: window).map {
      Variables(screen: $0, window: window, newSize: window.size)
    }
    let newWidth = try resized(window.width, by: width, base: base.width, variables: variables)
    let newHeight = try resized(window.height, by: height, base: base.height, variables: variables)
    let size = CGSize(width: newWidth, height: newHeight)
    if size == window.size {
      return Plan(size: size) { _ in window.origin }  // Slate doesn't touch an unchanged window.
    }
    return Plan(size: size) { actual in
      let right = (window.minX + window.width - actual.width).rounded(.towardZero)
      let bottom = (window.minY + window.height - actual.height).rounded(.towardZero)
      switch anchor {
      case .topLeft: return window.origin
      case .topRight: return CGPoint(x: right, y: window.minY.rounded(.towardZero))
      case .bottomLeft: return CGPoint(x: window.minX.rounded(.towardZero), y: bottom)
      case .bottomRight: return CGPoint(x: right, y: bottom)
      }
    }
  }

  /// One `resize` dimension. `+10%`/`-10%` change it by a percentage of `base`, `+100`/`-100` by points
  /// (Slate's forms, computed with Slate's whole-number arithmetic). Slated also accepts a signed
  /// expression (`+screenSizeX/10`) and an absolute size (`screenSizeX/2`, or `50%` of `base`).
  private static func resized(_ current: CGFloat, by value: String, base: CGFloat, variables: Variables?) throws
    -> CGFloat
  {
    let amount = ResizeAmount(value)
    let base = base.rounded(.towardZero)
    func magnitude() throws -> Double {
      if let whole = Int(amount.magnitude) { return Double(whole) }
      guard let variables else { throw SlatedError.screenNotFound("current") }
      do {
        return try variables.evaluate(amount.magnitude)
      } catch let error as SlatedError {
        throw SlatedError.invalidExpression("Invalid resize amount \"\(value)\": \(error.description)")
      }
    }
    if let sign = amount.sign {
      let change =
        amount.isPercent ? (sign * base * (try magnitude()) / 100).rounded(.towardZero) : sign * (try magnitude())
      return (current + change).rounded(.towardZero)
    }
    let size = amount.isPercent ? base * (try magnitude()) / 100 : try magnitude()
    return size.rounded(.towardZero)
  }

  private static func targetScreen(_ ref: ScreenRef?, context: WindowContext) throws -> ScreenInfo {
    guard
      let screen = ScreenResolver.screen(
        for: ref, windowFrame: context.frame, screens: context.screens, settings: context.settings)
    else {
      throw SlatedError.screenNotFound(ref?.slate ?? "current")
    }
    return screen
  }
}

/// The values of Slate's expression variables for one evaluation. Like Slate, each is a whole number.
struct Variables {
  let values: [String: Double]

  init(screen: ScreenInfo, window: CGRect, newSize: CGSize) {
    let visible = screen.visibleFrame
    func whole(_ value: CGFloat) -> Double { Double(value).rounded(.towardZero) }
    values = [
      "screenOriginX": whole(visible.minX),
      "screenOriginY": whole(visible.minY),
      "screenSizeX": whole(visible.width),
      "screenSizeY": whole(visible.height),
      "windowTopLeftX": whole(window.minX),
      "windowTopLeftY": whole(window.minY),
      "windowSizeX": whole(window.width),
      "windowSizeY": whole(window.height),
      "newWindowSizeX": whole(newSize.width),
      "newWindowSizeY": whole(newSize.height),
    ]
  }

  var screenOriginX: Double { values["screenOriginX"]! }
  var screenOriginY: Double { values["screenOriginY"]! }
  var screenSizeX: Double { values["screenSizeX"]! }
  var screenSizeY: Double { values["screenSizeY"]! }
  var windowTopLeftX: Double { values["windowTopLeftX"]! }
  var windowTopLeftY: Double { values["windowTopLeftY"]! }
  var windowSizeX: Double { values["windowSizeX"]! }
  var windowSizeY: Double { values["windowSizeY"]! }

  func evaluate(_ expression: String) throws -> Double {
    try SlateExpression.evaluate(expression, variables: values)
  }
}
