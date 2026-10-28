import SlatedCore

extension SourceBinding {
  /// What the shortcut does, as Settings and the island's cheat sheet name it: "Left Half", or
  /// "JavaScript Function" when Slated can't tell.
  public var title: String { action.map(ActionDescriber.title) ?? "JavaScript Function" }

  /// True when the shortcut runs a JavaScript function, whether or not Slated can show what it does.
  var runsFunction: Bool { function != nil || action == nil }

  /// Why Slated can't show what the function does ("depends on the focused app or window title").
  var undescribedReason: String? {
    if case .undescribed(let reason) = function { return reason }
    return nil
  }

  /// The line under the title in lists: the operation as the file writes it, or for a function, that
  /// it is one, or why Slated can't show what it does.
  var caption: String {
    if function == .described { return "JavaScript function" }
    if let reason = undescribedReason, !reason.isEmpty { return reason.prefix(1).uppercased() + reason.dropFirst() }
    return runsFunction ? "Runs code in your Slate file" : summary
  }
}
