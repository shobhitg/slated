// Renders Slated's UI with sample data (`PreviewServices`) to PNGs, in light and dark appearance:
// every pane of the main window plus empty, first-run and error states, every Get Started step, the
// clipboard switcher, the notch island and a component gallery. Also writes contact sheets of each run.
//
//   swift run SlatedUISnapshots <output-dir> [name-filter] [--scale 1|2]
//   swift run SlatedUISnapshots --probe [output-dir]     # what can cacheDisplay capture here?
//
// Views are hosted in offscreen windows and captured with `cacheDisplay` (see `Renderer` for the
// setup that makes that faithful on macOS 26). The run fails if any snapshot comes out blank.
// SNAPSHOT_HEIGHT=1600 renders settings shots taller, to review content below the fold.

import AppKit
import SlatedCore
@_spi(Snapshots) import SlatedUI
import SwiftUI

struct Shot {
  var name: String
  /// Height 0 means "as tall as the content wants at this width".
  var size: CGSize
  var make: @MainActor () -> AnyView
}

// MARK: - Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
var scale: CGFloat = 2
if let index = arguments.firstIndex(of: "--scale"), index + 1 < arguments.count {
  scale = CGFloat(Double(arguments[index + 1]) ?? 2)
  arguments.removeSubrange(index...(index + 1))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

if let index = arguments.firstIndex(of: "--probe") {
  arguments.remove(at: index)
  let url = arguments.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
  if let url { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
  try Probe.run(outputURL: url)
  exit(0)
}

guard let outputPath = arguments.first else {
  FileHandle.standardError.write(
    Data(
      "usage: SlatedUISnapshots <output-dir> [name-filter] [--scale 1|2]\n       SlatedUISnapshots --probe [output-dir]\n"
        .utf8))
  exit(2)
}
let filter = arguments.dropFirst().first
let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

// MARK: - Shots

func settings(
  _ name: String, scenario: PreviewServices.Scenario = .configured, pane: SettingsPane,
  configure: @escaping @MainActor (AppModel) -> Void = { _ in },
  services prepare: @escaping @MainActor (PreviewServices) -> Void = { _ in }
) -> Shot {
  Shot(name: name, size: SlatedUI.mainWindowSize) {
    let services = PreviewServices(scenario: scenario)
    prepare(services)
    let model = AppModel(services: services)
    model.selectedPane = pane
    configure(model)
    return AnyView(SlatedUI.makeMainView(model: model))
  }
}

/// Automations running, as the engine would report them.
@MainActor func running(_ services: PreviewServices) {
  services.automations = PreviewServices.sampleAutomations()
}

func selectBinding(named name: String) -> @MainActor (AppModel) -> Void {
  { model in
    if let binding = model.configuration.bindings.first(where: { $0.name == name }) {
      model.selectedBinding = .slated(binding.id)
    }
  }
}

/// Selects the first Slate binding whose summary ("throw 1 resize") or title ("Middle Third") is `text`.
func selectSourceBinding(_ text: String) -> @MainActor (AppModel) -> Void {
  { model in
    for source in model.sources {
      if let binding = source.bindings.first(where: { $0.summary == text || $0.title == text }) {
        model.selectedBinding = .source(path: source.path, id: binding.id)
        return
      }
    }
  }
}

var shots: [Shot] = [
  settings("settings-overview", pane: .overview),
  settings("settings-windows", pane: .windows, configure: selectBinding(named: "Left Half")),
  settings("settings-windows-chain", pane: .windows, configure: selectBinding(named: "Cycle Left")),
  settings("settings-windows-failed", pane: .windows, configure: selectBinding(named: "Window Hints")),
  settings("settings-windows-duplicate", pane: .windows, configure: selectBinding(named: "Almost Maximize")),
  settings("settings-windows-source", pane: .windows, configure: selectSourceBinding("throw 1 resize")),
  // A function Slated could describe by trying it, and one it couldn't.
  settings("settings-windows-function", pane: .windows, configure: selectSourceBinding("Middle Third")),
  settings("settings-windows-javascript", pane: .windows, configure: selectSourceBinding("JavaScript Function")),
  settings("settings-windows-new", pane: .windows) { model in model.newBinding() },
  settings("settings-hotstrings", pane: .hotstrings) { model in
    model.selectedHotstringID = model.configuration.hotstrings.first { $0.trigger == ";sig" }?.id
  },
  settings("settings-clipboard", pane: .clipboard),
  settings(
    "settings-clipboard-off", pane: .clipboard,
    services: { services in
      var config = services.configuration
      config.clipboard.enabled = false
      config.clipboard.shortcut = nil
      try? services.saveConfiguration(config)
    }),
  settings("settings-automation", pane: .automation),
  settings("settings-automation-running", pane: .automation, services: running),
  settings("settings-windows-autoclick", pane: .windows, configure: selectBinding(named: "Auto-Click Left")),
  settings("settings-windows-hold", pane: .windows, configure: selectBinding(named: "Hold W (Auto-Run)")),
  settings("settings-windows-macro", pane: .windows) { model in
    model.addRecipe(id: "macro", keys: KeyCombo(string: "hyper+7"))
    model.selectedPane = .windows
  },
  settings("settings-overview-running", pane: .overview, services: running),
  settings("settings-keyboard", pane: .keyboard),
  settings("settings-layouts", pane: .layouts) { model in model.selectedLayout = .slated(name: "Coding") },
  settings("settings-layouts-source", pane: .layouts) { model in
    if let source = model.sources.first { model.selectedLayout = .source(path: source.path, name: "Meeting") }
  },
  settings("settings-slate", pane: .slate),
  settings("settings-general", pane: .general),
  settings("settings-about", pane: .about),
  // Empty, first-run and error states.
  settings("state-firstrun-overview", scenario: .firstRun, pane: .overview),
  settings("state-empty-windows", scenario: .empty, pane: .windows),
  settings("state-empty-hotstrings", scenario: .empty, pane: .hotstrings),
  settings("state-empty-layouts", scenario: .empty, pane: .layouts),
  settings("state-empty-slate", scenario: .empty, pane: .slate),
  settings("state-empty-clipboard", scenario: .empty, pane: .clipboard),
  settings("state-empty-automation", scenario: .empty, pane: .automation),
  settings("state-broken-config", scenario: .brokenConfig, pane: .overview),
]

// Get Started, on a first run: each step, in the main window.
for step in GetStartedStep.allCases {
  shots.append(
    settings("getstarted-\(step.rawValue + 1)-\(step)", scenario: .firstRun, pane: .getStarted) { model in
      model.getStartedStep = step
    })
}

func switcher(
  _ name: String, scenario: PreviewServices.Scenario = .configured,
  configure: @escaping @MainActor (ClipboardSwitcherModel) -> Void = { _ in }
) -> Shot {
  Shot(name: name, size: CGSize(width: 780, height: 480)) {
    let model = ClipboardSwitcherModel(services: PreviewServices(scenario: scenario))
    model.resetForShowing()
    configure(model)
    return AnyView(SlatedUI.makeClipboardSwitcherView(model: model))
  }
}

shots += [
  switcher("clipboard-switcher"),
  switcher("clipboard-switcher-code") { model in model.selectedID = model.items.first { $0.text.hasPrefix("func") }?.id
  },
  switcher("clipboard-switcher-color") { model in model.selectedID = model.items.first { $0.text.hasPrefix("#") }?.id },
  switcher("clipboard-switcher-search") { model in model.query = "git" },
  switcher("clipboard-switcher-nomatch") { model in model.query = "invoice" },
  switcher("clipboard-switcher-empty", scenario: .empty),
]

for recipe in ["auto-click-left", "toggle-sprint"] {
  shots.append(
    Shot(name: "automation-recipe-\(recipe)", size: CGSize(width: 470, height: 0)) {
      AnyView(SlatedUI.makeRecipeSheet(model: AppModel(services: PreviewServices()), recipeID: recipe))
    })
}

shots += islandShots()

shots.append(Shot(name: "components", size: CGSize(width: 900, height: 0)) { AnyView(ComponentGallery()) })

// MARK: - Run

let tallHeight = ProcessInfo.processInfo.environment["SNAPSHOT_HEIGHT"].flatMap(Double.init)
var rendered: [Bool: [(name: String, image: NSBitmapImageRep)]] = [false: [], true: []]
var blank: [String] = []
for shot in shots where filter.map({ shot.name.contains($0) }) ?? true {
  var size = shot.size
  if size == SlatedUI.mainWindowSize, let tallHeight { size.height = tallHeight }
  for dark in [false, true] {
    let name = "\(shot.name)-\(dark ? "dark" : "light")"
    let image = Renderer.render(shot.make(), size: size, dark: dark, options: Renderer.Options(scale: scale))
    let url = outputURL.appendingPathComponent("\(name).png")
    try Renderer.writePNG(image, to: url)
    rendered[dark]!.append((name, image))
    if Renderer.contentFraction(image) < 0.02 {
      blank.append(name)
      print("✘ \(url.path) looks blank")
    } else {
      print(url.path)
    }
  }
}

for dark in [false, true] {
  let url = outputURL.appendingPathComponent("contact-sheet-\(dark ? "dark" : "light").png")
  try ContactSheet.write(rendered[dark]!, columns: 4, cellWidth: 540, to: url)
}

let count = rendered.values.reduce(0) { $0 + $1.count }
print("Rendered \(count) snapshots and 2 contact sheets into \(outputURL.path)")
if !blank.isEmpty {
  print("\(blank.count) snapshot(s) came out blank. Run with --probe to see what this macOS can capture.")
  exit(1)
}
