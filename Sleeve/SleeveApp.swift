import SwiftUI

@main
struct SleeveApp: App {
    @StateObject private var library = LibraryStore()

    var body: some Scene {
        Window("Sleeve", id: "library") {
            LibraryWindow()
                .environmentObject(library)
                .tint(.sleeveAccent)
                .frame(minWidth: 750, minHeight: 540)
                .task { library.restore() }
        }
        .defaultSize(width: 980, height: 815)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("Plex Connection…") { library.showConnection = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("Playback") {
                PlaybackCommands(player: library.player)
            }
        }
    }
}

private struct PlaybackCommands: View {
    @ObservedObject var player: Player
    var body: some View {
        Button(player.playing ? "Pause" : "Play") { player.toggle() }
            .keyboardShortcut(.space, modifiers: []).disabled(player.current == nil)
        Button("Previous Track") { player.previous() }
            .keyboardShortcut(.leftArrow, modifiers: .command).disabled(player.current == nil)
        Button("Next Track") { player.next() }
            .keyboardShortcut(.rightArrow, modifiers: .command).disabled(!player.hasNext)
    }
}
