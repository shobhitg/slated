import SlatedCore
import SwiftUI

/// Edits one of Slated's own shortcuts: name, keys, action, with a live placement preview.
struct BindingEditor: View {
  @Binding var binding: HotkeyBinding
  @Environment(AppModel.self) private var model
  @State private var confirmDelete = false
  @State private var showAdvanced = false

  var body: some View {
    let state = model.state(for: binding)
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header(state)
        if let explanation = state.explanation, state != .disabled {
          Notice(style: state == .duplicate ? .warning : .error, title: state.pill.text, message: explanation)
        }
        if binding.action.containsAutomation {
          AutomationSafetyNote()
        }
        // Automations that never touch a window get no window preview.
        if PlacementCalculator.previews(binding.action),
          !binding.action.containsAutomation || binding.action.containsWindowGeometry
        {
          PlacementPreviewCard(action: binding.action)
        }
        shortcutCard
        SettingsCard(title: "Action", symbol: "bolt.fill") {
          ActionEditor(action: $binding.action)
            .padding(16)
        }
        issueList
      }
      .padding(24)
      .frame(maxWidth: 640, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .scrollContentBackground(.hidden)
    .confirmationDialog("Delete “\(BindingTitle.title(for: binding))”?", isPresented: $confirmDelete) {
      Button("Delete", role: .destructive) { model.deleteBinding(binding.id) }
    } message: {
      Text("The shortcut stops working right away.")
    }
  }

  private func header(_ state: BindingState) -> some View {
    HStack(alignment: .center, spacing: 12) {
      if binding.action.containsAutomation {
        AutomationThumbnail(action: binding.action)
      } else {
        ActionGlyph(action: binding.action, width: 40, height: 28)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(BindingTitle.title(for: binding))
          .font(.system(size: 19, weight: .bold))
          .tracking(-0.2)
          .lineLimit(1)
        HStack(spacing: 8) {
          let pill = state.pill
          StatusPill(text: pill.text, color: pill.color, symbol: pill.symbol)
          if !binding.keys.key.isEmpty {
            KeyComboView(combo: binding.keys, modal: binding.modal, size: .small)
          }
        }
      }
      Spacer()
      Toggle("Enabled", isOn: $binding.enabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .help(binding.enabled ? "Turn this shortcut off" : "Turn this shortcut on")
      Menu {
        Button("Duplicate") { model.duplicateBinding(binding.id) }
        Divider()
        Button("Delete…", role: .destructive) { confirmDelete = true }
      } label: {
        Image(systemName: "ellipsis.circle").font(.system(size: 15))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
  }

  private var shortcutCard: some View {
    SettingsCard(title: "Shortcut", symbol: "command") {
      VStack(alignment: .leading, spacing: 14) {
        LabeledField("Name") {
          TextField(ActionDescriber.title(binding.action), text: nameBinding)
            .textFieldStyle(.roundedBorder)
        }
        LabeledField("Keys") {
          VStack(alignment: .leading, spacing: 6) {
            ShortcutRecorder(
              combo: $binding.keys, requiresModifier: binding.onlyInApps.isEmpty,
              autoStart: model.recordShortcutFor == binding.id,
              plainKeyHint: "Or limit the shortcut to a game below to use a plain key there."
            )
            .onAppear { model.recordShortcutFor = nil }
            let others = model.otherUses(of: binding.keys, modal: binding.modal, excluding: binding.id)
            if !others.isEmpty {
              Label(
                "Also used by \(ListFormatter.localizedString(byJoining: others))",
                systemImage: "exclamationmark.triangle.fill"
              )
              .font(.system(size: 11.5))
              .foregroundStyle(Theme.caution)
            }
            // Typing and mouse-button warnings; shared keys are listed just above.
            let warnings = model.issues(for: .binding(binding.id)).filter {
              $0.field == .keys && $0.severity == .warning && !$0.message.hasPrefix("Same ")
            }
            ForEach(warnings) { issue in
              Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.caution)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        LabeledField("Works in") {
          AppScopeEditor(apps: $binding.onlyInApps)
        }
        DisclosureGroup(isExpanded: $showAdvanced) {
          VStack(alignment: .leading, spacing: 14) {
            LabeledField("Repeat") {
              Picker("Repeat while held", selection: $binding.repeats) {
                Text("Default").tag(Bool?.none)
                Text("While held").tag(Bool?.some(true))
                Text("Never").tag(Bool?.some(false))
              }
              .labelsHidden()
              .pickerStyle(.segmented)
              .fixedSize()
            }
            LabeledField("Modal key") {
              ModalKeyEditor(modal: $binding.modal)
            }
          }
          .padding(.top, 12)
        } label: {
          Text("Advanced")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
      }
      .padding(16)
    }
  }

  @ViewBuilder private var issueList: some View {
    let warnings = model.issues(for: .binding(binding.id)).filter { $0.severity == .warning && $0.field == .action }
    ForEach(warnings) { issue in
      Notice(style: .warning, title: issue.message)
    }
  }

  private var nameBinding: Binding<String> {
    Binding(
      get: { binding.name ?? "" },
      set: { binding.name = $0.isEmpty ? nil : $0 })
  }
}

/// Everywhere, or only while one of some apps (usually a game) is in front. Limited to an app, a
/// shortcut can be a plain key like F without taking that key away from typing anywhere else.
struct AppScopeEditor: View {
  @Binding var apps: [String]
  /// Keeps "Only in…" selected while the list is still empty.
  @State private var choosing = false
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Picker("Works in", selection: limited) {
        Text("Everywhere").tag(false)
        Text("Only in…").tag(true)
      }
      .labelsHidden()
      .pickerStyle(.segmented)
      .fixedSize()
      if limited.wrappedValue {
        BundleChips(
          ids: $apps,
          emptyText:
            "Add the game or app it's for. It then works only there, and plain keys like F are fine as shortcuts.",
          sections: model.gameFirstSections, addTitle: "Add Game or App")
        if let first = apps.first {
          Hint(
            "Active only while \(apps.count == 1 ? model.appName(bundleID: first) : "one of these apps") is in front; the keys work normally everywhere else."
          )
        }
      }
    }
    .animation(Theme.snappy, value: limited.wrappedValue)
  }

  private var limited: Binding<Bool> {
    Binding(
      get: { !apps.isEmpty || choosing },
      set: { value in
        choosing = value
        if !value { apps = [] }
      })
  }
}

/// Slate's modal key: press it first, then the shortcut's own key.
private struct ModalKeyEditor: View {
  @Binding var modal: ModalKey?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle("Press a modal key first", isOn: enabled)
        .toggleStyle(.checkbox)
      if let current = modal {
        ShortcutRecorder(
          combo: Binding(get: { current.keys }, set: { modal?.keys = $0 }), requiresModifier: false,
          allowsMouseButtons: false)
        Toggle(
          "Stay in modal mode after the shortcut runs",
          isOn: Binding(get: { current.toggle }, set: { modal?.toggle = $0 })
        )
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
      }
    }
  }

  private var enabled: Binding<Bool> {
    Binding(
      get: { modal != nil },
      set: { modal = $0 ? ModalKey(keys: KeyCombo(key: "f4", modifiers: [.control])) : nil })
  }
}

/// A label column + field, aligned across rows.
struct LabeledField<Content: View>: View {
  let label: String
  var labelWidth: CGFloat = 76
  @ViewBuilder var content: Content

  init(_ label: String, labelWidth: CGFloat = 76, @ViewBuilder content: () -> Content) {
    self.label = label
    self.labelWidth = labelWidth
    self.content = content()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(label)
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
        .frame(width: labelWidth, alignment: .trailing)
      content
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

// MARK: - Placement preview

/// The live preview: the user's displays in miniature, the sample window and where the action puts it.
struct PlacementPreviewCard: View {
  let action: Action
  @Environment(AppModel.self) private var model
  @State private var step = 0

  var body: some View {
    let placement = PlacementCalculator.place(
      action, screens: model.screens, settings: model.configuration.settings, step: step)
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Image(systemName: "eye").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
        Text("Preview").font(.system(size: 13, weight: .semibold))
        Spacer()
        if case .chain(let ops) = action, ops.count > 1 {
          ChainStepper(step: $step, count: ops.count)
        }
        caption(placement)
      }
      .padding(.horizontal, 16)
      .padding(.top, 12)
      .padding(.bottom, 10)
      ZStack {
        ScreenPreview(
          screens: model.screens, target: placement?.target, origin: placement?.sample,
          dimmed: placement?.target == nil)
        overlay(placement)
      }
      .frame(height: 200)
      .padding(.horizontal, 20)
      .padding(.top, 16)
      .padding(.bottom, 12)
      .background(PreviewStage())
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .padding([.horizontal, .bottom], 8)
    }
    .cardStyle(padding: 0)
  }

  @ViewBuilder private func caption(_ placement: Placement?) -> some View {
    if let target = placement?.target {
      Text(
        verbatim:
          "\(Int(target.width.rounded())) × \(Int(target.height.rounded())) at \(Int(target.minX)), \(Int(target.minY))"
      )
      .font(.system(size: 11, design: .monospaced))
      .foregroundStyle(.secondary)
    } else if placement != nil {
      Text("From the center of \(model.mainScreen?.name ?? "the main display")")
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder private func overlay(_ placement: Placement?) -> some View {
    switch placement?.state {
    case nil:
      PreviewMessage(symbol: "display.trianglebadge.exclamationmark", title: "No displays found")
    case .unavailable(let reason)?:
      PreviewMessage(symbol: "eye.slash", title: "Preview unavailable", detail: reason)
    case .nothingToPreview(let message)?:
      PreviewMessage(symbol: "info.circle", title: message)
    case .placed?:
      EmptyView()
    }
  }
}

private struct ChainStepper: View {
  @Binding var step: Int
  let count: Int

  var body: some View {
    HStack(spacing: 2) {
      Button {
        step = (step - 1 + count) % count
      } label: {
        Image(systemName: "chevron.left")
      }
      Text("Press \(step % count + 1) of \(count)")
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .frame(minWidth: 74)
      Button {
        step = (step + 1) % count
      } label: {
        Image(systemName: "chevron.right")
      }
    }
    .buttonStyle(.borderless)
    .font(.system(size: 10, weight: .semibold))
    .padding(.trailing, 6)
  }
}

/// The recessed stage behind the screen miniature, with a soft spotlight.
struct PreviewStage: View {
  var body: some View {
    ZStack {
      Theme.well
      RadialGradient(colors: [Theme.accent.opacity(0.10), .clear], center: .top, startRadius: 0, endRadius: 260)
    }
  }
}

/// A quiet capsule over the preview: "Preview unavailable", "No window movement"…
struct PreviewMessage: View {
  let symbol: String
  let title: String
  var detail: String?

  var body: some View {
    // Short messages hug their text; long ones wrap in a fixed-width capsule.
    let compact = title.count + (detail?.count ?? 0) < 56
    VStack(spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
        Text(title).font(.system(size: 12, weight: .medium)).multilineTextAlignment(.center)
      }
      if let detail {
        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }
    }
    .modifier(MessageSizing(compact: compact))
    .foregroundStyle(.primary.opacity(0.75))
    .padding(.horizontal, 14)
    .padding(.vertical, 8)
    .background(Theme.cardBackground.opacity(0.92), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke))
    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    .help(detail ?? title)
  }

  private struct MessageSizing: ViewModifier {
    let compact: Bool

    func body(content: Content) -> some View {
      if compact {
        content.fixedSize()
      } else {
        content.frame(width: 300).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
