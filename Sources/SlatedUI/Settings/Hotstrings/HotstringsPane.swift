import SlatedCore
import SwiftUI

/// Text expansion: type a trigger, get the replacement.
struct HotstringsPane: View {
  @Environment(AppModel.self) private var model
  @State private var search = ""
  /// The hotstring the back button left, so the list comes back scrolled to it.
  @State private var returnTo: UUID?

  var body: some View {
    VStack(spacing: 0) {
      PaneHeader(pane: .hotstrings, subtitle: "Type a short trigger anywhere and Slated replaces it with your text.") {
        HStack(spacing: 14) {
          MasterSwitch()
          NewItemButton(title: "New Hotstring") { model.addHotstring() }
            .keyboardShortcut("n", modifiers: .command)
        }
      }
      .padding(.horizontal, Theme.paneHorizontalPadding)
      .padding(.top, 22)
      .padding(.bottom, 16)
      Rectangle().fill(Theme.hairline).frame(height: 0.5)
      if model.configuration.hotstrings.isEmpty {
        EmptyStateView(
          symbol: "text.insert", title: "No hotstrings yet",
          message:
            "Hotstrings expand short triggers into longer text — like ;shrug into ¯\\_(ツ)_/¯ or ;addr into your address."
        ) {
          Button("Create Your First Hotstring") { model.addHotstring() }
            .buttonStyle(.gradient)
        }
        .frame(maxHeight: .infinity)
      } else {
        ListDetail(
          listWidth: 310, hasSelection: model.selectedHotstringID.flatMap(model.hotstring) != nil,
          backTitle: "All Hotstrings",
          back: {
            returnTo = model.selectedHotstringID
            model.selectedHotstringID = nil
          }
        ) {
          HotstringList(search: $search, returnTo: returnTo)
        } detail: {
          detail
        }
      }
    }
  }

  @ViewBuilder private var detail: some View {
    if let id = model.selectedHotstringID, let hotstring = model.hotstringBinding(id) {
      HotstringEditor(hotstring: hotstring)
        .id(id)
    } else {
      EmptyStateView(
        symbol: "text.insert", title: "Pick a hotstring",
        message: "Select a hotstring on the left to edit its trigger, text and where it works."
      )
      .frame(maxHeight: .infinity)
    }
  }
}

/// The global text-expansion switch, independent of each hotstring's own switch.
private struct MasterSwitch: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    HStack(spacing: 8) {
      Text("Expansion")
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
      Toggle(
        "Expansion",
        isOn: Binding(get: { model.runtimeStatus.hotstringsEnabled }, set: { model.setHotstringsEnabled($0) })
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.small)
    }
    .help("Turn all text expansion on or off. Each hotstring keeps its own setting.")
  }
}

private struct HotstringList: View {
  @Binding var search: String
  var returnTo: UUID?
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(spacing: 0) {
      SearchField(prompt: "Search hotstrings", text: $search)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
      ScrollViewReader { proxy in
        List(selection: selection) {
          ForEach(filtered) { hotstring in
            HotstringRow(hotstring: hotstring)
              .tag(hotstring.id)
              .id(hotstring.id)
              .contextMenu {
                Button("Duplicate") { model.duplicateHotstring(hotstring.id) }
                Divider()
                Button("Delete", role: .destructive) { model.deleteHotstring(hotstring.id) }
              }
          }
          .onMove { from, to in
            guard search.isEmpty else { return }
            model.configuration.hotstrings.move(fromOffsets: from, toOffset: to)
          }
          if filtered.isEmpty {
            Text("No matches for “\(search)”").font(.system(size: 12)).foregroundStyle(.tertiary)
          }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .onDeleteCommand {
          if let id = model.selectedHotstringID { model.deleteHotstring(id) }
        }
        .onChange(of: model.selectedHotstringID ?? returnTo, initial: true) { _, id in
          if let id { proxy.scrollTo(id) }
        }
      }
    }
    .background(Theme.paneBackground)
  }

  private var selection: Binding<UUID?> {
    Binding(get: { model.selectedHotstringID }, set: { model.selectedHotstringID = $0 })
  }

  private var filtered: [Hotstring] {
    let query = search.trimmingCharacters(in: .whitespaces).lowercased()
    guard !query.isEmpty else { return model.configuration.hotstrings }
    return model.configuration.hotstrings.filter {
      $0.trigger.lowercased().contains(query) || $0.replacement.lowercased().contains(query)
        || ($0.notes ?? "").lowercased().contains(query)
    }
  }
}

private struct HotstringRow: View {
  let hotstring: Hotstring
  @Environment(AppModel.self) private var model

  var body: some View {
    let error = model.issues(for: .hotstring(hotstring.id)).first { $0.severity == .error }
    let warning = model.issues(for: .hotstring(hotstring.id)).first { $0.severity == .warning }
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 7) {
        TriggerChip(trigger: hotstring.trigger.isEmpty ? "new" : hotstring.trigger, size: 11.5)
          .opacity(hotstring.trigger.isEmpty ? 0.5 : 1)
          .layoutPriority(1)
        Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
        Text(hotstring.replacement.isEmpty ? "Nothing yet" : ActionDescriber.singleLine(hotstring.replacement))
          .font(.system(size: 12.5))
          .foregroundStyle(hotstring.replacement.isEmpty ? .tertiary : .primary)
          .lineLimit(1)
        Spacer(minLength: 4)
        if !hotstring.enabled {
          Text("Off").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
        }
      }
      if let issue = error ?? warning {
        Label(
          issue.message,
          systemImage: issue.severity == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill"
        )
        .font(.system(size: 11))
        .foregroundStyle(issue.severity == .error ? Theme.critical : Theme.caution)
        .lineLimit(1)
      } else if let caption {
        caption
      }
    }
    .padding(.vertical, 4)
    .opacity(hotstring.enabled ? 1 : 0.5)
  }

  /// Where it works and the first line of its notes, when there's something to say.
  private var caption: AnyView? {
    let filtered = !hotstring.onlyInApps.isEmpty || !hotstring.exceptInApps.isEmpty
    let note = hotstring.notes?.split(separator: "\n").first.map(String.init)
    guard filtered || note != nil else { return nil }
    return AnyView(
      HStack(spacing: 6) {
        if filtered { AppFilterBadge(hotstring: hotstring) }
        if let note {
          Text(note).lineLimit(1)
        }
      }
      .font(.system(size: 11))
      .foregroundStyle(.secondary))
  }
}

/// Small app icons when a hotstring is limited to (or kept out of) certain apps.
private struct AppFilterBadge: View {
  let hotstring: Hotstring
  @Environment(AppModel.self) private var model

  var body: some View {
    let ids = hotstring.onlyInApps.isEmpty ? hotstring.exceptInApps : hotstring.onlyInApps
    if !ids.isEmpty {
      HStack(spacing: 3) {
        Text(hotstring.onlyInApps.isEmpty ? "Not in" : "Only in")
        ForEach(ids.prefix(3), id: \.self) { id in
          AppIconView(bundleID: id, size: 13)
        }
        if ids.count == 1 {
          Text(AppIcons.name(bundleID: ids[0], running: model.runningApps))
        }
      }
      .help(
        (hotstring.onlyInApps.isEmpty ? "Not in " : "Only in ")
          + ids.map { AppIcons.name(bundleID: $0, running: model.runningApps) }.joined(separator: ", "))
    }
  }
}
