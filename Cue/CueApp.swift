import AppKit

@main
@MainActor
final class CueApp: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = CueApp()
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    private var window: LibraryWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = LibraryStore()
        window = LibraryWindow(store: store)
        window.window?.setFrameAutosaveName("CueLibraryWindow")
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            item.submenu = sub
            return sub
        }
        let app = submenu("Cue")
        app.addItem(withTitle: "About Cue", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Cue", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.option, .command]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Cue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = submenu("File")
        file.addItem(withTitle: "Plex Connection…", action: #selector(LibraryWindow.connect), keyEquivalent: "").target = window
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let edit = submenu("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        for (name, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: name, action: Selector(action), keyEquivalent: key)
        }
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find", action: #selector(LibraryWindow.find), keyEquivalent: "f").target = window
        let view = submenu("View")
        for (index, title) in (Catalog.allCases.map(\.title) + ["Queue"]).enumerated() {
            let item = view.addItem(withTitle: title, action: #selector(LibraryWindow.selectLibraryTab(_:)), keyEquivalent: String(index + 1))
            item.tag = index
            item.target = window
        }
        view.addItem(.separator())
        view.addItem(withTitle: "Columns", action: nil, keyEquivalent: "").submenu = window.columnMenu
        view.addItem(.separator())
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.control, .command]
        let library = submenu("Library")
        library.addItem(withTitle: "Back", action: #selector(LibraryWindow.back), keyEquivalent: "[").target = window
        library.addItem(withTitle: "Refresh", action: #selector(LibraryWindow.refresh), keyEquivalent: "r").target = window
        let orderItem = library.addItem(withTitle: "Sort Albums By", action: nil, keyEquivalent: "")
        let orderMenu = NSMenu()
        orderItem.submenu = orderMenu
        for (title, field) in [("Album Title", CatalogOrder.Field.album), ("Artist Name", .artist), ("Year", .year), ("Recently Added", .recent)] {
            let item = orderMenu.addItem(withTitle: title, action: #selector(LibraryWindow.setOrder(_:)), keyEquivalent: "")
            item.representedObject = field.rawValue
            item.target = window
        }
        library.addItem(.separator())
        window.addSelectionCommands(to: library)
        let playback = submenu("Playback")
        // Space belongs to the focused control. The player window handles it in the table.
        playback.addItem(withTitle: "Play or Pause", action: #selector(LibraryWindow.toggle), keyEquivalent: "").target = window
        playback.addItem(withTitle: "Previous Track", action: #selector(LibraryWindow.previousTrack),
                         keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!)).target = window
        playback.addItem(withTitle: "Next Track", action: #selector(LibraryWindow.nextTrack),
                         keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!)).target = window
        let equalizer = playback.addItem(withTitle: "Graphic Equalizer", action: #selector(LibraryWindow.showEqualizer), keyEquivalent: "e")
        equalizer.keyEquivalentModifierMask = [.option, .command]
        equalizer.target = window
        playback.addItem(withTitle: "Audio Output…", action: #selector(LibraryWindow.audioOutput), keyEquivalent: "").target = window
        playback.addItem(withTitle: "Copy AirPlay Diagnostics", action: #selector(LibraryWindow.copyAirPlayDiagnostics), keyEquivalent: "").target = window
        playback.addItem(withTitle: "Clear Queue", action: #selector(LibraryWindow.clearQueue), keyEquivalent: "").target = window
        let windows = submenu("Window")
        windows.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windows.addItem(.separator())
        windows.addItem(withTitle: "Show Player", action: #selector(showPlayer), keyEquivalent: "").target = self
        windows.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windows
        let help = submenu("Help")
        help.addItem(withTitle: "Cue Help", action: #selector(showHelp), keyEquivalent: "?").target = self
        NSApp.helpMenu = help
        NSApp.mainMenu = menu
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        if NSClassFromString("XCTestCase") == nil { store.restore() }
    }

    @objc private func showPlayer() {
        window.window?.deminiaturize(nil)
        window.showWindow(nil)
    }

    @objc private func showHelp() {
        NSWorkspace.shared.open(URL(string: "https://github.com/jamesacklin/cue#readme")!)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPlayer()
        return true
    }
}
