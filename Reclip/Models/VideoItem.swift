import Foundation
import AppKit

enum VideoStatus: Equatable {
    case pending
    case fetching
    case ready
    case downloading(progress: Double)
    case failed(error: String)
}

@Observable
class VideoItem: Identifiable {
    let id = UUID()
    let originalURL: String
    var status: VideoStatus = .pending
    var title: String?
    var thumbnailURL: URL?
    var thumbnailImage: NSImage?
    var duration: String?
    var durationSeconds: Double = 0
    var availableQualities: [VideoQuality] = []
    var selectedQuality: VideoQuality?

    // Local preview file for native player scrubbing
    var previewFileURL: URL?
    var previewError: String?
    var isLoadingPreview: Bool = false

    // Clip selection
    var clipStart: Double = 0
    var clipEnd: Double = 0
    var useClip: Bool = false

    // Completed downloads for this session (full + any clips)
    var recentDownloads: [URL] = []
    var lastDownloadError: String?

    // Live download stats (from yt-dlp progress output)
    var downloadSpeed: String = ""
    var downloadETA: String = ""

    init(url: String) {
        self.originalURL = url
    }

    var sourceDomain: String {
        URL(string: originalURL)?.host ?? ""
    }

    var isReady: Bool {
        if case .ready = status { return true }
        return false
    }

    var isDownloading: Bool {
        if case .downloading = status { return true }
        return false
    }

    static func formatTime(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}
