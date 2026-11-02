import AppKit
import Foundation
import SwiftUI

@testable import SlatedCore
@testable import SlatedUI

// The main window at the widths it gets snapped to (half of a 1280-pt screen is 640 pt, half of the
// author's 1512-pt MacBook screen 756): every pane fits, and nothing is centered and cut on both
// sides. Drawn in offscreen windows. Overflow shows in the AppKit views SwiftUI builds: a pane wider
// than its room widens its scroll view past the window's edge or over its neighbor.

private func onMain(_ body: @MainActor () throws -> Void) throws {
  try MainActor.assumeIsolated(body)
}

@MainActor private func spin(_ seconds: Double = 0.3) {
  RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

/// The main window's content at `size`, in a borderless offscreen window, the way `make snapshots`
/// draws it. Close the window when done.
@MainActor private func host(_ model: AppModel, size: CGSize) -> (NSWindow, NSView) {
  _ = NSApplication.shared
  let host = NSHostingView(rootView: SlatedUI.makeMainView(model: model))
  host.sizingOptions = []
  host.frame = CGRect(origin: .zero, size: size)
  let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
  window.contentView = host
  window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
  window.orderFrontRegardless()
  spin()
  return (window, host)
}

@MainActor private func allViews(in root: NSView) -> [NSView] {
  [root] + root.subviews.flatMap { allViews(in: $0) }
}

/// Where content is wider than its room: a scroll view (every pane, list and editor scrolls) that
/// reaches past the window's edges, past the scroll view it's in, or over a scroll view beside it.
@MainActor private func overflows(in host: NSView) -> [String] {
  let scrolls = allViews(in: host).compactMap { $0 as? NSScrollView }.filter { !$0.isHidden }
  func frame(_ view: NSView) -> CGRect { view.convert(view.bounds, to: nil) }
  func name(_ scroll: NSScrollView) -> String {
    "\(type(of: scroll)) (\(scroll.documentView.map { "\(type(of: $0))" } ?? "empty")) at \(Int(frame(scroll).minX))…\(Int(frame(scroll).maxX))"
  }
  var problems: [String] = []
  for scroll in scrolls {
    let rect = frame(scroll)
    let enclosing = sequence(first: scroll.superview, next: { $0?.superview }).lazy.compactMap { $0 as? NSScrollView }
      .first
    let room = enclosing.map { frame($0) } ?? host.bounds
    if rect.minX < room.minX - 1 || rect.maxX > room.maxX + 1 {
      problems.append("\(name(scroll)) is outside \(Int(room.minX))…\(Int(room.maxX))")
    }
  }
  for (index, first) in scrolls.enumerated() {
    for second in scrolls[(index + 1)...] where !first.isDescendant(of: second) && !second.isDescendant(of: first) {
      let overlap = frame(first).intersection(frame(second))
      if overlap.width > 1 && overlap.height > 1 {
        problems.append("\(name(first)) overlaps \(name(second))")
      }
    }
  }
  return problems
}

/// A pane, and what's selected in it.
@MainActor private struct Variant {
  var name: String
  var scenario: PreviewServices.Scenario = .configured
  var pane: SettingsPane
  var configure: (AppModel) -> Void = { _ in }
}

@MainActor private func selectBinding(_ name: String) -> (AppModel) -> Void {
  { model in model.selectedBinding = model.configuration.bindings.first { $0.name == name }.map { .slated($0.id) } }
}

/// Every pane, list + detail panes both with nothing selected and with an editor open.
@MainActor private var variants: [Variant] {
  SettingsPane.allCases.filter { $0 != .getStarted }.map { Variant(name: $0.rawValue, pane: $0) } + [
    Variant(name: "windows editor", pane: .windows, configure: selectBinding("Left Half")),
    Variant(name: "windows automation editor", pane: .windows, configure: selectBinding("Auto-Click Left")),
    Variant(name: "windows chain editor", pane: .windows, configure: selectBinding("Cycle Left")),
    Variant(name: "windows new", pane: .windows) { $0.newBinding() },
    Variant(name: "hotstrings editor", pane: .hotstrings) { model in
      model.selectedHotstringID = model.configuration.hotstrings.first?.id
    },
    Variant(name: "layouts editor", pane: .layouts) { $0.selectedLayout = .slated(name: "Coding") },
    Variant(name: "automation running", pane: .automation) { _ in },
    Variant(name: "first-run overview", scenario: .firstRun, pane: .overview),
  ]
    + GetStartedStep.allCases.map { step in
      Variant(name: "get started \(step)", scenario: .firstRun, pane: .getStarted) { $0.getStartedStep = step }
    }
}

let uiAdaptiveLayoutTests = Suite(
  "UIAdaptiveLayout",
  [
    (
      "the breakpoints: icon sidebar under 900 pt, list and editor side by side only with 460 pt for the editor",
      {
        try onMain {
          expect(MainWindowLayout.showsRail(windowWidth: 640))
          expect(MainWindowLayout.showsRail(windowWidth: 899))
          expect(!MainWindowLayout.showsRail(windowWidth: 900))
          expectEqual(MainWindowLayout.paneWidth(windowWidth: 640), 579.5)
          expectEqual(MainWindowLayout.paneWidth(windowWidth: 1080), 855.5)
          // Below the minimum the content keeps the minimum's layout (and scrolls).
          expectEqual(MainWindowLayout.paneWidth(windowWidth: 500), 579.5)
          expect(MainWindowLayout.splitsListAndDetail(paneWidth: 855.5, listWidth: 330))
          expect(!MainWindowLayout.splitsListAndDetail(paneWidth: 675.5, listWidth: 330))
          expect(!MainWindowLayout.splitsListAndDetail(paneWidth: 790, listWidth: 330))
          expect(MainWindowLayout.splitsListAndDetail(paneWidth: 790.5, listWidth: 330))
        }
      }
    ),
    (
      "the main window can be dragged down to 640 × 480, and starts at 1080 × 720",
      {
        try onMain {
          _ = NSApplication.shared
          let window = SlatedUI.makeMainWindow(model: AppModel(services: PreviewServices()))
          defer { window.close() }
          expectEqual(window.contentMinSize, CGSize(width: 640, height: 480))
          expectEqual(window.contentRect(forFrameRect: window.frame).size, SlatedUI.mainWindowSize)
        }
      }
    ),
    (
      "every pane fits at 640 pt (half of a 1280-pt screen), 851 pt (the narrowest editor beside a list) and 1080",
      {
        try onMain {
          // 851 pt leaves Windows' editor exactly MainWindowLayout.minimumDetailWidth beside its list.
          for width in [640.0, 851, 1080] {
            for variant in variants {
              let services = PreviewServices(scenario: variant.scenario)
              if variant.name == "automation running" { services.automations = PreviewServices.sampleAutomations() }
              let model = AppModel(services: services)
              model.selectedPane = variant.pane
              variant.configure(model)
              let (window, view) = host(model, size: CGSize(width: width, height: 720))
              let problems = overflows(in: view)
              expect(problems.isEmpty, "\(variant.name) at \(Int(width)) pt: \(problems.joined(separator: "; "))")
              window.close()
            }
          }
        }
      }
    ),
    (
      "a window narrower than 640 pt (macOS tiling, Accessibility) keeps the layout anchored left and scrolls",
      {
        try onMain {
          let model = AppModel(services: PreviewServices())
          model.selectedPane = .hotstrings
          let (window, view) = host(model, size: CGSize(width: 480, height: 400))
          defer { window.close() }
          let views = allViews(in: view)
          let sidebar = try require(views.compactMap { $0 as? NSTableView }.first, "no sidebar")
          expectEqual(sidebar.convert(sidebar.bounds, to: nil).minX, 0)
          let outer = views.compactMap { $0 as? NSScrollView }.first { $0.frame.size == view.bounds.size }
          let scroller = try require(outer, "no scroll view around the whole window")
          let document = try require(scroller.documentView)
          expect(document.frame.width >= 640 && document.frame.height >= 480, "content \(document.frame.size)")
        }
      }
    ),
  ])
