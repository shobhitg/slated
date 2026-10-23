import SlatedCore
import SwiftUI

/// The parameter fields for the current operation. Fields bind through `ActionForm`, so every edit
/// rebuilds a valid `Action`.
struct ActionParameters: View {
  @Binding var action: Action
  var depth = 0

  private func field<T>(_ keyPath: WritableKeyPath<ActionForm, T>) -> Binding<T> {
    Binding(
      get: { ActionForm(action)[keyPath: keyPath] },
      set: { newValue in
        var form = ActionForm(action)
        form[keyPath: keyPath] = newValue
        action = form.action
      })
  }

  var body: some View {
    switch ActionKind(action) {
    case .move:
      VStack(alignment: .leading, spacing: 10) {
        ExpressionGrid(fields: [("X", field(\.x)), ("Y", field(\.y)), ("W", field(\.width)), ("H", field(\.height))])
        LabeledField("Display", labelWidth: 56) { ScreenRefPicker(selection: field(\.screen)) }
      }
    case .resize:
      VStack(alignment: .leading, spacing: 10) {
        ExpressionGrid(fields: [("W", field(\.resizeWidth)), ("H", field(\.resizeHeight))], relative: true)
        LabeledField("Anchor", labelWidth: 56) { CornerPicker(corner: field(\.anchor)) }
        Hint("Use +10% or -100 to grow or shrink, or an expression for an exact size.")
      }
    case .push:
      VStack(alignment: .leading, spacing: 10) {
        LabeledField("Edge", labelWidth: 56) { DirectionPicker(direction: field(\.direction)) }
        LabeledField("Size", labelWidth: 56) { PushStylePicker(style: field(\.pushStyle)) }
        if case .barResize = ActionForm(action).pushStyle {
          ExpressionField(label: ActionForm(action).direction.isVertical ? "H" : "W", text: barResizeExpression)
        }
        LabeledField("Display", labelWidth: 56) { ScreenRefPicker(selection: field(\.screen)) }
      }
    case .nudge:
      VStack(alignment: .leading, spacing: 10) {
        ExpressionGrid(fields: [("X", field(\.nudgeX)), ("Y", field(\.nudgeY))], relative: true)
        Hint(
          "Positive values move right and down. Percentages are of the screen size unless nudgePercentOf says otherwise."
        )
      }
    case .throwWindow:
      VStack(alignment: .leading, spacing: 10) {
        LabeledField("Display", labelWidth: 56) {
          ScreenRefPicker(
            selection: Binding(
              get: { ActionForm(action).throwScreen },
              set: { if let ref = $0 { field(\.throwScreen).wrappedValue = ref } }), allowsNone: false)
        }
        Toggle("Resize on the new display", isOn: field(\.resizes)).toggleStyle(.checkbox)
        if ActionForm(action).resizes {
          ExpressionGrid(fields: [("W", field(\.width)), ("H", field(\.height))])
        }
      }
    case .corner:
      VStack(alignment: .leading, spacing: 10) {
        LabeledField("Corner", labelWidth: 56) { CornerPicker(corner: field(\.corner)) }
        Toggle("Resize", isOn: field(\.resizes)).toggleStyle(.checkbox)
        if ActionForm(action).resizes {
          ExpressionGrid(fields: [("W", field(\.width)), ("H", field(\.height))])
        }
        LabeledField("Display", labelWidth: 56) { ScreenRefPicker(selection: field(\.screen)) }
      }
    case .chain:
      OperationListEditor(operations: field(\.operations), depth: depth, isChain: true)
    case .sequence:
      SequenceEditor(steps: field(\.steps), depth: depth)
    case .layout:
      LayoutPicker(name: field(\.name))
    case .focus:
      LabeledField("Direction", labelWidth: 64) { FocusDirectionPicker(direction: field(\.focusDirection)) }
    case .focusApp:
      LabeledField("App", labelWidth: 56) { AppNameField(name: field(\.app)) }
    case .hint:
      LabeledField("Letters", labelWidth: 56) {
        TextField("Default (A–Z, 0–9)", text: field(\.hintCharacters))
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 12, design: .monospaced))
      }
    case .grid:
      GridEditor(padding: field(\.gridPadding), grids: field(\.grids))
    case .hide, .show, .toggle:
      AppSelectorEditor(selector: field(\.appSelector))
    case .switchApp:
      Notice(
        style: .info, title: "Not available yet",
        message: "Slated keeps this binding so your Slate file loads, but the app switcher doesn't run yet.")
    case .snapshot:
      VStack(alignment: .leading, spacing: 10) {
        LabeledField("Name", labelWidth: 56) {
          TextField("main", text: field(\.snapshotName)).textFieldStyle(.roundedBorder)
        }
        Toggle("Save to disk so it survives restarts", isOn: field(\.save)).toggleStyle(.checkbox)
        Toggle("Stack: keep earlier snapshots with this name", isOn: field(\.stack)).toggleStyle(.checkbox)
      }
    case .activateSnapshot:
      VStack(alignment: .leading, spacing: 10) {
        LabeledField("Name", labelWidth: 56) {
          TextField("main", text: field(\.snapshotName)).textFieldStyle(.roundedBorder)
        }
        Toggle("Delete the snapshot after restoring it", isOn: field(\.delete)).toggleStyle(.checkbox)
      }
    case .deleteSnapshot:
      VStack(alignment: .leading, spacing: 10) {
        LabeledField("Name", labelWidth: 56) {
          TextField("main", text: field(\.snapshotName)).textFieldStyle(.roundedBorder)
        }
        Toggle("Delete every stacked snapshot with this name", isOn: field(\.all)).toggleStyle(.checkbox)
      }
    case .undo, .relaunch:
      EmptyView()
    case .insertText:
      VStack(alignment: .leading, spacing: 10) {
        TextEditor(text: field(\.text))
          .font(.system(size: 12.5))
          .frame(minHeight: 70, maxHeight: 140)
          .scrollContentBackground(.hidden)
          .padding(6)
          .wellStyle(radius: 8)
        LabeledField("Insert by", labelWidth: 64) { InsertMethodPicker(method: field(\.method)) }
      }
    case .keystroke:
      LabeledField("Keys", labelWidth: 56) { ShortcutRecorder(combo: field(\.keys), requiresModifier: false) }
    case .openURL:
      LabeledField("URL", labelWidth: 56) {
        TextField("https://example.com", text: field(\.url))
          .textFieldStyle(.roundedBorder)
          .font(.system(size: 12, design: .monospaced))
      }
    case .shell:
      VStack(alignment: .leading, spacing: 10) {
        LabeledField("Command", labelWidth: 72) {
          TextField("open -a Terminal", text: field(\.command))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
        }
        LabeledField("Folder", labelWidth: 72) {
          TextField("Home folder", text: field(\.workingDirectory))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
        }
        Toggle("Wait for the command to finish", isOn: field(\.wait)).toggleStyle(.checkbox)
      }
    }
  }

  private var barResizeExpression: Binding<String> {
    Binding(
      get: {
        if case .barResize(let e) = ActionForm(action).pushStyle { return e }
        return ""
      },
      set: { field(\.pushStyle).wrappedValue = .barResize($0) })
  }
}

/// Secondary explanatory text under a group of fields.
struct Hint: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.system(size: 11))
      .foregroundStyle(.tertiary)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// Expression fields two to a row.
struct ExpressionGrid: View {
  let fields: [(String, Binding<String>)]
  var relative = false

  var body: some View {
    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
      ForEach(Array(stride(from: 0, to: fields.count, by: 2)), id: \.self) { start in
        GridRow(alignment: .top) {
          ExpressionField(label: fields[start].0, text: fields[start].1, relative: relative)
          if start + 1 < fields.count {
            ExpressionField(label: fields[start + 1].0, text: fields[start + 1].1, relative: relative)
          }
        }
      }
    }
  }
}

// MARK: - Pickers

struct DirectionPicker: View {
  @Binding var direction: Direction

  var body: some View {
    Picker("Edge", selection: $direction) {
      Label("Left", systemImage: "arrow.left.to.line").tag(Direction.left)
      Label("Right", systemImage: "arrow.right.to.line").tag(Direction.right)
      Label("Top", systemImage: "arrow.up.to.line").tag(Direction.up)
      Label("Bottom", systemImage: "arrow.down.to.line").tag(Direction.down)
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .fixedSize()
  }
}

struct FocusDirectionPicker: View {
  @Binding var direction: FocusDirection

  var body: some View {
    Picker("Direction", selection: $direction) {
      Label("Left", systemImage: "arrow.left").tag(FocusDirection.left)
      Label("Right", systemImage: "arrow.right").tag(FocusDirection.right)
      Label("Up", systemImage: "arrow.up").tag(FocusDirection.up)
      Label("Down", systemImage: "arrow.down").tag(FocusDirection.down)
      Text("Behind").tag(FocusDirection.behind)
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .fixedSize()
  }
}

struct CornerPicker: View {
  @Binding var corner: Corner

  var body: some View {
    Picker("Corner", selection: $corner) {
      Label("Top Left", systemImage: "arrow.up.left").tag(Corner.topLeft)
      Label("Top Right", systemImage: "arrow.up.right").tag(Corner.topRight)
      Label("Bottom Left", systemImage: "arrow.down.left").tag(Corner.bottomLeft)
      Label("Bottom Right", systemImage: "arrow.down.right").tag(Corner.bottomRight)
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .fixedSize()
  }
}

struct PushStylePicker: View {
  @Binding var style: PushStyle

  private var tag: Binding<String> {
    Binding(
      get: {
        switch style {
        case .none: return "none"
        case .center: return "center"
        case .bar: return "bar"
        case .barResize: return "bar-resize"
        }
      },
      set: { value in
        switch value {
        case "center": style = .center
        case "bar": style = .bar
        case "bar-resize":
          if case .barResize = style { return }
          style = .barResize("screenSizeX/2")
        default: style = .none
        }
      })
  }

  var body: some View {
    Picker("Size", selection: tag) {
      Text("Keep").tag("none")
      Text("Centered").tag("center")
      Text("Fill Edge").tag("bar")
      Text("Fill & Resize").tag("bar-resize")
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .fixedSize()
  }
}

struct InsertMethodPicker: View {
  @Binding var method: InsertMethod

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Picker("Insert by", selection: $method) {
        Text("Automatic").tag(InsertMethod.auto)
        Text("Typing").tag(InsertMethod.type)
        Text("Pasting").tag(InsertMethod.paste)
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .fixedSize()
      Hint(method.explanation)
    }
  }
}

extension InsertMethod {
  var explanation: String {
    switch self {
    case .auto: return "Types short text and pastes long text."
    case .type: return "Types each character. Works in every app; slower for long text."
    case .paste: return "Pastes through the clipboard, then puts your clipboard back."
    }
  }
}

/// Slate screen references: the window's own display, relative ones, or a specific display.
struct ScreenRefPicker: View {
  @Binding var selection: ScreenRef?
  var allowsNone = true
  @Environment(AppModel.self) private var model

  var body: some View {
    let ordered = model.screens.orderedLeftToRight()
    Picker("Display", selection: tag) {
      if allowsNone {
        Text("Window's display").tag("")
        Divider()
      }
      Text("Next display").tag("next")
      Text("Previous display").tag("previous")
      Text("Display to the left").tag("left")
      Text("Display to the right").tag("right")
      Text("Display above").tag("up")
      Text("Display below").tag("down")
      Divider()
      ForEach(Array(ordered.enumerated()), id: \.offset) { index, screen in
        Text("Display \(index + 1) · \(screen.name)").tag(String(index))
      }
      if let selection, !knownTags(count: ordered.count).contains(selection.slate) {
        Text(selection.slate).tag(selection.slate)
      }
    }
    .labelsHidden()
    .fixedSize()
  }

  private func knownTags(count: Int) -> Set<String> {
    Set(["next", "previous", "left", "right", "up", "down"] + (0..<count).map(String.init))
  }

  private var tag: Binding<String> {
    Binding(
      get: { selection?.slate ?? "" },
      set: { selection = $0.isEmpty ? nil : ScreenRef(slate: $0) })
  }
}

/// Picks one of the layouts defined in config.json or a Slate file.
struct LayoutPicker: View {
  @Binding var name: String
  @Environment(AppModel.self) private var model

  var body: some View {
    let names = model.knownLayoutNames.sorted()
    VStack(alignment: .leading, spacing: 8) {
      LabeledField("Layout", labelWidth: 56) {
        if names.isEmpty {
          Text("No layouts yet").foregroundStyle(.secondary)
        } else {
          Picker("Layout", selection: $name) {
            if !names.contains(name) { Text(name.isEmpty ? "Choose…" : name).tag(name) }
            ForEach(names, id: \.self) { Text($0).tag($0) }
          }
          .labelsHidden()
          .fixedSize()
        }
      }
      Button("Edit Layouts…") { model.selectedPane = .layouts }
        .buttonStyle(.link)
        .font(.system(size: 12))
        .padding(.leading, 68)
    }
  }
}

/// An app name (Slate matches apps by name) with a menu of running apps.
struct AppNameField: View {
  @Binding var name: String
  var prompt = "Safari"
  /// Shows the app's icon before the field (off where the row already shows it).
  var showsIcon = true
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 6) {
      if showsIcon, let app = model.runningApps.first(where: { $0.name == name }) {
        AppIconView(path: app.path, bundleID: app.bundleID, size: 18)
      }
      TextField(prompt, text: $name)
        .textFieldStyle(.roundedBorder)
      Menu {
        ForEach(model.runningApps) { app in
          Button(app.name) { name = app.name }
        }
      } label: {
        Image(systemName: "app.badge")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .help("Choose a running app")
    }
  }
}

/// Which apps hide/show/toggle act on.
struct AppSelectorEditor: View {
  @Binding var selector: AppSelector
  @Environment(AppModel.self) private var model

  private var mode: Binding<String> {
    Binding(
      get: {
        switch selector {
        case .current: return "current"
        case .all: return "all"
        case .allBut: return "allBut"
        case .apps: return "apps"
        }
      },
      set: { value in
        switch value {
        case "all": selector = .all
        case "allBut": selector = .allBut("")
        case "apps": selector = .apps([])
        default: selector = .current
        }
      })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Picker("Apps", selection: mode) {
        Text("Current App").tag("current")
        Text("All Apps").tag("all")
        Text("All But…").tag("allBut")
        Text("These Apps").tag("apps")
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .fixedSize()
      switch selector {
      case .allBut(let app):
        LabeledField("Except", labelWidth: 56) {
          AppNameField(name: Binding(get: { app }, set: { selector = .allBut($0) }))
        }
      case .apps(let apps):
        AppChips(names: apps) { selector = .apps($0) }
      default:
        EmptyView()
      }
    }
  }
}

/// A wrap of app chips with an "Add App" menu.
struct AppChips: View {
  let names: [String]
  let onChange: ([String]) -> Void
  @Environment(AppModel.self) private var model

  var body: some View {
    FlowLayout(spacing: 6) {
      ForEach(names, id: \.self) { name in
        HStack(spacing: 5) {
          if let app = model.runningApps.first(where: { $0.name == name }) {
            AppIconView(path: app.path, bundleID: app.bundleID, size: 14)
          }
          Text(name).font(.system(size: 12))
          Button {
            onChange(names.filter { $0 != name })
          } label: {
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.well, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.wellStroke))
      }
      Menu {
        ForEach(model.runningApps.filter { !names.contains($0.name) }) { app in
          Button(app.name) { onChange(names + [app.name]) }
        }
      } label: {
        Label("Add App", systemImage: "plus")
          .font(.system(size: 12))
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
  }
}

/// Per-display grid sizes for the grid overlay.
struct GridEditor: View {
  @Binding var padding: Int
  @Binding var grids: [GridScreen]
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      LabeledField("Padding", labelWidth: 56) {
        Stepper("\(padding) pt", value: $padding, in: 0...40)
          .font(.system(size: 12.5).monospacedDigit())
          .fixedSize()
      }
      ForEach(Array(grids.enumerated()), id: \.offset) { index, grid in
        HStack(spacing: 10) {
          Text("Display \((Int(grid.screen) ?? 0) + 1)")
            .font(.system(size: 12.5))
            .frame(width: 72, alignment: .leading)
          Stepper("\(grid.width) wide", value: size(index, \.width), in: 1...24).fixedSize()
          Stepper("\(grid.height) tall", value: size(index, \.height), in: 1...24).fixedSize()
          Spacer()
          Button {
            if grids.indices.contains(index) { grids.remove(at: index) }
          } label: {
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
        }
        .font(.system(size: 12.5).monospacedDigit())
      }
      if grids.count < max(model.screens.count, 1) {
        Button {
          let used = Set(grids.map(\.screen))
          let next = (0..<max(model.screens.count, 1)).map(String.init).first { !used.contains($0) } ?? "0"
          grids.append(GridScreen(screen: next, width: 6, height: 4))
        } label: {
          Label("Set a Grid Size for a Display", systemImage: "plus")
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
      }
      if grids.isEmpty {
        Hint("Without sizes, every display uses Slate's default grid.")
      }
    }
  }

  /// A bounds-checked binding to one grid's width or height, safe while rows are being removed.
  private func size(_ index: Int, _ keyPath: WritableKeyPath<GridScreen, Int>) -> Binding<Int> {
    Binding(
      get: { grids.indices.contains(index) ? grids[index][keyPath: keyPath] : 1 },
      set: { if grids.indices.contains(index) { grids[index][keyPath: keyPath] = $0 } })
  }
}

/// A simple flow layout that wraps its children onto new lines.
struct FlowLayout: SwiftUI.Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? .infinity
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var widest: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        y += rowHeight + spacing
        x = 0
        rowHeight = 0
      }
      x += size.width + spacing
      widest = max(widest, x - spacing)
      rowHeight = max(rowHeight, size.height)
    }
    return CGSize(width: min(widest, width), height: y + rowHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX
    var y = bounds.minY
    var rowHeight: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > bounds.minX, x + size.width > bounds.maxX {
        y += rowHeight + spacing
        x = bounds.minX
        rowHeight = 0
      }
      subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
  }
}
