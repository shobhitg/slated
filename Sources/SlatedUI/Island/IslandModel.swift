import AppKit
import Observation
import SlatedCore

/// What a shortcut just did, for the island's banner.
public struct IslandFeedback: Hashable, Sendable {
  public var title: String
  /// The app whose window moved or that came forward.
  public var app: String?
  /// Where the window ended up, as fractions of its screen's visible area (0…1).
  public var region: CGRect?
  /// SF Symbol for feedback without a region.
  public var symbol: String

  public init(title: String, app: String? = nil, region: CGRect? = nil, symbol: String = "checkmark") {
    self.title = title
    self.app = app
    self.region = region
    self.symbol = symbol
  }

  /// The symbol the settings UI uses for this kind of action.
  public static func symbol(for action: Action) -> String {
    WindowPresets.matching(action)?.symbol ?? ActionKind(action).symbol
  }
}

/// The display the island is on: its notch, if it has one, and the menu bar's height.
public struct IslandGeometry: Hashable, Sendable {
  /// The camera housing's size; nil on displays without a notch.
  public var notch: CGSize?
  public var menuBarHeight: CGFloat

  public init(notch: CGSize? = nil, menuBarHeight: CGFloat = 24) {
    self.notch = notch
    self.menuBarHeight = menuBarHeight
  }

  /// Height of the band at the top that the island's wings share with the notch.
  var band: CGFloat { notch?.height ?? max(menuBarHeight, 24) }
  var notchWidth: CGFloat { notch?.width ?? 0 }
}

/// What the island shows, highest priority first: the cheat sheet while Hyper is held, the active
/// modal key, a brief banner, running automations, else nothing.
public enum IslandPresentation: Hashable, Sendable {
  case hidden
  case cheatSheet(CheatSheet)
  case modal(CheatSheet, expanded: Bool)
  case banner(IslandModel.Banner)
  case automations(expanded: Bool)

  var isExpanded: Bool {
    switch self {
    case .cheatSheet, .automations(expanded: true), .modal(_, expanded: true): return true
    default: return false
    }
  }
}

/// The island's state. The app's presenter feeds it (and schedules banner expiry); `IslandView`
/// draws it.
@MainActor @Observable
public final class IslandModel {
  public enum Banner: Hashable, Sendable {
    case done(IslandFeedback)
    case failed(String)
  }

  public var geometry = IslandGeometry()
  public private(set) var banner: Banner?
  /// Identifies the current banner, so an expiry timer only clears the banner it was set for.
  public private(set) var bannerID = 0
  public var automations: [ActiveAutomation] = []
  public var stopShortcut: KeyCombo?
  /// Shown while the Hyper key is held past the delay.
  public var cheatSheet: CheatSheet?
  /// The active modal key's shortcuts; `modalExpanded` once the delay passes.
  public var modal: CheatSheet?
  public var modalExpanded = false
  /// The pointer is over the island (running automations expand to show a Stop button).
  public var isHovering = false
  /// A cheat sheet item that just ran, briefly highlighted.
  public var highlightedItem: String?
  /// The Stop button.
  public var onStop: (() -> Void)?
  /// Draw collapsed regardless of state: set while the panel comes on screen, so the island then
  /// grows out of the notch instead of appearing at full size.
  public var isParked = false

  public init() {}

  /// Shows a banner and returns its id for `clearBanner(id:)`.
  @discardableResult
  public func show(_ banner: Banner) -> Int {
    self.banner = banner
    bannerID += 1
    return bannerID
  }

  /// Clears the banner if it's still the one `id` refers to.
  public func clearBanner(id: Int) {
    if id == bannerID { banner = nil }
  }

  public var presentation: IslandPresentation {
    if isParked { return .hidden }
    if let cheatSheet, !cheatSheet.isEmpty { return .cheatSheet(cheatSheet) }
    if let modal { return .modal(modal, expanded: modalExpanded && !modal.isEmpty) }
    if let banner { return .banner(banner) }
    if !automations.isEmpty { return .automations(expanded: isHovering) }
    return .hidden
  }

  /// The pointer can interact with the island (hover to expand, the Stop button).
  public var isInteractive: Bool {
    if case .automations = presentation { return true }
    return false
  }

  /// The island's size, not counting the flared top corners.
  public var size: CGSize { IslandLayout.size(for: presentation, geometry: geometry, automations: automations.count) }
}

/// Sizes and corner radii for each presentation, shared by the view and by the presenter's hit
/// testing, so the clickable area always matches what's drawn.
enum IslandLayout {
  static let wing: CGFloat = 54
  static let bannerRow: CGFloat = 38
  static let automationRow: CGFloat = 48
  static let automationFooter: CGFloat = 54
  static let maxAutomationRows = 4
  static let sheetColumnWidth: CGFloat = 212
  static let sheetRow: CGFloat = 28
  static let sheetSectionHeader: CGFloat = 24
  static let sheetHeader: CGFloat = 40
  static let sheetPadding: CGFloat = 18

  static func size(for presentation: IslandPresentation, geometry: IslandGeometry, automations: Int) -> CGSize {
    let band = geometry.band
    let notch = geometry.notchWidth
    switch presentation {
    case .hidden:
      return CGSize(width: geometry.notch == nil ? 2 * wing : notch, height: band)
    case .automations(expanded: false), .modal(_, expanded: false):
      return CGSize(width: notch + 2 * wing + (geometry.notch == nil ? 24 : 0), height: band)
    case .banner(let banner):
      // A little slack over the measured text, so it's never cut off by rounding.
      let width = bannerContentWidth(banner) + 2 * sheetPadding + 12
      let minimum = geometry.notch == nil ? 0 : notch + 2 * wing
      return CGSize(
        width: min(max(width, minimum), 560),
        height: geometry.notch == nil ? max(band, 40) : band + bannerRow)
    case .automations(expanded: true):
      let rows = CGFloat(min(automations, maxAutomationRows) + (automations > maxAutomationRows ? 1 : 0))
      return CGSize(
        width: max(notch + 2 * wing + 60, 380),
        height: topInset(geometry) + max(rows, 1) * automationRow + automationFooter)
    case .cheatSheet(let sheet), .modal(let sheet, expanded: true):
      let grid = sheetGrid(sheet)
      let rows = sheet.sections.reduce(CGFloat(0)) { total, section in
        total + CGFloat((section.items.count + grid.columns - 1) / grid.columns)
      }
      let headers = sheet.sections.count > 1 ? CGFloat(sheet.sections.count) * sheetSectionHeader : 0
      return CGSize(
        width: max(CGFloat(grid.columns) * sheetColumnWidth + 2 * sheetPadding, notch + 2 * wing),
        height: topInset(geometry) + sheetHeader + rows * sheetRow + headers + sheetPadding)
    }
  }

  /// Room left at the top for the notch (or a little air on displays without one).
  static func topInset(_ geometry: IslandGeometry) -> CGFloat { geometry.notch == nil ? 6 : geometry.band }

  static func sheetGrid(_ sheet: CheatSheet) -> (columns: Int, rows: Int) {
    let count = sheet.items.count
    let columns = count <= 6 ? 2 : (count <= 36 ? 3 : 4)
    return (columns, (count + columns - 1) / columns)
  }

  /// Concave flare at the top corners and rounding at the bottom, notch-like when small.
  static func radii(for presentation: IslandPresentation, geometry: IslandGeometry) -> (top: CGFloat, bottom: CGFloat) {
    switch presentation {
    case .hidden:
      // No flare, so nothing shows beside the notch while the panel waits to be ordered out.
      return (0, geometry.notch == nil ? geometry.band / 2 : 10)
    case .automations(expanded: false), .modal(_, expanded: false):
      return (6, geometry.notch == nil ? geometry.band / 2 : 10)
    case .banner:
      return (8, geometry.notch == nil ? 18 : 16)
    default:
      return (14, 26)
    }
  }

  static func bannerContentWidth(_ banner: IslandModel.Banner) -> CGFloat {
    let title = NSFont.systemFont(ofSize: 13, weight: .semibold)
    let detail = NSFont.systemFont(ofSize: 13, weight: .regular)
    switch banner {
    case .done(let feedback):
      var width = 26 + 10 + measure(feedback.title, title)
      if let app = feedback.app { width += 12 + measure("·", detail) + measure(app, detail) }
      return width.rounded(.up)
    case .failed(let message):
      return (18 + 10 + measure(message, title)).rounded(.up)
    }
  }

  static func measure(_ text: String, _ font: NSFont) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: font]).width
  }
}
