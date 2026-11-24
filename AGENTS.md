# Sleeve handoff

Sleeve is a SwiftUI music client for macOS 14 and later. The user chose music as the first-draft scope and a shelf of album covers as the opening view. A fresh launch offers six playable sample albums. The next integration check is a listening session against a real Plex Media Server. [Product plan](PRODUCT.md) · [Album shelf screenshot](Sleeve-album-shelf-1795484919673.jpg)

## Run the code you changed

From the project root, open `Sleeve.xcodeproj`, select the **Sleeve** scheme and **My Mac**, and press ⌘R. For a terminal build, launch the app from the build output. The top-level `Sleeve.app` is a copy of the first release build and can lag behind source edits. [Build and launch commands](README.md#run)

Edit existing Swift files directly. When adding or removing source files or bundled resources, or changing target settings in `project.yml`, run `xcodegen generate` from the project root to update the included project. The first build used Xcode 26.6 and XcodeGen 2.48.0.

## Where changes belong

| Area | Entry points and behavior |
| --- | --- |
| Navigation and artwork | [LibraryWindow.swift](Sleeve/LibraryWindow.swift) owns shelf search, sorting, the artist index, and selection. Search and sorting operate on loaded albums. [Artwork.swift](Sleeve/Artwork.swift) loads sample covers or requests thumbnails from Plex and caches them in memory. |
| Connection and restoration | [ConnectionView.swift](Sleeve/ConnectionView.swift) presents sign-in and selection. [LibraryStore.swift](Sleeve/LibraryStore.swift) coordinates discovery, library loading, and playback. A proposed server becomes active after its selected library loads. Check cancellation before applying asynchronous results so a late response cannot replace a newer selection. |
| Plex requests and credentials | [PlexClient.swift](Sleeve/PlexClient.swift) handles the browser PIN flow, HTTPS endpoint fallback, paginated album reads, and track decoding. [Credentials.swift](Sleeve/Credentials.swift) stores the account token in Keychain. User defaults hold the client, server, and library IDs. Each server supplies its own access token. Playback URLs contain that token, so redact them when capturing diagnostics. |
| Playback and sample data | [ListeningViews.swift](Sleeve/ListeningViews.swift) displays tracks, queue, and transport. [Player.swift](Sleeve/Player.swift) owns the shared AVPlayer and advances the queue when a track ends. Switching libraries clears the queue. [Music.swift](Sleeve/Music.swift) defines the models and maps sample tracks to bundled audio. |

## Verification baseline

On November 23, 2026, all seven tests passed on Apple silicon with macOS 26.5.2. [PlexClientTests.swift](SleeveTests/PlexClientTests.swift) substitutes a URLProtocol fixture for Plex and exercises an isolated Keychain credential. [PlaybackTests.swift](SleeveTests/PlaybackTests.swift) uses AVFoundation and the bundled audio. Search, album playback, queue navigation, and the connection sheet were also exercised in the running app. [Test command](README.md#verify)

## First live Plex check

1. Choose **Connect to Plex…**, complete browser sign-in with a test account, then select a server and music library. Confirm the expected albums and covers appear.
2. Open a familiar album, start a track, seek, and browse away. Listen through a track boundary and confirm the transport and queue advance together. For a multi-disc release, compare the displayed order with Plex.
3. Quit and relaunch. Confirm Sleeve restores the selected library. Sign out of the test account and confirm the sample shelf returns.

If the library is missing, start with `PlexClient.connect`, which tries secure local, remote, then relay endpoints and selects sections of type `artist`. If metadata loads but audio fails, start with `PlexServer.stream(for:)`: the player requests the first media part directly, so the file must be decodable by AVFoundation.
