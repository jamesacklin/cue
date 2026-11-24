# Sleeve

Sleeve is a native macOS music player for Plex, built with SwiftUI and AVFoundation. It opens on the album shelf. The Library sidebar lists Albums, Artists, and Transit Map in that order. On the 3D transit map, newer releases sit at the bottom. The map lays out the whole selected collection at once. Overview fits every matching album as a selectable stop. Click a stop to highlight its artist route and inspect the album in the upper right. Sleeve loads covers near the camera and highlights the selected artist’s route across the collection. Each year branches into horizontal imprint lanes. Artist lines connect credits using the Plex artist ID when available. Click an imprint name along the top of the map to follow its releases through the decades. Zooming exposes more imprint names as their lanes spread apart. Shared artist credits bring imprint lanes together, especially when the artist appears on only a few labels. Sleeve learns genre neighborhoods once per library load using spherical k-means over the genres and styles of each imprint’s releases. Sleeve requests missing tags in batches from Plex. When a release lacks its own tags, its album artist’s genres and styles contribute half a vote. Each directly tagged album contributes one vote split across its distinct tags. Tags found on fewer imprints receive more weight, and each imprint profile is normalized. Deterministic farthest-first seeding starts up to 18 clusters, with the target scaled to the number of tagged imprints. Within a neighborhood, catalogue similarity guides the lane order, and shared-artist bridges can cross neighborhood boundaries. The album inspector lists the strongest tags of its imprint’s cluster. Untagged imprints keep their artist connections and have no genre assignment. Imprints come from the album studio field. To place albums on a scene depth plane, give them a Plex album collection such as `Scene: Detroit techno`. If several scene collections apply, the first alphabetically sets depth and the inspector lists them all. Missing metadata has an unknown lane or an unassigned plane. The sample albums use fictional imprints and scenes. The map stays face-on, with distant sleeves appearing smaller. Click a sleeve to inspect it in place, drag to pan, or press Escape with the map focused to regain an overview. Scroll the wheel or pinch to zoom around the pointer. Click and drag to pan. The arrow keys and station buttons move between albums. Follow artist condenses the map to that artist’s releases, closing gaps between their years and imprints. Overview fits the discography. In a zoomed view, the selected album anchors the layout as the filter changes. Use the decade menu to filter by release year. An album selected outside the visible decade is remembered when you return to it. Double-click a stop to start playing its album while browsing the map. Choose Open album for the track list. Albums opens the flat cover shelf. The transport stays available as you move through the library.

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
