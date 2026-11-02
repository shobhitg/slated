import Foundation
import SlatedCore

/// Key repeat (Settings → Keyboard) and the menu bar icon's notice.
extension AppModel {
  /// Used when the switch goes on and this Mac's setting can't be read: GNOME's default.
  static let fallbackKeyRepeat = KeyRepeat(delay: 500, interval: 30)

  /// "Set key repeat with Slated". On, it starts from this Mac's current setting, so nothing changes
  /// until a slider moves; off removes `keyboard.keyRepeat` and leaves the Mac's setting as it is.
  var keyRepeatEnabled: Bool {
    get { configuration.keyboard.keyRepeat != nil }
    set {
      guard newValue != keyRepeatEnabled else { return }
      configuration.keyboard.keyRepeat =
        newValue ? (services.currentSystemKeyRepeat() ?? Self.fallbackKeyRepeat) : nil
    }
  }

  /// "Use this Mac's current setting".
  func useCurrentKeyRepeat() {
    guard let current = services.currentSystemKeyRepeat() else {
      showToast("Couldn't read this Mac's key repeat setting.", symbol: "exclamationmark.triangle", style: .failure)
      return
    }
    configuration.keyboard.keyRepeat = current
    showToast("Using this Mac's key repeat: \(current.delay) ms, then every \(current.interval) ms.")
  }

  /// What the Key Repeat card's status line says.
  enum KeyRepeatStatus: Equatable {
    case off
    /// The change is waiting to be saved.
    case saving
    case applied
    case afterLogout
    case failed(String)
  }

  var keyRepeatStatus: KeyRepeatStatus {
    guard let wanted = configuration.keyboard.keyRepeat else { return .off }
    if wanted != saved.keyboard.keyRepeat { return .saving }
    switch runtimeStatus.keyRepeat {
    case .applied: return .applied
    case .afterLogout: return .afterLogout
    case .failed(let message): return .failed(message)
    case nil: return .saving
    }
  }

  /// Overview's notice that macOS uses the new key repeat only after logging out and in, until the
  /// "Got It" button (for this run) or the next login.
  var showsKeyRepeatLogoutNotice: Bool {
    keyRepeatStatus == .afterLogout && keyRepeatNoticeDismissedFor != configuration.keyboard.keyRepeat
  }

  func dismissKeyRepeatLogoutNotice() {
    keyRepeatNoticeDismissedFor = configuration.keyboard.keyRepeat
  }

  /// The notice about Slated's icon behind the camera notch (Overview and General).
  var showsMenuBarNotice: Bool {
    runtimeStatus.menuBarIcon == .behindNotch && !runtimeStatus.menuBarNoticeDismissed
  }

  func dismissMenuBarNotice() {
    services.dismissMenuBarNotice()
    refresh()
  }
}

extension KeyRepeat {
  /// "200 ms".
  var delayLabel: String { "\(delay) ms" }

  /// "60 per second (17 ms)": the rate the Mac really applies, in whole 1/60 s ticks.
  var rateLabel: String {
    let perSecond = Int((1000 / macEffectiveInterval).rounded())
    return "\(perSecond) per second (\(interval) ms)"
  }
}
