import SwiftUI

enum LibraryPage: String, CaseIterable {
    case transit = "Transit Map", albums = "Albums", artists = "Artists", queue = "Play Queue"
    var icon: String {
        switch self {
        case .transit: "point.3.connected.trianglepath.dotted"
        case .albums: "square.stack"
        case .artists: "music.mic"
        case .queue: "music.note.list"
        }
    }
}

private enum ShelfOrder: String, CaseIterable {
    case recent = "Recently added", title = "Album title", artist = "Artist name"
}

struct LibraryWindow: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("albumCoverSize") private var coverSize: Double = 220
    @State private var page: LibraryPage? = .albums
    @State private var mapDestination: MapDestination?
    @State private var album: Album?
    @State private var artist: String?
    @State private var search = ""
    @State private var order = ShelfOrder.recent
    @FocusState private var searching: Bool

    private var filtered: [Album] {
        library.albums.filter { item in
            (artist == nil || item.artist == artist) &&
                (search.isEmpty || item.title.localizedCaseInsensitiveContains(search) ||
                 item.artist.localizedCaseInsensitiveContains(search))
        }.sorted { a, b in
            if order == .recent, a.added != b.added { return a.added > b.added }
            if order == .artist, a.artist != b.artist { return a.artist.localizedStandardCompare(b.artist) == .orderedAscending }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 9) {
                        RecordMark().frame(width: 31, height: 31)
                        Text("Sleeve").font(.system(size: 27, weight: .medium, design: .serif))
                    }.padding(.leading, 19).padding(.top, 12).padding(.bottom, 28)
                    List(selection: $page) {
                        Section("Library") {
                            ForEach([LibraryPage.albums, .artists, .transit], id: \.self) { item in
                                Label(item.rawValue, systemImage: item.icon).tag(item)
                            }
                        }
                        Section("Playback") {
                            Label(LibraryPage.queue.rawValue, systemImage: LibraryPage.queue.icon).tag(LibraryPage.queue)
                        }
                    }.listStyle(.sidebar)
                    Divider()
                    Button { library.showConnection = true } label: {
                        HStack(spacing: 9) {
                            Image(systemName: library.server == nil ? "opticaldisc" : "externaldrive.connected.to.line.below")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(library.section?.title ?? "Sample library").fontWeight(.medium)
                                Text(library.server?.name ?? "Connect to Plex…").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).padding(16).help("Manage Plex connection")
                }
                .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 240)
            } detail: {
                Group {
                    if page == .transit {
                        ZStack {
                            TransitMap(albums: library.albums, search: search, destination: mapDestination) { album = $0 }
                                .id(library.revision)
                                .opacity(album == nil ? 1 : 0)
                                .accessibilityHidden(album != nil)
                                .allowsHitTesting(album == nil)
                            if let album { AlbumDetail(album: album, showOnMap: { showOnMap(album) }) }
                        }
                    } else if let album {
                        AlbumDetail(album: album, showOnMap: { showOnMap(album) })
                    } else if page == .queue {
                        QueueView(player: library.player)
                    } else if page == .artists && artist == nil {
                        ArtistIndex(albums: filtered) { name in artist = name; search = "" }
                    } else {
                        albumShelf
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.background)
                .toolbar {
                    if album != nil || artist != nil {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                if album != nil { album = nil } else { artist = nil }
                            } label: { Label("Back", systemImage: "chevron.left") }
                                .help("Go back").keyboardShortcut("[", modifiers: .command)
                        }
                    }
                    ToolbarItem(placement: .principal) {
                        if let activity = library.activity, !library.showConnection {
                            HStack { ProgressView().controlSize(.small); Text(activity).foregroundStyle(.secondary) }
                        }
                    }
                    if album == nil && page != .queue {
                        ToolbarItem {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                TextField("Search library", text: $search).textFieldStyle(.plain).focused($searching)
                                if !search.isEmpty {
                                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                                }
                            }.frame(width: 153).padding(.horizontal, 5)
                        }
                    }
                }
            }
            .navigationTitle("")
            Divider()
            Transport(player: library.player, showQueue: { album = nil; artist = nil; page = .queue })
        }
        .background {
            Button("Find in Library") { if page == .queue { page = .albums }; album = nil; searching = true }
                .keyboardShortcut("f").hidden()
        }
        .onChange(of: page) { _, next in
            album = nil; artist = nil; search = ""
            if next != .transit { mapDestination = nil }
        }
        .onChange(of: library.revision) { _, _ in mapDestination = nil; album = nil; artist = nil; search = "" }
        .sheet(isPresented: $library.showConnection, onDismiss: { library.cancel() }) {
            ConnectionView()
        }
    }

    private func showOnMap(_ target: Album) {
        mapDestination = MapDestination(albumID: target.id)
        search = ""
        album = nil
        page = .transit
    }

    private var albumShelf: some View {
        let records = filtered
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom, spacing: 16) {
                    PageHeading(title: artist ?? "Albums", detail: albumCount(records.count))
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "square.grid.2x2")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Slider(value: $coverSize, in: 110...310, step: 5)
                            .controlSize(.small)
                            .frame(width: 100)
                            .accessibilityLabel("Album cover size")
                    }
                    .help("Adjust album cover size")
                    Menu {
                        Picker("Sort by", selection: $order) {
                            ForEach(ShelfOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        if library.server != nil {
                            Divider()
                            Button("Refresh Library") { library.refresh() }
                        }
                    } label: {
                        Label(order.rawValue, systemImage: "arrow.up.arrow.down")
                    }.fixedSize().menuStyle(.borderlessButton).foregroundStyle(.secondary)
                }
                if records.isEmpty {
                    if search.isEmpty {
                        ContentUnavailableView("No albums", systemImage: "square.stack", description: Text("Add music to this Plex library, then refresh."))
                    } else {
                        ContentUnavailableView.search(text: search)
                    }
                } else {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: coverSize, maximum: coverSize), spacing: 22, alignment: .top)
                    ], alignment: .leading, spacing: 24) {
                        ForEach(records) { item in
                            Button { album = item } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    Artwork(album: item)
                                    Text(item.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).padding(.top, 9)
                                    Text(item.artist).foregroundStyle(.secondary).lineLimit(1).padding(.top, 2)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).help("\(item.title) — \(item.artist)")
                        }
                    }
                }
            }.padding(30)
        }
    }
}

func albumCount(_ count: Int) -> String { "\(count) \(count == 1 ? "album" : "albums")" }

struct PageHeading: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 38, weight: .regular, design: .serif))
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
}

private struct ArtistIndex: View {
    let albums: [Album]
    let select: (String) -> Void
    var body: some View {
        let groups = Dictionary(grouping: albums, by: \.artist)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PageHeading(title: "Artists", detail: "\(groups.count) \(groups.count == 1 ? "artist" : "artists")").padding(.bottom, 24)
                if groups.isEmpty {
                    ContentUnavailableView("No matching artists", systemImage: "music.mic")
                }
                ForEach(groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { name in
                    Button { select(name) } label: {
                        HStack(spacing: 12) {
                            if let first = groups[name]?.first { Artwork(album: first).frame(width: 46, height: 46) }
                            Text(name).font(.headline)
                            Spacer()
                            Text(albumCount(groups[name]?.count ?? 0)).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }.padding(.vertical, 9).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Divider()
                }
            }.padding(30)
        }
    }
}
