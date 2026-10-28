import CoreGraphics
import Foundation

@testable import SlatedCore

// PopupPlacement: where the clipboard picker opens (below the caret, above it near the bottom of the
// screen) and where its image preview goes (beside the picker). GNOME's picker uses the JavaScript
// port, so both platforms place it the same way. Edge cases (rects touching a screen's edge, empty
// and negative sizes, NaN) pin CoreGraphics' rectangle semantics for the port.

private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
  CGRect(x: x, y: y, width: width, height: height)
}

private func sizeJ(_ size: CGSize) -> J {
  ["width": .number(Double(size.width)), "height": .number(Double(size.height))]
}

/// Visible frames (work areas): a laptop under a menu bar, an external display to its right, a
/// portrait display to its left, a GNOME screen under a 32 px top bar, and one smaller than a panel.
private let visibleFrames: [(String, CGRect)] = [
  ("laptop", rect(0, 25, 1440, 815)), ("external", rect(1440, 25, 2560, 1415)),
  ("portrait", rect(-1080, 25, 1080, 1895)), ("gnome", rect(0, 32, 1920, 1048)), ("tiny", rect(0, 0, 300, 200)),
]

/// Carets, fields and the pointer (an empty rect), in the middle, near every edge, outside the
/// screen, fractional, and with a negative size.
private let anchors: [CGRect] = [
  rect(700, 400, 2, 18), rect(700, 800, 2, 18), rect(700, 830, 2, 18), rect(1400, 400, 2, 18),
  rect(-50, 400, 2, 18), rect(700, 0, 2, 18), rect(100, 100, 0, 0), rect(100, 100, 600, 300),
  rect(700.5, 400.25, 1.5, 17.75), rect(5000, 5000, 0, 0), rect(700, 400, -2, -18), rect(2000, 1300, 2, 20),
  rect(-500, 1800, 2, 18), rect(150, 120, 2, 18), rect(10, 380, 300, 40),
]

/// The picker with a few rows and with nine, one taller than any screen, one wider, and nothing.
private let pickerSizes: [CGSize] = [
  CGSize(width: 320, height: 68.5), CGSize(width: 320, height: 287.5), CGSize(width: 320, height: 2000),
  CGSize(width: 3000, height: 100), CGSize(width: 0, height: 0),
]

private let pickers: [CGRect] = [
  rect(100, 100, 320, 300), rect(1100, 100, 320, 300), rect(10, 100, 320, 300), rect(1300, 600, 320, 300),
  rect(-1000, 1500, 320, 300),
]

private let previewSizes: [CGSize] = [
  CGSize(width: 256, height: 155), CGSize(width: 136, height: 50), CGSize(width: 256, height: 2000),
  CGSize(width: 3000, height: 100),
]

/// Rects to clamp and bounds to clamp them in.
private let clampCases: [(CGRect, CGRect)] = [
  (rect(10, 10, 100, 100), rect(0, 0, 500, 500)), (rect(-10, -10, 100, 100), rect(0, 0, 500, 500)),
  (rect(450, 450, 100, 100), rect(0, 0, 500, 500)), (rect(450, -50, 100, 100), rect(0, 0, 500, 500)),
  (rect(0, 0, 600, 600), rect(0, 0, 500, 500)), (rect(100, 100, 600, 50), rect(0, 0, 500, 500)),
  (rect(1500, 30, 320, 200), rect(1440, 25, 2560, 1415)), (rect(-2000, 0, 320, 200), rect(-1080, 25, 1080, 1895)),
  (rect(10, 10, -50, -50), rect(0, 0, 500, 500)), (rect(480, 480, -50, -50), rect(0, 0, 500, 500)),
  (rect(10.25, 499.75, 0.5, 0.5), rect(0, 0, 500, 500)), (rect(5, 5, 10, 10), rect(0, 0, 0, 0)),
  (rect(5, 5, 10, 10), rect(100, 100, -50, -50)), (rect(1e6, -1e6, 1, 1), rect(-3, -3, 7, 7)),
]

/// Screen setups for `screen(for:)`: side by side, with a gap, stacked, sharing corners, none.
private let screenSets: [(String, [CGRect])] = [
  ("sideBySide", [rect(0, 0, 1440, 900), rect(1440, 0, 2560, 1440)]),
  ("gap", [rect(0, 0, 1000, 800), rect(1200, 0, 1000, 800)]),
  ("stacked", [rect(0, 0, 1920, 1080), rect(0, -1440, 2560, 1440)]),
  ("corners", [rect(0, 0, 1000, 1000), rect(1000, 1000, 1000, 1000), rect(-1000, -1000, 1000, 1000)]),
  ("one", [rect(0, 0, 1440, 900)]),
  ("none", []),
]

private let screenProbes: [CGRect] = [
  rect(700, 400, 2, 18), rect(1440, 400, 0, 0), rect(1439, 400, 2, 18), rect(1439.5, 899.5, 0, 0),
  rect(1100, 400, 0, 0), rect(1050, 400, 0, 0), rect(1150, 400, 0, 0), rect(1100, 900, 0, 0),
  rect(-10, -10, 0, 0), rect(1000, 1000, 0, 0), rect(999.5, 999.5, 1, 1), rect(500, 500, 1000, 1000),
  rect(5000, 5000, 2, 18), rect(-5000, 300, 2, 18), rect(300, -2000, 2, 18), rect(10, 10, -40, -40),
  rect(100, 0, 0, 0), rect(0, 100, 0, 0), rect(2000, 1440, 0, 0), rect(4000, 0, 0, 0),
]

/// Rects apps report for a caret or a focused element, good and bad.
private let usableRects: [CGRect] = [
  rect(700, 400, 2, 18), rect(700, 400, 0, 18), rect(700, 400, 2, 0), rect(700, 400, 0, 0),
  rect(700, 400, -2, 18), rect(700, 400, 2, -18), rect(5000, 5000, 2, 18), rect(-50, 400, 60, 18),
  rect(1440, 400, 0, 18), rect(1439, 400, 0, 18), rect(-1, 400, 1, 18), rect(-1, 400, 0, 18), rect(-0.5, 400, 0, 18),
  rect(700, 900, 2, 18), rect(700, -18, 2, 18), rect(700, -17.5, 2, 18), rect(100, 100, 600, 300),
  rect(100, 100, 600, 200), rect(100, 100, 600, 200.5), rect(0, 0, 0.25, 0.25), rect(1500, 100, 2, 18),
  rect(.nan, 400, 2, 18), rect(700, .nan, 2, 18), rect(700, 400, .nan, 18), rect(700, 400, 2, .nan),
  rect(.infinity, 400, 2, 18), rect(700, -.infinity, 2, 18), rect(700, 400, .infinity, 18),
  rect(700, 400, 2, .infinity), rect(-.infinity, -.infinity, .infinity, .infinity), .null, .infinite, .zero,
]

private let usableScreens: [(String, [CGRect])] = [
  ("one", [rect(0, 0, 1440, 900)]), ("two", [rect(0, 0, 1440, 900), rect(1440, 0, 2560, 1440)]), ("none", []),
]

func placementFixtures() -> FixtureFile {
  var below: [J] = []
  for (name, visible) in visibleFrames {
    for anchor in anchors {
      for size in pickerSizes {
        below.append([
          "visible": .string(name), "anchor": rectJ(anchor), "size": sizeJ(size),
          "result": rectJ(PopupPlacement.below(anchor, size: size, in: visible)),
        ])
      }
    }
  }
  // Other gaps, once each.
  for gap: CGFloat in [0, 10.5] {
    for anchor in anchors.prefix(4) {
      below.append([
        "visible": "laptop", "anchor": rectJ(anchor), "size": sizeJ(pickerSizes[1]), "gap": .number(Double(gap)),
        "result": rectJ(PopupPlacement.below(anchor, size: pickerSizes[1], in: visibleFrames[0].1, gap: gap)),
      ])
    }
  }

  var beside: [J] = []
  for (name, visible) in visibleFrames where name != "external" {
    for picker in pickers {
      let rows = [
        rect(picker.minX + 5, picker.minY + 37.5, picker.width - 10, 36), rect(picker.minX, picker.minY, 0, 0),
        rect(picker.minX + 5, picker.maxY + 400, picker.width - 10, 26),
      ]
      for row in rows {
        for size in previewSizes {
          beside.append([
            "visible": .string(name), "target": rectJ(picker), "row": rectJ(row), "size": sizeJ(size),
            "result": rectJ(PopupPlacement.beside(picker, alignedWith: row, size: size, in: visible)),
          ])
        }
      }
    }
  }
  for gap: CGFloat in [0, 12] {
    let picker = pickers[1]
    let row = rect(picker.minX, picker.minY + 40, picker.width, 26)
    beside.append([
      "visible": "laptop", "target": rectJ(picker), "row": rectJ(row), "size": sizeJ(previewSizes[0]),
      "gap": .number(Double(gap)),
      "result": rectJ(
        PopupPlacement.beside(picker, alignedWith: row, size: previewSizes[0], in: visibleFrames[0].1, gap: gap)),
    ])
  }

  let clamp: [J] = clampCases.map { rectToClamp, bounds in
    [
      "rect": rectJ(rectToClamp), "bounds": rectJ(bounds),
      "result": rectJ(PopupPlacement.clamp(rectToClamp, to: bounds)),
    ]
  }

  var screen: [J] = []
  for (name, frames) in screenSets {
    let screens = frames.enumerated().map { index, frame in
      ScreenInfo(
        displayID: UInt32(index + 1), name: "S\(index + 1)", frame: frame, visibleFrame: frame, isMain: index == 0)
    }
    for probe in screenProbes {
      screen.append([
        "screens": .string(name), "anchor": rectJ(probe),
        "screen": PopupPlacement.screen(for: probe, in: screens).map { .string($0.name) } ?? .null,
      ])
    }
  }

  var usable: [J] = []
  for (name, screens) in usableScreens {
    for candidate in usableRects {
      for maxHeight: CGFloat in [.infinity, 200] {
        usable.append([
          "screens": .string(name), "rect": rectJ(candidate), "maxHeight": .number(Double(maxHeight)),
          "usable": .bool(PopupPlacement.isUsable(candidate, maxHeight: maxHeight, on: screens)),
        ])
      }
    }
  }

  return FixtureFile(
    name: "placement.json",
    description:
      "PopupPlacement: the clipboard picker below an anchor (the caret, a field or the pointer as an empty rect), "
      + "above it when there's no room, kept in the visible frame (`gap` 4 unless given); the image preview beside "
      + "the picker, level with a row (`gap` 6 unless given); `clamp`; the screen showing an anchor (the one "
      + "containing its center, else the closest; screens are named S1, S2… in the order given); and whether a "
      + "reported rect can place a panel.",
    sections: ["below": below, "beside": beside, "clamp": clamp, "screen": screen, "isUsable": usable],
    extra: [
      "visibleFrames": .object(Dictionary(uniqueKeysWithValues: visibleFrames.map { ($0.0, rectJ($0.1)) })),
      "screenSets": .object(
        Dictionary(uniqueKeysWithValues: screenSets.map { ($0.0, J.array($0.1.map(rectJ))) })),
      "usableScreens": .object(
        Dictionary(uniqueKeysWithValues: usableScreens.map { ($0.0, J.array($0.1.map(rectJ))) })),
    ])
}
