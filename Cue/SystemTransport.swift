import MediaPlayer

/// macOS extrapolates elapsed time from the last position and rate.
@MainActor
final class SystemTransport {
    private weak var player: Player?
    private let center = MPRemoteCommandCenter.shared()
    private let info = MPNowPlayingInfoCenter.default()
    private var handlers: [(MPRemoteCommand, Any)] = []

    init(player: Player) {
        self.player = player
        bind(center.playCommand) { player, _ in player.resume(); return .success }
        bind(center.pauseCommand) { player, _ in player.pause(); return .success }
        bind(center.togglePlayPauseCommand) { player, _ in player.toggle(); return .success }
        bind(center.previousTrackCommand) { player, _ in player.previous(); return .success }
        bind(center.nextTrackCommand) { player, _ in
            guard player.hasNext else { return .noSuchContent }
            player.next()
            return .success
        }
        bind(center.changePlaybackPositionCommand) { player, event in
            guard let seek = event as? MPChangePlaybackPositionCommandEvent, player.length > 0 else { return .commandFailed }
            player.seek(to: seek.positionTime)
            return .success
        }
    }

    private func bind(_ command: MPRemoteCommand, action: @escaping @MainActor (Player, MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        let token = command.addTarget { [weak player] event in
            let perform: @MainActor () -> MPRemoteCommandHandlerStatus = {
                guard let player, player.current != nil else { return .noSuchContent }
                return action(player, event)
            }
            if Thread.isMainThread { return MainActor.assumeIsolated { perform() } }
            return DispatchQueue.main.sync { perform() }
        }
        command.isEnabled = true
        handlers.append((command, token))
    }

    func update(position: Double, rate: Double) {
        guard let player, let entry = player.current else { return }
        center.nextTrackCommand.isEnabled = player.hasNext
        center.changePlaybackPositionCommand.isEnabled = player.length > 0
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: entry.track.title,
            MPMediaItemPropertyArtist: entry.track.artist,
            MPMediaItemPropertyAlbumTitle: entry.album.title,
            MPMediaItemPropertyPlaybackDuration: player.length,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue
        ]
        info.playbackState = rate > 0 ? .playing : .paused
    }

    deinit {
        for (command, token) in handlers {
            command.removeTarget(token)
            command.isEnabled = false
        }
        info.playbackState = .stopped
        info.nowPlayingInfo = nil
    }
}
