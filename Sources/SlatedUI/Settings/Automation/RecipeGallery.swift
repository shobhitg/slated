import SlatedCore
import SwiftUI

/// One-click starting points: each card adds a shortcut that runs the recipe, after you pick its
/// keys (and, optionally, the game it's for) in a small sheet.
struct RecipeGallery: View {
  @Environment(AppModel.self) private var model

  private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 4)

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      SectionHeader(title: "Recipes", symbol: "wand.and.stars") {
        Text("Pick one, choose a shortcut, done.").font(.system(size: 11.5)).foregroundStyle(.secondary)
      }
      LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
        ForEach(AutomationRecipes.all) { recipe in
          RecipeCard(recipe: recipe)
        }
        BuildYourOwnCard()
      }
    }
  }
}

/// A recipe: its drawing, what it does, its key facts and an Add button.
struct RecipeCard: View {
  let recipe: AutomationRecipe
  @Environment(AppModel.self) private var model
  @State private var adding = false
  @State private var hovering = false

  var body: some View {
    let existing = model.binding(for: recipe)
    VStack(alignment: .leading, spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(Theme.well)
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(
            RadialGradient(
              colors: [SettingsPane.automation.tint.opacity(0.16), .clear], center: .center, startRadius: 2,
              endRadius: 70))
        RecipeArt(art: recipe.art, badge: Self.badge(for: recipe.action))
          .scaleEffect(hovering ? 1.05 : 1)
          .animation(Theme.spring, value: hovering)
      }
      .frame(height: 86)
      .overlay(alignment: .topTrailing) {
        if existing != nil {
          Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 14))
            .foregroundStyle(.white, Theme.positive)
            .padding(6)
            .help("You already have this one")
        }
      }
      VStack(alignment: .leading, spacing: 3) {
        Text(recipe.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.85)
        Text(recipe.summary)
          .font(.system(size: 11)).foregroundStyle(.secondary)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
          .frame(height: 42, alignment: .topLeading)
      }
      HStack(spacing: 6) {
        if let existing, !existing.keys.key.isEmpty {
          KeyComboView(combo: existing.keys, size: .small)
          Spacer(minLength: 4)
          Button("Edit") { model.openInEditor(existing.id) }
            .buttonStyle(.soft)
            .fixedSize()
        } else {
          Text(Self.chip(for: recipe.action))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Theme.well, in: Capsule())
          Spacer(minLength: 2)
          Button {
            adding = true
          } label: {
            Label("Add", systemImage: "plus")
          }
          .buttonStyle(.gradientCompact)
          .fixedSize()
        }
      }
      .frame(height: 28)
      .popover(isPresented: $adding, arrowEdge: .bottom) {
        RecipeSheet(recipe: recipe) { adding = false }
          .environment(model)
      }
    }
    .padding(12)
    .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        .strokeBorder(
          hovering ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.cardStroke),
          lineWidth: hovering ? 1.2 : 1)
    )
    .shadow(color: hovering ? Theme.accent.opacity(0.18) : Theme.cardShadow, radius: hovering ? 14 : 10, y: 3)
    .onHover { hovering = $0 }
    .animation(Theme.snappy, value: hovering)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("\(recipe.title): \(recipe.summary)")
  }

  /// The number on the art: the speed or the count.
  static func badge(for action: Action) -> String? {
    switch action {
    case .autoRepeat(_, let interval, _, let times, _):
      return times.map { "×\($0)" } ?? AutomationDescriber.shortRate(interval)
    case .click(_, let count) where count > 1: return "\(count)×"
    default: return nil
    }
  }

  /// How it starts and stops, for the card's chip.
  /// Short enough to sit beside the Add button in the narrowest card.
  static func chip(for action: Action) -> String {
    switch action {
    case .autoRepeat(_, _, let mode, let times, _):
      return times == nil ? AutomationDescriber.modeTitle(mode) : "Auto-stops"
    case .hold: return "Toggle"
    case .click: return "Instant"
    case .sequence(let steps): return "\(steps.count) steps"
    default: return ActionKind(action).title
    }
  }
}

/// The last card: start from scratch in the full editor.
private struct BuildYourOwnCard: View {
  @Environment(AppModel.self) private var model
  @State private var hovering = false

  var body: some View {
    Button {
      model.newAutomation()
    } label: {
      VStack(spacing: 10) {
        Image(systemName: "plus")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(Theme.accentGradient)
          .frame(width: 44, height: 44)
          .background(Theme.cardBackground, in: Circle())
          .overlay(Circle().strokeBorder(Theme.cardStroke))
          .shadow(color: Theme.accent.opacity(0.18), radius: 8, y: 2)
        VStack(spacing: 3) {
          Text("Build Your Own").font(.system(size: 12.5, weight: .semibold))
          Text("Clicks, keys, holds and waits, in any order.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
      }
      .padding(12)
      .frame(maxWidth: .infinity)
      .frame(height: 210)
      .background(
        hovering ? Theme.selection : Color.clear,
        in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
      )
      .overlay(
        RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
          .strokeBorder(Theme.accent.opacity(hovering ? 0.6 : 0.3), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hovering = $0 }
    .animation(Theme.snappy, value: hovering)
  }
}

// MARK: - Add sheet

/// Adjust a recipe, pick its shortcut and where it works, then add it.
struct RecipeSheet: View {
  let recipe: AutomationRecipe
  let onDone: () -> Void
  @Environment(AppModel.self) private var model
  @State private var action: Action
  @State private var keys = KeyCombo(key: "")
  @State private var apps: [String]? = nil

  init(recipe: AutomationRecipe, onDone: @escaping () -> Void) {
    self.recipe = recipe
    self.onDone = onDone
    _action = State(initialValue: recipe.action)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      if !recipe.options.isEmpty {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(recipe.options, id: \.self) { option in
            optionView(option)
          }
        }
        .padding(12)
        .wellStyle()
      }
      FieldGroup("Shortcut") {
        VStack(alignment: .leading, spacing: 8) {
          ShortcutRecorder(
            combo: $keys, requiresModifier: currentApps.isEmpty, autoStart: true,
            plainKeyHint: "Or limit it to a game below to use a plain key there.")
          suggestions
          let conflicts = model.otherUses(ofNewKeys: keys, onlyInApps: currentApps)
          if !conflicts.isEmpty {
            Label(
              "Also used by \(ListFormatter.localizedString(byJoining: conflicts))",
              systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 11.5)).foregroundStyle(Theme.caution)
          }
          // A plain key recorded for a game, then made global, would swallow typing.
          if !keys.key.isEmpty, currentApps.isEmpty, !ShortcutRules.isAcceptableGlobalShortcut(keys) {
            Label(
              "On its own, \(keys.display()) would get in the way of typing everywhere. Limit it to a game, or add ⌃, ⌥ or ⌘.",
              systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 11.5)).foregroundStyle(Theme.caution)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      FieldGroup("Works In") {
        AppScopeEditor(apps: appsBinding)
      }
      AutomationSafetyNote()
      HStack(spacing: 10) {
        Button("Open in Editor…") {
          let id = model.addRecipe(recipe, keys: keys.key.isEmpty ? nil : keys, action: action, onlyInApps: currentApps)
          model.openInEditor(id)
          onDone()
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
        .help("Add it and fine-tune every option in Settings → Windows")
        Spacer()
        Button("Cancel", action: onDone)
          .buttonStyle(.soft)
          .keyboardShortcut(.cancelAction)
        Button {
          model.addRecipe(recipe, keys: keys, action: action, onlyInApps: currentApps)
          onDone()
        } label: {
          Label("Add Automation", systemImage: "plus")
        }
        .buttonStyle(.gradient)
        .disabled(keys.key.isEmpty)
        .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 470)
  }

  private var header: some View {
    HStack(alignment: .center, spacing: 14) {
      ZStack {
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.well)
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(
            RadialGradient(
              colors: [SettingsPane.automation.tint.opacity(0.18), .clear], center: .center, startRadius: 2,
              endRadius: 50))
        RecipeArt(art: recipe.art, badge: RecipeCard.badge(for: action), scale: 0.86)
      }
      .frame(width: 104, height: 76)
      VStack(alignment: .leading, spacing: 4) {
        Text(recipe.bindingName(for: action)).font(.system(size: 16, weight: .bold)).tracking(-0.2)
        Text(AutomationDescriber.sentence(action) + ".")
          .font(.system(size: 12)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  @ViewBuilder private var suggestions: some View {
    let suggested = model.suggestedAutomationKeys()
    if !suggested.isEmpty {
      HStack(spacing: 6) {
        Text("Suggested").font(.system(size: 11)).foregroundStyle(.tertiary)
        ForEach(suggested, id: \.self) { combo in
          Button {
            keys = combo
          } label: {
            KeyComboView(combo: combo, size: .small)
              .padding(3)
              .background(
                keys == combo ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          }
          .buttonStyle(.plain)
          .help("Use \(combo.display())")
        }
        Text("free right now").font(.system(size: 11)).foregroundStyle(.tertiary)
      }
    }
  }

  // MARK: Options

  @ViewBuilder private func optionView(_ option: AutomationRecipe.Option) -> some View {
    let form = ActionForm(action)
    switch option {
    case .speed:
      FieldGroup("How Often") { IntervalField(interval: field(\.interval), jitter: form.jitter) }
    case .humanize:
      JitterField(jitter: field(\.jitter))
    case .count:
      FieldGroup("How Many") {
        HStack(spacing: 8) {
          TextField("50", value: timesBinding, format: .number)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 64)
          Stepper("Clicks", value: timesBinding, in: 1...100_000).labelsHidden()
          Text("clicks, then it stops by itself").font(.system(size: 12)).foregroundStyle(.secondary)
        }
      }
    case .key:
      FieldGroup(recipe.id == "spam-key" ? "Key to Press" : "Key to Hold") {
        KeyChooser(combo: keyBinding, allowsModifierKeys: recipe.id != "spam-key")
      }
    case .modifierKey:
      FieldGroup("Key to Hold") {
        Picker("Key to hold", selection: keyBinding) {
          ForEach(AutomationRecipes.modifierKeys.prefix(4), id: \.key) { modifier in
            Text(modifier.title).tag(KeyCombo(key: modifier.key))
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
      }
    case .button:
      FieldGroup("Button") { MouseButtonPicker(button: field(\.mouseButton)) }
    }
  }

  private func field<T>(_ keyPath: WritableKeyPath<ActionForm, T>) -> Binding<T> {
    Binding(
      get: { ActionForm(action)[keyPath: keyPath] },
      set: { newValue in
        var form = ActionForm(action)
        form[keyPath: keyPath] = newValue
        action = form.action
      })
  }

  private var timesBinding: Binding<Int> {
    Binding(get: { ActionForm(action).repeatTimes ?? 50 }, set: { field(\.repeatTimes).wrappedValue = max(1, $0) })
  }

  /// The key a hold holds, or the key a repeat presses.
  private var keyBinding: Binding<KeyCombo> {
    Binding(
      get: {
        switch action {
        case .hold(.key(let combo)): return combo
        case .autoRepeat(.keystroke(let combo), _, _, _, _): return combo
        default: return KeyCombo(key: "")
        }
      },
      set: { combo in
        switch action {
        case .hold: action = .hold(.key(combo))
        case .autoRepeat(_, let interval, let mode, let times, let jitter):
          action = .autoRepeat(.keystroke(combo), interval: interval, mode: mode, times: times, jitter: jitter)
        default: break
        }
      })
  }

  // MARK: Apps

  /// The apps chosen so far; until the user picks, a running game if there is one.
  private var currentApps: [String] { apps ?? model.runningGames.compactMap(\.bundleID).prefix(1).map { $0 } }

  private var appsBinding: Binding<[String]> {
    Binding(get: { currentApps }, set: { apps = $0 })
  }
}
