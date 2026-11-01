import AppKit

/// The standard Mac menus, shown whenever one of Inkbar's windows is in front: the app menu
/// (About, Settings, Pause, Hide, Quit), Edit (so copy, paste and undo work in every text
/// field), Window and Help. Inkbar has no Dock icon, so this menu is how a Mac user reaches
/// these things when the menu bar icon is switched off.
@MainActor
enum MainMenu {
    static func install(target: AppDelegate) {
        let main = NSMenu()

        main.addItem(submenuItem(appMenu(target: target)))
        main.addItem(submenuItem(editMenu()))
        let window = windowMenu()
        main.addItem(submenuItem(window))
        let help = helpMenu(target: target)
        main.addItem(submenuItem(help))

        NSApp.mainMenu = main
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(_ title: String, _ action: Selector?, _ key: String = "",
                             modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        item.target = target
        return item
    }

    private static func appMenu(target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Inkbar")
        menu.addItem(item("About Inkbar", #selector(AppDelegate.showAbout), target: target))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.openSettings), ",", target: target))
        menu.addItem(item("Pause Inkbar", #selector(AppDelegate.togglePause), target: target))
        menu.addItem(.separator())
        menu.addItem(item("Hide Inkbar", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit Inkbar", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func helpMenu(target: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Inkbar Help", #selector(AppDelegate.showHelp), "?", target: target))
        return menu
    }
}
