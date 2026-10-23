import SlatedCore

/// A flat, editable view of an `Action`: every parameter any operation can have.
///
/// The editor binds fields to this form and rebuilds the `Action` on each change. Switching the
/// operation keeps compatible values (a Move's width/height become a Corner's), and fields the
/// current operation doesn't use fall back to sensible defaults.
struct ActionForm: Hashable {
  var kind: ActionKind

  // move / corner / throw
  var x = "screenOriginX"
  var y = "screenOriginY"
  var width = "screenSizeX/2"
  var height = "screenSizeY"
  /// Throw and corner only resize when this is on.
  var resizes = false
  var screen: ScreenRef?
  // resize
  var resizeWidth = "+10%"
  var resizeHeight = "+0"
  var anchor: Corner = .topLeft
  // push
  var direction: Direction = .left
  var pushStyle: PushStyle = .barResize("screenSizeX/2")
  // nudge
  var nudgeX = "+10%"
  var nudgeY = "+0"
  // throw
  var throwScreen: ScreenRef = .next
  // corner
  var corner: Corner = .topLeft
  // chain / sequence
  var operations: [Action] = WindowPresets.defaultChain
  var steps: [SequenceStep] = WindowPresets.defaultSequence
  // layout / snapshots
  var name = ""
  var snapshotName = "main"
  var save = false
  var stack = false
  var all = false
  var delete = false
  // focus
  var focusDirection: FocusDirection = .left
  var app = ""
  // overlays
  var hintCharacters = ""
  var gridPadding = 0
  var grids: [GridScreen] = []
  // apps
  var appSelector: AppSelector = .current
  // automation
  var command = ""
  var wait = false
  var workingDirectory = ""
  var text = ""
  var method: InsertMethod = .auto
  var url = "https://"
  var keys = KeyCombo(key: "4", modifiers: [.command, .shift])

  init(kind: ActionKind) {
    self.kind = kind
  }

  init(_ action: Action) {
    kind = ActionKind(action)
    switch action {
    case .move(let x, let y, let w, let h, let screen):
      (self.x, self.y, width, height, self.screen) = (x, y, w, h, screen)
    case .resize(let w, let h, let anchor):
      (resizeWidth, resizeHeight, self.anchor) = (w, h, anchor)
    case .push(let direction, let style, let screen):
      (self.direction, pushStyle, self.screen) = (direction, style, screen)
    case .nudge(let x, let y):
      (nudgeX, nudgeY) = (x, y)
    case .throwWindow(let screen, let w, let h):
      throwScreen = screen
      if let w, let h { (width, height, resizes) = (w, h, true) }
    case .corner(let corner, let w, let h, let screen):
      (self.corner, self.screen) = (corner, screen)
      if let w, let h { (width, height, resizes) = (w, h, true) }
    case .chain(let ops): operations = ops
    case .sequence(let steps): self.steps = steps
    case .layout(let name): self.name = name
    case .focus(let d): focusDirection = d
    case .focusApp(let app): self.app = app
    case .snapshot(let name, let save, let stack): (snapshotName, self.save, self.stack) = (name, save, stack)
    case .deleteSnapshot(let name, let all): (snapshotName, self.all) = (name, all)
    case .activateSnapshot(let name, let delete): (snapshotName, self.delete) = (name, delete)
    case .hint(let chars): hintCharacters = chars ?? ""
    case .grid(let padding, let grids): (gridPadding, self.grids) = (padding ?? 0, grids)
    case .hide(let s), .show(let s), .toggle(let s): appSelector = s
    case .shell(let command, let wait, let path):
      (self.command, self.wait, workingDirectory) = (command, wait, path ?? "")
    case .insertText(let text, let method): (self.text, self.method) = (text, method)
    case .openURL(let url): self.url = url
    case .keystroke(let combo): keys = combo
    case .undo, .relaunch, .switchApp: break
    }
  }

  var action: Action {
    switch kind {
    case .move: return .move(x: x, y: y, width: width, height: height, screen: screen)
    case .resize: return .resize(width: resizeWidth, height: resizeHeight, anchor: anchor)
    case .push: return .push(direction: direction, style: pushStyle, screen: screen)
    case .nudge: return .nudge(x: nudgeX, y: nudgeY)
    case .throwWindow:
      return .throwWindow(screen: throwScreen, width: resizes ? width : nil, height: resizes ? height : nil)
    case .corner:
      return .corner(corner, width: resizes ? width : nil, height: resizes ? height : nil, screen: screen)
    case .chain: return .chain(operations)
    case .sequence: return .sequence(steps)
    case .layout: return .layout(name: name)
    case .focus: return .focus(focusDirection)
    case .focusApp: return .focusApp(app)
    case .hint: return .hint(characters: hintCharacters.isEmpty ? nil : hintCharacters)
    case .grid: return .grid(padding: gridPadding == 0 ? nil : gridPadding, grids: grids)
    case .hide: return .hide(appSelector)
    case .show: return .show(appSelector)
    case .toggle: return .toggle(appSelector)
    case .switchApp: return .switchApp
    case .snapshot: return .snapshot(name: snapshotName, save: save, stack: stack)
    case .activateSnapshot: return .activateSnapshot(name: snapshotName, delete: delete)
    case .deleteSnapshot: return .deleteSnapshot(name: snapshotName, all: all)
    case .undo: return .undo
    case .insertText: return .insertText(text, method: method)
    case .keystroke: return .keystroke(keys)
    case .openURL: return .openURL(url)
    case .shell: return .shell(command: command, wait: wait, path: workingDirectory.isEmpty ? nil : workingDirectory)
    case .relaunch: return .relaunch
    }
  }

  /// `action` converted to another operation, keeping whatever parameters carry over.
  static func convert(_ action: Action, to kind: ActionKind) -> Action {
    var form = ActionForm(action)
    form.kind = kind
    // A Move always has a size; keep it when it becomes a Corner (a Throw stays a plain throw).
    if kind == .corner, case .move = action { form.resizes = true }
    return form.action
  }
}
