import SwiftUI

/// Version, license and credits.
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
        Text("Keyboard-first window management, a Hyper key and text expansion — in one small menu bar app.")
          .font(.system(size: 13.5))
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 400)
      }
      .frame(maxWidth: .infinity)
      SettingsCard {
        SettingRow(
          title: "Inspired by Slate by Jigish Patel",
          subtitle:
            "Slate pioneered configurable, keyboard-driven window management on the Mac. Slated is an independent reimplementation and contains none of Slate's code.",
          symbol: "heart.fill", tint: Color(hex: 0xE5484D)
        ) {
          Link(destination: URL(string: "https://github.com/jigish/slate")!) {
            Label("Slate on GitHub", systemImage: "arrow.up.right")
          }
          .font(.system(size: 12))
        }
        CardDivider(inset: 54)
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
