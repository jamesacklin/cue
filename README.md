# Cue

Cue is a native Plex music player for macOS 14 and later. Browse albums, artists, and tracks in a text-based library, then play music directly from your Plex Media Server.

Download the ZIP from [GitHub Releases](https://github.com/jamesacklin/cue/releases/latest), unzip it, and move Cue to Applications. The guide below describes the current source checkout. Each release has notes for its published build.

## Connect and play

Choose **Connect to Plex…** in the toolbar, sign in through your browser, and select a server and music library. Cue saves your account token in Keychain and remembers your library. Click the server name to change libraries or sign out.

In the library, double-click an album to open it or a track to play its album from that track. To add music while something else is playing, right-click an album, artist, or track and choose **Append to Queue**. **Replace Queue** starts the new selection immediately.

## Browse and manage the queue

- Type in the table or press **⌘F** to search the current view. Press **↓** to select a result and **Return** to open or play it.
- Right-click a track to jump to its album or credited artist. An album’s menu links to its artist’s albums, and an artist’s menu links to their tracks. Press **⌘[** to go back.
- Click a column heading to sort, drag headings to reorder them, or use **View → Columns** to choose which appear. **⌘1** through **⌘4** switch between Albums, Artists, Tracks, and Queue.
- In Queue, finished tracks drop off. Skipped tracks stay available. Command-click to select individual entries or Shift-click to select a range. Drag to change playback order, or press Delete to remove the selection. Sorting the table changes only the displayed order.

## Playback

Press **Space** with the table focused to play or pause. Use the transport to seek, adjust volume, or choose an AirPlay output. Media keys and macOS Now Playing also control playback. The ten-band equalizer is under **Playback → Graphic Equalizer**.

Closing the window keeps Cue in the Dock and lets the queue continue playing. Click Cue’s Dock icon or choose **Window → Show Player** to reopen it. **⌘Q** quits Cue.

If the connection drops and playback stops, press **Play** after reconnecting to retry from your last position. If Plex asks you to sign in again, reconnect to the same library to keep your queue. Cue skips files the server reports as missing.

For an output problem, choose **Playback → Copy AirPlay Diagnostics** after reproducing it. The report includes recent playback and output events from this launch.

## Build and test

Open the checked-in `Cue.xcodeproj` in Xcode 26 or later. Choose the **Cue** scheme and **My Mac**, then press **⌘R**. To build a Release app from the command line, run the following in the project directory.

```sh
xcodebuild -project Cue.xcodeproj -scheme Cue -configuration Release -derivedDataPath .build build
open ".build/Build/Products/Release/Cue.app"
```

Run the tests with the fixture Plex responses and bundled audio file.

```sh
xcodebuild -project Cue.xcodeproj -scheme Cue -derivedDataPath .build -destination 'platform=macOS' -parallel-testing-enabled NO test
```
