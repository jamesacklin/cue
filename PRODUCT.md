# Product

## Platform and purpose

A native macOS client written in Swift for listening to a Plex music library. Music is the user's priority for the first draft.

## First-draft plan

1. Connect through Plex's browser sign-in. Discover available servers and let the listener choose a music library. Store reusable credentials in the macOS Keychain.
2. Browse the album collection, search by album or artist, and open a record to see its tracks in disc order.
3. Direct-play music through AVFoundation with a persistent transport, seeking, volume, and an album queue.
4. Include a playable sample library for first launch. Verify Plex response handling with fixtures and exercise the native app on macOS.

The first draft targets macOS 14 and later. Server-side transcoding and offline downloads are outside this iteration.
