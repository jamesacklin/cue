# Minimal Player

A text-only Plex music player for macOS 14 and later. It opens on an album list. The four tabs share one native AppKit table and a persistent transport. Six sample albums are playable before sign-in.

## Listen

Choose **Connect to Plex…**, sign in through your browser, then select a server and music library. On the next launch the player restores that selection. Account credentials are stored in this app’s own Keychain service. Sign out from **Plex Connection…** to return to the sample library.

- **Albums** opens a release in disc and track order. Use the footer’s Play button to start a selected album, or double-click a track to start there.
- **Artists** opens an artist’s albums.
- **Tracks** searches across the selected music library. Playing a result queues its album at that track.
- **Queue** shows the current album queue and emphasizes the current track. Double-click an entry to jump to it.

Press **⌘F** to search the current view. Album and track searches include artist names, and track searches also include album titles. Press **↓** to select a result, then **Return** to open or play it. **⌘[** goes back. The Library menu offers album sorting and refresh. **Space** toggles playback outside text fields. **⌘←** and **⌘→** control track navigation. The AirPlay picker beside Next selects the audio output. The Playback menu also offers audio output selection and Clear Queue.

## Memory

The library browser requests 50 rows at a time and asks Plex for the fields needed for each view. Paging and searching replace the current result set, and Plex performs library-wide filtering and sorting. Metadata responses bypass the URL cache. Opening or playing an album loads its track list. AVFoundation creates a player on demand and streams one media part at a time. Clearing the queue releases the player. Hiding or minimizing the window suspends the progress clock while audio continues. The app has no third-party runtime dependencies, cover cache, artwork requests, or visualization renderer.

In the initial text-only release (91be935), three fresh launches of the six-album sample on Apple silicon with macOS 26.5.2 measured 27, 29 and 30 MB of physical footprint. The baseline shelf measured 39, 40 and 40 MB. Measurements used `footprint -p PID` five seconds after launch, with playback stopped and account restoration skipped in the baseline. These figures describe the app process on this machine.

### Live library measurements

On an Apple M1 running macOS 26.5.2, a 4,633-album Plex library produced the following results. Each column gives the median of three fresh Release runs. Footprint is the median of repeated macOS `footprint -p PID` samples within each phase. CPU is player-process CPU time divided by wall time, where 100% is one core.

| Activity | Previous footprint | Current footprint | Previous CPU | Current CPU |
| --- | ---: | ---: | ---: | ---: |
| Album list, idle | 33 MB | 33 MB | 0.02% | 0.03% |
| Six track searches | 38 MB | 35 MB | 4.91% | 4.01% |
| Direct playback | 43 MB | 42 MB | 1.06% | 1.46% |
| Same searches during playback | 45 MB | 42 MB | 6.57% | 5.61% |

The benchmark drove the AppKit search handler with successive prefixes of six terms, waited for each result page, and played the same remote track at zero volume. The playback-only phase sampled ten seconds after the clock had advanced. The prior build (91be935) returned 100 rows per page and the current build returns 50. Match totals were identical. Across the six searches the decoded HTTP response bodies fell from 818,952 to 109,862 bytes. These figures cover the client process and exclude server CPU and system audio services.

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
