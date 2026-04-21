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
    var youtubeVideoID: String?

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

    init(url: String) {
        self.originalURL = url
        self.youtubeVideoID = VideoItem.extractYouTubeID(from: url)
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

    var isCompleted: Bool {
        !recentDownloads.isEmpty
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

    // MARK: - YouTube ID extraction

    static func extractYouTubeID(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let host = url.host?.lowercased() ?? ""

        guard host.contains("youtube.com") || host.contains("youtu.be") else {
            return nil
        }

        // youtu.be/ID
        if host.contains("youtu.be") {
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }

        // youtube.com/watch?v=ID
        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let v = components.queryItems?.first(where: { $0.name == "v" })?.value {
            return v
        }

        // youtube.com/shorts/ID or youtube.com/embed/ID
        let pathComponents = url.pathComponents
        if pathComponents.count >= 3 &&
            (pathComponents[1] == "shorts" || pathComponents[1] == "embed") {
            return pathComponents[2]
        }

        return nil
    }
}
