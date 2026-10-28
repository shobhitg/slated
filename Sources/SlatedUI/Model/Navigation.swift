import Foundation

/// The panes of the main window.
public enum SettingsPane: String, CaseIterable, Identifiable, Hashable, Sendable {
  /// First-run setup (`GetStartedStep`). In the sidebar while setup isn't finished, and while open.
  case getStarted
  case overview
  case windows
  case hotstrings
  case clipboard
  case automation
  case keyboard
  case layouts
  case slate
  case general
  case about

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .getStarted: return "Get Started"
    case .overview: return "Overview"
    case .windows: return "Windows"
    case .hotstrings: return "Hotstrings"
    case .clipboard: return "Clipboard"
    case .automation: return "Automation"
    case .keyboard: return "Keyboard"
    case .layouts: return "Layouts"
    case .slate: return "Slate Compatibility"
    case .general: return "General"
    case .about: return "About"
    }
  }
}

/// The steps of Get Started, in order.
public enum GetStartedStep: Int, CaseIterable, Sendable {
  case welcome, accessibility, hyperKey, slateConfig, done
}

/// Which binding is selected in Settings → Windows.
public enum BindingSelection: Hashable, Sendable {
  /// One of Slated's own (editable) bindings.
  case slated(UUID)
  /// A read-only binding from a Slate file; `id` is `SourceBinding.id`.
  case source(path: String, id: String)
}

/// Which layout is selected in Settings → Layouts.
public enum LayoutSelection: Hashable, Sendable {
  /// One of Slated's own layouts. `index` is its place in `layouts` (see `AppModel.layoutIndex`): a
  /// layout copied in config.json shares its name with the original.
  case slated(name: String, index: Int? = nil)
  case source(path: String, name: String)
}

/// A short confirmation shown at the bottom of the main window.
struct Toast: Identifiable, Equatable {
  enum Style { case success, info, failure }

  let id = UUID()
  var message: String
  var symbol: String
  var style: Style
}
