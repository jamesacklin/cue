# Cue

A text-only Plex music player for macOS 14 and later. It opens on an album list. The four tabs share one native AppKit table and a persistent transport.

## Listen

Choose **Connect to Plex…**, sign in through your browser, then select a server and music library. On the next launch the player restores that selection. Account credentials are stored in this app’s own Keychain service. Click the server name in the toolbar to manage the connection. Sign out from **Plex Connection…** to disconnect and clear the library view.

- **Albums** opens a release in disc and track order. Use the footer’s Play button to start a selected album, or double-click a track to start there.
- **Artists** opens an artist’s albums.
- **Tracks** searches across the selected music library. Playing a result queues its album at that track.
- **Queue** shows the tracks still to finish and displays their count in the tab. The transport shows the current track. Double-click an entry or select it and press Return to play it immediately. It stays in Queue until it finishes, and skipped or interrupted tracks keep their places. Shift-click selects a range. Control-click or Command-click toggles individual entries. Drag the selection between rows to move it in playback order, or press Backspace or Forward Delete to remove it. A drag from a sorted view returns Queue to playback order and keeps the search filter.

Right-click an album, artist, or track and choose **Append to Queue** or **Replace Queue**. Appending an album adds its playable tracks in disc and track order. Appending an artist adds their albums in year order. Appending a track adds that track. Replacing starts playback immediately. With a track selected, replacing starts its album at that track, just like double-clicking. Appending also starts playback if Cue is idle.

By default, Albums sorts by artist and then year, Artists by name, and Tracks by title. An artist’s albums sort by year. Opening an album from either tab lists its tracks by disc number and then track number.

Start typing in any table to begin a new search in that view, or press **⌘F** to focus search. Album and track searches include artist names, and track searches also include album titles. Press **↓** to select a result, then **Return** to open or play it. Click any column header to sort and click again to reverse. Drag a column header left or right to reorder it. Use the Columns button beside search, or right-click the tab bar or table header, to choose which columns appear. Cue remembers column order and visibility for each view. Sorting Queue changes the display order and preserves the playback sequence. Click **Year** to browse albums chronologically, including within an artist’s discography. Tracks shows the track number within its album. In Tracks, **Artist** sorts by the credited performer, using the album artist when a track has no separate credit. **Album Artist** sorts by the album-level credit. Click a breadcrumb above the table to return to that level, or press **⌘[** to go back one level. Switching tabs restores the open album or artist, search, sort, selection and scroll position. Back and breadcrumbs restore the parent view the same way. The Library menu offers album sorting and refresh. **Space** toggles playback outside text fields. Once a track is loaded, the macOS media keys and Now Playing controls can play, pause, and skip tracks while Cue is in the background. **⌘←** and **⌘→** control track navigation. The seek bar follows playback. Drag it to change position. The AirPlay picker beside Next selects the audio output. The Playback menu also offers audio output selection and Clear Queue.

To troubleshoot AirPlay, reproduce the issue, then choose **Playback → Copy AirPlay Diagnostics** and paste the report into a text editor or chat. Cue keeps the last 100 diagnostic events for the current launch. The same events appear in Console under subsystem `org.cueplayer.Minimal` and category `AirPlay`. The report records the macOS default audio output type, playback state, picker activity, and error codes.

Choose **Playback → Graphic Equalizer…** (⌘E) and turn on **Enable equalizer**. Ten sliders cover 31 Hz to 16 kHz with ±12 dB per band. The center detent sets a band to zero. Toggle the checkbox to compare with the original, or choose **Reset to Flat** to zero every band. Cue remembers the curve and enable setting. The equalizer starts off on first launch.

The digital filters approximate the [API 560](https://apiaudio.com/product/560-graphic-eq/) proportional-Q response. Small adjustments affect a wider frequency range, and large adjustments narrow the band. The model covers frequency shaping and omits analog amplifier and transformer coloration.

## Memory

The library browser requests 50 rows at a time and asks Plex for the fields needed for each view. Scroll through one continuous list. Cue fetches rows near the viewport and releases distant metadata. Plex handles most library-wide filtering and sorting. The first time you sort Tracks by Artist, Cue reads track metadata in batches of 500 into a temporary SQLite index. Subsequent searches, reversals and tab switches reuse it. Refresh or a library change discards the index. Metadata responses bypass the URL cache. Opening or playing an album loads its track list. AVFoundation creates a player on demand and streams one media part at a time. Clearing the queue releases the player. Hiding or minimizing the window suspends the progress clock while audio continues. The app has no third-party runtime dependencies, cover cache, artwork requests, or visualization renderer.

In the initial text-only release (91be935), three fresh launches of the six-album sample on Apple silicon with macOS 26.5.2 measured 27, 29 and 30 MB of physical footprint. The baseline shelf measured 39, 40 and 40 MB. Measurements used `footprint -p PID` five seconds after launch, with playback stopped and account restoration skipped in the baseline. These figures describe the app process on this machine.

### FLAC playback and scrubbing

**Cue 0.1.6 stayed under 70 MB of app memory in these tests on an 8 GB Apple M1 Mac running macOS 26.5.2.** The highest peak while streaming from Plex was **66.3 MB (63.3 MiB)**. The highest peak across all eight runs was **68.7 MB (65.5 MiB)** while streaming a generated FLAC over local HTTP.

| Stereo FLAC source | Seeks per run | Runs | Peak physical footprint per run (MiB) |
| --- | ---: | ---: | --- |
| Plex, 16-bit / 44.1 kHz | 60 in 30 seconds | 3 | 54.33, 54.46, 54.47 |
| Plex, 24-bit / 96 kHz | 60 in 30 seconds | 3 | 62.50, 63.25, 62.99 |
| Plex, 24-bit / 96 kHz | 240 in 2 minutes | 1 | 61.92 |
| Local HTTP, 16-bit / 44.1 kHz | 60 in 30 seconds | 1 | 65.52 |

Each run started a fresh arm64 Release process built from `b793b7a`. A benchmark startup hook selected the track at zero volume. The album list stayed visible. After eight seconds of direct playback, an external driver dragged the seek bar back and forth across the track, verified each seek, then let playback continue for 20 seconds.

The table reports the macOS kernel’s peak physical footprint for the Cue process. The benchmark sampled memory about every 25 ms and checked the high-water mark with `footprint --noCategories -f bytes -p PID`. The totals exclude WindowServer, system audio services and the Plex server. MB uses decimal units and MiB uses binary units.

### Live library measurements

On an Apple M1 running macOS 26.5.2, a 4,633-album Plex library produced the following results. Each column gives the median of three fresh Release runs. Footprint is the median of repeated macOS `footprint -p PID` samples within each phase. CPU is player-process CPU time divided by wall time, where 100% is one core.

| Activity | Previous footprint | Current footprint | Previous CPU | Current CPU |
| --- | ---: | ---: | ---: | ---: |
| Album list, idle | 33 MB | 33 MB | 0.02% | 0.03% |
| Six track searches | 38 MB | 35 MB | 4.91% | 4.01% |
| Direct playback | 43 MB | 42 MB | 1.06% | 1.46% |
| Same searches during playback | 45 MB | 42 MB | 6.57% | 5.61% |

The benchmark drove the AppKit search handler with successive prefixes of six terms, waited for each result page, and played the same remote track at zero volume. The playback-only phase sampled ten seconds after the clock had advanced. The comparison used builds `91be935` (100 rows per request) and `caf233e` (50 rows per request). Match totals were identical. Across the six searches the decoded HTTP response bodies fell from 818,952 to 109,862 bytes. These figures cover the client process and exclude server CPU and system audio services.

## Build and run

In Xcode 26 or later, open `Cue.xcodeproj`, choose the **Cue** scheme and **My Mac**, and press **⌘R**. From the project directory:

```sh
xcodebuild -project Cue.xcodeproj -scheme Cue -configuration Release -derivedDataPath .build build
open ".build/Build/Products/Release/Cue.app"
```

## Verify

```sh
xcodebuild -project Cue.xcodeproj -scheme Cue -derivedDataPath .build -destination 'platform=macOS' -parallel-testing-enabled NO test
```

The tests use a URLProtocol fixture for Plex and AVFoundation for local playback. They cover sign-in, connection fallback, paging, search, XML fallback, track ordering, authenticated URLs, seeking and automatic advance. A synthetic million-artist catalog exercises random access and a partial final batch. AppKit tests scroll through a 100,003-album search result and check the footer slider during playback, pause, and seeking. Live playback requires a reachable Plex server and an audio format macOS can direct-play.

The `utility-player-baseline` Git tag marks the original player.
