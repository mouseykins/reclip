import SwiftUI
import AVKit
import AVFoundation

class VideoPlayerController: ObservableObject {
    private(set) var player: AVPlayer?
    private var isSeeking = false
    private var pendingSeekTime: CMTime?
    private var currentFileURL: URL?

    func loadFile(_ fileURL: URL) {
        guard fileURL != currentFileURL else { return }
        currentFileURL = fileURL

        let playerItem = AVPlayerItem(url: fileURL)
        if let existing = player {
            existing.replaceCurrentItem(with: playerItem)
        } else {
            player = AVPlayer(playerItem: playerItem)
        }
        player?.allowsExternalPlayback = false
    }

    /// Seek using Apple's "chase time" pattern for smooth scrubbing.
    /// Pauses playback and seeks frame-accurately.
    func seekTo(_ seconds: Double) {
        guard let player else { return }

        player.pause()

        let targetTime = CMTime(seconds: seconds, preferredTimescale: 600)

        if isSeeking {
            // Already seeking — queue this one up
            pendingSeekTime = targetTime
            return
        }

        performSeek(to: targetTime)
    }

    private func performSeek(to time: CMTime) {
        guard let player else { return }
        isSeeking = true

        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if let pending = self.pendingSeekTime {
                    self.pendingSeekTime = nil
                    self.performSeek(to: pending)
                } else {
                    self.isSeeking = false
                }
            }
        }
    }

    func pause() {
        player?.pause()
    }

    func play() {
        player?.play()
    }
}

struct VideoEmbedView: NSViewRepresentable {
    let fileURL: URL
    let controller: VideoPlayerController

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true

        controller.loadFile(fileURL)
        playerView.player = controller.player

        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        controller.loadFile(fileURL)
        playerView.player = controller.player
    }
}
