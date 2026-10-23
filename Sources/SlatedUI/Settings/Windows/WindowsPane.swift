import SlatedCore
import SwiftUI

/// Window shortcuts: Slated's own (editable) and every Slate file's (read-only), with an editor.
struct WindowsPane: View {
  @Environment(AppModel.self) private var model
  @State private var search = ""

  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(pane: .windows, subtitle: "Keyboard shortcuts that move, resize and focus windows.") {
        NewBindingButton()
      }
      .padding(.horizontal, Theme.paneHorizontalPadding)
      .padding(.top, 22)
      .padding(.bottom, 16)
      Rectangle().fill(Theme.hairline).frame(height: 0.5)
      HStack(spacing: 0) {
        BindingList(search: $search)
          .frame(width: 330)
        Rectangle().fill(Theme.hairline).frame(width: 0.5)
        detail
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  @ViewBuilder private var detail: some View {
    switch model.selectedBinding {
    case .slated(let id):
      if let binding = model.bindingBinding(id) {
        BindingEditor(binding: binding)
          .id(id)
      } else {
        noSelection
      }
    case .source(let path, let id):
      if let source = model.sources.first(where: { $0.path == path }),
        let binding = source.bindings.first(where: { $0.id == id })
      {
        SourceBindingDetail(source: source, binding: binding)
          .id("\(path)|\(id)")
      } else {
        noSelection
      }
    case nil:
      noSelection
    }
  }

  private var noSelection: some View {
    EmptyStateView(
      symbol: "macwindow.on.rectangle", title: "Pick a shortcut",
      message: "Select a shortcut on the left to edit it and see exactly where it puts the window."
    ) {
      Button("New Shortcut") { model.addBinding() }
        .buttonStyle(.gradient)
    }
    .frame(maxHeight: .infinity)
  }
}

/// "New Shortcut" with a menu of common placements to start from.
private struct NewBindingButton: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 8) {
      Menu {
        ForEach(WindowPreset.Group.allCases) { group in
          Section(group.rawValue) {
            ForEach(WindowPresets.all.filter { $0.group == group }) { preset in
              Button(preset.title) { model.addBinding(action: preset.action) }
            }
          }
        }
      } label: {
        Text("From Preset")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .foregroundStyle(.secondary)
      Button {
        model.addBinding()
      } label: {
        Label("New Shortcut", systemImage: "plus")
      }
      .buttonStyle(.gradient)
      .keyboardShortcut("n", modifiers: .command)
    }
  }
}

// MARK: - List

private struct BindingList: View {
  @Binding var search: String
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(spacing: 0) {
      SearchField(prompt: "Search shortcuts", text: $search)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
      ScrollViewReader { proxy in
        list
          .onChange(of: model.selectedBinding, initial: true) { _, selection in
            // Bring programmatic selections (new, copied, opened from the menu bar) into view.
            if let selection { proxy.scrollTo(selection) }
          }
      }
    }
    .background(Theme.paneBackground)
  }

  private var list: some View {
    List(selection: selection) {
      Section {
        if slated.isEmpty {
          emptySlatedRow
        }
        ForEach(slated) { binding in
          BindingRow(binding: binding)
            .tag(BindingSelection.slated(binding.id))
            .id(BindingSelection.slated(binding.id))
            .contextMenu {
              Button("Duplicate") { model.duplicateBinding(binding.id) }
              Button(binding.enabled ? "Turn Off" : "Turn On") { toggle(binding.id) }
              Divider()
              Button("Delete", role: .destructive) { model.deleteBinding(binding.id) }
            }
        }
        .onMove { from, to in
          guard search.isEmpty else { return }
          model.configuration.bindings.move(fromOffsets: from, toOffset: to)
        }
      } header: {
        ListSectionHeader(title: "Slated", count: model.configuration.bindings.count, symbol: nil)
      }
      if model.configuration.general.loadSlateConfigs {
        ForEach(model.sources.filter { $0.loaded && !$0.bindings.isEmpty }) { source in
          Section {
            let rows = filtered(source)
            if rows.isEmpty {
              Text("No matches").font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            ForEach(rows) { binding in
              SourceBindingRow(binding: binding)
                .tag(BindingSelection.source(path: source.path, id: binding.id))
                .id(BindingSelection.source(path: source.path, id: binding.id))
                .contextMenu {
                  if binding.action != nil {
                    Button("Copy into Slated") { model.copyIntoSlated(binding) }
                  }
                  Button("Reveal \(source.fileName) in Finder") { model.revealFile(atPath: source.path) }
                }
            }
          } header: {
            ListSectionHeader(title: source.displayName, count: source.bindings.count, symbol: "lock.fill")
          }
        }
      }
    }
    .listStyle(.inset)
    .scrollContentBackground(.hidden)
    .onDeleteCommand {
      if case .slated(let id) = model.selectedBinding { model.deleteBinding(id) }
    }
  }

  private var selection: Binding<BindingSelection?> {
    Binding(get: { model.selectedBinding }, set: { model.selectedBinding = $0 })
  }

  private var query: String { search.trimmingCharacters(in: .whitespaces).lowercased() }

  private var slated: [HotkeyBinding] {
    guard !query.isEmpty else { return model.configuration.bindings }
    return model.configuration.bindings.filter { binding in
      matches(
        [
          BindingTitle.title(for: binding), ActionDescriber.detail(binding.action), binding.keys.display(),
          binding.keys.string,
        ])
    }
  }

  private func filtered(_ source: SlateSource) -> [SourceBinding] {
    guard !query.isEmpty else { return source.bindings }
    return source.bindings.filter { matches([$0.summary, $0.keys.display(), $0.keys.string]) }
  }

  private func matches(_ fields: [String]) -> Bool {
    fields.contains { $0.lowercased().contains(query) }
  }

  private func toggle(_ id: UUID) {
    guard let index = model.configuration.bindings.firstIndex(where: { $0.id == id }) else { return }
    model.configuration.bindings[index].enabled.toggle()
  }

  @ViewBuilder private var emptySlatedRow: some View {
    if query.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("No shortcuts of your own yet.").font(.system(size: 12.5, weight: .medium))
        Text("Start with a set of Hyper shortcuts for halves, maximize and more.")
          .font(.system(size: 11.5)).foregroundStyle(.secondary)
        Button("Add Starter Shortcuts") { model.addStarterBindings() }
          .buttonStyle(.soft)
          .controlSize(.small)
      }
      .padding(.vertical, 6)
      .selectionDisabled()
    } else {
      Text("No matches for “\(search)”").font(.system(size: 12)).foregroundStyle(.tertiary).selectionDisabled()
    }
  }
}

private struct ListSectionHeader: View {
  let title: String
  let count: Int
  let symbol: String?

  var body: some View {
    HStack(spacing: 5) {
      if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
      Text(title).font(.system(size: 11.5, weight: .semibold))
      Text("\(count)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.tertiary)
      Spacer()
      if symbol != nil {
        Text("Read-only").font(.system(size: 10.5)).foregroundStyle(.tertiary)
      }
    }
    .foregroundStyle(.secondary)
  }
}

private struct BindingRow: View {
  let binding: HotkeyBinding
  @Environment(AppModel.self) private var model

  var body: some View {
    let state = model.state(for: binding)
    HStack(spacing: 10) {
      ActionGlyph(action: binding.action, width: 26, height: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(BindingTitle.title(for: binding))
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
        HStack(spacing: 4) {
          if let badge = state.rowBadge {
            Image(systemName: badge.symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(badge.color)
            Text(badge.text).foregroundStyle(badge.color)
          } else {
            Text(BindingTitle.subtitle(for: binding)).foregroundStyle(.secondary)
          }
        }
        .font(.system(size: 11))
        .lineLimit(1)
      }
      Spacer(minLength: 6)
      if binding.keys.key.isEmpty {
        Text("No shortcut").font(.system(size: 11)).foregroundStyle(.tertiary)
      } else {
        KeyComboView(combo: binding.keys, modal: binding.modal, size: .small)
      }
    }
    .padding(.vertical, 3)
    .opacity(binding.enabled ? 1 : 0.5)
  }
}

private struct SourceBindingRow: View {
  let binding: SourceBinding
  @Environment(AppModel.self) private var model

  var body: some View {
    let state = model.state(for: binding)
    HStack(spacing: 10) {
      if let action = binding.action {
        ActionGlyph(action: action, width: 26, height: 18)
      } else {
        Image(systemName: "curlybraces")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(.secondary)
          .frame(width: 26, height: 18)
          .background(Theme.well, in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(binding.action.map(ActionDescriber.title) ?? "JavaScript Function")
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
        HStack(spacing: 4) {
          if let badge = state.rowBadge {
            Image(systemName: badge.symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(badge.color)
            Text(badge.text).foregroundStyle(badge.color)
          } else {
            Text(binding.action == nil ? "Runs code in your Slate file" : binding.summary).foregroundStyle(.secondary)
          }
        }
        .font(.system(size: 11))
        .lineLimit(1)
      }
      Spacer(minLength: 6)
      KeyComboView(combo: binding.keys, modal: binding.modal, size: .small)
    }
    .padding(.vertical, 3)
  }
}

// MARK: - State presentation

extension BindingState {
  /// A short label for list rows. `nil` for healthy states, so lists only call out exceptions.
  var rowBadge: (text: String, symbol: String, color: Color)? {
    switch self {
    case .active, .inactive, .saving: return nil
    case .disabled: return ("Off", "moon.fill", Theme.neutral)
    case .duplicate: return ("Duplicate shortcut", "exclamationmark.triangle.fill", Theme.caution)
    case .failed: return ("Couldn't register", "xmark.octagon.fill", Theme.critical)
    case .notSaved(let message): return (message, "exclamationmark.circle.fill", Theme.critical)
    case .paused: return ("Paused", "pause.circle.fill", Theme.neutral)
    case .slateOff: return ("Slate files off", "moon.fill", Theme.neutral)
    }
  }

  /// The pill shown in editor headers.
  var pill: (text: String, color: Color, symbol: String?) {
    switch self {
    case .active: return ("Active", Theme.positive, nil)
    case .disabled: return ("Off", Theme.neutral, nil)
    case .duplicate: return ("Duplicate", Theme.caution, "exclamationmark.triangle.fill")
    case .failed: return ("Failed", Theme.critical, "xmark.octagon.fill")
    case .notSaved: return ("Not saved", Theme.critical, "exclamationmark.circle.fill")
    case .saving: return ("Saving…", Theme.neutral, nil)
    case .paused: return ("Paused", Theme.neutral, "pause.fill")
    case .slateOff: return ("Not loaded", Theme.neutral, nil)
    case .inactive: return ("Not registered", Theme.neutral, nil)
    }
  }

  /// A sentence explaining a problem state, for the editor.
  var explanation: String? {
    switch self {
    case .duplicate:
      return "Another shortcut uses the same keys, so only one of them can run. Change one of them, or turn one off."
    case .failed(let reason): return reason
    case .notSaved(let message):
      return "\(message) Until then, the last saved version of this shortcut stays in effect."
    case .slateOff: return "Loading Slate files is turned off in Slate Compatibility."
    case .paused: return "Slated is paused from the menu bar."
    default: return nil
    }
  }
}
