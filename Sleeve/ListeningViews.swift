import SwiftUI

struct AlbumDetail: View {
    let album: Album
    @EnvironmentObject private var library: LibraryStore
    @State private var tracks: [Track] = []
    @State private var loading = true
    @State private var problem: String?
    @State private var attempt = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 23) {
                    Artwork(album: album).frame(width: 160, height: 160)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(album.title).font(.system(size: 35, weight: .regular, design: .serif))
                        Text(album.artist).font(.title3)
                        Text([album.year.map(String.init), tracks.isEmpty ? nil : trackCount(tracks.count)]
                            .compactMap { $0 }.joined(separator: "  ·  ")).foregroundStyle(.secondary)
                        Button {
                            if let first = tracks.first(where: { $0.localFile != nil || $0.part != nil }) {
                                library.play(tracks, from: first.id, album: album)
                            }
                        } label: { Label("Play Album", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent)
                            .disabled(!tracks.contains { $0.localFile != nil || $0.part != nil })
                            .padding(.top, 6)
                    }
                }
                Divider()
                if loading {
                    ProgressView("Loading tracks…").controlSize(.small)
                } else if let problem {
                    Text(problem).foregroundStyle(.secondary)
                    Button("Retry") { attempt += 1 }
                } else if tracks.isEmpty {
                    ContentUnavailableView("No tracks", systemImage: "music.note")
                } else {
                    let discs = Dictionary(grouping: tracks, by: \.disc)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(discs.keys.sorted(), id: \.self) { disc in
                            if discs.count > 1 { Text("Disc \(disc)").font(.headline).padding(.vertical, 8) }
                            ForEach(discs[disc] ?? []) { track in
                                Button { library.play(tracks, from: track.id, album: album) } label: {
                                    HStack(spacing: 13) {
                                        Text("\(track.number)").monospacedDigit().foregroundStyle(.secondary)
                                            .frame(width: 26, alignment: .trailing)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(track.title).fontWeight(.medium)
                                            if track.artist != album.artist {
                                                Text(track.artist).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Text(timeLabel(track.duration)).monospacedDigit().foregroundStyle(.secondary)
                                        Image(systemName: "play.fill").font(.caption2).foregroundStyle(.secondary)
                                    }.padding(.vertical, 13).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(track.localFile == nil && track.part == nil)
                                Divider()
                            }
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(30)
        }
        .task(id: "\(album.id)-\(attempt)") {
            loading = true
            tracks = []
            problem = nil
            do {
                let result = try await library.tracks(for: album)
                try Task.checkCancellation()
                tracks = result
            } catch {
                if !Task.isCancelled { problem = error.localizedDescription }
            }
            if !Task.isCancelled { loading = false }
        }
    }
}

private func trackCount(_ count: Int) -> String { "\(count) \(count == 1 ? "track" : "tracks")" }

struct QueueView: View {
    @ObservedObject var player: Player

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom) {
                    PageHeading(title: "Play Queue", detail: trackCount(player.queue.count))
                    Spacer()
                    if !player.queue.isEmpty { Button("Clear Queue") { player.reset() } }
                }.padding(.bottom, 23)
                if player.queue.isEmpty {
                    ContentUnavailableView("Your queue is empty", systemImage: "music.note.list",
                                           description: Text("Play an album or track to start listening."))
                        .frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                ForEach(Array(player.queue.enumerated()), id: \.element.id) { offset, entry in
                    Button { player.select(offset) } label: {
                        HStack(spacing: 13) {
                            Artwork(album: entry.album).frame(width: 42, height: 42)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.track.title).fontWeight(.medium)
                                Text(entry.track.artist).font(.callout).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if player.index == offset {
                                Image(systemName: player.playing ? "speaker.wave.2.fill" : "pause.fill")
                                    .foregroundStyle(Color.sleeveAccent).accessibilityLabel("Current track")
                            }
                            Text(timeLabel(entry.track.duration)).monospacedDigit().foregroundStyle(.secondary)
                        }.padding(.vertical, 9).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                }
            }.padding(30)
        }
    }
}

struct Transport: View {
    @ObservedObject var player: Player
    let showQueue: () -> Void
    @State private var scrubbing: Double?

    var body: some View {
        VStack(spacing: 0) {
            if let error = player.error {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                    Text(error).font(.callout)
                    Spacer()
                    Button { player.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss playback error")
                }.padding(.horizontal, 18).padding(.top, 9)
            }
            HStack(spacing: 18) {
                HStack(spacing: 10) {
                    if let current = player.current {
                        Artwork(album: current.album).frame(width: 44, height: 44)
                    } else {
                        Image(systemName: "music.note").font(.title3).foregroundStyle(.secondary)
                            .frame(width: 44, height: 44).background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.current?.track.title ?? "Nothing playing")
                            .fontWeight(.semibold).lineLimit(1)
                        Text(player.current?.track.artist ?? "Choose an album").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 4) {
                    HStack(spacing: 20) {
                        control("Previous track", image: "backward.fill", action: player.previous)
                            .disabled(player.current == nil)
                        control(player.playing ? "Pause" : "Play", image: player.playing ? "pause.fill" : "play.fill", action: player.toggle)
                            .font(.system(size: 19)).disabled(player.current == nil)
                        control("Next track", image: "forward.fill", action: player.next).disabled(!player.hasNext)
                    }
                    HStack(spacing: 7) {
                        Text(timeLabel(scrubbing ?? player.elapsed)).frame(minWidth: 30, alignment: .trailing)
                        Slider(value: Binding(get: { scrubbing ?? min(player.elapsed, player.length) },
                                              set: { scrubbing = $0 }), in: 0...max(1, player.length)) { editing in
                            if !editing, let target = scrubbing {
                                player.seek(to: target)
                                scrubbing = nil
                            }
                        }.controlSize(.mini).disabled(player.current == nil || player.length <= 0)
                            .accessibilityLabel("Playback position")
                        Text(timeLabel(player.length)).frame(minWidth: 30, alignment: .leading)
                    }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }.frame(minWidth: 200, idealWidth: 285, maxWidth: 360)
                HStack(spacing: 9) {
                    Image(systemName: player.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(.secondary)
                    Slider(value: $player.volume, in: 0...1).controlSize(.small).frame(width: 74).accessibilityLabel("Volume")
                    control("Show play queue", image: "music.note.list", action: showQueue).padding(.leading, 7)
                }.frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(.horizontal, 20).padding(.vertical, 10)
        }.background(.bar)
            .onChange(of: player.current?.id) { _, _ in scrubbing = nil }
    }

    private func control(_ label: String, image: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: image).frame(minWidth: 22, minHeight: 22) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}
