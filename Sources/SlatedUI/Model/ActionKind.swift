import SlatedCore

/// One entry in the action picker per `Action` case (`focus` is split into direction and app).
///
/// When `Action` gains a case, handle it in: `ActionKind` (here: case, `init`, category, title,
/// explanation, symbol), `ActionForm` (fields, `init`, `action`), `ActionDescriber` (`title`,
/// `localDetail`), `ConfigValidator.actionProblems`, `PlacementCalculator` and `ActionParameters`.
/// Composite actions can reuse the nested editors (`OperationListEditor`, `OrientationEditor`).
enum ActionKind: String, CaseIterable, Identifiable, Hashable {
  case move, resize, push, nudge, throwWindow, corner
  case chain, sequence, layout, byOrientation
  case focus, focusApp, hint, grid
  case hide, show, toggle, switchApp
  case snapshot, activateSnapshot, deleteSnapshot, undo
  case insertText, keystroke, openURL, shell, relaunch, clipboardHistory
  case click, press, hold, autoRepeat, wait, stopAutomations

  enum Category: String, CaseIterable, Identifiable {
    case window = "Window"
    case combine = "Combine"
    case focus = "Focus"
    case apps = "Apps"
    case snapshots = "Snapshots"
    /// Text, keystrokes, URLs, commands. (Named apart from Settings → Automation, which is about
    /// the Mouse & Keys actions.)
    case automation = "Utilities"
    case input = "Mouse & Keys"

    var id: String { rawValue }

    var kinds: [ActionKind] { ActionKind.allCases.filter { $0.category == self } }
  }

  var id: String { rawValue }

  init(_ action: Action) {
    switch action {
    case .move: self = .move
    case .resize: self = .resize
    case .push: self = .push
    case .nudge: self = .nudge
    case .throwWindow: self = .throwWindow
    case .corner: self = .corner
    case .chain: self = .chain
    case .sequence: self = .sequence
    case .layout: self = .layout
    case .byOrientation: self = .byOrientation
    case .focus: self = .focus
    case .focusApp: self = .focusApp
    case .snapshot: self = .snapshot
    case .deleteSnapshot: self = .deleteSnapshot
    case .activateSnapshot: self = .activateSnapshot
    case .hint: self = .hint
    case .grid: self = .grid
    case .hide: self = .hide
    case .show: self = .show
    case .toggle: self = .toggle
    case .shell: self = .shell
    case .undo: self = .undo
    case .relaunch: self = .relaunch
    case .switchApp: self = .switchApp
    case .insertText: self = .insertText
    case .openURL: self = .openURL
    case .keystroke: self = .keystroke
    case .clipboardHistory: self = .clipboardHistory
    case .click: self = .click
    case .press: self = .press
    case .hold: self = .hold
    case .autoRepeat: self = .autoRepeat
    case .wait: self = .wait
    case .stopAutomations: self = .stopAutomations
    }
  }

  var category: Category {
    switch self {
    case .move, .resize, .push, .nudge, .throwWindow, .corner: return .window
    case .chain, .sequence, .layout, .byOrientation: return .combine
    case .focus, .focusApp, .hint, .grid: return .focus
    case .hide, .show, .toggle, .switchApp: return .apps
    case .snapshot, .activateSnapshot, .deleteSnapshot, .undo: return .snapshots
    case .insertText, .keystroke, .openURL, .shell, .relaunch, .clipboardHistory: return .automation
    case .click, .press, .hold, .autoRepeat, .wait, .stopAutomations: return .input
    }
  }

  var title: String {
    switch self {
    case .move: return "Move & Resize"
    case .resize: return "Resize"
    case .push: return "Push to Edge"
    case .nudge: return "Nudge"
    case .throwWindow: return "Throw to Screen"
    case .corner: return "Corner"
    case .chain: return "Chain"
    case .sequence: return "Sequence"
    case .layout: return "Apply Layout"
    case .byOrientation: return "By Screen Orientation"
    case .focus: return "Focus Direction"
    case .focusApp: return "Focus App"
    case .hint: return "Window Hints"
    case .grid: return "Grid"
    case .hide: return "Hide Apps"
    case .show: return "Show Apps"
    case .toggle: return "Toggle Apps"
    case .switchApp: return "App Switcher"
    case .snapshot: return "Take Snapshot"
    case .activateSnapshot: return "Restore Snapshot"
    case .deleteSnapshot: return "Delete Snapshot"
    case .undo: return "Undo"
    case .insertText: return "Insert Text"
    case .keystroke: return "Press Keys"
    case .openURL: return "Open URL"
    case .shell: return "Run Shell Command"
    case .relaunch: return "Reload Configuration"
    case .clipboardHistory: return "Clipboard History"
    case .click: return "Click"
    case .press: return "Press or Release"
    case .hold: return "Hold Down"
    case .autoRepeat: return "Auto-Repeat"
    case .wait: return "Wait"
    case .stopAutomations: return "Stop Automations"
    }
  }

  /// One line under the picker explaining what the action does.
  var explanation: String {
    switch self {
    case .move: return "Place the window at an exact position and size. Expressions can use the screen and window size."
    case .resize: return "Grow or shrink the window, keeping one corner fixed."
    case .push: return "Slide the window against a screen edge, optionally stretching it along that edge."
    case .nudge: return "Move the window by a small amount without resizing it."
    case .throwWindow: return "Send the window to another display."
    case .corner: return "Snap the window into a corner, optionally resizing it."
    case .chain: return "Each press runs the next operation, then wraps around — great for cycling sizes."
    case .sequence: return "Run several operations in order with one shortcut."
    case .layout: return "Arrange several apps' windows at once."
    case .byOrientation: return "Do one thing on landscape displays and another on portrait ones — thirds side by side or stacked, say."
    case .focus: return "Focus the nearest window in a direction."
    case .focusApp: return "Bring an app to the front."
    case .hint: return "Show a letter over every window; type it to focus that window."
    case .grid: return "Show a grid over each screen and drag out the window's new frame."
    case .hide: return "Hide the current app, all apps, or a list of apps."
    case .show: return "Unhide apps."
    case .toggle: return "Hide apps that are visible and show apps that are hidden."
    case .switchApp: return "Slate's app switcher. Slated recognizes it but doesn't run it yet."
    case .snapshot: return "Remember where every window is, to restore later."
    case .activateSnapshot: return "Put windows back where a snapshot saw them."
    case .deleteSnapshot: return "Forget a snapshot."
    case .undo: return "Put the last moved window back where it was."
    case .insertText: return "Type or paste text into the focused app."
    case .keystroke: return "Send a keyboard shortcut to the focused app."
    case .openURL: return "Open a link or app URL scheme."
    case .shell: return "Run a command in the background."
    case .relaunch: return "Reload config.json and settings.json."
    case .clipboardHistory: return "Open the clipboard history to search and paste something you copied earlier."
    case .click: return "Click a mouse button where the pointer is."
    case .press: return "Press or release a mouse button or key on its own: a building block for macros with waits."
    case .hold: return "Hold a mouse button or key down until this shortcut fires again, e.g. keep W pressed to auto-run."
    case .autoRepeat:
      return "Repeat a click or a key on a timer: an auto-clicker or key spammer, toggled by the shortcut or while it's held."
    case .wait: return "Pause a sequence for a moment, to time the steps of a macro."
    case .stopAutomations: return "Stop every running auto-repeat and let go of anything held down."
    }
  }

  var symbol: String {
    switch self {
    case .move: return "arrow.up.and.down.and.arrow.left.and.right"
    case .resize: return "arrow.up.left.and.arrow.down.right"
    case .push: return "arrow.left.to.line"
    case .nudge: return "arrow.right.circle"
    case .throwWindow: return "rectangle.portrait.and.arrow.right"
    case .corner: return "arrow.up.left.square"
    case .chain: return "link"
    case .sequence: return "list.number"
    case .layout: return "rectangle.3.group"
    case .byOrientation: return "rectangle.portrait.rotate"
    case .focus: return "scope"
    case .focusApp: return "app.badge.checkmark"
    case .hint: return "character.cursor.ibeam"
    case .grid: return "square.grid.3x3"
    case .hide: return "eye.slash"
    case .show: return "eye"
    case .toggle: return "eye.trianglebadge.exclamationmark"
    case .switchApp: return "square.stack.3d.forward.dottedline"
    case .snapshot: return "camera.viewfinder"
    case .activateSnapshot: return "clock.arrow.circlepath"
    case .deleteSnapshot: return "trash"
    case .undo: return "arrow.uturn.backward"
    case .insertText: return "text.insert"
    case .keystroke: return "keyboard"
    case .openURL: return "link.circle"
    case .shell: return "terminal"
    case .relaunch: return "arrow.clockwise"
    case .clipboardHistory: return "list.clipboard"
    case .click: return "cursorarrow.click"
    case .press: return "hand.point.up.left"
    case .hold: return "hand.tap"
    case .autoRepeat: return "repeat"
    case .wait: return "hourglass"
    case .stopAutomations: return "stop.circle"
    }
  }

  /// Window-geometry kinds get presets and a placement preview.
  var isWindowGeometry: Bool { category == .window }
}
