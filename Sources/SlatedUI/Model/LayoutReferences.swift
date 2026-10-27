import Foundation
import SlatedCore

/// Something in config.json that applies a layout by its name: a shortcut or hotstring (in any
/// step), or a display default (by its place in `defaults`).
enum LayoutReference: Hashable {
  case binding(UUID)
  case hotstring(UUID)
  case screenDefault(Int)
}

extension Action {
  /// The names of the layouts this action applies: itself, in any step, or in what it repeats.
  var layoutNames: Set<String> {
    switch self {
    case .layout(let name): return [name]
    case .chain(let actions): return actions.reduce(into: []) { $0.formUnion($1.layoutNames) }
    case .sequence(let steps): return steps.reduce(into: []) { $0.formUnion($1.action.layoutNames) }
    case .byOrientation(let landscape, let portrait): return landscape.layoutNames.union(portrait.layoutNames)
    case .autoRepeat(let action, _, _, _, _): return action.layoutNames
    default: return []
    }
  }

  /// This action with every step that applies the layout `old` applying `new` instead (the same
  /// action when none does).
  func renamingLayout(_ old: String, to new: String) -> Action {
    switch self {
    case .layout(let name) where name == old: return .layout(name: new)
    case .chain(let actions): return .chain(actions.map { $0.renamingLayout(old, to: new) })
    case .sequence(let steps):
      return .sequence(steps.map { SequenceStep($0.action.renamingLayout(old, to: new), keepWindow: $0.keepWindow) })
    case .byOrientation(let landscape, let portrait):
      return .byOrientation(
        landscape: landscape.renamingLayout(old, to: new), portrait: portrait.renamingLayout(old, to: new))
    case .autoRepeat(let action, let interval, let mode, let times, let jitter):
      return .autoRepeat(
        action.renamingLayout(old, to: new), interval: interval, mode: mode, times: times, jitter: jitter)
    default: return self
    }
  }
}
