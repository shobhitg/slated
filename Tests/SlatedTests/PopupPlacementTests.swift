import CoreGraphics
import SlatedCore

// Where the clipboard picker opens (below the caret, above it near the bottom, kept on screen) and
// where its image preview goes (beside it). Top-left-origin coordinates, y growing down.

/// A 1440×900 display with a 25 pt menu bar and no Dock; a second one to its right.
private let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
private let picker = CGSize(width: 320, height: 280)

private func screen(_ id: UInt32, _ frame: CGRect) -> ScreenInfo {
  ScreenInfo(displayID: id, name: "\(id)", frame: frame, visibleFrame: frame, isMain: id == 1, scale: 2)
}

let popupPlacementTests = Suite(
  "PopupPlacement",
  [
    (
      "the picker opens just below the caret, left edges aligned",
      {
        let caret = CGRect(x: 200, y: 300, width: 0, height: 17)
        expectEqual(
          PopupPlacement.below(caret, size: picker, in: visible), CGRect(x: 200, y: 321, width: 320, height: 280))
        // The pointer, as an empty rect.
        let pointer = CGRect(x: 700, y: 100, width: 0, height: 0)
        expectEqual(PopupPlacement.below(pointer, size: picker, in: visible).origin, CGPoint(x: 700, y: 104))
      }
    ),
    (
      "near the bottom of the screen it opens above the caret instead",
      {
        let caret = CGRect(x: 200, y: 800, width: 0, height: 17)
        expectEqual(
          PopupPlacement.below(caret, size: picker, in: visible), CGRect(x: 200, y: 516, width: 320, height: 280))
        // Exactly enough room below still goes below.
        let fits = CGRect(x: 200, y: 900 - 280 - 4 - 17, width: 0, height: 17)
        expectEqual(PopupPlacement.below(fits, size: picker, in: visible).minY, fits.maxY + 4)
      }
    ),
    (
      "near the right edge it moves left to stay on screen; never above the menu bar or past the left edge",
      {
        let caret = CGRect(x: 1400, y: 300, width: 0, height: 17)
        expectEqual(PopupPlacement.below(caret, size: picker, in: visible).minX, 1440 - 320)
        let offLeft = CGRect(x: -50, y: 10, width: 0, height: 10)
        let placed = PopupPlacement.below(offLeft, size: picker, in: visible)
        expectEqual(placed.origin, CGPoint(x: 0, y: 25))
        // Too tall for either side: the side with more room, then clamped inside.
        let tall = CGSize(width: 320, height: 600)
        let middle = CGRect(x: 100, y: 400, width: 0, height: 20)
        expectEqual(PopupPlacement.below(middle, size: tall, in: visible).minY, 900 - 600)
        let high = CGRect(x: 100, y: 200, width: 0, height: 20)
        expectEqual(PopupPlacement.below(high, size: tall, in: visible).minY, 224)
        // Bigger than the screen: its top-left corner stays visible.
        let huge = PopupPlacement.below(middle, size: CGSize(width: 2000, height: 1000), in: visible)
        expectEqual(huge.origin, CGPoint(x: 0, y: 25))
      }
    ),
    (
      "the image preview goes right of the picker, level with its row; left when there's no room",
      {
        let size = CGSize(width: 256, height: 170)
        let at = CGRect(x: 200, y: 321, width: 320, height: 280)
        let row = CGRect(x: 205, y: 383, width: 310, height: 36)
        expectEqual(
          PopupPlacement.beside(at, alignedWith: row, size: size, in: visible),
          CGRect(x: 526, y: 383, width: 256, height: 170))
        let right = CGRect(x: 1100, y: 321, width: 320, height: 280)
        expectEqual(PopupPlacement.beside(right, alignedWith: row, size: size, in: visible).minX, 1100 - 6 - 256)
        // A row near the bottom: the preview rises to stay on screen.
        let low = CGRect(x: 205, y: 880, width: 310, height: 36)
        expectEqual(PopupPlacement.beside(at, alignedWith: low, size: size, in: visible).minY, 900 - 170)
        // No room either side (a narrow screen): the roomier side, kept inside.
        let narrow = CGRect(x: 0, y: 25, width: 600, height: 875)
        let middle = CGRect(x: 150, y: 321, width: 320, height: 280)
        expectEqual(PopupPlacement.beside(middle, alignedWith: row, size: size, in: narrow).minX, 0)  // left: 150 pt vs 130
      }
    ),
    (
      "the screen for an anchor: the one it's on, else the nearest",
      {
        let screens = [
          screen(1, CGRect(x: 0, y: 0, width: 1440, height: 900)),
          screen(2, CGRect(x: 1440, y: -200, width: 2560, height: 1440)),
        ]
        expectEqual(
          PopupPlacement.screen(for: CGRect(x: 2000, y: 100, width: 0, height: 17), in: screens)?.displayID, 2)
        expectEqual(PopupPlacement.screen(for: CGRect(x: 100, y: 100, width: 0, height: 17), in: screens)?.displayID, 1)
        expectEqual(PopupPlacement.screen(for: CGRect(x: -300, y: 400, width: 0, height: 0), in: screens)?.displayID, 1)
        expectEqual(PopupPlacement.screen(for: CGRect(x: 5000, y: 0, width: 0, height: 0), in: screens)?.displayID, 2)
        expect(PopupPlacement.screen(for: .zero, in: []) == nil)
      }
    ),
    (
      "a caret or field rect an app reports is used only when it's real and on a screen",
      {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        expect(PopupPlacement.isUsable(CGRect(x: 200, y: 300, width: 0, height: 17), on: screens), "a zero-wide caret")
        expect(!PopupPlacement.isUsable(.zero, on: screens), "no answer")
        expect(!PopupPlacement.isUsable(CGRect(x: 200, y: 300, width: 5, height: 0), on: screens))
        expect(!PopupPlacement.isUsable(CGRect(x: -9000, y: 300, width: 2, height: 17), on: screens), "off screen")
        expect(!PopupPlacement.isUsable(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 17), on: screens))
        expect(!PopupPlacement.isUsable(CGRect(x: 0, y: 0, width: 1, height: CGFloat.infinity), on: screens))
        expect(!PopupPlacement.isUsable(CGRect(x: 200, y: 300, width: 5, height: 17), on: []))
        // A focused field is fine; a whole editor isn't, it says little about where you type.
        expect(PopupPlacement.isUsable(CGRect(x: 100, y: 100, width: 600, height: 22), maxHeight: 240, on: screens))
        expect(!PopupPlacement.isUsable(CGRect(x: 0, y: 25, width: 1440, height: 800), maxHeight: 240, on: screens))
      }
    ),
  ])
