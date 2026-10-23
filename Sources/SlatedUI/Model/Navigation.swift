import Foundation

/// The panes of the settings window.
public enum SettingsPane: String, CaseIterable, Identifiable, Hashable, Sendable {
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

/// Which binding is selected in Settings → Windows.
public enum BindingSelection: Hashable, Sendable {
  /// One of Slated's own (editable) bindings.
  case slated(UUID)
  /// A read-only binding from a Slate file; `id` is `SourceBinding.id`.
  case source(path: String, id: String)
}

/// Which layout is selected in Settings → Layouts.
public enum LayoutSelection: Hashable, Sendable {
  case slated(name: String)
  case source(path: String, name: String)
}

/// A short confirmation shown at the bottom of the settings window.
struct Toast: Identifiable, Equatable {
  enum Style { case success, info, failure }

  let id = UUID()
  var message: String
  var symbol: String
  var style: Style
}
