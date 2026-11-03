import AppKit
import SlatedCore
import SwiftUI

/// Edits one hotstring: trigger and its rules, replacement, where it works, notes, and a test field.
struct HotstringEditor: View {
  @Binding var hotstring: Hotstring
  @Environment(AppModel.self) private var model
  @State private var confirmDelete = false
  /// A sensitive hotstring's text is shown (the eye): until the editor closes or the switch changes.
  @State private var revealed = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        triggerCard
        replacementCard
        appsCard
        SettingsCard(title: "Try It", symbol: "sparkles") {
          TryItField(hotstring: tryItHotstring)
            .padding(16)
        }
        SettingsCard(title: "Notes", symbol: "note.text") {
          TextField("What this is for, where it came from…", text: notesBinding, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .lineLimit(2...6)
            .configField(ConfigKeys.Hotstring.notes)
            .padding(14)
        }
      }
      .configKeyItem(model.configKey(forHotstring: hotstring.id))
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
          if hotstring.isSensitive {
            MaskedLine(fontSize: 16)
          } else {
            Text(hotstring.replacement.isEmpty ? "Replacement" : ActionDescriber.singleLine(hotstring.replacement))
              .font(.system(size: 17, weight: .semibold))
              .foregroundStyle(hotstring.replacement.isEmpty ? .tertiary : .primary)
              .lineLimit(1)
          }
        }
        let pill = state
        StatusPill(text: pill.text, color: pill.color, symbol: pill.symbol)
        ConfigItemCaption(key: model.configKey(forHotstring: hotstring.id))
      }
      Spacer()
      Toggle("Enabled", isOn: $hotstring.enabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .configField(ConfigKeys.Hotstring.enabled)
      Menu {
        Button("Duplicate") { model.duplicateHotstring(hotstring.id) }
        Divider()
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

  private var state: (text: String, color: Color, symbol: String?) {
    switch model.state(for: hotstring) {
    case .notSaved: return ("Not saved", Theme.critical, "exclamationmark.circle.fill")
    case .missingText: return ("Needs its text", Theme.caution, "exclamationmark.triangle.fill")
    case .off: return ("Off", Theme.neutral, nil)
    case .expansionOff: return ("Expansion is off", Theme.neutral, nil)
    case .paused: return ("Paused", Theme.neutral, "pause.fill")
    case .active: return ("Active", Theme.positive, nil)
    case .waitingForPermission: return ("Waiting for permission", Theme.caution, nil)
    case .notRunning: return ("Not running", Theme.caution, nil)
    }
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
            .configField(ConfigKeys.Hotstring.trigger)
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
        LabeledField("Expand", labelWidth: 60, key: ConfigKeys.Hotstring.fire) {
          FittingPicker("Expand", selection: $hotstring.fire) {
            Text("Right away").tag(Hotstring.Fire.immediately)
            Text("After a space or punctuation").tag(Hotstring.Fire.afterDelimiter)
          }
        }
        VStack(alignment: .leading, spacing: 8) {
          Toggle("Match case exactly", isOn: $hotstring.caseSensitive).configField(ConfigKeys.Hotstring.caseSensitive)
          Toggle("Only at the start of a word", isOn: $hotstring.wordBoundary).configField(
            ConfigKeys.Hotstring.wordBoundary)
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
        if hotstring.isSensitive {
          SensitiveReplacement(hotstring: hotstring, revealed: $revealed)
        } else {
          TextEditor(text: $hotstring.replacement)
            .font(.system(size: 13))
            .scrollContentBackground(.hidden)
            .frame(minHeight: 84, maxHeight: 180)
            .padding(8)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.wellStroke))
            .configField(ConfigKeys.Hotstring.replacement)
          HStack {
            Text("\(hotstring.replacement.count) characters")
              .font(.system(size: 11).monospacedDigit())
              .foregroundStyle(.tertiary)
            Spacer()
          }
        }
        sensitiveSwitch
        if hotstring.isSensitive {
          Hint(
            "Always typed, never pasted, so its text never goes through the clipboard. Placeholders like {date} are typed as they are."
          )
        } else {
          LabeledField("Insert by", labelWidth: 60, key: ConfigKeys.Hotstring.method) {
            InsertMethodPicker(method: $hotstring.method)
          }
        }
      }
      .padding(16)
    }
  }

  /// Moves the text into secrets.json (only you can read it) and masks it here, or back.
  private var sensitiveSwitch: some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Label("Sensitive", systemImage: "lock.fill")
          .font(.system(size: 12.5, weight: .medium))
        LinkedText("Its text moves to secrets.json, which only you can read, and stays hidden here.")
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 8)
      Toggle(
        "Sensitive",
        isOn: Binding(
          get: { hotstring.isSensitive },
          set: { on in
            revealed = false
            model.setSensitive(on, hotstring: hotstring.id)
          })
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.small)
      .configFieldMenu(ConfigKeys.Hotstring.replacement)
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
        FittingPicker("Where", selection: scope) {
          Text("Everywhere").tag(Scope.everywhere)
          Text("Only in…").tag(Scope.only)
          Text("Everywhere except…").tag(Scope.except)
        }
        .configField(
          scope.wrappedValue == .except ? ConfigKeys.Hotstring.exceptInApps : ConfigKeys.Hotstring.onlyInApps)
        switch scope.wrappedValue {
        case .everywhere:
          Hint("Expands in every app. Slated never expands in password fields.")
        case .only:
          BundleChips(
            ids: $hotstring.onlyInApps, emptyText: "Add the apps where this hotstring should expand.",
            sections: [AppChoiceSection(title: "Running Apps", apps: model.runningAppChoices)])
        case .except:
          BundleChips(
            ids: $hotstring.exceptInApps, emptyText: "Add the apps where this hotstring should stay quiet.",
            sections: [AppChoiceSection(title: "Running Apps", apps: model.runningAppChoices)])
        }
      }
      .padding(16)
    }
  }

  /// What Try It expands to: a sensitive hotstring's text only while it's shown, else dots.
  private var tryItHotstring: Hotstring {
    guard hotstring.isSensitive else { return hotstring }
    var shown = hotstring
    shown.replacement = revealed ? model.secretText(of: hotstring.id) ?? "" : ClipboardItem.mask
    return shown
  }

  private var notesBinding: Binding<String> {
    Binding(get: { hotstring.notes ?? "" }, set: { hotstring.notes = $0.isEmpty ? nil : $0 })
  }
}

/// A sensitive hotstring's text: dots, with an eye to show and edit it (edits go to secrets.json), its
/// key there, and a field to type it when it isn't on this computer. The field's menu is the
/// replacement's in config.json: Copy Value copies the reference, never the text.
private struct SensitiveReplacement: View {
  let hotstring: Hotstring
  @Binding var revealed: Bool
  @Environment(AppModel.self) private var model
  @State private var entry = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let text = model.secretText(of: hotstring.id) {
        if revealed {
          TextEditor(
            text: Binding(
              get: { model.secretText(of: hotstring.id) ?? "" },
              set: { model.setSecretText($0, hotstring: hotstring.id) })
          )
          .font(.system(size: 13))
          .scrollContentBackground(.hidden)
          .frame(minHeight: 84, maxHeight: 180)
          .padding(8)
          .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.wellStroke))
          .configFieldMenu(ConfigKeys.Hotstring.replacement)
        } else {
          HStack {
            MaskedLine(fontSize: 14)
            Spacer()
          }
          .padding(.horizontal, 12)
          .frame(height: 38)
          .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
          .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.wellStroke))
          .contentShape(Rectangle())
          .configFieldMenu(ConfigKeys.Hotstring.replacement)
        }
        HStack(spacing: 8) {
          caption
          Spacer(minLength: 8)
          // Its length only while it's shown.
          if revealed {
            Text("\(text.count) characters")
              .font(.system(size: 11).monospacedDigit())
              .foregroundStyle(.tertiary)
          }
          Button {
            revealed.toggle()
          } label: {
            Label(revealed ? "Hide" : "Show", systemImage: revealed ? "eye.slash" : "eye")
              .font(.system(size: 11.5))
          }
          .buttonStyle(.borderless)
          .help(revealed ? "Hide the text again" : "Show the text to read or edit it")
        }
      } else {
        Label("Its text isn't on this computer yet", systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(Theme.caution)
        LinkedText(
          "It's in secrets.json on the computer where you made it sensitive. Type it here and it's kept in this computer's secrets.json; until then it doesn't expand."
        )
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          SecureField("Its text", text: $entry)
            .textFieldStyle(.roundedBorder)
            .onSubmit(save)
            .configFieldMenu(ConfigKeys.Hotstring.replacement)
          Button("Save", action: save)
            .disabled(entry.isEmpty)
        }
        caption
      }
    }
  }

  /// Where the text is: `secrets.json › pw`, the file's name a link.
  @ViewBuilder private var caption: some View {
    if let name = hotstring.secret, model.showsConfigKeys {
      ConfigKeyCaption(key: ConfigKeys.secret(named: name))
        .configFieldMenu(ConfigKeys.Hotstring.replacement)
    }
  }

  private func save() {
    guard !entry.isEmpty else { return }
    model.setSecretText(entry, hotstring: hotstring.id)
    entry = ""
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
  @State private var fieldWindow = WindowReader.Found()
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // config key: none, a test field that isn't saved
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
          // Typing here again after switching apps or reopening Settings suspends the engine again.
          if focused { setSuspended(true) }
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
        // Switching apps or closing Settings leaves this field focused: SwiftUI neither clears
        // @FocusState nor calls onDisappear then (UIHostingContract). Without these, every hotkey,
        // the Hyper key and hotstrings would stay off until Settings came back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
          setSuspended(false)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
          // The window whose text has focus; a closing tooltip or input-method window isn't ours.
          if (notification.object as? NSWindow)?.firstResponder is NSText { setSuspended(false) }
        }
        // Coming back to it (switching back to Slated, reopening Settings) leaves it focused too, and
        // the first keystroke may already complete a trigger: suspend again as its window becomes key,
        // not when the text first changes.
        .background(WindowReader(window: fieldWindow))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
          if focused, let window = fieldWindow.window, notification.object as? NSWindow === window {
            setSuspended(true)
          }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
          if focused, fieldWindow.window?.isKeyWindow == true { setSuspended(true) }
        }
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

/// Finds the window a view is in, so the view can tell its own window's notifications from others'.
private struct WindowReader: NSViewRepresentable {
  /// Where the window goes. A reference, so finding the window doesn't redraw anything.
  final class Found {
    weak var window: NSWindow?
  }

  let window: Found

  func makeNSView(context: Context) -> NSView { Reader(found: window) }
  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class Reader: NSView {
    let found: Found

    init(found: Found) {
      self.found = found
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      found.window = window
    }

    // Only here to find the window: clicks go to whatever is behind it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
}
