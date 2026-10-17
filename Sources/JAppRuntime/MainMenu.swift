import AppKit

/// The menu bar, built in code. Items whose title names the app ("About …",
/// "Hide …", "Quit …") are renamed after the hosted app.
///
/// Browser-like commands (Reload, page zoom) live in a Develop menu that only
/// appears in developer mode; a hidden menu's shortcuts are inactive, so ⌘R and
/// friends stay free for the app itself. In an app bundle the runtime's own
/// commands (About JApp Runtime, Install Command-Line Tool, Open…, Help) are left
/// out, so the menu bar reads like the app's own.
@MainActor
final class MainMenu {
    private let aboutItem = NSMenuItem(title: "About JApp Runtime", action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: "")
    private let hideItem = NSMenuItem(title: "Hide JApp Runtime", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    private let quitItem = NSMenuItem(title: "Quit JApp Runtime", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    private let developItem = NSMenuItem(title: "Develop", action: nil, keyEquivalent: "")
    private var appMenuItem: NSMenuItem?

    func install() {
        let main = NSMenu()
        let app = submenu(appMenu(), title: "JApp Runtime")
        appMenuItem = app
        main.addItem(app)
        main.addItem(submenu(fileMenu(), title: "File"))
        main.addItem(submenu(editMenu(), title: "Edit"))
        main.addItem(submenu(viewMenu(), title: "View"))
        let develop = developMenu()
        develop.title = "Develop"
        developItem.submenu = develop
        developItem.isHidden = true
        main.addItem(developItem)
        let window = windowMenu()
        main.addItem(submenu(window, title: "Window"))
        let help = helpMenu()
        main.addItem(submenu(help, title: "Help"))
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
        NSApp.helpMenu = help  // adds the system's menu search field
    }

    private var isRuntime: Bool { !ProcessIdentity.isAppBundle }

    func setDevelopMenuVisible(_ visible: Bool) {
        developItem.isHidden = !visible
    }

    func setAppName(_ name: String) {
        // The menu bar shows the process's name in bold whatever this title says;
        // it matters to VoiceOver and to anything that reads the menus.
        appMenuItem?.title = name
        appMenuItem?.submenu?.title = name
        aboutItem.title = "About \(name)"
        hideItem.title = "Hide \(name)"
        quitItem.title = "Quit \(name)"
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(aboutItem)
        if isRuntime {
            menu.addItem(item("About JApp Runtime", #selector(AppDelegate.showRuntimeAbout(_:))))
            menu.addItem(.separator())
            menu.addItem(item("Install Command-Line Tool…", #selector(AppDelegate.installCommandLineTool(_:))))
        }
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(hideItem)
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(quitItem)
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu()
        if isRuntime {
            menu.addItem(item("Open…", #selector(AppDelegate.openDocument(_:)), "o"))
            menu.addItem(.separator())
        }
        menu.addItem(item("Edit Source…", #selector(AppDelegate.editSource(_:)), "e", [.command, .option]))
        menu.addItem(item("Reveal in Finder", #selector(AppDelegate.revealInFinder(_:)), "r", [.command, .shift]))
        menu.addItem(item("Restore Finder Icon", #selector(AppDelegate.restoreFinderIcon(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private func developMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Reload App", #selector(AppDelegate.reloadApp(_:)), "r"))
        menu.addItem(.separator())
        menu.addItem(item("Actual Size", #selector(AppDelegate.actualSize(_:)), "0"))
        menu.addItem(item("Zoom In", #selector(AppDelegate.zoomIn(_:)), "+"))
        menu.addItem(item("Zoom Out", #selector(AppDelegate.zoomOut(_:)), "-"))
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private func helpMenu() -> NSMenu {
        let menu = NSMenu()
        if isRuntime { menu.addItem(item("JApp Runtime Help", #selector(AppDelegate.showHelp(_:)))) }
        return menu
    }
}
