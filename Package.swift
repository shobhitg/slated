// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Slated",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "Slated", targets: ["Slated"])
  ],
  targets: [
    // Pure Swift (Foundation only): model, expressions, Slate syntax, frame math, hotstring matching.
    .target(name: "SlatedCore"),
    // macOS boundary: Accessibility, screens, hotkeys, event tap, Hyper key, text injection.
    .target(name: "SlatedSystem", dependencies: ["SlatedCore"]),
    // Slate's JavaScript config API (~/.slate.js) on JavaScriptCore.
    .target(name: "SlatedScript", dependencies: ["SlatedCore"]),
    // SwiftUI settings, onboarding and menu bar UI.
    .target(
      name: "SlatedUI",
      dependencies: ["SlatedCore"],
      swiftSettings: [.defaultIsolation(MainActor.self)]
    ),
    // The menu-bar app: wires config → triggers → actions.
    .executableTarget(
      name: "Slated",
      dependencies: ["SlatedCore", "SlatedSystem", "SlatedScript", "SlatedUI"],
      swiftSettings: [.defaultIsolation(MainActor.self)]
    ),
    // Renders every settings pane, onboarding step and the menu bar view to PNGs (light and dark)
    // with sample data: `swift run SlatedUISnapshots <output-dir>`.
    .executableTarget(
      name: "SlatedUISnapshots",
      dependencies: ["SlatedUI", "SlatedCore"],
      swiftSettings: [.defaultIsolation(MainActor.self)]
    ),
    // Tests run as an executable (`make test`): Swift Testing and XCTest need Xcode, and this
    // machine only has the Command Line Tools. The harness mirrors Swift Testing's #expect/#require.
    .executableTarget(
      name: "SlatedTests",
      dependencies: ["SlatedCore", "SlatedScript", "SlatedUI"],
      path: "Tests/SlatedTests"
    ),
  ]
)
