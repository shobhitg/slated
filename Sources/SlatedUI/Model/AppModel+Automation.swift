import Foundation
import SlatedCore

extension AppModel {
  // MARK: Automation bindings

  /// Slated bindings that click, press or hold, anywhere in their action, in config order.
  var automationBindings: [HotkeyBinding] { configuration.bindings.filter { $0.action.containsAutomation } }

  /// The automations a binding started. The engine names a hotkey's trigger "hotkey <keys>".
  func activeAutomations(for binding: HotkeyBinding) -> [ActiveAutomation] {
    let trigger = "hotkey " + BindingStatusKey.key(binding.keys, modal: binding.modal)
    return activeAutomations.filter { $0.trigger == trigger }
  }

  /// The Slated binding that started a running automation, if any.
  func binding(for automation: ActiveAutomation) -> HotkeyBinding? {
    guard let trigger = automation.trigger, trigger.hasPrefix("hotkey ") else { return nil }
    let key = String(trigger.dropFirst("hotkey ".count))
    return configuration.bindings.first { $0.enabled && BindingStatusKey.key($0.keys, modal: $0.modal) == key }
  }

  /// The name to show for a running automation: its binding's title when it has one.
  func title(for automation: ActiveAutomation) -> String {
    binding(for: automation).map(BindingTitle.title(for:)) ?? automation.title
  }

  /// Stops every automation and lets go of anything held.
  func stopAutomations() {
    let count = activeAutomations.count
    services.stopAutomations()
    refresh()
    if count > 0 {
      showToast(count == 1 ? "Stopped the automation" : "Stopped \(count) automations", symbol: "stop.circle.fill")
    }
  }

  /// Shows a binding in Settings → Windows.
  func openInEditor(_ id: UUID) {
    selectedBinding = .slated(id)
    selectedPane = .windows
  }

  /// A new auto-clicker, opened in the Windows editor with its shortcut recorder running.
  func newAutomation() {
    addBinding(action: AutomationRecipes.all[0].action)
    selectedPane = .windows
  }

  // MARK: Recipes

  /// A binding already set up from a recipe (adjusted or not), if there is one.
  func binding(for recipe: AutomationRecipe) -> HotkeyBinding? {
    configuration.bindings.first { recipe.matches($0.action) }
  }

  /// Adds a binding that runs the recipe (`action` is the recipe's action as adjusted in the add
  /// sheet), limited to `apps` when given. With keys it's live right away and the user stays where
  /// they are; without, Settings → Windows opens with its shortcut recorder running.
  @discardableResult
  func addRecipe(
    _ recipe: AutomationRecipe, keys: KeyCombo?, action: Action? = nil, onlyInApps apps: [String] = []
  ) -> UUID {
    let action = action ?? recipe.action
    let name = recipe.bindingName(for: action)
    let hasKeys = keys.map { !$0.key.isEmpty } ?? false
    let binding = HotkeyBinding(name: name, keys: keys ?? KeyCombo(key: ""), action: action, onlyInApps: apps)
    configuration.bindings.append(binding)
    selectedBinding = .slated(binding.id)
    if hasKeys, let keys {
      let place = apps.first.map { " in \(appName(bundleID: $0))" } ?? ""
      showToast("Added “\(name)” on \(keys.display())\(place)", symbol: "sparkles")
    } else {
      recordShortcutFor = binding.id
      selectedPane = .windows
    }
    return binding.id
  }

  /// What already uses `keys`, for a binding about to be added with `apps`: Slated bindings that
  /// can be live at the same time, loaded Slate files and the built-in shortcuts.
  func otherUses(ofNewKeys keys: KeyCombo, onlyInApps apps: [String]) -> [String] {
    guard !keys.key.isEmpty else { return [] }
    let probe = HotkeyBinding(keys: keys, action: .stopAutomations, onlyInApps: apps)
    let key = BindingStatusKey.key(keys, modal: nil)
    var uses = configuration.bindings
      .filter { $0.enabled && BindingStatusKey.key($0.keys, modal: $0.modal) == key && $0.sharesApps(with: probe) }
      .map { "“\(BindingTitle.title(for: $0))”" }
    if configuration.general.loadSlateConfigs {
      for source in sources where source.loaded {
        for binding in source.bindings where binding.id == key {
          uses.append("“\(binding.summary)” in \(source.displayName)")
        }
      }
    }
    for builtIn in BuiltInShortcut.allCases where builtIn.keys(in: configuration) == keys {
      uses.append(builtIn.title)
    }
    return uses
  }

  /// Running apps that say they're games (their App Store category), for "Only in…" pickers.
  var runningGames: [AppInfo] { runningApps.filter { AppIcons.isGame(path: $0.path, bundleID: $0.bundleID) } }

  /// Free shortcuts to offer for a new automation: the first unused function key from F6 up, then
  /// an unused ✦ digit when the Hyper key is on, then more function keys.
  func suggestedAutomationKeys(limit: Int = 2) -> [KeyCombo] {
    let used = usedShortcutKeys
    let functionKeys = AutomationRecipes.preferredFunctionKeys.map { KeyCombo(key: $0) }.filter {
      !used.contains($0.string)
    }
    var result = Array(functionKeys.prefix(1))
    if hyperKeyEnabled,
      let digit = (1...9).map({ KeyCombo(key: "\($0)", modifiers: .hyper) }).first(where: { !used.contains($0.string) })
    {
      result.append(digit)
    }
    result += functionKeys.dropFirst().prefix(max(0, limit - result.count))
    return Array(result.prefix(limit))
  }
}

extension ActiveAutomation {
  /// The shortcut that started it, when that was a plain hotkey (`trigger` "hotkey hyper+r").
  var triggerKeys: KeyCombo? {
    guard let trigger, trigger.hasPrefix("hotkey ") else { return nil }
    let keys = String(trigger.dropFirst("hotkey ".count))
    guard !keys.contains(" ") else { return nil }  // modal bindings: "ctrl+f4 1"
    return KeyCombo(string: keys)
  }
}
