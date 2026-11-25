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
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            item.submenu = sub
            return sub
        }
        let app = submenu("Cue")
        app.addItem(withTitle: "Plex Connection…", action: #selector(LibraryWindow.connect), keyEquivalent: ",").target = window
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Cue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = submenu("Edit")
        for (name, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: name, action: Selector(action), keyEquivalent: key)
        }
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find", action: #selector(LibraryWindow.find), keyEquivalent: "f").target = window
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
        let playback = submenu("Playback")
        let toggle = playback.addItem(withTitle: "Play or Pause", action: #selector(LibraryWindow.toggle), keyEquivalent: " ")
        toggle.target = window
        toggle.keyEquivalentModifierMask = []
        playback.addItem(withTitle: "Previous Track", action: #selector(LibraryWindow.previousTrack),
                         keyEquivalent: String(UnicodeScalar(NSLeftArrowFunctionKey)!)).target = window
        playback.addItem(withTitle: "Next Track", action: #selector(LibraryWindow.nextTrack),
                         keyEquivalent: String(UnicodeScalar(NSRightArrowFunctionKey)!)).target = window
        playback.addItem(withTitle: "Graphic Equalizer…", action: #selector(LibraryWindow.showEqualizer), keyEquivalent: "e").target = window
        playback.addItem(withTitle: "Audio Output…", action: #selector(LibraryWindow.audioOutput), keyEquivalent: "").target = window
        playback.addItem(withTitle: "Clear Queue", action: #selector(LibraryWindow.clearQueue), keyEquivalent: "").target = window
        NSApp.mainMenu = menu
        window.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        if NSClassFromString("XCTestCase") == nil { store.restore() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
