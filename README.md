# Minimal Player

A text-only Plex music player for macOS 14 and later. It opens on an album list. The four tabs share one native AppKit table and a persistent transport. Six sample albums are playable before sign-in.

## Listen

Choose **Connect to Plex…**, sign in through your browser, then select a server and music library. On the next launch the player restores that selection. Account credentials are stored in this app’s own Keychain service. Sign out from **Plex Connection…** to return to the sample library.

- **Albums** opens a release in disc and track order. Choose **Play Album** or start from a particular track.
- **Artists** opens an artist’s albums.
- **Tracks** searches across the selected music library. Playing a result queues its album at that track.
- **Queue** shows the current album queue and emphasizes the current track. Double-click an entry to jump to it.

Press **⌘F** to search the current view. Album and track searches include artist names, and track searches also include album titles. Press **↓** to select a result, then **Return** to open or play it. **⌘[** goes back. The Library menu offers album sorting and refresh. **Space** toggles playback outside text fields. **⌘←** and **⌘→** control track navigation. The Playback menu includes AirPlay output selection and Clear Queue.

## Memory

The library browser requests 100 rows at a time. Paging and searching replace the current result set, and Plex performs library-wide filtering and sorting. Metadata responses bypass the URL cache. Opening or playing an album loads its track list. AVFoundation creates a player on demand and streams one media part at a time. Clearing the queue releases the player. The app has no third-party runtime dependencies, cover cache, artwork requests, or visualization renderer.

On Apple silicon with macOS 26.5.2, three fresh Release launches of the six-album sample measured 27, 29 and 30 MB of physical footprint. The baseline shelf measured 39, 40 and 40 MB. Measurements used `footprint -p PID` five seconds after launch, with playback stopped and account restoration skipped in the baseline. These figures describe the app process on this machine.

## Build and run

Open `Sleeve.xcodeproj`, choose the **Sleeve** scheme and **My Mac**, and press **⌘R**. From the project directory:

```sh
xcodebuild -project Sleeve.xcodeproj -scheme Sleeve -configuration Release -derivedDataPath .build build
open ".build/Build/Products/Release/Minimal Player.app"
```

## Verify

```sh
xcodebuild -project Sleeve.xcodeproj -scheme Sleeve -derivedDataPath .build -destination 'platform=macOS' -parallel-testing-enabled NO test
```

The tests use a URLProtocol fixture for Plex and AVFoundation for local playback. They cover sign-in, connection fallback, paging, search, XML fallback, track ordering, authenticated URLs, seeking and automatic advance. A synthetic million-artist catalog exercises random access to a page and a partial final page. Live playback requires a reachable Plex server and an audio format macOS can direct-play.

This repository preserves the history of [Sleeve’s utility-player-baseline tag](https://github.com/jamesacklin/sleeve/tree/utility-player-baseline).
