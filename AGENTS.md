# Cue

Use the checked-in Xcode project and the Cue scheme. Build and test commands are in README.md. Run `xcodegen generate` after adding or removing source files or bundled resources, or after changing project.yml.

- LibraryWindow.swift owns AppKit navigation, the reusable table, keyboard search and lazy loading. The active tab and search determine which rows to request. Cancel stale requests before applying UI changes.
- LibraryStore.swift manages sign-in, server and music section selection, restoration and playback requests. Validate the first page before switching libraries. Clear the queue on a library change.
- PlexClient.swift handles browser PIN sign-in, endpoint fallback, metadata queries and direct-play URLs. Keep tokens out of logs. Credentials.swift stores the account token in Keychain.
- Player.swift owns the on-demand AVPlayer and queue. ListeningViews.swift contains the transport and system output picker. Music.swift defines catalog models and the bounded row cache.
- Use fixture tests for network behavior and the test bundle’s audio fixture for playback. For footprint comparisons, measure Release builds in the same library and playback state with the macOS footprint tool.
