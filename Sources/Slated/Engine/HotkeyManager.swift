import AppKit
import SlatedCore
import SlatedSystem
import SlatedUI

/// Registers bindings from every source as global hotkeys, including Slate's modal keys and
/// repeat-while-held, and tracks each binding's status for the UI.
final class HotkeyManager {
  struct Entry {
    /// Status key: `KeyCombo.string`, prefixed by the modal key's string and a space.
    var id: String { (modal.map { $0.keys.string + " " } ?? "") + keys.string }
    var keys: KeyCombo
    var modal: ModalKey?
    var repeats: Bool
    /// Where the binding is defined ("Slated", "~/.slate.js", …), for logs.
    var source: String = "Slated"
    /// Only registered while one of these apps is frontmost; empty means everywhere.
    var apps: [String] = []
    /// What it runs, when known (not for a Slate script's functions), for the duplicate check.
    var action: Action? = nil
    /// One of Slated's own shortcuts (clipboard history, stop automations), registered after the bindings.
    var builtIn = false
    var run: () -> Void

    /// Whether `other`, on the same keys, gets in this one's way: they can be live at once (everywhere,
    /// or in an app they share), so only the first runs. A binding on a built-in shortcut's keys that
    /// runs what the shortcut runs doesn't: it does what the shortcut would.
    func clashes(with other: Entry) -> Bool {
      let sharesApps = apps.isEmpty || other.apps.isEmpty || !Set(apps).isDisjoint(with: other.apps)
      let sameBuiltIn = (builtIn || other.builtIn) && action != nil && action == other.action
      return sharesApps && !sameBuiltIn
    }
  }

  private(set) var statuses: [String: HotkeyStatus] = [:]
  /// Shortcuts bound more than once where the bindings can be live at once; only the first one runs.
  /// Their status is `.duplicate` (statuses are keyed by shortcut), unless registering failed.
  private(set) var duplicates: [String] = []
  private var settings = SlateSettings()
  private var tokens: [UInt32] = []
  private var direct: [KeyCombo: Entry] = [:]
  private var modalEntries: [KeyCombo: [Entry]] = [:]
  private var activeModal: KeyCombo?
  private var modalTokens: [UInt32] = []
  private var repeatTimer: Timer?
  private var repeatAction: (() -> Void)?
  /// Invoked when modal mode starts or ends (the menu bar icon reflects it).
  var onModalChange: ((KeyCombo?) -> Void)?
  /// A binding's key went up (while-held auto-repeats stop then).
  var onRelease: ((Entry) -> Void)?
  /// A binding fired (not its repeats while held); the island highlights it in the cheat sheet.
  var onFire: ((Entry) -> Void)?
  /// Whether the keyboard tap can deliver mouse button shortcuts (needs Accessibility permission).
  var mouseTriggersAvailable = false

  private var lastEntries: [Entry] = []
  private var lastDisabled: [String] = []
  private var frontmostApp: String?

  func apply(_ entries: [Entry], disabled: [String] = [], settings: SlateSettings) {
    unregisterAll()
    self.settings = settings
    lastEntries = entries
    lastDisabled = disabled
    var seen = Set<String>()
    var direct: [Entry] = []
    statuses = Dictionary(disabled.map { ($0, HotkeyStatus.disabled) }, uniquingKeysWith: { a, _ in a })
    // From every entry, not just those live for the app in front, so statuses don't change as you
    // switch apps (and Settings, in front while you look, sees app-specific ones too).
    duplicates = Self.duplicates(in: entries)
    // App-specific bindings are registered only while their app is in front, so a plain key in a
    // game never steals that key anywhere else. The rest count as ready.
    let live = entries.filter { $0.apps.isEmpty || frontmostApp.map($0.apps.contains) == true }
    for entry in entries where !entry.apps.isEmpty && statuses[entry.id] == nil {
      statuses[entry.id] = .active
    }
    for entry in live {
      guard seen.insert(entry.id).inserted else { continue }
      if let modal = entry.modal {
        modalEntries[modal.keys, default: []].append(entry)
      } else {
        direct.append(entry)
      }
    }
    for entry in direct {
      if KeyNames.isModifierKey(entry.keys.key) {
        statuses[entry.id] = .failed("A modifier key can't be a shortcut on its own")
        continue
      }
      self.direct[entry.keys] = entry
      if KeyNames.isMouseButton(entry.keys.key) {
        // Delivered by the keyboard tap, not Carbon (which only knows keys).
        statuses[entry.id] =
          mouseTriggersAvailable ? .active : .failed("Mouse button shortcuts need Accessibility permission")
        continue
      }
      register(entry.keys, id: entry.id) { [weak self] phase in self?.handle(entry, phase: phase) }
    }
    defer { logRegistration() }
    for modalKeys in modalEntries.keys {
      // The keys behind a modal key are registered when the mode starts; until then the bindings are
      // as live as their modal key.
      let status: HotkeyStatus
      do {
        tokens.append(
          try HotKeyCenter.shared.register(modalKeys) { [weak self] phase in
            guard phase == .pressed else { return }
            self?.toggleModal(modalKeys)
          })
        status = .active
      } catch {
        status = .failed("Its modal key can't be used: \(error.description)")
      }
      for entry in modalEntries[modalKeys] ?? [] where statuses[entry.id] == nil {
        statuses[entry.id] = status
      }
    }
    for id in duplicates where statuses[id] == .active { statuses[id] = .duplicate }
  }

  /// Ids of the shortcuts some entry shadows: an earlier entry on the same keys clashes with it.
  static func duplicates(in entries: [Entry]) -> [String] {
    var earlier: [String: [Entry]] = [:]
    var result: [String] = []
    for entry in entries {
      if !result.contains(entry.id), earlier[entry.id, default: []].contains(where: { $0.clashes(with: entry) }) {
        result.append(entry.id)
      }
      earlier[entry.id, default: []].append(entry)
    }
    return result
  }

  /// Non-modal combos currently bound, so the keyboard tap can catch Hyper combos itself.
  var boundCombos: [KeyCombo] { Array(direct.keys) }

  /// Mouse button shortcuts currently bound (delivered by the keyboard tap).
  var boundMouseCombos: [KeyCombo] { direct.keys.filter { KeyNames.isMouseButton($0.key) } }

  /// Re-registers app-specific bindings when another app comes to the front. Returns true if
  /// anything had to change.
  @discardableResult
  func setFrontmostApp(_ bundleID: String?) -> Bool {
    let previous = frontmostApp
    frontmostApp = bundleID
    guard previous != bundleID, lastEntries.contains(where: { !$0.apps.isEmpty }) else { return false }
    apply(lastEntries, disabled: lastDisabled, settings: settings)
    return true
  }

  /// Runs the binding for `keys` as if its hotkey fired. Returns false if nothing is bound.
  @discardableResult
  func trigger(_ keys: KeyCombo, phase: HotKeyCenter.Phase) -> Bool {
    guard let entry = direct[keys] else { return false }
    handle(entry, phase: phase)
    return true
  }

  private var lastLoggedRegistration = ""

  /// Logs a summary when the set of registered hotkeys or their problems change (applying the config
  /// happens on every settings save, so unchanged registrations aren't repeated).
  private func logRegistration() {
    let failed = statuses.compactMap { key, status -> String? in
      if case .failed(let reason) = status { return "\(key): \(reason)" }
      return nil
    }.sorted()
    let active = statuses.values.filter { $0 == .active }.count
    // Problems only: app switches re-register app-specific bindings without changing them.
    let signature = "\(failed)|\(duplicates)"
    guard signature != lastLoggedRegistration else { return }
    lastLoggedRegistration = signature
    var data: [String: Any] = ["active": active, "total": statuses.count]
    if !failed.isEmpty { data["failed"] = failed }
    if !duplicates.isEmpty { data["duplicates"] = duplicates }
    Log.record("hotkeys.registered", level: failed.isEmpty ? .info : .error, data)
  }

  func unregisterAll() {
    exitModal()
    for token in tokens { HotKeyCenter.shared.unregister(token) }
    tokens.removeAll()
    direct.removeAll()
    modalEntries.removeAll()
    // Nothing comes back until the next `apply`: an app switch re-applies `lastEntries`, which used to
    // bring every hotkey back while Slated was paused or Settings was recording a shortcut.
    lastEntries = []
    lastDisabled = []
    stopRepeating()
  }

  private func register(_ keys: KeyCombo, id: String, handler: @escaping HotKeyCenter.Handler) {
    do {
      tokens.append(try HotKeyCenter.shared.register(keys, handler: handler))
      statuses[id] = .active
    } catch {
      statuses[id] = .failed(error.description)
    }
  }

  private func handle(_ entry: Entry, phase: HotKeyCenter.Phase) {
    switch phase {
    case .pressed:
      onFire?(entry)
      entry.run()
      if entry.repeats { startRepeating(entry.run) }
    case .released where repeatAction != nil:
      stopRepeating()
      onRelease?(entry)
    case .released:
      stopRepeating()
      onRelease?(entry)
    }
  }

  // MARK: Repeat while held (Slate's repeatOnHoldOps)

  private func startRepeating(_ run: @escaping () -> Void) {
    stopRepeating()
    repeatAction = run
    let interval = max(settings.secondsBetweenRepeat, 0.02)
    repeatTimer = Timer.scheduledTimer(withTimeInterval: settings.secondsBeforeRepeat, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.repeatAction?()
        self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.repeatAction?() }
        }
      }
    }
  }

  private func stopRepeating() {
    repeatTimer?.invalidate()
    repeatTimer = nil
    repeatAction = nil
  }

  // MARK: Modal keys

  private func toggleModal(_ modalKeys: KeyCombo) {
    if activeModal == modalKeys {
      exitModal()
      return
    }
    exitModal()
    activeModal = modalKeys
    for entry in modalEntries[modalKeys] ?? [] {
      do {
        modalTokens.append(
          try HotKeyCenter.shared.register(entry.keys) { [weak self] phase in
            guard phase == .pressed else { return }
            self?.onFire?(entry)
            entry.run()
            if entry.modal?.toggle != true { self?.exitModal() }
          })
      } catch {
        // Keys are only registered now, so this is where a key another binding or app owns fails.
        statuses[entry.id] = .failed(error.description)
        Log.record("modal.key_failed", level: .error, ["keys": entry.id, "reason": error.description])
      }
    }
    let escapeKey = KeyCombo(string: settings.string("modalEscapeKey", default: "esc")) ?? KeyCombo(key: "esc")
    do {
      modalTokens.append(
        try HotKeyCenter.shared.register(escapeKey) { [weak self] phase in
          if phase == .pressed { self?.exitModal() }
        })
    } catch {
      Log.record("modal.key_failed", level: .error, ["keys": escapeKey.string, "reason": error.description])
    }
    Log.record("modal.entered", ["keys": modalKeys.string])
    onModalChange?(modalKeys)
  }

  private func exitModal() {
    guard activeModal != nil else { return }
    for token in modalTokens { HotKeyCenter.shared.unregister(token) }
    modalTokens.removeAll()
    activeModal = nil
    Log.record("modal.exited")
    onModalChange?(nil)
  }
}
