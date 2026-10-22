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
    var run: () -> Void
  }

  private(set) var statuses: [String: HotkeyStatus] = [:]
  private var settings = SlateSettings()
  private var tokens: [UInt32] = []
  private var modalEntries: [KeyCombo: [Entry]] = [:]
  private var activeModal: KeyCombo?
  private var modalTokens: [UInt32] = []
  private var repeatTimer: Timer?
  private var repeatAction: (() -> Void)?
  /// Invoked when modal mode starts or ends (the menu bar icon reflects it).
  var onModalChange: ((KeyCombo?) -> Void)?

  func apply(_ entries: [Entry], disabled: [String] = [], settings: SlateSettings) {
    unregisterAll()
    self.settings = settings
    var seen = Set<String>()
    var direct: [Entry] = []
    statuses = Dictionary(disabled.map { ($0, HotkeyStatus.disabled) }, uniquingKeysWith: { a, _ in a })
    for entry in entries {
      guard seen.insert(entry.id).inserted else {
        statuses[entry.id] = .duplicate
        continue
      }
      if let modal = entry.modal {
        modalEntries[modal.keys, default: []].append(entry)
      } else {
        direct.append(entry)
      }
    }
    for entry in direct {
      register(entry.keys, id: entry.id) { [weak self] phase in self?.handle(entry, phase: phase) }
    }
    for modalKeys in modalEntries.keys {
      register(modalKeys, id: nil) { [weak self] phase in
        guard phase == .pressed else { return }
        self?.toggleModal(modalKeys)
      }
      for entry in modalEntries[modalKeys] ?? [] where statuses[entry.id] == nil {
        statuses[entry.id] = .active
      }
    }
  }

  func unregisterAll() {
    exitModal()
    for token in tokens { HotKeyCenter.shared.unregister(token) }
    tokens.removeAll()
    modalEntries.removeAll()
    stopRepeating()
  }

  private func register(_ keys: KeyCombo, id: String?, handler: @escaping HotKeyCenter.Handler) {
    do {
      tokens.append(try HotKeyCenter.shared.register(keys, handler: handler))
      if let id { statuses[id] = .active }
    } catch {
      if let id { statuses[id] = .failed(error.description) }
      log.error("Hotkey \(keys.string, privacy: .public): \(error.description, privacy: .public)")
    }
  }

  private func handle(_ entry: Entry, phase: HotKeyCenter.Phase) {
    switch phase {
    case .pressed:
      entry.run()
      if entry.repeats { startRepeating(entry.run) }
    case .released:
      stopRepeating()
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
      if let token = try? HotKeyCenter.shared.register(entry.keys, handler: { [weak self] phase in
        guard phase == .pressed else { return }
        entry.run()
        if entry.modal?.toggle != true { self?.exitModal() }
      }) {
        modalTokens.append(token)
      }
    }
    let escapeKey = KeyCombo(string: settings.string("modalEscapeKey", default: "esc")) ?? KeyCombo(key: "esc")
    if let token = try? HotKeyCenter.shared.register(escapeKey, handler: { [weak self] phase in
      if phase == .pressed { self?.exitModal() }
    }) {
      modalTokens.append(token)
    }
    onModalChange?(modalKeys)
  }

  private func exitModal() {
    guard activeModal != nil else { return }
    for token in modalTokens { HotKeyCenter.shared.unregister(token) }
    modalTokens.removeAll()
    activeModal = nil
    onModalChange?(nil)
  }
}
