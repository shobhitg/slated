import SlatedCore
import SwiftUI

/// Layouts (Slate's `layout`): several apps arranged at once.
struct LayoutsPane: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(pane: .layouts, subtitle: "Arrange several apps at once — one shortcut sets up a whole workspace.") {
        Button {
          model.addLayout()
        } label: {
          Label("New Layout", systemImage: "plus")
        }
        .buttonStyle(.gradient)
      }
      .padding(.horizontal, Theme.paneHorizontalPadding)
      .padding(.top, 22)
      .padding(.bottom, 16)
      Rectangle().fill(Theme.hairline).frame(height: 0.5)
      if model.configuration.layouts.isEmpty {
        EmptyStateView(
          symbol: "rectangle.3.group", title: "No layouts yet",
          message:
            "A layout puts Xcode on the left two-thirds, Safari on the right and Slack on your second display — all with one shortcut."
        ) {
          Button("Create a Layout") { model.addLayout() }
            .buttonStyle(.gradient)
        }
        .frame(maxHeight: .infinity)
      } else {
        HStack(spacing: 0) {
          LayoutList()
            .frame(width: 280)
          Rectangle().fill(Theme.hairline).frame(width: 0.5)
          detail
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
    }
  }

  @ViewBuilder private var detail: some View {
    switch model.selectedLayout {
    case .slated(let name, _):
      if let index = model.selectedLayoutIndex, let layout = model.layoutBinding(name, at: index) {
        // Keyed by position, not name: renaming mustn't rebuild the editor (and drop focus) on every keystroke.
        LayoutDetail(layout: layout, index: index)
          .id("slated|\(index)")
      } else {
        noSelection
      }
    case nil:
      noSelection
    }
  }

  private var noSelection: some View {
    EmptyStateView(
      symbol: "rectangle.3.group", title: "Pick a layout",
      message: "Select a layout to see which apps it arranges and where they go."
    )
    .frame(maxHeight: .infinity)
  }
}

private struct LayoutList: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    List(selection: selection) {
      Section {
        if model.configuration.layouts.isEmpty {
          Text("None yet — click New Layout.").font(.system(size: 12)).foregroundStyle(.tertiary).selectionDisabled()
        }
        ForEach(Array(model.configuration.layouts.enumerated()), id: \.offset) { index, layout in
          LayoutRow(layout: layout).tag(LayoutSelection.slated(name: layout.name, index: index))
            .contextMenu {
              Button("Delete", role: .destructive) { model.deleteLayout(layout.name, at: index) }
            }
        }
      } header: {
        Text("Slated").font(.system(size: 11.5, weight: .semibold)).pinnedHeaderBackground()
      }
    }
    .listStyle(.inset)
    .scrollContentBackground(.hidden)
    .background(Theme.paneBackground)
  }

  /// The selection as the rows are tagged: a Slated layout with its position.
  private var selection: Binding<LayoutSelection?> {
    Binding(
      get: {
        guard case .slated(let name, _) = model.selectedLayout, let index = model.selectedLayoutIndex else {
          return model.selectedLayout
        }
        return .slated(name: name, index: index)
      },
      set: { model.selectedLayout = $0 })
  }
}

private struct LayoutRow: View {
  let layout: WindowLayout
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 10) {
      IconTile(symbol: "rectangle.3.group", tint: SettingsPane.layouts.tint, size: 26)
      VStack(alignment: .leading, spacing: 2) {
        Text(layout.name.isEmpty ? "Untitled" : layout.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
        Text(layout.apps.isEmpty ? "No apps yet" : layout.apps.map(\.app).joined(separator: ", "))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 4)
      if let trigger = model.triggers(forLayout: layout.name).first {
        KeyComboView(combo: trigger.keys, modal: trigger.modal, size: .small)
      }
    }
    .padding(.vertical, 3)
  }
}

/// A layout's apps, triggers and preview. `index` is the layout's place in `layouts`.
private struct LayoutDetail: View {
  @Binding var layout: WindowLayout
  let index: Int?
  @Environment(AppModel.self) private var model
  @State private var confirmDelete = false
  /// The name as typed. It becomes the layout's name whenever it's usable, so typing through
  /// another layout's name ("Work 2" → "Work" → "Workshop") never renames or re-points that layout.
  @State private var nameDraft: String
  /// What applied each name this layout took while typing, before it took it (see
  /// `AppModel.typeLayoutName`).
  @State private var nameArrivals: [String: Set<LayoutReference>] = [:]

  init(layout: Binding<WindowLayout>, index: Int?) {
    _layout = layout
    self.index = index
    _nameDraft = State(initialValue: layout.wrappedValue.name)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        LayoutPreviewCard(layout: layout)
        appsCard
        beforeAfterCard
      }
      .padding(24)
      .frame(maxWidth: 640, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .scrollContentBackground(.hidden)
    .confirmationDialog("Delete “\(layout.name)”?", isPresented: $confirmDelete) {
      Button("Delete", role: .destructive) { model.deleteLayout(layout.name, at: index) }
    } message: {
      Text("Shortcuts that apply it will stop working.")
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      IconTile(symbol: "rectangle.3.group", tint: SettingsPane.layouts.tint, size: 38)
      VStack(alignment: .leading, spacing: 5) {
        let nameProblem = model.layoutNameProblem(nameDraft, renaming: layout.name, at: index)
        TextField("Layout name", text: $nameDraft)
          .textFieldStyle(.plain)
          .font(.system(size: 19, weight: .bold))
          .onChange(of: nameDraft) { _, name in commitName(name) }
          // A refused name can become usable with no keystroke, e.g. when the other layout is deleted.
          .onChange(of: nameProblem) { _, problem in
            if problem == nil { commitName(nameDraft) }
          }
        if let problem = nameProblem {
          Label(problem, systemImage: "exclamationmark.circle.fill")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.critical)
        }
        HStack(spacing: 8) { triggers }
      }
      Spacer()
      Menu {
        Button("Delete…", role: .destructive) { confirmDelete = true }
      } label: {
        Image(systemName: "ellipsis.circle").font(.system(size: 15))
      }
      .accessibilityLabel("More")
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
  }

  @ViewBuilder private var triggers: some View {
    let triggers = model.triggers(forLayout: layout.name)
    if triggers.isEmpty {
      Button {
        model.selectedPane = .windows
        model.addBinding(action: .layout(name: layout.name))
      } label: {
        Label("Add a Shortcut", systemImage: "plus")
      }
      .buttonStyle(.link)
      .font(.system(size: 12))
    } else {
      ForEach(Array(triggers.enumerated()), id: \.offset) { _, trigger in
        KeyComboView(combo: trigger.keys, modal: trigger.modal, size: .small)
      }
    }
  }

  private var appsCard: some View {
    SettingsCard(
      title: "Apps", symbol: "square.stack.3d.up",
      footer: "Operations apply to an app's windows in order: the first to its first window, and so on."
    ) {
      VStack(spacing: 0) {
        if layout.apps.isEmpty {
          Text("No apps yet. Add the apps this layout should arrange.")
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        ForEach(layout.apps.indices, id: \.self) { index in
          if index > 0 { CardDivider() }
          LayoutAppRow(app: appBinding(index)) { layout.apps.remove(at: index) }
        }
        CardDivider()
        HStack {
          Menu {
            ForEach(model.runningApps.filter { app in !layout.apps.contains { $0.app == app.name } }) { app in
              Button(app.name) {
                layout.apps.append(LayoutApp(app: app.name, operations: [WindowPresets.preset("maximize").action]))
              }
            }
          } label: {
            Label("Add App", systemImage: "plus.circle.fill").font(.system(size: 12.5, weight: .medium))
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
      }
    }
  }

  private var beforeAfterCard: some View {
    SettingsCard(title: "Before & After", symbol: "arrow.left.arrow.right") {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Before arranging").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
          OperationListEditor(operations: $layout.before, depth: 1, isChain: false)
        }
        VStack(alignment: .leading, spacing: 6) {
          Text("After arranging").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
          OperationListEditor(operations: $layout.after, depth: 1, isChain: false)
        }
      }
      .padding(16)
    }
  }

  /// Makes the typed name the layout's name when it's usable (see `AppModel.typeLayoutName`).
  private func commitName(_ name: String) {
    let after = model.typeLayoutName(name, renaming: layout.name, at: index, arrivals: &nameArrivals)
    // Refused although the name is fine (Settings is read-only while config.json can't be read): show
    // the name the layout keeps, as fields bound to the model do.
    if after != name, model.layoutNameProblem(name, renaming: after, at: index) == nil { nameDraft = after }
  }

  private func appBinding(_ index: Int) -> Binding<LayoutApp> {
    Binding(
      get: { layout.apps.indices.contains(index) ? layout.apps[index] : LayoutApp(app: "", operations: []) },
      set: { if layout.apps.indices.contains(index) { layout.apps[index] = $0 } })
  }
}

private struct LayoutAppRow: View {
  @Binding var app: LayoutApp
  let onRemove: () -> Void
  @Environment(AppModel.self) private var model
  @State private var showOptions = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        let info = model.runningApps.first { $0.name == app.app }
        AppIconView(path: info?.path, bundleID: info?.bundleID, size: 26)
        AppNameField(name: $app.app, showsIcon: false)
          .frame(maxWidth: 240)
        Spacer()
        optionTags
        Menu {
          Button(showOptions ? "Hide Options" : "Show Options") { showOptions.toggle() }
          Divider()
          Button("Remove App", role: .destructive, action: onRemove)
        } label: {
          Image(systemName: "ellipsis")
        }
        .accessibilityLabel("Options for \(app.app.isEmpty ? "this app" : app.app)")
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
      }
      OperationListEditor(operations: $app.operations, depth: 1, isChain: false)
        .padding(.leading, 36)
      if showOptions {
        OptionsEditor(options: $app.options)
          .padding(.leading, 36)
      }
    }
    .padding(16)
  }

  @ViewBuilder private var optionTags: some View {
    let tags = Self.tags(app.options)
    if !tags.isEmpty {
      HStack(spacing: 4) {
        ForEach(tags, id: \.self) { tag in
          Text(tag)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.well, in: Capsule())
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  static func tags(_ options: LayoutAppOptions) -> [String] {
    var tags: [String] = []
    if options.ignoreFail { tags.append("If running") }
    if options.repeat { tags.append("Repeat") }
    if options.repeatLast { tags.append("Repeat last") }
    if options.mainFirst { tags.append("Main first") }
    if options.mainLast { tags.append("Main last") }
    if options.sortTitle { tags.append("By title") }
    return tags
  }
}

private struct OptionsEditor: View {
  @Binding var options: LayoutAppOptions

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Toggle("Skip quietly if the app isn't running", isOn: $options.ignoreFail)
      Toggle("Repeat the operations for extra windows", isOn: $options.repeat)
      Toggle("Arrange the main window first", isOn: $options.mainFirst)
      Toggle("Order windows by title", isOn: $options.sortTitle)
    }
    .toggleStyle(.checkbox)
    .font(.system(size: 12))
    .padding(12)
    .wellStyle()
  }
}

/// Every app's first window, placed by its first operation, on the miniature screens.
private struct LayoutPreviewCard: View {
  let layout: WindowLayout
  @Environment(AppModel.self) private var model

  var body: some View {
    let result = placements
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "eye").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
        Text("Preview").font(.system(size: 13, weight: .semibold))
        Spacer()
        Text(layout.apps.isEmpty ? "" : "\(layout.apps.count) app\(layout.apps.count == 1 ? "" : "s")")
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 10)
      ZStack {
        ScreenPreview(screens: model.screens, dimmed: result.windows.isEmpty, windows: result.windows)
        if result.windows.isEmpty {
          if layout.apps.isEmpty {
            PreviewMessage(symbol: "plus.rectangle.on.rectangle", title: "Add apps to see the layout")
          } else {
            PreviewMessage(symbol: "eye.slash", title: "Preview unavailable", detail: result.reason)
          }
        }
      }
      .frame(height: 190)
      .padding(.horizontal, 20)
      .padding(.top, 16)
      .padding(.bottom, 12)
      .background(PreviewStage())
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .padding([.horizontal, .bottom], 8)
    }
    .cardStyle(padding: 0)
  }

  private var placements: (windows: [ScreenPreview.PreviewWindow], reason: String?) {
    var windows: [ScreenPreview.PreviewWindow] = []
    var reason: String?
    for (index, app) in layout.apps.enumerated() {
      guard let operation = app.operations.first,
        let placement = PlacementCalculator.place(
          operation, screens: model.screens, settings: model.configuration.windows)
      else { continue }
      switch placement.state {
      case .placed(let frame):
        let hue = (0.70 + Double(index) * 0.13).truncatingRemainder(dividingBy: 1)
        windows.append(.init(frame: frame, label: app.app, hue: hue))
      case .unavailable(let why):
        reason = reason ?? why
      case .nothingToPreview:
        break
      }
    }
    return (windows, reason)
  }
}
