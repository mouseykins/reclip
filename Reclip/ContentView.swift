import SwiftUI

struct ContentView: View {
    @State private var viewModel = DownloadListViewModel()
    @StateObject private var playerController = VideoPlayerController()
    @State private var console = ConsoleLog.shared
    @State private var deps = DependencyCheck.shared
    @State private var isConsoleExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            if !deps.allRequiredInstalled {
                SetupView(deps: deps)
            } else {
                mainUI
            }

            Divider()

            // Console is always visible (useful during setup too)
            ConsoleView(log: console, isExpanded: $isConsoleExpanded)
        }
        .frame(minWidth: 700, minHeight: 500)
    }

    private var mainUI: some View {
        VStack(spacing: 0) {
            // URL input bar
            urlBar
            Divider()

            // Main content
            if let item = viewModel.currentItem {
                videoDetail(item: item)
            } else {
                emptyState
            }

            Divider()

            // Bottom toolbar
            bottomBar
        }
    }

    // MARK: - URL Bar

    private var urlBar: some View {
        HStack(spacing: 8) {
            TextField("Paste a video URL...", text: $viewModel.urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { fetch() }

            Button("Fetch") { fetch() }
                .disabled(viewModel.urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isFetching)
                .keyboardShortcut(.return, modifiers: .command)

            if viewModel.isFetching {
                ProgressView()
                    .scaleEffect(0.6)
            }

            Picker("Format", selection: $viewModel.outputFormat) {
                ForEach(DownloadFormat.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
        }
        .padding()
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Reclip", systemImage: "arrow.down.circle")
        } description: {
            Text("Paste a video URL above and click Fetch to preview and download.")
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Video Detail

    private func videoDetail(item: VideoItem) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                // Native video player or thumbnail/loading fallback
                if let previewURL = item.previewFileURL {
                    VideoEmbedView(fileURL: previewURL, controller: playerController)
                        .frame(height: 340)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if let image = item.thumbnailImage {
                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()

                        if item.isLoadingPreview {
                            // Preview is downloading — show spinner over thumbnail
                            VStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Loading preview…")
                                    .font(.caption)
                                    .foregroundStyle(.white)
                            }
                            .padding(12)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        } else if let err = item.previewError {
                            VStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                Text("Preview unavailable")
                                    .font(.caption).bold()
                                    .foregroundStyle(.white)
                                Text(err)
                                    .font(.caption2)
                                    .foregroundStyle(.white.opacity(0.8))
                                    .lineLimit(3)
                                    .multilineTextAlignment(.center)
                                    .textSelection(.enabled)
                            }
                            .padding(12)
                            .frame(maxWidth: 360)
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .frame(maxHeight: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Video info row
                if item.title != nil {
                    videoInfoRow(item: item)
                }

                // Clip range selector — visible whenever metadata is loaded,
                // so the user can kick off more downloads after one completes
                if item.durationSeconds > 0 && item.title != nil {
                    clipSelector(item: item)
                }

                // Recent downloads banner (this session)
                if !item.recentDownloads.isEmpty {
                    recentDownloadsView(item: item)
                }

                // Last download error, if any
                if let err = item.lastDownloadError {
                    downloadErrorBanner(message: err, item: item)
                }

                // In-flight status (fetching / downloading / fetch-failed)
                statusView(item: item)
            }
            .padding()
        }
        .frame(maxHeight: .infinity)
    }

    private func videoInfoRow(item: VideoItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title ?? "")
                    .font(.headline)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    Text(item.sourceDomain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let duration = item.duration {
                        Text(duration)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if item.isReady && viewModel.outputFormat == .mp4 && !item.availableQualities.isEmpty {
                Picker("Quality", selection: Binding(
                    get: { item.selectedQuality ?? item.availableQualities.first! },
                    set: { item.selectedQuality = $0 }
                )) {
                    ForEach(item.availableQualities) { quality in
                        Text(quality.displayLabel).tag(quality)
                    }
                }
                .labelsHidden()
                .frame(width: 150)
            }
        }
    }

    // MARK: - Clip Selector

    private func clipSelector(item: VideoItem) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text("Clip Selection")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            RangeSliderView(
                start: Binding(
                    get: { item.clipStart },
                    set: { item.clipStart = $0 }
                ),
                end: Binding(
                    get: { item.clipEnd },
                    set: { item.clipEnd = $0 }
                ),
                range: 0...item.durationSeconds,
                onSeek: { seconds in
                    playerController.pause()
                    playerController.seekTo(seconds)
                }
            )

            HStack {
                Text(VideoItem.formatTime(item.clipStart))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                let clipDuration = item.clipEnd - item.clipStart
                if clipDuration < item.durationSeconds {
                    Text("Selected: \(VideoItem.formatTime(clipDuration))")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }

                Spacer()

                Text(VideoItem.formatTime(item.clipEnd))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Download buttons
            HStack(spacing: 12) {
                Button {
                    viewModel.downloadFull()
                } label: {
                    Label("Download Full", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(.bordered)
                .disabled(item.isDownloading)
                .keyboardShortcut("d", modifiers: .command)

                let isClipped = item.clipStart > 0 || item.clipEnd < item.durationSeconds
                Button {
                    viewModel.downloadClip()
                } label: {
                    Label(
                        "Download Clip (\(VideoItem.formatTime(item.clipStart)) — \(VideoItem.formatTime(item.clipEnd)))",
                        systemImage: "scissors"
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isClipped || item.isDownloading)
                .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            .padding(.top, 4)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }

    // MARK: - Recent Downloads

    private func recentDownloadsView(item: VideoItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Downloaded this session")
                    .font(.subheadline).bold()
                Spacer()
                Button("Clear list") {
                    item.recentDownloads.removeAll()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            ForEach(item.recentDownloads, id: \.self) { fileURL in
                HStack(spacing: 8) {
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                    Text(fileURL.lastPathComponent)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 8).fill(.green.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.green.opacity(0.3), lineWidth: 1)
        )
    }

    private func downloadErrorBanner(message: String, item: VideoItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("Last download failed")
                    .font(.caption).bold()
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Dismiss") {
                item.lastDownloadError = nil
            }
            .controlSize(.small)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 8).fill(.red.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.red.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Status

    @ViewBuilder
    private func statusView(item: VideoItem) -> some View {
        switch item.status {
        case .fetching:
            HStack {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Fetching video info...")
                    .foregroundStyle(.secondary)
            }

        case .downloading(let progress):
            HStack(spacing: 10) {
                if progress >= 100 {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Repackaging for QuickTime...")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView(value: min(max(progress, 0), 100), total: 100)
                        .frame(maxWidth: 240)
                    Text(String(format: "%.0f%%", progress))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if !item.downloadSpeed.isEmpty {
                        Text(item.downloadSpeed)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if !item.downloadETA.isEmpty {
                        Text("ETA \(item.downloadETA)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Button("Cancel") {
                        viewModel.cancelDownload()
                    }
                    .controlSize(.small)
                }
            }

        case .failed(let error):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)

                Button("Retry") {
                    Task { await viewModel.fetchVideo() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("Clear") {
                    clear()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

        default:
            EmptyView()
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
            Text(viewModel.destinationFolder.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 200, alignment: .leading)
            Button("Change...") {
                viewModel.pickDestinationFolder()
            }
            .controlSize(.small)

            Button {
                NSWorkspace.shared.open(viewModel.destinationFolder)
            } label: {
                Image(systemName: "arrow.right.circle")
            }
            .buttonStyle(.borderless)
            .help("Open in Finder")

            Spacer()
        }
        .padding()
        .background(.bar)
    }

    // MARK: - Actions

    private func fetch() {
        // Stop the old preview's audio before its view is replaced.
        playerController.pause()
        Task { await viewModel.fetchVideo() }
    }

    private func clear() {
        playerController.pause()
        viewModel.clear()
    }
}
