# Sleeve

Sleeve is a native macOS music player for Plex, built with SwiftUI and AVFoundation. It opens on a shelf of album covers. Select an album to see its tracks, or open Artists to browse a discography. The transport stays available as you move through the library.

## Run

Open `Sleeve.xcodeproj` in Xcode, choose the **Sleeve** scheme and **My Mac**, then press **⌘R**. The app targets macOS 14 or later. The generated Xcode project is included and has no package dependencies. Regenerate it with `xcodegen generate` after changing `project.yml` or adding or removing source files or resources.

To build and launch from the terminal on a Mac with Xcode installed, run the following commands from the project directory.

```sh
xcodebuild -project Sleeve.xcodeproj -scheme Sleeve -configuration Release -derivedDataPath .build build
open .build/Build/Products/Release/Sleeve.app
```

## Listen

The sample library contains six fictional albums with original sleeve artwork and twelve short synthesized instrumentals. Open a cover and choose **Play Album**, or click a track to start there. Space toggles playback, ⌘← and ⌘→ move between tracks, and ⌘F focuses library search.

Choose **Connect to Plex…** at the foot of the sidebar to open Plex sign-in in your browser. After authorizing Sleeve, return to the app, select a server, and choose a music library. Sleeve saves the account token in the login keychain and restores your server and library selection on launch. **Sign Out** removes the saved credential and restores the sample collection.

The player uses secure server connections, including Plex Relay when available. Music streams directly from the selected media part in formats AVFoundation can decode. Artwork comes from Plex. This draft does not transcode audio, download tracks for offline use, or report listening history to Plex.

## Verify

```sh
xcodebuild -project Sleeve.xcodeproj -scheme Sleeve -derivedDataPath .build -destination 'platform=macOS' -parallel-testing-enabled NO test
```

The tests exercise sign-in and server discovery with fixture responses, connection fallback, paginated album reads, multi-disc track ordering, and authenticated stream addresses. Playback tests load the bundled audio through AVFoundation and check seeking and automatic track advance.

The first-draft scope is recorded in [PRODUCT.md](PRODUCT.md). Plex API behavior follows the [Plex Media Server developer reference](https://developer.plex.tv/pms/).

For implementation details, the verification baseline, and the next live-server check, read the [agent handoff](AGENTS.md).
