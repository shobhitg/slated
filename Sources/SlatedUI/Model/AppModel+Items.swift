import Foundation
import SlatedCore
import SwiftUI

/// The live state of one binding, combining the draft, validation and the engine's report.
enum BindingState: Equatable {
  case active
  case disabled
  case duplicate
  case failed(String)
  /// Has errors, so the last saved version (if any) is what's running.
  case notSaved(String)
  case saving
  case paused
  /// Slate config loading is switched off.
  case slateOff
  /// Not (yet) reported by the engine.
  case inactive
}

extension AppModel {
  // MARK: Bindings

  func binding(_ id: UUID) -> HotkeyBinding? { configuration.bindings.first { $0.id == id } }

  /// A binding to one Slated binding by id. Writes are ignored if it was deleted meanwhile.
  func bindingBinding(_ id: UUID) -> Binding<HotkeyBinding>? {
    guard let current = binding(id) else { return nil }
    return Binding(
      get: { [weak self] in self?.binding(id) ?? current },
      set: { [weak self] newValue in
        guard let self, let index = self.configuration.bindings.firstIndex(where: { $0.id == id }) else { return }
        self.configuration.bindings[index] = newValue
      })
  }

  /// Adds a new shortcut (Left Half until changed), selects it and starts recording its keys.
  /// Set `selectedPane = .windows` and show the settings window to let the user finish it.
  public func newBinding() { addBinding() }

  @discardableResult
  func addBinding(action: Action = WindowPresets.preset("left-half").action) -> UUID {
    let binding = HotkeyBinding(keys: KeyCombo(key: "", modifiers: []), action: action)
    configuration.bindings.append(binding)
    selectedBinding = .slated(binding.id)
    recordShortcutFor = binding.id
    return binding.id
  }

  func duplicateBinding(_ id: UUID) {
    guard let index = configuration.bindings.firstIndex(where: { $0.id == id }) else { return }
    var copy = configuration.bindings[index]
    copy.id = UUID()
    copy.name = copy.name.map { "\($0) Copy" }
    copy.keys = KeyCombo(key: "", modifiers: [])
    configuration.bindings.insert(copy, at: index + 1)
    selectedBinding = .slated(copy.id)
    recordShortcutFor = copy.id
  }

  func deleteBinding(_ id: UUID) {
    guard let index = configuration.bindings.firstIndex(where: { $0.id == id }) else { return }
    let name = BindingTitle.title(for: configuration.bindings[index])
    configuration.bindings.remove(at: index)
    if selectedBinding == .slated(id) {
      let remaining = configuration.bindings
      selectedBinding = remaining.isEmpty ? nil : .slated(remaining[min(index, remaining.count - 1)].id)
    }
    showToast("Deleted “\(name)”", symbol: "trash")
  }

  func addStarterBindings() {
    let existing = Set(configuration.bindings.map { BindingStatusKey.key($0.keys, modal: $0.modal) })
    let fresh = WindowPresets.starterBindings.filter { !existing.contains(BindingStatusKey.key($0.keys, modal: nil)) }
    configuration.bindings.append(contentsOf: fresh)
  }

  /// Copies a static Slate binding into Slated's own bindings, where it can be edited.
  func copyIntoSlated(_ source: SourceBinding) {
    guard let action = source.action else { return }
    let binding = HotkeyBinding(name: source.summary, keys: source.keys, modal: source.modal, action: action)
    configuration.bindings.append(binding)
    selectedBinding = .slated(binding.id)
    showToast("Copied into Slated. Remove it from your Slate file to avoid a duplicate.", symbol: "doc.on.doc.fill")
  }

  /// True when Slated already has a binding with the same keys and action as `source`.
  func isCopied(_ source: SourceBinding) -> Bool {
    configuration.bindings.contains { $0.keys == source.keys && $0.modal == source.modal && $0.action == source.action }
  }

  func state(for binding: HotkeyBinding) -> BindingState {
    if !binding.enabled { return .disabled }
    if let error = issues.first(where: { $0.target == .binding(binding.id) && $0.severity == .error }) {
      return .notSaved(error.message)
    }
    if saved.bindings.first(where: { $0.id == binding.id }) != binding { return .saving }
    if runtimeStatus.paused { return .paused }
    return state(forKey: BindingStatusKey.key(binding.keys, modal: binding.modal))
  }

  func state(for source: SourceBinding) -> BindingState {
    if !configuration.general.loadSlateConfigs { return .slateOff }
    if runtimeStatus.paused { return .paused }
    return state(forKey: source.id)
  }

  private func state(forKey key: String) -> BindingState {
    switch runtimeStatus.hotkeys[key] {
    case .active: return .active
    case .disabled: return .disabled
    case .duplicate: return .duplicate
    case .failed(let reason): return .failed(reason)
    case nil: return .inactive
    }
  }

  /// Slate bindings and Slated bindings that share `keys` with the given one, for duplicate hints.
  func otherUses(of keys: KeyCombo, modal: ModalKey?, excluding id: UUID?) -> [String] {
    guard !keys.key.isEmpty else { return [] }
    let key = BindingStatusKey.key(keys, modal: modal)
    var uses = configuration.bindings
      .filter { $0.id != id && $0.enabled && BindingStatusKey.key($0.keys, modal: $0.modal) == key }
      .map { "“\(BindingTitle.title(for: $0))”" }
    if configuration.general.loadSlateConfigs {
      for source in sources where source.loaded {
        for binding in source.bindings where binding.id == key {
          uses.append("“\(binding.summary)” in \(source.displayName)")
        }
      }
    }
    return uses
  }

  // MARK: Counts

  var activeBindingCount: Int {
    runtimeStatus.hotkeys.values.filter { $0 == .active }.count
  }

  var problemBindingCount: Int {
    runtimeStatus.hotkeys.values.filter {
      if case .failed = $0 { return true }
      return $0 == .duplicate
    }.count
  }

  var sourceBindingCount: Int { sources.filter(\.loaded).reduce(0) { $0 + $1.bindings.count } }

  // MARK: Hotstrings

  func hotstring(_ id: UUID) -> Hotstring? { configuration.hotstrings.first { $0.id == id } }

  func hotstringBinding(_ id: UUID) -> Binding<Hotstring>? {
    guard let current = hotstring(id) else { return nil }
    return Binding(
      get: { [weak self] in self?.hotstring(id) ?? current },
      set: { [weak self] newValue in
        guard let self, let index = self.configuration.hotstrings.firstIndex(where: { $0.id == id }) else { return }
        self.configuration.hotstrings[index] = newValue
      })
  }

  @discardableResult
  func addHotstring() -> UUID {
    let hotstring = Hotstring(trigger: "", replacement: "")
    configuration.hotstrings.append(hotstring)
    selectedHotstringID = hotstring.id
    return hotstring.id
  }

  func deleteHotstring(_ id: UUID) {
    guard let index = configuration.hotstrings.firstIndex(where: { $0.id == id }) else { return }
    let trigger = configuration.hotstrings[index].trigger
    configuration.hotstrings.remove(at: index)
    if selectedHotstringID == id {
      let remaining = configuration.hotstrings
      selectedHotstringID = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
    }
    showToast(trigger.isEmpty ? "Deleted hotstring" : "Deleted “\(trigger)”", symbol: "trash")
  }

  func duplicateHotstring(_ id: UUID) {
    guard let index = configuration.hotstrings.firstIndex(where: { $0.id == id }) else { return }
    var copy = configuration.hotstrings[index]
    copy.id = UUID()
    copy.trigger += "2"
    configuration.hotstrings.insert(copy, at: index + 1)
    selectedHotstringID = copy.id
  }

  var enabledHotstringCount: Int { configuration.hotstrings.filter(\.enabled).count }

  // MARK: Layouts

  func layoutBinding(_ name: String) -> Binding<WindowLayout>? {
    guard let current = configuration.layouts.first(where: { $0.name == name }) else { return nil }
    var trackedName = name
    return Binding(
      get: { [weak self] in self?.configuration.layouts.first { $0.name == trackedName } ?? current },
      set: { [weak self] newValue in
        guard let self, let index = self.configuration.layouts.firstIndex(where: { $0.name == trackedName }) else {
          return
        }
        let oldName = trackedName
        self.configuration.layouts[index] = newValue
        if newValue.name != oldName {
          trackedName = newValue.name
          self.renameLayoutReferences(from: oldName, to: newValue.name)
          self.selectedLayout = .slated(name: newValue.name)
        }
      })
  }

  @discardableResult
  func addLayout() -> String {
    var name = "New Layout"
    var n = 2
    while knownLayoutNames.contains(name) {
      name = "New Layout \(n)"
      n += 1
    }
    configuration.layouts.append(WindowLayout(name: name))
    selectedLayout = .slated(name: name)
    return name
  }

  func deleteLayout(_ name: String) {
    configuration.layouts.removeAll { $0.name == name }
    if selectedLayout == .slated(name: name) { selectedLayout = nil }
    showToast("Deleted layout “\(name)”", symbol: "trash")
  }

  /// Keeps `.layout(name:)` bindings pointing at a renamed layout.
  private func renameLayoutReferences(from old: String, to new: String) {
    for index in configuration.bindings.indices where configuration.bindings[index].action == .layout(name: old) {
      configuration.bindings[index].action = .layout(name: new)
    }
  }

  /// Bindings (Slated and Slate) that apply the named layout.
  func triggers(forLayout name: String) -> [(keys: KeyCombo, modal: ModalKey?)] {
    var result = configuration.bindings.filter { $0.action == .layout(name: name) }.map { ($0.keys, $0.modal) }
    for source in sources {
      for binding in source.bindings where binding.action == .layout(name: name) {
        result.append((binding.keys, binding.modal))
      }
    }
    return result
  }
}

extension SlateSource {
  /// `~/.slate.js`-style path for display.
  var displayName: String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }

  var fileName: String { (path as NSString).lastPathComponent }

  var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }
}
