import Foundation
import AppKit

@MainActor
@Observable
class DownloadListViewModel {
    var currentItem: VideoItem?
    var outputFormat: DownloadFormat = .mp4
    var destinationFolder: URL
    var urlText: String = ""
    var isFetching = false

    private let service = YTDLPService()
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    init() {
        let moviesDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        destinationFolder = moviesDir.appendingPathComponent("Reclip")
        // Sweep preview files left over from earlier sessions.
        Task.detached { YTDLPService.cleanUpPreviewDirectory() }
    }

    private func ensureDestinationExists() {
        try? FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
    }

    // MARK: - Fetch

    func fetchVideo() async {
        guard !isFetching else { return }
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return }

        discardPreview(of: currentItem)

        let item = VideoItem(url: url)
        currentItem = item
        isFetching = true
        item.status = .fetching

        let info: VideoInfo
        do {
            info = try await service.fetchInfo(url: item.originalURL)
        } catch {
            item.status = .failed(error: error.localizedDescription)
            isFetching = false
            return
        }

        item.title = info.title
        item.thumbnailURL = info.thumbnailURL
        item.duration = info.duration
        item.durationSeconds = info.durationSeconds
        item.availableQualities = info.qualities
        item.selectedQuality = info.qualities.first
        item.clipStart = 0
        item.clipEnd = info.durationSeconds
        item.status = .ready
        // Metadata is in — release the Fetch button while the thumbnail and
        // preview continue loading below.
        isFetching = false

        item.isLoadingPreview = true
        async let thumbnail: Void = loadThumbnail(for: item, from: info.thumbnailURL)
        async let preview: Void = loadPreview(for: item)
        _ = await (thumbnail, preview)
    }

    private func loadThumbnail(for item: VideoItem, from url: URL?) async {
        guard let url,
              let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        item.thumbnailImage = NSImage(data: data)
    }

    private func loadPreview(for item: VideoItem) async {
        do {
            let previewURL = try await service.downloadPreview(url: item.originalURL)
            if currentItem === item {
                item.previewFileURL = previewURL
            } else {
                // The user fetched a different video while this downloaded.
                try? FileManager.default.removeItem(at: previewURL)
            }
        } catch {
            item.previewError = error.localizedDescription
        }
        item.isLoadingPreview = false
    }

    private func discardPreview(of item: VideoItem?) {
        guard let item, let url = item.previewFileURL else { return }
        try? FileManager.default.removeItem(at: url)
        item.previewFileURL = nil
    }

    func clear() {
        discardPreview(of: currentItem)
        currentItem = nil
        urlText = ""
    }

    // MARK: - Download

    func downloadFull() {
        startDownload(asClip: false)
    }

    func downloadClip() {
        startDownload(asClip: true)
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    private func startDownload(asClip: Bool) {
        guard let item = currentItem, item.isReady, downloadTask == nil else { return }
        item.useClip = asClip
        downloadTask = Task {
            await download(item: item)
            downloadTask = nil
        }
    }

    private func download(item: VideoItem) async {
        ensureDestinationExists()

        item.status = .downloading(progress: 0)
        item.downloadSpeed = ""
        item.downloadETA = ""

        let quality = outputFormat == .mp4 ? item.selectedQuality : nil

        var clipRange: (start: Double, end: Double)?
        if item.useClip {
            clipRange = (start: item.clipStart, end: item.clipEnd)
        }

        let stream = service.download(
            url: item.originalURL,
            quality: quality,
            outputDir: destinationFolder,
            format: outputFormat,
            clipRange: clipRange
        )

        for await event in stream {
            switch event {
            case .progress(let percent, let speed, let eta):
                item.status = .downloading(progress: percent)
                item.downloadSpeed = speed
                item.downloadETA = eta
            case .completed(let fileURL):
                if let fileURL {
                    item.recentDownloads.append(fileURL)
                }
                item.lastDownloadError = nil
            case .failed(let error):
                item.lastDownloadError = error
            }
        }

        if Task.isCancelled {
            item.lastDownloadError = nil
        }
        item.status = .ready  // return to ready so more downloads can be started
    }

    // MARK: - Folder Picker

    func pickDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = destinationFolder
        panel.prompt = "Choose"
        panel.message = "Select download destination folder"

        if panel.runModal() == .OK, let url = panel.url {
            destinationFolder = url
        }
    }
}
