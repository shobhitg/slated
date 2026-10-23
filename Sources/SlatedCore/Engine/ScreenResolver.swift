import Foundation

/// Resolves Slate screen references against the current displays, the way Slate did.
public enum ScreenResolver {
  /// The screen `ref` points to, relative to the screen holding `windowFrame` (the one with the largest
  /// share of the window). A nil `ref` means the window's own screen. Returns nil when nothing matches;
  /// Slate then leaves the window alone.
  ///
  /// - `index`: left-to-right position (`orderScreensLeftToRight`, the default) or the OS order; `-1` is
  ///   the window's screen, as in Slate.
  /// - `orderedIndex`: always the left-to-right position.
  /// - `resolution`: the first screen (OS order) whose full size matches.
  /// - `relative`: the screen sharing the most of that edge of the window's screen, as Slate found it;
  ///   when no screen touches that edge (say, displays meeting only at a corner), the nearest screen
  ///   lying in that direction.
  /// - `next`/`previous`: the next or previous screen in OS order, wrapping around (Slate's behavior,
  ///   even when screens are numbered left to right).
  ///
  /// When an index or resolution matches no screen, `defaultToCurrentScreen` picks the window's screen
  /// instead of nil. It doesn't apply to directions, matching Slate.
  public static func screen(
    for ref: ScreenRef?, windowFrame: CGRect, screens: [ScreenInfo], settings: SlateSettings = .init()
  ) -> ScreenInfo? {
    guard let current = screens.screen(containing: windowFrame) else { return nil }
    guard let ref else { return current }
    let fallback = settings.defaultToCurrentScreen ? current : nil
    switch ref {
    case .index(let index):
      return screen(at: index, in: settings.orderScreensLeftToRight ? screens.orderedLeftToRight() : screens)
        ?? (index == -1 ? current : index < -1 ? nil : fallback)
    case .orderedIndex(let index):
      return screen(at: index, in: screens.orderedLeftToRight())
        ?? (index == -1 ? current : index < -1 ? nil : fallback)
    case .resolution(let width, let height):
      return screens.first { $0.resolution == "\(width)x\(height)" } ?? fallback
    case .relative(let direction):
      return neighbor(of: current, toward: direction, in: screens)
    case .next, .previous:
      guard let index = screens.firstIndex(of: current) else { return current }
      let step = ref == .next ? 1 : screens.count - 1
      return screens[(index + step) % screens.count]
    }
  }

  private static func screen(at index: Int, in list: [ScreenInfo]) -> ScreenInfo? {
    list.indices.contains(index) ? list[index] : nil
  }

  /// The screen next to `current` in `direction`.
  ///
  /// Like Slate, this looks at a one-point strip just outside that edge of `current`'s full frame and
  /// takes the screen covering most of it. If none does, it falls back to the nearest screen lying
  /// entirely beyond that edge (by the gap between the two frames, then by how far their centers are
  /// offset sideways), so displays that meet only at a corner still find each other.
  static func neighbor(of current: ScreenInfo, toward direction: Direction, in screens: [ScreenInfo]) -> ScreenInfo? {
    let frame = current.frame
    let strip: CGRect
    switch direction {
    case .right: strip = CGRect(x: frame.maxX, y: frame.minY, width: 1, height: frame.height)
    case .left: strip = CGRect(x: frame.minX - 1, y: frame.minY, width: 1, height: frame.height)
    case .up: strip = CGRect(x: frame.minX, y: frame.minY - 1, width: frame.width, height: 1)
    case .down: strip = CGRect(x: frame.minX, y: frame.maxY, width: frame.width, height: 1)
    }
    var best: (screen: ScreenInfo, area: CGFloat)?
    for screen in screens where screen != current {
      let overlap = screen.frame.intersection(strip)
      guard !overlap.isNull else { continue }
      let area = overlap.width * overlap.height
      if area > (best?.area ?? 0) { best = (screen, area) }
    }
    if let best { return best.screen }

    var nearest: (screen: ScreenInfo, gap: CGFloat, offset: CGFloat)?
    for screen in screens where screen != current {
      let other = screen.frame
      let beyond: Bool
      let offset: CGFloat
      switch direction {
      case .right:
        beyond = other.minX >= frame.maxX
        offset = abs(other.midY - frame.midY)
      case .left:
        beyond = other.maxX <= frame.minX
        offset = abs(other.midY - frame.midY)
      case .up:
        beyond = other.maxY <= frame.minY
        offset = abs(other.midX - frame.midX)
      case .down:
        beyond = other.minY >= frame.maxY
        offset = abs(other.midX - frame.midX)
      }
      guard beyond else { continue }
      let gap = distance(between: frame, and: other)
      if let nearest, (nearest.gap, nearest.offset) <= (gap, offset) { continue }
      nearest = (screen, gap, offset)
    }
    return nearest?.screen
  }

  /// Shortest distance between two rectangles (0 when they touch or overlap).
  private static func distance(between a: CGRect, and b: CGRect) -> CGFloat {
    let dx = max(0, max(b.minX - a.maxX, a.minX - b.maxX))
    let dy = max(0, max(b.minY - a.maxY, a.minY - b.maxY))
    return (dx * dx + dy * dy).squareRoot()
  }
}
