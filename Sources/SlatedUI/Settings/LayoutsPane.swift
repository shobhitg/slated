import SlatedCore
import SwiftUI

/// Slate layouts: several apps arranged at once. Slated's own are editable, Slate files' read-only.
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
      if model.configuration.layouts.isEmpty && model.sources.allSatisfy({ $0.layouts.isEmpty }) {
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
    case .slated(let name):
      if let index = model.configuration.layouts.firstIndex(where: { $0.name == name }),
        let layout = model.layoutBinding(name)
      {
        // Keyed by position, not name: renaming mustn't rebuild the editor (and drop focus) on every keystroke.
        LayoutDetail(layout: layout, source: nil)
          .id("slated|\(index)")
      } else {
        noSelection
      }
    case .source(let path, let name):
      if let source = model.sources.first(where: { $0.path == path }),
        let layout = source.layouts.first(where: { $0.name == name })
      {
        LayoutDetail(layout: .constant(layout), source: source)
          .id("\(path)|\(name)")
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
        ForEach(Array(model.configuration.layouts.enumerated()), id: \.offset) { _, layout in
          LayoutRow(layout: layout).tag(LayoutSelection.slated(name: layout.name))
            .contextMenu {
              Button("Delete", role: .destructive) { model.deleteLayout(layout.name) }
            }
        }
      } header: {
        Text("Slated").font(.system(size: 11.5, weight: .semibold)).pinnedHeaderBackground()
      }
      ForEach(model.sources.filter { !$0.layouts.isEmpty }) { source in
        Section {
          ForEach(source.layouts, id: \.name) { layout in
            LayoutRow(layout: layout).tag(LayoutSelection.source(path: source.path, name: layout.name))
          }
        } header: {
          HStack(spacing: 5) {
            Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold))
            Text(source.displayName).font(.system(size: 11.5, weight: .semibold))
            Spacer()
            Text("Read-only").font(.system(size: 10.5)).foregroundStyle(.tertiary)
          }
          .pinnedHeaderBackground()
        }
      }
    }
    .listStyle(.inset)
    .scrollContentBackground(.hidden)
    .background(Theme.paneBackground)
  }

  private var selection: Binding<LayoutSelection?> {
    Binding(get: { model.selectedLayout }, set: { model.selectedLayout = $0 })
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

/// A layout's apps, triggers and preview. Editable when `source` is nil.
private struct LayoutDetail: View {
  @Binding var layout: WindowLayout
  let source: SlateSource?
  @Environment(AppModel.self) private var model
  @State private var confirmDelete = false
  /// The name as typed. It becomes the layout's name whenever it's usable, so typing through
  /// another layout's name ("Work 2" → "Work" → "Workshop") never renames or re-points that layout.
  @State private var nameDraft: String

  init(layout: Binding<WindowLayout>, source: SlateSource?) {
    _layout = layout
    self.source = source
    _nameDraft = State(initialValue: layout.wrappedValue.name)
  }

  private var editable: Bool { source == nil }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        LayoutPreviewCard(layout: layout)
        appsCard
        if editable || !layout.before.isEmpty || !layout.after.isEmpty {
          beforeAfterCard
        }
      }
      .padding(24)
      .frame(maxWidth: 640, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .scrollContentBackground(.hidden)
    .confirmationDialog("Delete “\(layout.name)”?", isPresented: $confirmDelete) {
      Button("Delete", role: .destructive) { model.deleteLayout(layout.name) }
    } message: {
      Text("Shortcuts that apply it will stop working.")
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      IconTile(symbol: "rectangle.3.group", tint: SettingsPane.layouts.tint, size: 38)
      VStack(alignment: .leading, spacing: 5) {
        if editable {
          TextField("Layout name", text: $nameDraft)
            .textFieldStyle(.plain)
            .font(.system(size: 19, weight: .bold))
            .onChange(of: nameDraft) { _, name in
              if model.layoutNameProblem(name, renaming: layout.name) == nil { layout.name = name }
            }
          if let problem = model.layoutNameProblem(nameDraft, renaming: layout.name) {
            Label(problem, systemImage: "exclamationmark.circle.fill")
              .font(.system(size: 11.5))
              .foregroundStyle(Theme.critical)
          }
        } else {
          Text(layout.name).font(.system(size: 19, weight: .bold))
        }
        HStack(spacing: 8) {
          if let source {
            StatusPill(text: "Read-only · \(source.displayName)", color: Theme.neutral, symbol: "lock.fill")
          }
          triggers
        }
      }
      Spacer()
      if editable {
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
  }

  @ViewBuilder private var triggers: some View {
    let triggers = model.triggers(forLayout: layout.name)
    if triggers.isEmpty {
      if editable {
        Button {
          model.selectedPane = .windows
          model.addBinding(action: .layout(name: layout.name))
        } label: {
          Label("Add a Shortcut", systemImage: "plus")
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
      } else {
        Text("No shortcut").font(.system(size: 12)).foregroundStyle(.tertiary)
      }
    } else {
      ForEach(Array(triggers.enumerated()), id: \.offset) { _, trigger in
        KeyComboView(combo: trigger.keys, modal: trigger.modal, size: .small)
      }
    }
  }

  private var appsCard: some View {
    SettingsCard(
      title: "Apps", symbol: "square.stack.3d.up",
      footer: editable
        ? "Operations apply to an app's windows in order: the first to its first window, and so on." : nil
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
          LayoutAppRow(app: appBinding(index), editable: editable) { layout.apps.remove(at: index) }
        }
        if editable {
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
  }

  private var beforeAfterCard: some View {
    SettingsCard(title: "Before & After", symbol: "arrow.left.arrow.right") {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          Text("Before arranging").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
          if editable {
            OperationListEditor(operations: $layout.before, depth: 1, isChain: false)
          } else {
            ReadOnlyOperations(operations: layout.before)
          }
        }
        VStack(alignment: .leading, spacing: 6) {
          Text("After arranging").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
          if editable {
            OperationListEditor(operations: $layout.after, depth: 1, isChain: false)
          } else {
            ReadOnlyOperations(operations: layout.after)
          }
        }
      }
      .padding(16)
    }
  }

  private func appBinding(_ index: Int) -> Binding<LayoutApp> {
    Binding(
      get: { layout.apps.indices.contains(index) ? layout.apps[index] : LayoutApp(app: "", operations: []) },
      set: { if layout.apps.indices.contains(index) { layout.apps[index] = $0 } })
  }
}

private struct LayoutAppRow: View {
  @Binding var app: LayoutApp
  let editable: Bool
  let onRemove: () -> Void
  @Environment(AppModel.self) private var model
  @State private var showOptions = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        let info = model.runningApps.first { $0.name == app.app }
        AppIconView(path: info?.path, bundleID: info?.bundleID, size: 26)
        if editable {
          AppNameField(name: $app.app, showsIcon: false)
            .frame(maxWidth: 240)
        } else {
          Text(app.app).font(.system(size: 13, weight: .semibold))
        }
        Spacer()
        optionTags
        if editable {
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
      }
      if editable {
        OperationListEditor(operations: $app.operations, depth: 1, isChain: false)
          .padding(.leading, 36)
        if showOptions {
          OptionsEditor(options: $app.options)
            .padding(.leading, 36)
        }
      } else {
        ReadOnlyOperations(operations: app.operations)
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

private struct ReadOnlyOperations: View {
  let operations: [Action]

  var body: some View {
    if operations.isEmpty {
      Text("None").font(.system(size: 12)).foregroundStyle(.tertiary)
    } else {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(Array(operations.enumerated()), id: \.offset) { _, operation in
          HStack(spacing: 8) {
            ActionGlyph(action: operation, width: 24, height: 16)
            Text(ActionDescriber.title(operation)).font(.system(size: 12.5))
            Text(ActionDescriber.detail(operation))
              .font(.system(size: 10.5, design: .monospaced))
              .foregroundStyle(.tertiary)
              .lineLimit(1)
          }
        }
      }
    }
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
          operation, screens: model.screens, settings: model.configuration.settings)
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
