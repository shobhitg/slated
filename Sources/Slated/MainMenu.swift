import AppKit

/// The menus in the menu bar while Slated is in front: the app menu, File, Edit (so text fields get
/// Undo, Cut, Copy, Paste and Select All), Window and Help.
@MainActor
enum MainMenu {
  static func make(for app: AppDelegate) -> NSMenu {
    let menu = NSMenu()
    for submenu in [appMenu(app), fileMenu(app), editMenu(), windowMenu(), helpMenu(app)] {
      let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
      item.submenu = submenu
      menu.addItem(item)
    }
    return menu
  }

  private static func appMenu(_ app: AppDelegate) -> NSMenu {
    let menu = NSMenu(title: "Slated")
    menu.addItem(item("About Slated", #selector(AppDelegate.showAbout), target: app))
    menu.addItem(.separator())
    menu.addItem(item("Settings…", #selector(AppDelegate.openMainWindowFromMenu), ",", target: app))
    menu.addItem(.separator())
    menu.addItem(item("Pause Slated", #selector(AppDelegate.togglePause), target: app))
    menu.addItem(.separator())
    let services = NSMenu(title: "Services")
    menu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
    NSApp.servicesMenu = services
    menu.addItem(.separator())
    menu.addItem(item("Hide Slated", #selector(NSApplication.hide(_:)), "h"))
    menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
    menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
    menu.addItem(.separator())
    menu.addItem(item("Quit Slated", #selector(AppDelegate.quitFromMenu), "q", target: app))
    return menu
  }

  private static func fileMenu(_ app: AppDelegate) -> NSMenu {
    let menu = NSMenu(title: "File")
    menu.addItem(item("Reload Configuration", #selector(AppDelegate.reload), "r", target: app))
    menu.addItem(item("Open Config File", #selector(AppDelegate.openConfig), target: app))
    menu.addItem(item("Import Slate Config into Slated…", #selector(AppDelegate.importSlate), target: app))
    menu.addItem(.separator())
    menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
    return menu
  }

  private static func editMenu() -> NSMenu {
    let menu = NSMenu(title: "Edit")
    menu.addItem(item("Undo", Selector(("undo:")), "z"))
    menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
    menu.addItem(.separator())
    menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
    menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
    menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
    menu.addItem(item("Delete", #selector(NSText.delete(_:))))
    menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
    return menu
  }

  /// AppKit lists the open windows below these.
  private static func windowMenu() -> NSMenu {
    let menu = NSMenu(title: "Window")
    menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
    menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
    menu.addItem(.separator())
    menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
    NSApp.windowsMenu = menu
    return menu
  }

  private static func helpMenu(_ app: AppDelegate) -> NSMenu {
    let menu = NSMenu(title: "Help")
    menu.addItem(item("Get Started", #selector(AppDelegate.showGetStartedFromMenu), target: app))
    menu.addItem(item("Show Log", #selector(AppDelegate.showLog), target: app))
    NSApp.helpMenu = menu
    return menu
  }

  /// A menu item; with no `target` its action goes up the responder chain (the window, a text field).
  private static func item(
    _ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command,
    target: AnyObject? = nil
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    item.target = target
    return item
  }
}
