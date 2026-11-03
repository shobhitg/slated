import Foundation

/// Every key the settings window shows: the one registry that maps its controls to the files.
///
/// Settings have fixed keys (`ConfigKeys.islandEnabled`). Items (shortcuts, hotstrings, layouts) are
/// found by index in their list, and their editors' fields by the keys in `Binding`, `Hotstring`,
/// `Layout` and `Action`, relative to the item. Tests check every key here against an encoded
/// configuration, check that every setting the files have is here, and check that every control in
/// the settings panes names one (on the Mac and in GNOME's preferences, whose copy of this registry
/// is pinned to this one by `fixtures/config-keys.json`).
public enum ConfigKeys {
  /// A platform whose settings window shows a setting.
  public enum Platform: String, Sendable, CaseIterable {
    case mac, gnome
  }

  /// A setting with a fixed key. `id` names it across platforms (the GNOME registry uses the same ids).
  public struct Setting: Hashable, Sendable {
    public var id: String
    public var key: ConfigKey
    /// Where the settings window offers it. Launch at login is the Mac's own, for example: GNOME runs
    /// the extension with the session.
    public var platforms: Set<Platform>

    public init(_ id: String, _ key: ConfigKey, platforms: Set<Platform> = [.mac, .gnome]) {
      self.id = id
      self.key = key
      self.platforms = platforms
    }
  }

  // MARK: settings.json

  public static let launchAtLogin = ConfigKey(.settings, "general.launchAtLogin")
  public static let showStatusIcon = ConfigKey(.settings, "general.showStatusIcon")
  public static let showActionHUD = ConfigKey(.settings, "general.showActionHUD")
  public static let hotstringsEnabled = ConfigKey(.settings, "general.hotstringsEnabled")
  public static let showConfigKeys = ConfigKey(.settings, "general.showConfigKeys")

  public static let islandEnabled = ConfigKey(.settings, "island.enabled")
  public static let islandCheatSheet = ConfigKey(.settings, "island.cheatSheet")
  public static let islandCheatSheetDelay = ConfigKey(.settings, "island.cheatSheetDelay")
  public static let islandShowFailures = ConfigKey(.settings, "island.showFailures")

  public static let orderScreensLeftToRight = ConfigKey(.settings, "windows.orderScreensLeftToRight")
  public static let secondsBeforeRepeat = ConfigKey(.settings, "windows.secondsBeforeRepeat")
  public static let undoMaxStackSize = ConfigKey(.settings, "windows.undoMaxStackSize")

  public static let clipboardEnabled = ConfigKey(.settings, "clipboard.enabled")
  public static let clipboardShortcut = ConfigKey(.settings, "clipboard.shortcut")
  public static let clipboardPasteAfterSelecting = ConfigKey(.settings, "clipboard.pasteAfterSelecting")
  public static let clipboardMaxItems = ConfigKey(.settings, "clipboard.maxItems")
  public static let clipboardRetentionDays = ConfigKey(.settings, "clipboard.retentionDays")
  public static let clipboardPersist = ConfigKey(.settings, "clipboard.persist")
  public static let clipboardScreenshots = ConfigKey(.settings, "clipboard.screenshots")
  public static let clipboardSecrets = ConfigKey(.settings, "clipboard.secrets")
  public static let clipboardSecretMinutes = ConfigKey(.settings, "clipboard.secretMinutes")
  public static let clipboardSecretPatterns = ConfigKey(.settings, "clipboard.secretPatterns")
  public static let clipboardExcludedApps = ConfigKey(.settings, "clipboard.excludedApps")

  public static let automationStopShortcut = ConfigKey(.settings, "automation.stopShortcut")
  public static let automationStopOnAppSwitch = ConfigKey(.settings, "automation.stopOnAppSwitch")
  public static let automationMaxRunMinutes = ConfigKey(.settings, "automation.maxRunMinutes")
  public static let automationShowIndicator = ConfigKey(.settings, "automation.showIndicator")

  // MARK: config.json

  public static let capsLock = ConfigKey(.config, "keyboard.capsLock")
  public static let capsLockAlone = ConfigKey(.config, "keyboard.capsLockAlone")
  public static let hyperModifiers = ConfigKey(.config, "keyboard.hyperModifiers")
  public static let keyRepeat = ConfigKey(.config, "keyboard.keyRepeat")
  public static let keyRepeatDelay = ConfigKey(.config, "keyboard.keyRepeat.delay")
  public static let keyRepeatInterval = ConfigKey(.config, "keyboard.keyRepeat.interval")

  /// The lists items live in.
  public static let bindings = ConfigKey(.config, "bindings")
  public static let hotstrings = ConfigKey(.config, "hotstrings")
  public static let layouts = ConfigKey(.config, "layouts")

  // MARK: secrets.json

  /// The secrets, by name.
  public static let secrets = ConfigKey(.secrets, "secrets")

  /// A sensitive hotstring's text: `secrets.json › pw`. Copy Value never copies it (`valueText`).
  public static func secret(named name: String) -> ConfigKey {
    ConfigKey(file: .secrets, components: [.key("secrets"), .key(name)])
  }

  /// Every setting with a fixed key, in the order the window shows them.
  public static let settings: [Setting] = [
    Setting("launchAtLogin", launchAtLogin, platforms: [.mac]),
    Setting("showStatusIcon", showStatusIcon),
    Setting("showActionHUD", showActionHUD),
    Setting("showConfigKeys", showConfigKeys),
    Setting("islandEnabled", islandEnabled),
    Setting("islandCheatSheet", islandCheatSheet),
    Setting("islandCheatSheetDelay", islandCheatSheetDelay),
    Setting("islandShowFailures", islandShowFailures),
    Setting("orderScreensLeftToRight", orderScreensLeftToRight),
    Setting("secondsBeforeRepeat", secondsBeforeRepeat),
    Setting("undoMaxStackSize", undoMaxStackSize),
    Setting("hotstringsEnabled", hotstringsEnabled),
    Setting("clipboardEnabled", clipboardEnabled),
    Setting("clipboardShortcut", clipboardShortcut),
    Setting("clipboardPasteAfterSelecting", clipboardPasteAfterSelecting),
    Setting("clipboardMaxItems", clipboardMaxItems),
    Setting("clipboardRetentionDays", clipboardRetentionDays),
    Setting("clipboardPersist", clipboardPersist),
    Setting("clipboardScreenshots", clipboardScreenshots),
    Setting("clipboardSecrets", clipboardSecrets),
    Setting("clipboardSecretMinutes", clipboardSecretMinutes),
    Setting("clipboardSecretPatterns", clipboardSecretPatterns),
    Setting("clipboardExcludedApps", clipboardExcludedApps),
    Setting("automationStopShortcut", automationStopShortcut),
    Setting("automationStopOnAppSwitch", automationStopOnAppSwitch),
    Setting("automationMaxRunMinutes", automationMaxRunMinutes),
    Setting("automationShowIndicator", automationShowIndicator),
    Setting("capsLock", capsLock),
    Setting("capsLockAlone", capsLockAlone),
    Setting("hyperModifiers", hyperModifiers),
    Setting("keyRepeat", keyRepeat),
    Setting("keyRepeatDelay", keyRepeatDelay),
    Setting("keyRepeatInterval", keyRepeatInterval),
  ]

  /// Keys the files have that no control shows, and why. A new setting must go in `settings` or here.
  public static let notShown: [String: String] = [
    "settings.json › version": "The format's version, written by Slated.",
    "config.json › version": "The format's version, written by Slated.",
    "settings.json › windows":
      "Slate's own settings: the window shows the three people tune; the rest are for hand edits.",
    "config.json › defaults": "Slate's default layouts per display arrangement: imported from Slate, edited by hand.",
    "secrets.json › version": "The format's version, written by Slated.",
    "secrets.json › secrets":
      "Sensitive hotstrings' text: each one's editor shows it masked, under the key secrets.json › its name.",
  ]

  // MARK: Items' fields, relative to the item

  /// A shortcut in `bindings`, named by its keys (`"hyper+h"`).
  public enum Binding {
    public static let name = "name"
    public static let keys = "keys"
    public static let modal = "modal"
    public static let modalKeys = "modal.keys"
    public static let modalToggle = "modal.toggle"
    public static let action = "action"
    public static let repeats = "repeats"
    public static let enabled = "enabled"
    public static let onlyInApps = "onlyInApps"
    public static let all = [name, keys, modal, modalKeys, modalToggle, action, repeats, enabled, onlyInApps]
  }

  /// A hotstring in `hotstrings`, named by its trigger (`";sig"`).
  public enum Hotstring {
    public static let trigger = "trigger"
    public static let replacement = "replacement"
    public static let action = "action"
    public static let enabled = "enabled"
    public static let caseSensitive = "caseSensitive"
    public static let fire = "fire"
    public static let wordBoundary = "wordBoundary"
    public static let method = "method"
    public static let onlyInApps = "onlyInApps"
    public static let exceptInApps = "exceptInApps"
    public static let notes = "notes"
    public static let all = [
      trigger, replacement, action, enabled, caseSensitive, fire, wordBoundary, method, onlyInApps, exceptInApps, notes,
    ]
  }

  /// A layout in `layouts`, named by its name; its apps in `apps`, named by app.
  public enum Layout {
    public static let name = "name"
    public static let apps = "apps"
    public static let before = "before"
    public static let after = "after"
    public static let app = "app"
    public static let operations = "operations"
    public static let ignoreFail = "options.ignoreFail"
    public static let `repeat` = "options.repeat"
    public static let mainFirst = "options.mainFirst"
    public static let sortTitle = "options.sortTitle"
    public static let all = [name, apps, before, after]
    /// Relative to an app of the layout.
    public static let appFields = [app, operations, ignoreFail, `repeat`, mainFirst, sortTitle]
  }

  /// An action's parameters (Slate's JavaScript names), relative to the action.
  public enum Action {
    public static let op = "op"
    public static let x = "x"
    public static let y = "y"
    public static let width = "width"
    public static let height = "height"
    public static let screen = "screen"
    public static let anchor = "anchor"
    public static let direction = "direction"
    public static let style = "style"
    public static let operations = "operations"
    public static let steps = "steps"
    public static let name = "name"
    public static let app = "app"
    public static let save = "save"
    public static let stack = "stack"
    public static let all = "all"
    public static let delete = "delete"
    public static let characters = "characters"
    public static let padding = "padding"
    public static let grids = "grids"
    public static let command = "command"
    public static let wait = "wait"
    public static let path = "path"
    public static let landscape = "landscape"
    public static let portrait = "portrait"
    public static let text = "text"
    public static let method = "method"
    public static let url = "url"
    public static let keys = "keys"
    public static let button = "button"
    public static let count = "count"
    public static let input = "input"
    public static let phase = "phase"
    public static let action = "action"
    public static let interval = "interval"
    public static let mode = "mode"
    public static let times = "times"
    public static let jitter = "jitter"
    public static let seconds = "seconds"
    /// A sequence step's, under `steps[i]` (written only when some step keeps its window).
    public static let keepWindow = "keepWindow"

    /// Each operation's parameters besides `op`, as the encoder writes them (optional ones included).
    public static let parameters: [String: [String]] = [
      "move": [x, y, width, height, screen],
      "resize": [width, height, anchor],
      "push": [direction, style, screen],
      "nudge": [x, y],
      "throw": [screen, width, height],
      "corner": [direction, width, height, screen],
      "chain": [operations],
      "sequence": [operations, steps],
      "layout": [name],
      "focus": [direction, app],
      "snapshot": [name, save, stack],
      "delete-snapshot": [name, all],
      "activate-snapshot": [name, delete],
      "hint": [characters],
      "grid": [padding, grids],
      "hide": [app], "show": [app], "toggle": [app],
      "shell": [command, wait, path],
      "undo": [], "relaunch": [], "switch": [],
      "by-orientation": [landscape, portrait],
      "insert-text": [text, method],
      "open-url": [url],
      "keystroke": [keys],
      "click": [button, count],
      "press": [input, phase],
      "hold": [input],
      "repeat": [action, interval, mode, times, jitter],
      "wait": [seconds],
      "stop-automations": [],
      "clipboard-history": [],
    ]

    /// Every operation with every parameter set to something other than its default (the encoder
    /// leaves defaults out), as config.json has them. Tests on both platforms check `parameters`
    /// against what these encode to.
    public static let examples: [String] = [
      #"{"op": "move", "x": "screenOriginX", "y": "screenOriginY", "width": "screenSizeX/2", "height": "screenSizeY", "screen": "1"}"#,
      #"{"op": "resize", "width": "+10%", "height": "-5%", "anchor": "bottom-right"}"#,
      #"{"op": "push", "direction": "left", "style": "bar-resize:screenSizeX/3", "screen": "next"}"#,
      #"{"op": "nudge", "x": "+10%", "y": "-20"}"#,
      #"{"op": "throw", "screen": "next", "width": "screenSizeX", "height": "screenSizeY"}"#,
      #"{"op": "corner", "direction": "top-right", "width": "screenSizeX/2", "height": "screenSizeY/2", "screen": "0"}"#,
      #"{"op": "chain", "operations": [{"op": "undo"}, {"op": "relaunch"}]}"#,
      #"{"op": "sequence", "operations": [{"op": "undo"}, {"op": "relaunch"}]}"#,
      #"{"op": "sequence", "steps": [{"action": {"op": "undo"}, "keepWindow": true}]}"#,
      #"{"op": "layout", "name": "Coding"}"#,
      #"{"op": "focus", "direction": "left"}"#,
      #"{"op": "focus", "app": "Safari"}"#,
      #"{"op": "snapshot", "name": "desk", "save": true, "stack": true}"#,
      #"{"op": "delete-snapshot", "name": "desk", "all": true}"#,
      #"{"op": "activate-snapshot", "name": "desk", "delete": true}"#,
      #"{"op": "hint", "characters": "ASDFGHJKL"}"#,
      #"{"op": "grid", "padding": 5, "grids": {"0": {"width": 6, "height": 4}}}"#,
      #"{"op": "hide", "app": "current"}"#,
      #"{"op": "show", "app": "all"}"#,
      #"{"op": "toggle", "app": ["Safari", "Mail"]}"#,
      #"{"op": "shell", "command": "open -a Terminal", "wait": true, "path": "~/src"}"#,
      #"{"op": "undo"}"#,
      #"{"op": "relaunch"}"#,
      #"{"op": "switch"}"#,
      #"{"op": "by-orientation", "landscape": {"op": "undo"}, "portrait": {"op": "relaunch"}}"#,
      #"{"op": "insert-text", "text": "Thanks", "method": "paste"}"#,
      #"{"op": "open-url", "url": "https://example.com"}"#,
      #"{"op": "keystroke", "keys": "cmd+shift+4"}"#,
      #"{"op": "click", "button": "right", "count": 2}"#,
      #"{"op": "press", "input": "mouse:left", "phase": "up"}"#,
      #"{"op": "hold", "input": "mouse:right"}"#,
      #"{"op": "repeat", "action": {"op": "click", "button": "left"}, "interval": 0.2, "mode": "while-held", "times": 50, "jitter": 0.1}"#,
      #"{"op": "wait", "seconds": 1.5}"#,
      #"{"op": "stop-automations"}"#,
      #"{"op": "clipboard-history"}"#,
    ]
  }

  // MARK: Items' keys

  /// The key of the binding at `index`, named by its keys when no other binding has them. One behind
  /// a modal key goes by its index: its keys alone don't name it, and the file has no "modal keys" text.
  public static func binding(at index: Int, in configuration: SlatedConfiguration) -> ConfigKey {
    let names = configuration.bindings.map { $0.modal == nil ? $0.keys.string : "" }
    return bindings.item(index, name: ConfigKey.itemName(names, at: index))
  }

  /// The key of the hotstring at `index`, named by its trigger when no other hotstring has it.
  public static func hotstring(at index: Int, in configuration: SlatedConfiguration) -> ConfigKey {
    hotstrings.item(index, name: ConfigKey.itemName(configuration.hotstrings.map(\.trigger), at: index))
  }

  /// The key of the layout at `index`, named by its name when no other layout has it.
  public static func layout(at index: Int, in configuration: SlatedConfiguration) -> ConfigKey {
    layouts.item(index, name: ConfigKey.itemName(configuration.layouts.map(\.name), at: index))
  }

  /// The key of the app at `index` in `layout` (under the layout's key), named by its app.
  public static func layoutApp(at index: Int, of layout: SlatedCore.Layout, under key: ConfigKey) -> ConfigKey {
    key.appending(Layout.apps).item(index, name: ConfigKey.itemName(layout.apps.map(\.app), at: index))
  }
}
