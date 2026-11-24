import SwiftUI

struct ConnectionView: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                PageHeading(title: "Plex Connection", detail: library.server?.name ?? "Music libraries")
                Spacer()
                Button("Done") { library.showConnection = false }.keyboardShortcut(.cancelAction)
            }
            Divider()
            if let message = library.connectionError {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            }
            if let activity = library.activity {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(activity)
                    Spacer()
                    Button("Cancel") { library.cancel() }
                }
            } else if !library.signedIn {
                Text("Sign in through your browser to choose a Plex server and music library.").foregroundStyle(.secondary)
                Button("Sign In with Plex") { library.signIn() }.buttonStyle(.borderedProminent)
            } else {
                if library.resources.isEmpty {
                    Text("No servers available. Make sure your Plex Media Server is online and shared with this account.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Server").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(library.resources) { resource in
                                choice(resource.name, icon: "externaldrive", selected: library.proposedServer?.id == resource.id) {
                                    library.choose(resource)
                                }
                            }
                        }
                    }.frame(maxHeight: min(135, CGFloat(library.resources.count * 33)))
                    if let server = library.proposedServer {
                        Text("Music library").font(.headline)
                        if library.sections.isEmpty {
                            Text("There are no music libraries on \(server.name) available to this account.").foregroundStyle(.secondary)
                        } else {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 5) {
                                    ForEach(library.sections) { section in
                                        choice(section.title, icon: "music.note.house", selected: library.server?.id == server.id && library.section?.id == section.id) {
                                            library.choose(section)
                                        }
                                    }
                                }
                            }.frame(maxHeight: min(135, CGFloat(library.sections.count * 33)))
                        }
                    }
                }
                Divider()
                HStack {
                    Button("Refresh Servers") { library.discover() }
                    Spacer()
                    Button("Sign Out") { library.signOut() }
                }
            }
        }.padding(26).frame(width: 440).fixedSize(horizontal: false, vertical: true)
    }

    private func choice(_ label: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(label, systemImage: icon).lineLimit(1)
                Spacer()
                Image(systemName: selected ? "checkmark" : "chevron.right").font(.caption)
            }.padding(.horizontal, 9).frame(height: 28)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
