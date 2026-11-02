import SwiftUI

/// Version, author, source code and license.
struct AboutPane: View {
  var body: some View {
    PaneScroll(maxWidth: 620) {
      VStack(spacing: 14) {
        SlatedMark(size: 96, glow: true)
          .padding(.top, 18)
          .padding(.bottom, 6)
        Text("Slated")
          .font(.system(size: 30, weight: .bold))
          .tracking(-0.6)
        Text(AppInfoText.version)
          .font(.system(size: 12, design: .monospaced))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .background(Theme.well, in: Capsule())
        Text(
          "Keyboard-first window management, a Hyper key, text expansion, clipboard history and game automation, for macOS and GNOME."
        )
          .font(.system(size: 13.5))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 400)
      }
      .frame(maxWidth: .infinity)
      SettingsCard {
        // config key: none, about the app rather than a setting
        SettingRow(
          title: "Made by Shobhit Gupta",
          subtitle: "Author and maintainer.",
          symbol: "person.crop.circle.fill", tint: Color(hex: 0x6E56F7)
        ) {
          Link(destination: AppInfoText.authorURL) {
            Label("github.com/shobhitg", systemImage: "arrow.up.right")
          }
          .font(.system(size: 12))
        }
        CardDivider(inset: 54)
        // config key: none, about the app rather than a setting
        SettingRow(
          title: "Source code",
          subtitle: "Read the code, report a problem or suggest an idea.",
          symbol: "chevron.left.forwardslash.chevron.right", tint: Color(hex: 0x3B82F6)
        ) {
          Link(destination: AppInfoText.repositoryURL) {
            Label("Slated on GitHub", systemImage: "arrow.up.right")
          }
          .font(.system(size: 12))
        }
        CardDivider(inset: 54)
        // config key: none, credits rather than a setting
        SettingRow(
          title: "MIT License",
          subtitle: "Slated is free and open source. Use it, change it and share it.",
          symbol: "checkmark.seal.fill", tint: Color(hex: 0x30B85A)
        ) { EmptyView() }
      }
      if let copyright = AppInfoText.copyright {
        Text(copyright)
          .font(.system(size: 11))
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity)
      }
    }
  }
}

enum AppInfoText {
  static let repositoryURL = URL(string: "https://github.com/shobhitg/slated")!
  static let authorURL = URL(string: "https://github.com/shobhitg")!

  /// "Version 0.1.0 (12)", or a development marker when running outside the app bundle.
  static var version: String {
    let info = Bundle.main.infoDictionary ?? [:]
    guard let short = info["CFBundleShortVersionString"] as? String else { return "Development build" }
    let build = info["CFBundleVersion"] as? String
    return "Version \(short)" + (build.map { " (\($0))" } ?? "")
  }

  /// From the app bundle's Info.plist; nil when running outside the bundle.
  static var copyright: String? {
    Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String
  }
}
