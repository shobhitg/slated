import SlatedCore
import SwiftUI

/// Edits one hotstring: trigger and its rules, replacement, where it works, notes, and a test field.
struct HotstringEditor: View {
  @Binding var hotstring: Hotstring
  @Environment(AppModel.self) private var model
  @State private var confirmDelete = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        triggerCard
        replacementCard
        appsCard
        SettingsCard(title: "Try It", symbol: "sparkles") {
          TryItField(hotstring: hotstring)
            .padding(16)
        }
        SettingsCard(title: "Notes", symbol: "note.text") {
          TextField("What this is for, where it came from…", text: notesBinding, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .lineLimit(2...6)
            .padding(14)
        }
      }
      .padding(24)
      .frame(maxWidth: 640, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
    .scrollContentBackground(.hidden)
    .confirmationDialog("Delete this hotstring?", isPresented: $confirmDelete) {
      Button("Delete", role: .destructive) { model.deleteHotstring(hotstring.id) }
    }
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          TriggerChip(trigger: hotstring.trigger.isEmpty ? "trigger" : hotstring.trigger, size: 15)
            .opacity(hotstring.trigger.isEmpty ? 0.5 : 1)
          Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
          Text(hotstring.replacement.isEmpty ? "Replacement" : ActionDescriber.singleLine(hotstring.replacement))
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(hotstring.replacement.isEmpty ? .tertiary : .primary)
            .lineLimit(1)
        }
        let pill = state
        StatusPill(text: pill.text, color: pill.color, symbol: pill.symbol)
      }
      Spacer()
      Toggle("Enabled", isOn: $hotstring.enabled)
        .labelsHidden()
        .toggleStyle(.switch)
      Menu {
        Button("Duplicate") { model.duplicateHotstring(hotstring.id) }
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

  private var state: (text: String, color: Color, symbol: String?) {
    if model.issues(for: .hotstring(hotstring.id)).contains(where: { $0.severity == .error }) {
      return ("Not saved", Theme.critical, "exclamationmark.circle.fill")
    }
    if !hotstring.enabled { return ("Off", Theme.neutral, nil) }
    if !model.runtimeStatus.hotstringsEnabled { return ("Expansion is off", Theme.neutral, nil) }
    if model.runtimeStatus.paused { return ("Paused", Theme.neutral, "pause.fill") }
    return model.runtimeStatus.hotstringsActive
      ? ("Active", Theme.positive, nil) : ("Waiting for permission", Theme.caution, nil)
  }

  // MARK: Trigger

  private var triggerCard: some View {
    let issues = model.issues(for: .hotstring(hotstring.id)).filter { $0.field == .trigger }
    return SettingsCard(title: "Trigger", symbol: "keyboard") {
      VStack(alignment: .leading, spacing: 14) {
        VStack(alignment: .leading, spacing: 6) {
          TextField(";shrug", text: $hotstring.trigger)
            .textFieldStyle(.plain)
            .font(.system(size: 15, weight: .medium, design: .monospaced))
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
              RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                  issues.contains { $0.severity == .error } ? Theme.critical.opacity(0.7) : Theme.wellStroke,
                  lineWidth: 1)
            )
          ForEach(issues) { issue in
            Label(
              issue.message,
              systemImage: issue.severity == .error ? "exclamationmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .font(.system(size: 11.5))
            .foregroundStyle(issue.severity == .error ? Theme.critical : Theme.caution)
          }
          if issues.isEmpty {
            Hint("Tip: start triggers with a character you rarely type, like ; or //, so they never fire by accident.")
          }
        }
        LabeledField("Expand", labelWidth: 60) {
          Picker("Expand", selection: $hotstring.fire) {
            Text("Right away").tag(Hotstring.Fire.immediately)
            Text("After a space or punctuation").tag(Hotstring.Fire.afterDelimiter)
          }
          .labelsHidden()
          .pickerStyle(.segmented)
          .fixedSize()
        }
        VStack(alignment: .leading, spacing: 8) {
          Toggle("Match case exactly", isOn: $hotstring.caseSensitive)
          Toggle("Only at the start of a word", isOn: $hotstring.wordBoundary)
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 12.5))
        .padding(.leading, 72)
      }
      .padding(16)
    }
  }

  // MARK: Replacement

  private var replacementCard: some View {
    SettingsCard(title: "Replacement", symbol: "text.alignleft") {
      VStack(alignment: .leading, spacing: 12) {
        TextEditor(text: $hotstring.replacement)
          .font(.system(size: 13))
          .scrollContentBackground(.hidden)
          .frame(minHeight: 84, maxHeight: 180)
          .padding(8)
          .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.wellStroke))
        HStack {
          Text("\(hotstring.replacement.count) characters")
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.tertiary)
          Spacer()
        }
        LabeledField("Insert by", labelWidth: 60) {
          InsertMethodPicker(method: $hotstring.method)
        }
      }
      .padding(16)
    }
  }

  // MARK: Apps

  private enum Scope: String { case everywhere, only, except }

  private var scope: Binding<Scope> {
    Binding(
      get: {
        if !hotstring.onlyInApps.isEmpty { return .only }
        if !hotstring.exceptInApps.isEmpty { return .except }
        return storedScope
      },
      set: { newValue in
        storedScope = newValue
        let apps = hotstring.onlyInApps.isEmpty ? hotstring.exceptInApps : hotstring.onlyInApps
        switch newValue {
        case .everywhere:
          hotstring.onlyInApps = []
          hotstring.exceptInApps = []
        case .only:
          hotstring.onlyInApps = apps
          hotstring.exceptInApps = []
        case .except:
          hotstring.exceptInApps = apps
          hotstring.onlyInApps = []
        }
      })
  }

  @State private var storedScope: Scope = .everywhere

  private var appsCard: some View {
    SettingsCard(title: "Where It Works", symbol: "macwindow") {
      VStack(alignment: .leading, spacing: 12) {
        Picker("Where", selection: scope) {
          Text("Everywhere").tag(Scope.everywhere)
          Text("Only in…").tag(Scope.only)
          Text("Everywhere except…").tag(Scope.except)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
        switch scope.wrappedValue {
        case .everywhere:
          Hint("Expands in every app. Slated never expands in password fields.")
        case .only:
          BundleChips(ids: $hotstring.onlyInApps, emptyText: "Add the apps where this hotstring should expand.")
        case .except:
          BundleChips(ids: $hotstring.exceptInApps, emptyText: "Add the apps where this hotstring should stay quiet.")
        }
      }
      .padding(16)
    }
  }

  private var notesBinding: Binding<String> {
    Binding(get: { hotstring.notes ?? "" }, set: { hotstring.notes = $0.isEmpty ? nil : $0 })
  }
}

/// Apps by bundle identifier, as removable chips, with an "Add App" menu of running apps.
private struct BundleChips: View {
  @Binding var ids: [String]
  let emptyText: String
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      FlowLayout(spacing: 6) {
        ForEach(ids, id: \.self) { id in
          HStack(spacing: 6) {
            AppIconView(bundleID: id, size: 16)
            Text(AppIcons.name(bundleID: id, running: model.runningApps)).font(.system(size: 12.5))
            Button {
              ids.removeAll { $0 == id }
            } label: {
              Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove")
          }
          .padding(.leading, 6)
          .padding(.trailing, 9)
          .padding(.vertical, 5)
          .background(Theme.cardBackground, in: Capsule())
          .overlay(Capsule().strokeBorder(Theme.wellStroke))
        }
        Menu {
          let available = model.runningApps.filter { app in app.bundleID.map { !ids.contains($0) } ?? false }
          if available.isEmpty {
            Text("No other apps are running")
          }
          ForEach(available) { app in
            Button(app.name) { if let id = app.bundleID { ids.append(id) } }
          }
        } label: {
          Label("Add App", systemImage: "plus")
            .font(.system(size: 12.5, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
      }
      if ids.isEmpty { Hint(emptyText) }
    }
  }
}

/// A scratch field that simulates the hotstring as you type, without touching other apps.
/// Real expansion is suspended while it has focus, so the two never both fire.
struct TryItField: View {
  let hotstring: Hotstring
  @Environment(AppModel.self) private var model
  @State private var text = ""
  @State private var expanded = false
  @State private var suspended = false
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField(prompt, text: $text, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.system(size: 13))
        .lineLimit(1...5)
        .focused($focused)
        .padding(10)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(
              expanded ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.wellStroke),
              lineWidth: expanded ? 1.5 : 1)
        )
        .onChange(of: text) { old, new in
          guard let result = HotstringTester.expand(previous: old, current: new, hotstring: hotstring) else { return }
          text = result
          withAnimation(Theme.snappy) { expanded = true }
          Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(Theme.snappy) { expanded = false }
          }
        }
        .onChange(of: focused) { _, isFocused in setSuspended(isFocused) }
        .onDisappear { setSuspended(false) }
      HStack(spacing: 6) {
        if expanded {
          Label("Expanded", systemImage: "sparkles")
            .foregroundStyle(Theme.accent)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        } else {
          Text(helpText).foregroundStyle(.tertiary)
        }
        Spacer()
        if !text.isEmpty {
          Button("Clear") { text = "" }
            .buttonStyle(.link)
        }
      }
      .font(.system(size: 11.5))
    }
  }

  private var prompt: String {
    hotstring.trigger.isEmpty ? "Add a trigger, then type it here" : "Type “\(hotstring.trigger)” here…"
  }

  private var helpText: String {
    if hotstring.trigger.isEmpty { return "Nothing to try yet." }
    return hotstring.fire == .immediately
      ? "Expands as soon as you finish typing the trigger."
      : "Expands when you type a space or punctuation after the trigger."
  }

  private func setSuspended(_ value: Bool) {
    guard value != suspended else { return }
    suspended = value
    if value { model.beginHotkeySuspension() } else { model.endHotkeySuspension() }
  }
}
