import CoreGraphics
import SlatedCore

/// Where an action would put a sample window, for the live placement preview.
struct Placement: Equatable {
  enum State: Equatable {
    /// The window's resulting frame (top-left global coordinates).
    case placed(CGRect)
    /// The frame math couldn't produce a frame. `reason` is nil while SlatedCore's frame math isn't
    /// implemented yet, which the preview shows as a quiet "Preview unavailable".
    case unavailable(reason: String?)
    /// The action doesn't move windows (or has nothing to preview yet).
    case nothingToPreview(String)
  }

  /// The window the action starts from: centered on the main screen.
  var sample: CGRect
  var state: State

  var target: CGRect? {
    if case .placed(let rect) = state { return rect }
    return nil
  }
}

enum PlacementCalculator {
  /// The sample window: half the width and 60% of the height of the main screen's visible frame,
  /// centered on it.
  static func sampleFrame(screens: [ScreenInfo]) -> CGRect? {
    guard let main = screens.first(where: \.isMain) ?? screens.first else { return nil }
    let v = main.visibleFrame
    let size = CGSize(width: (v.width * 0.5).rounded(), height: (v.height * 0.6).rounded())
    return CGRect(
      x: (v.midX - size.width / 2).rounded(), y: (v.midY - size.height / 2).rounded(), width: size.width,
      height: size.height)
  }

  /// Whether the editor should show a placement preview for this action.
  static func previews(_ action: Action) -> Bool {
    switch action {
    case .chain, .sequence: return true
    default: return action.isWindowGeometry
    }
  }

  /// - Parameter step: for a chain, which operation to preview (wraps around).
  static func place(_ action: Action, screens: [ScreenInfo], settings: SlateSettings, step: Int = 0) -> Placement? {
    guard let sample = sampleFrame(screens: screens) else { return nil }
    return Placement(
      sample: sample, state: state(for: action, from: sample, screens: screens, settings: settings, step: step))
  }

  private static func state(
    for action: Action, from sample: CGRect, screens: [ScreenInfo], settings: SlateSettings, step: Int
  ) -> Placement.State {
    do {
      switch action {
      case .chain(let ops):
        guard !ops.isEmpty else { return .nothingToPreview("Add an operation to see where it puts the window.") }
        return state(for: ops[step % ops.count], from: sample, screens: screens, settings: settings, step: 0)
      case .sequence(let steps):
        let moves = steps.map(\.action).filter(\.isWindowGeometry)
        guard !moves.isEmpty else { return .nothingToPreview("None of these steps move the window.") }
        var frame = sample
        for move in moves {
          frame = try FrameCalculator.targetFrame(
            for: move, in: WindowContext(frame: frame, screens: screens, settings: settings))
        }
        return .placed(frame)
      default:
        guard action.isWindowGeometry else { return .nothingToPreview(ActionKind(action).explanation) }
        let frame = try FrameCalculator.targetFrame(
          for: action, in: WindowContext(frame: sample, screens: screens, settings: settings))
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
          return .unavailable(reason: "The window would have no size.")
        }
        return .placed(frame)
      }
    } catch let error as SlatedError {
      if case .notImplemented = error { return .unavailable(reason: nil) }
      return .unavailable(reason: error.description)
    } catch {
      return .unavailable(reason: error.localizedDescription)
    }
  }
}
