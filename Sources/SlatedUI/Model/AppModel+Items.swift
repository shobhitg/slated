import Foundation
import SlatedCore
import SwiftUI

/// The live state of one binding, combining the draft, validation and the engine's report.
enum BindingState: Equatable {
  case active
  case disabled
  case duplicate
  case failed(String)
  /// Just created and waiting for its keys; nothing to save yet.
  case new
  /// Has errors. `wasSaved`: an earlier version is on disk and is what's running meanwhile.
  case notSaved(String, wasSaved: Bool)
  case saving
  case paused
  /// Slate config loading is switched off.
  case slateOff
  /// Not (yet) reported by the engine.
  case inactive
}

/// The state of one hotstring, for its editor.
enum HotstringState: Equatable {
  case notSaved
  case off
  /// The master switch is off.
  case expansionOff
  case paused
  case active
  case waitingForPermission
  /// Permission is granted and nothing is paused or switched off, yet the app reports that hotstrings
  /// aren't running (its keyboard event tap couldn't start), so nothing expands.
  case notRunning
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

  /// Reorders the bindings listed in one section of the Windows list (`subset`, in list order),
  /// leaving every other binding where it is.
  func moveBindings(_ subset: [UUID], fromOffsets offsets: IndexSet, toOffset destination: Int) {
    var ordered = subset
    ordered.move(fromOffsets: offsets, toOffset: destination)
    let members = Set(subset)
    let slots = configuration.bindings.indices.filter { members.contains(configuration.bindings[$0].id) }
    guard slots.count == ordered.count else { return }
    let byID = Dictionary(configuration.bindings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var bindings = configuration.bindings
    for (slot, id) in zip(slots, ordered) {
      if let binding = byID[id] { bindings[slot] = binding }
    }
    configuration.bindings = bindings
  }

  func addStarterBindings() {
    let existing = Set(configuration.bindings.map { BindingStatusKey.key($0.keys, modal: $0.modal) })
    let fresh = WindowPresets.starterBindings.filter { !existing.contains(BindingStatusKey.key($0.keys, modal: nil)) }
    configuration.bindings.append(contentsOf: fresh)
  }

  /// Copies a static Slate binding into Slated's own bindings, where it can be edited.
  func copyIntoSlated(_ source: SourceBinding) {
    guard let action = source.action else { return }
    let binding = HotkeyBinding(keys: source.keys, modal: source.modal, action: action)
    configuration.bindings.append(binding)
    selectedBinding = .slated(binding.id)
    showToast("Copied into Slated. Remove it from your Slate file to avoid a duplicate.", symbol: "doc.on.doc.fill")
  }

  /// True when Slated already has a binding with the same keys and action as `source`.
  func isCopied(_ source: SourceBinding) -> Bool {
    configuration.bindings.contains { $0.keys == source.keys && $0.modal == source.modal && $0.action == source.action }
  }

  func state(for binding: HotkeyBinding) -> BindingState {
    let wasSaved = saved.bindings.contains { $0.id == binding.id }
    if binding.keys.key.isEmpty && !wasSaved { return .new }
    if !binding.enabled { return .disabled }
    if let error = issues.first(where: { $0.target == .binding(binding.id) && $0.severity == .error }) {
      return .notSaved(error.message, wasSaved: wasSaved)
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

  /// Slate bindings, Slated bindings and Slated's built-in shortcuts (clipboard history, stop
  /// automations) that share `keys` with the given one, for duplicate hints.
  func otherUses(
    of keys: KeyCombo, modal: ModalKey?, excluding id: UUID?, excludingBuiltIn: BuiltInShortcut? = nil
  ) -> [String] {
    guard !keys.key.isEmpty else { return [] }
    let key = BindingStatusKey.key(keys, modal: modal)
    let editing = id.flatMap { binding($0) }
    var uses = configuration.bindings
      .filter { other in
        other.id != id && other.enabled && BindingStatusKey.key(other.keys, modal: other.modal) == key
          && (editing.map { $0.sharesApps(with: other) } ?? true)
      }
      .map { "“\(BindingTitle.title(for: $0))”" }
    if configuration.general.loadSlateConfigs {
      for source in sources where source.loaded {
        for binding in source.bindings where binding.id == key {
          uses.append("“\(binding.summary)” in \(source.displayName)")
        }
      }
    }
    if modal == nil {
      // A binding that runs the same thing as the built-in shortcut doesn't get in its way.
      let action = id.flatMap { binding($0)?.action }
      for builtIn in BuiltInShortcut.allCases where builtIn != excludingBuiltIn && builtIn.action != action {
        if let builtInKeys = builtIn.keys(in: configuration), BindingStatusKey.key(builtInKeys, modal: nil) == key {
          uses.append(builtIn.title)
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

  /// What a hotstring's editor says about it: the draft, validation and the engine combined.
  func state(for hotstring: Hotstring) -> HotstringState {
    if issues(for: .hotstring(hotstring.id)).contains(where: { $0.severity == .error }) { return .notSaved }
    if !hotstring.enabled { return .off }
    if !runtimeStatus.hotstringsEnabled { return .expansionOff }
    if runtimeStatus.paused { return .paused }
    if !runtimeStatus.accessibilityGranted { return .waitingForPermission }
    // The app also reports hotstrings inactive while Settings suspends them on purpose (the Try It
    // field or a shortcut recorder has focus), and while none is saved yet: the first one runs once
    // its save lands. Otherwise they really don't run, e.g. the keyboard event tap couldn't start.
    if runtimeStatus.hotstringsActive || isSuspendingHotkeys || !saved.hotstrings.contains(where: \.enabled) {
      return .active
    }
    return .notRunning
  }

  // MARK: Layouts

  /// Where the Slated layout called `name` is in `layouts`: at `index` when the layout there has that
  /// name, else the first with it. A layout copied in config.json shares its name with the original,
  /// so the editor, the list and Delete go by position.
  func layoutIndex(_ name: String, at index: Int? = nil) -> Int? {
    if let index, configuration.layouts.indices.contains(index), configuration.layouts[index].name == name {
      return index
    }
    return configuration.layouts.firstIndex { $0.name == name }
  }

  /// Where the selected Slated layout is in `layouts`, if one is selected.
  var selectedLayoutIndex: Int? {
    guard case .slated(let name, let index) = selectedLayout else { return nil }
    return layoutIndex(name, at: index)
  }

  /// A binding to one Slated layout: the one called `name` at `index` (see `layoutIndex`). A new
  /// name goes through `renameLayout`, which ignores names that would make the layout impossible to
  /// tell apart.
  func layoutBinding(_ name: String, at index: Int? = nil) -> Binding<WindowLayout>? {
    guard let start = layoutIndex(name, at: index) else { return nil }
    let current = configuration.layouts[start]
    var trackedName = name
    var trackedIndex = start
    return Binding(
      get: { [weak self] in
        guard let self, let at = self.layoutIndex(trackedName, at: trackedIndex) else { return current }
        return self.configuration.layouts[at]
      },
      set: { [weak self] newValue in
        guard let self, let at = self.layoutIndex(trackedName, at: trackedIndex) else { return }
        trackedIndex = at
        var edited = newValue
        edited.name = trackedName
        self.configuration.layouts[at] = edited
        if newValue.name != trackedName { trackedName = self.renameLayout(trackedName, at: at, to: newValue.name) }
      })
  }

  /// Renames the Slated layout called `name` (the one at `index`, see `layoutIndex`) and re-points
  /// what applies it, except what's in `keeping`. A name `layoutNameProblem` objects to isn't taken:
  /// shortcuts apply a layout by its name, so they would follow this one onto the other layout.
  /// Returns the layout's name after.
  @discardableResult
  func renameLayout(
    _ name: String, at index: Int? = nil, to newName: String, keeping: Set<LayoutReference> = []
  ) -> String {
    guard newName != name, let at = layoutIndex(name, at: index),
      layoutNameProblem(newName, renaming: name, at: at) == nil
    else { return name }
    configuration.layouts[at].name = newName
    // Refused while config.json can't be read (the model said so).
    guard configuration.layouts[at].name == newName else { return name }
    // A copy still has the old name: what applies that name stays with it.
    if !configuration.layouts.contains(where: { $0.name == name }) {
      renameLayoutReferences(from: name, to: newName, keeping: keeping)
    }
    selectedLayout = .slated(name: newName, index: at)
    return newName
  }

  /// The layout editor's name field: makes `typed` the name of the layout called `current` (the one
  /// at `index`) when it's usable, and returns the layout's name after. Typing passes through other
  /// names. What applied one of them before this layout took it (a shortcut waiting for a layout of
  /// that name, say) is recorded in `arrivals`, which the editor keeps while it's open, and stays
  /// on that name when typing goes on: only this layout's own shortcuts move with it.
  @discardableResult
  func typeLayoutName(
    _ typed: String, renaming current: String, at index: Int?, arrivals: inout [String: Set<LayoutReference>]
  ) -> String {
    guard typed != current, layoutNameProblem(typed, renaming: current, at: index) == nil else { return current }
    let named = layoutReferences(typed)
    let name = renameLayout(current, at: index, to: typed, keeping: arrivals[current] ?? [])
    if name == typed { arrivals[typed] = named }
    return name
  }

  /// Why `name` can't become the name of the layout now called `current` (the one at `index`, see
  /// `layoutIndex`), if it can't. A Slate file's layout names are taken too, as for `addLayout`:
  /// Slated's layouts replace Slate's of the same name, for the Slate file's shortcuts as well.
  func layoutNameProblem(_ name: String, renaming current: String, at index: Int? = nil) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return "Name the layout." }
    guard name != current else { return nil }
    let own = layoutIndex(current, at: index)
    // Spaces around a name don't show in any list: “Work ” would look like a second “Work”.
    let isTrimmed = { (layout: WindowLayout) in layout.name.trimmingCharacters(in: .whitespaces) == trimmed }
    let taken =
      configuration.layouts.indices.contains { $0 != own && isTrimmed(configuration.layouts[$0]) }
      || sources.contains { $0.layouts.contains(where: isTrimmed) }
    return taken ? "Another layout already has this name." : nil
  }

  /// What applies the layout called `name`: shortcuts and hotstrings, in any step, and display
  /// defaults.
  func layoutReferences(_ name: String) -> Set<LayoutReference> {
    var references = Set<LayoutReference>()
    for binding in configuration.bindings where binding.action.layoutNames.contains(name) {
      references.insert(.binding(binding.id))
    }
    for hotstring in configuration.hotstrings where hotstring.action?.layoutNames.contains(name) == true {
      references.insert(.hotstring(hotstring.id))
    }
    for (index, screenDefault) in configuration.defaults.enumerated() where screenDefault.target == name {
      references.insert(.screenDefault(index))
    }
    return references
  }

  @discardableResult
  func addLayout() -> String {
    var name = "New Layout"
    var n = 2
    // Nor a name something still applies (a deleted layout's): renaming the new layout would take it along.
    while knownLayoutNames.contains(name) || !layoutReferences(name).isEmpty {
      name = "New Layout \(n)"
      n += 1
    }
    configuration.layouts.append(WindowLayout(name: name))
    // Not when refused while config.json can't be read.
    if configuration.layouts.last?.name == name {
      selectedLayout = .slated(name: name, index: configuration.layouts.count - 1)
    }
    return name
  }

  /// Deletes the Slated layout called `name` (the one at `index`, see `layoutIndex`). Shortcuts that
  /// apply it stay, waiting for a layout of that name.
  func deleteLayout(_ name: String, at index: Int? = nil) {
    guard let at = layoutIndex(name, at: index) else { return }
    let selected = selectedLayoutIndex
    let count = configuration.layouts.count
    configuration.layouts.remove(at: at)
    guard configuration.layouts.count < count else { return }  // refused while config.json can't be read
    if let selected, case .slated(let selectedName, _) = selectedLayout {
      selectedLayout = selected == at ? nil : .slated(name: selectedName, index: selected - (selected > at ? 1 : 0))
    }
    showToast("Deleted layout “\(name)”", symbol: "trash")
  }

  /// Keeps what applies a renamed layout on it: shortcuts and hotstrings, in any step, and display
  /// defaults. What's in `keep` stays where it is.
  private func renameLayoutReferences(from old: String, to new: String, keeping keep: Set<LayoutReference>) {
    var config = configuration
    for index in config.bindings.indices where !keep.contains(.binding(config.bindings[index].id)) {
      config.bindings[index].action = config.bindings[index].action.renamingLayout(old, to: new)
    }
    for index in config.hotstrings.indices where !keep.contains(.hotstring(config.hotstrings[index].id)) {
      config.hotstrings[index].action = config.hotstrings[index].action?.renamingLayout(old, to: new)
    }
    for index in config.defaults.indices
    where config.defaults[index].target == old && !keep.contains(.screenDefault(index)) {
      config.defaults[index].target = new
    }
    configuration = config
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
