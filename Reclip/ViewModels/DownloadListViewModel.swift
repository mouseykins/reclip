import Foundation
import AppKit

@Observable
class DownloadListViewModel {
    var currentItem: VideoItem?
    var outputFormat: DownloadFormat = .mp4
    var destinationFolder: URL
    var urlText: String = ""
    var isFetching = false

    private let service = YTDLPService()

    init() {
        let moviesDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        destinationFolder = moviesDir.appendingPathComponent("Reclip")
    }

    private func ensureDestinationExists() {
        try? FileManager.default.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
    }

    // MARK: - Fetch

    func fetchVideo() async {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return }

        let item = VideoItem(url: url)
        currentItem = item
        isFetching = true

        await MainActor.run { item.status = .fetching }

        do {
            let info = try await service.fetchInfo(url: item.originalURL)

            var thumbImage: NSImage?
            if let thumbURL = info.thumbnailURL {
                if let (data, _) = try? await URLSession.shared.data(from: thumbURL) {
                    thumbImage = NSImage(data: data)
                }
            }

            await MainActor.run {
                item.title = info.title
                item.thumbnailURL = info.thumbnailURL
                item.thumbnailImage = thumbImage
                item.duration = info.duration
                item.durationSeconds = info.durationSeconds
                item.availableQualities = info.qualities
                item.selectedQuality = info.qualities.first
                item.clipStart = 0
                item.clipEnd = info.durationSeconds
                item.status = .ready
            }

            // Download low-res preview for native player scrubbing (runs after metadata is shown)
            await MainActor.run { item.isLoadingPreview = true }
            do {
                let previewURL = try await service.downloadPreview(url: item.originalURL)
                await MainActor.run {
                    item.previewFileURL = previewURL
                    item.isLoadingPreview = false
                }
            } catch {
                await MainActor.run {
                    item.previewError = error.localizedDescription
                    item.isLoadingPreview = false
                }
            }
        } catch {
            await MainActor.run {
                item.status = .failed(error: error.localizedDescription)
            }
        }

        isFetching = false
    }

    func clear() {
        currentItem = nil
        urlText = ""
    }

    // MARK: - Download

    func downloadFull() async {
        guard let item = currentItem, item.isReady else { return }
        item.useClip = false
        await download(item: item)
    }

    func downloadClip() async {
        guard let item = currentItem, item.isReady else { return }
        item.useClip = true
        await download(item: item)
    }

    private func download(item: VideoItem) async {
        ensureDestinationExists()

        await MainActor.run {
            item.status = .downloading(progress: 0)
        }

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
            await MainActor.run {
                switch event {
                case .progress(let percent, _, _):
                    item.status = .downloading(progress: percent)
                case .completed(let fileURL):
                    if let fileURL {
                        item.recentDownloads.append(fileURL)
                    }
                    item.lastDownloadError = nil
                    item.status = .ready  // return to ready so more downloads can be started
                case .failed(let error):
                    item.lastDownloadError = error
                    item.status = .ready  // still allow retry / other downloads
                }
            }
        }
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
