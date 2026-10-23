import AppKit
import SlatedUI
import SwiftUI

/// `--probe`: checks which kinds of SwiftUI content `cacheDisplay` can capture on this macOS.
///
/// These are the experiments behind `Renderer`'s setup, kept runnable so a new macOS release that
/// changes capture behavior shows up as a changed table rather than as mysteriously blank PNGs.
/// Each case renders distinctive content and reports whether it came out (non-background pixels
/// in the region that should show it).
enum Probe {
  private struct Case {
    var name: String
    var expectation: String
    var options: Renderer.Options
    /// Region that must show content, in points; nil means the whole image.
    var region: CGRect?
    /// Defaults to `Probe.size`.
    var size: CGSize?
    var view: AnyView
  }

  private static let size = CGSize(width: 520, height: 260)

  private static func content(_ label: String) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(label).font(.system(size: 26, weight: .bold))
      RoundedRectangle(cornerRadius: 10).fill(.orange).frame(height: 36)
      Toggle("A switch", isOn: .constant(true)).toggleStyle(.switch)
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private static func list(_ style: Int) -> some View {
    List {
      ForEach(0..<6) { index in
        Label("Row \(index)", systemImage: "star.fill")
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(.orange)
      }
    }
    .modifier(ListStyleModifier(sidebar: style == 1))
  }

  private struct ListStyleModifier: ViewModifier {
    let sidebar: Bool
    func body(content: Content) -> some View {
      if sidebar { content.listStyle(.sidebar) } else { content.listStyle(.inset) }
    }
  }

  private static var cases: [Case] {
    let sized = Renderer.Options(scale: 1, styleMask: [.borderless], hostSizing: [])
    let selfSizing = Renderer.Options(
      scale: 1, styleMask: [.borderless], hostSizing: [.minSize, .intrinsicContentSize])
    let titled = Renderer.Options(scale: 1, styleMask: [.titled, .fullSizeContentView], hostSizing: [])
    return [
      Case(name: "Plain stack", expectation: "captures", options: sized, view: AnyView(content("Plain stack"))),
      Case(
        name: "ScrollView", expectation: "captures", options: sized,
        view: AnyView(ScrollView { content("Scroll view") })),
      Case(
        name: "ScrollView, host sizing its window", expectation: "captures in a borderless window", options: selfSizing,
        view: AnyView(ScrollView { content("Self-sizing") })),
      Case(
        name: "ScrollView under a transparent title bar", expectation: "blank on macOS 26 (scroll edge effect)",
        options: titled, view: AnyView(ScrollView { content("Under title bar") })),
      Case(
        name: "List under a transparent title bar", expectation: "blank on macOS 26 (scroll edge effect)",
        options: titled, view: AnyView(list(0))),
      Case(
        name: "Inset List nested in a stack", expectation: "captures", options: sized,
        view: AnyView(
          HStack(spacing: 0) {
            list(0).frame(width: 260); content("Detail")
          })),
      Case(name: "Sidebar List", expectation: "captures", options: sized, view: AnyView(list(1))),
      Case(
        // Measured inside the floating glass panel, clear of its edge shadow.
        name: "NavigationSplitView sidebar (glass)", expectation: "blank on macOS 26", options: sized,
        region: CGRect(x: 40, y: 50, width: 150, height: 160),
        view: AnyView(
          NavigationSplitView {
            list(1).navigationSplitViewColumnWidth(220)
          } detail: {
            content("Detail")
          })),
      Case(
        // Smoke test of the real settings window layout (snapshots use the flat one): the detail
        // column must render even though the glass sidebar can't be captured.
        name: "Settings window, real split view (detail)", expectation: "captures", options: sized,
        region: CGRect(x: 420, y: 40, width: 500, height: 400), size: SlatedUI.settingsWindowSize,
        view: AnyView(SlatedUI.makeSettingsView(model: AppModel(services: PreviewServices())))),
    ]
  }

  /// Prints one line per case: whether the content came out, and what was expected.
  static func run(outputURL: URL?) throws {
    print("cacheDisplay capture probe — macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n")
    for probe in cases {
      let image = Renderer.render(probe.view, size: probe.size ?? size, dark: false, options: probe.options)
      let fraction = Renderer.contentFraction(image, in: probe.region)
      let captured = fraction > 0.02
      let mark = captured ? "✔ captures" : "✘ blank   "
      print(
        "\(mark)  \(probe.name)  (expected: \(probe.expectation); content \(String(format: "%.1f", fraction * 100))%)")
      if let outputURL {
        let file = probe.name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }.replacingOccurrences(
          of: " ", with: "-")
        try Renderer.writePNG(image, to: outputURL.appendingPathComponent("probe-\(file).png"))
      }
    }
  }
}
