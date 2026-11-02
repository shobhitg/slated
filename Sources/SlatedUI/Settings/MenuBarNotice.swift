import Foundation
import SwiftUI

/// Said in Overview and General when macOS put Slated's menu bar icon behind the camera notch (the
/// menu bar is full), until dismissed or the icon shows again.
struct MenuBarNoticeCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Notice(
      style: .warning, title: "Slated's menu bar icon is hidden behind the camera", message: MenuBarText.message,
      symbol: "menubar.rectangle"
    ) {
      Button("Got It") { model.dismissMenuBarNotice() }
        .buttonStyle(.soft)
        .controlSize(.small)
        .padding(.top, 4)
    }
  }
}

/// Overview's notice after a key repeat change macOS applies only at the next login.
struct KeyRepeatLogoutNoticeCard: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    Notice(
      style: .info, title: KeyRepeatText.logoutTitle, message: KeyRepeatText.logoutMessage,
      symbol: "person.crop.circle.badge.clock"
    ) {
      HStack(spacing: 8) {
        Button("Key Repeat Settings") { model.selectedPane = .keyboard }
        Button("Got It") { model.dismissKeyRepeatLogoutNotice() }
      }
      .buttonStyle(.soft)
      .controlSize(.small)
      .padding(.top, 4)
    }
  }
}

enum MenuBarText {
  /// macOS 26 has a Menu Bar pane in System Settings with a switch for each app's icon ("Allow in the
  /// Menu Bar"); earlier versions have none for other apps' icons.
  static var hasMenuBarPane: Bool {
    ProcessInfo.processInfo.isOperatingSystemAtLeast(
      OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
  }

  static var message: String {
    let makeRoom =
      hasMenuBarPane
      ? "To make room, turn off icons you don't need in System Settings → Menu Bar, under Allow in the Menu Bar, "
        + "or hold ⌘ and drag them out of the menu bar."
      : "To make room, quit apps you don't need in the menu bar, or hold ⌘ and drag their icons out of it."
    return "Your menu bar is full, so macOS put Slated's icon behind the notch. Slated keeps working, and its "
      + "Dock icon opens this window. " + makeRoom
  }
}
