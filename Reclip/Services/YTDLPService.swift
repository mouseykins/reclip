import Foundation

enum DownloadEvent {
    case progress(percent: Double, speed: String, eta: String)
    case completed(fileURL: URL?)
    case failed(error: String)
}

struct VideoInfo {
    let title: String
    let thumbnailURL: URL?
    let duration: String?
    let durationSeconds: Double
    let qualities: [VideoQuality]
}

struct YTDLPService {
    private let ytdlpPath: String
    private let ffmpegPath: String
    private let log = ConsoleLog.shared

    /// Marker prepended to progress lines so they can be told apart from other
    /// yt-dlp output. yt-dlp consumes a leading "download:" in the template as
    /// a template-type selector, so the printed line starts with this marker.
    static let progressMarker = "RECLIP_PROGRESS|"

    /// Environment for subprocesses: ensures yt-dlp can find ffmpeg, deno, and other brew binaries
    /// when the app is launched from Finder (where PATH is normally just /usr/bin:/bin).
    private var subprocessEnv: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let brewBinDirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        let existing = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (brewBinDirs + [existing]).joined(separator: ":")
        return env
    }

    /// Log an external command in a shell-pasteable form.
    private func logCommand(_ path: String, _ args: [String]) {
        let quoted = args.map { arg -> String in
            if arg.contains(" ") || arg.contains("\"") || arg.contains("*") {
                return "\"\(arg.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
            return arg
        }
        log.log("\(path) \(quoted.joined(separator: " "))", level: .command)
    }

    init() {
        // Prefer homebrew installs (kept current via `brew upgrade`) over older
        // /usr/local/bin copies that may be stale.
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/yt-dlp") {
            ytdlpPath = "/opt/homebrew/bin/yt-dlp"
        } else if FileManager.default.fileExists(atPath: "/usr/local/bin/yt-dlp") {
            ytdlpPath = "/usr/local/bin/yt-dlp"
        } else {
            ytdlpPath = "yt-dlp"
        }

        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/ffmpeg") {
            ffmpegPath = "/opt/homebrew/bin/ffmpeg"
        } else if FileManager.default.fileExists(atPath: "/usr/local/bin/ffmpeg") {
            ffmpegPath = "/usr/local/bin/ffmpeg"
        } else {
            ffmpegPath = "ffmpeg"
        }
    }

    private func makeProcess(_ path: String) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.environment = subprocessEnv
        return process
    }

    /// Extracts yt-dlp ERROR lines from stderr, falling back to a generic message.
    func errorSummary(from stderr: String, fallback: String) -> String {
        let errorLines = stderr.components(separatedBy: "\n").filter { $0.contains("ERROR") }
        return errorLines.isEmpty ? fallback : errorLines.joined(separator: "\n")
    }

    // MARK: - Fetch Metadata

    func fetchInfo(url: String) async throws -> VideoInfo {
        log.log("Fetching metadata for \(url)", level: .info)
        let process = makeProcess(ytdlpPath)
        let args = ["--dump-json", "--no-download", "--no-playlist", url]
        process.arguments = args
        logCommand(ytdlpPath, args)

        let result = try await runProcess(process)
        guard result.status == 0 else {
            let msg = errorSummary(from: result.stderr, fallback: "yt-dlp failed (exit code \(result.status))")
            log.log(msg, level: .error)
            throw YTDLPError.fetchFailed(msg)
        }
        log.log("Metadata fetched successfully", level: .success)

        guard let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw YTDLPError.parseFailed
        }

        return VideoInfo(
            title: json["title"] as? String ?? "Unknown",
            thumbnailURL: (json["thumbnail"] as? String).flatMap { URL(string: $0) },
            duration: json["duration_string"] as? String,
            durationSeconds: json["duration"] as? Double ?? 0,
            qualities: parseQualities(from: json)
        )
    }

    func parseQualities(from json: [String: Any]) -> [VideoQuality] {
        guard let formats = json["formats"] as? [[String: Any]] else { return [] }

        var qualities: [VideoQuality] = []

        let videoFormats = formats.filter { format in
            let vcodec = format["vcodec"] as? String ?? "none"
            return vcodec != "none" && format["height"] != nil
        }

        var byResolution: [Int: [[String: Any]]] = [:]
        for format in videoFormats {
            guard let height = format["height"] as? Int, height > 0 else { continue }
            byResolution[height, default: []].append(format)
        }

        for height in byResolution.keys.sorted(by: >) {
            let candidates = byResolution[height]!

            let preferred = candidates.first { format in
                let vcodec = format["vcodec"] as? String ?? ""
                return vcodec.hasPrefix("avc1") || vcodec.hasPrefix("h264")
            } ?? candidates.first

            guard let format = preferred,
                  let formatId = format["format_id"] as? String else { continue }

            let ext = format["ext"] as? String ?? "mp4"
            let filesize = format["filesize"] as? Int ?? format["filesize_approx"] as? Int
            let codec = format["vcodec"] as? String ?? ""

            qualities.append(VideoQuality(
                id: formatId,
                resolution: "\(height)p",
                ext: ext,
                filesize: filesize,
                codec: codec,
                description: "\(height)p"
            ))
        }

        return qualities
    }

    // MARK: - Download Preview

    static var previewDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ReclipPreviews")
    }

    /// Removes preview files left over from previous sessions.
    static func cleanUpPreviewDirectory() {
        try? FileManager.default.removeItem(at: previewDirectory)
    }

    /// Downloads a low-res (360p) preview copy for native AVPlayer scrubbing.
    /// Returns the local file URL of the downloaded preview.
    func downloadPreview(url: String) async throws -> URL {
        let previewDir = Self.previewDirectory
        try? FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)

        let uuid = UUID().uuidString
        let outputTemplate = previewDir.appendingPathComponent("\(uuid).%(ext)s").path

        let process = makeProcess(ytdlpPath)
        let args = [
            // Strictly prefer h264/avc1 (AVPlayer-compatible). Format 18 is universally
            // available muxed 360p h264+aac mp4. Fall back to merged avc1 video + m4a audio.
            "-f", "18/best[height<=360][ext=mp4][vcodec^=avc1]/bestvideo[height<=480][vcodec^=avc1]+bestaudio[ext=m4a]/bestvideo[height<=720][vcodec^=avc1]+bestaudio[ext=m4a]/best[ext=mp4][vcodec^=avc1]/best",
            "--merge-output-format", "mp4",
            "--ffmpeg-location", ffmpegPath,
            "-o", outputTemplate,
            "--no-playlist",
            "--no-warnings",
            url
        ]
        process.arguments = args

        log.log("Downloading 360p preview for scrubbing", level: .info)
        logCommand(ytdlpPath, args)

        let console = log
        let result = try await runProcess(
            process,
            onStdoutLine: { line in
                // Skip progress spam but surface destination/merge lines
                if line.contains("[download]") && line.contains("%") { return }
                console.log(line, level: .info)
            },
            onStderrLine: { line in
                let level: LogLevel = line.contains("ERROR") ? .error : (line.contains("WARNING") ? .warning : .info)
                console.log(line, level: level)
            }
        )

        guard result.status == 0 else {
            let msg = errorSummary(from: result.stderr, fallback: "Preview download failed (exit \(result.status))")
            log.log("Preview download failed: \(msg)", level: .error)
            throw YTDLPError.fetchFailed(msg)
        }

        // Find the output file (extension may vary)
        guard let files = try? FileManager.default.contentsOfDirectory(at: previewDir, includingPropertiesForKeys: nil),
              let match = files.first(where: { $0.lastPathComponent.hasPrefix(uuid) }) else {
            log.log("Preview file not found after download", level: .error)
            throw YTDLPError.fetchFailed("Preview file not found after download")
        }
        log.log("Preview ready: \(match.lastPathComponent)", level: .success)
        return match
    }

    // MARK: - Download

    func download(url: String, quality: VideoQuality?, outputDir: URL, format: DownloadFormat, clipRange: (start: Double, end: Double)? = nil) -> AsyncStream<DownloadEvent> {
        AsyncStream { continuation in
            let process = makeProcess(ytdlpPath)
            let cancelled = AtomicFlag()

            // If the consumer stops iterating (user hit Cancel), kill yt-dlp.
            continuation.onTermination = { reason in
                guard case .cancelled = reason else { return }
                cancelled.set()
                if process.isRunning { process.terminate() }
            }

            Task {
                var args: [String] = []

                switch format {
                case .mp4:
                    if let quality {
                        args += ["-f", "\(quality.id)+bestaudio/best"]
                    } else {
                        args += ["-f", "bestvideo[vcodec^=avc1]+bestaudio/bestvideo+bestaudio/best"]
                    }
                    args += ["--merge-output-format", "mp4"]
                case .mp3:
                    args += ["-x", "--audio-format", "mp3", "--audio-quality", "0"]
                }

                // Clip range support
                var clipSuffix = ""
                if let clip = clipRange {
                    let startStr = formatSeconds(clip.start)
                    let endStr = formatSeconds(clip.end)
                    args += ["--download-sections", "*\(startStr)-\(endStr)"]
                    // Force keyframes for clean cuts
                    args += ["--force-keyframes-at-cuts"]
                    // Build a filename-safe suffix like " [clip 00.18 to 12.35]"
                    // (colons aren't allowed in macOS filenames)
                    let safeStart = formatFilenameTimestamp(clip.start)
                    let safeEnd = formatFilenameTimestamp(clip.end)
                    clipSuffix = " [clip \(safeStart) to \(safeEnd)]"
                }

                let outputTemplate = outputDir.appendingPathComponent("%(title)s\(clipSuffix).%(ext)s").path
                args += ["-o", outputTemplate, "--newline", "--no-overwrites", "--no-playlist"]
                // --print implies --quiet, which suppresses progress output;
                // --progress re-enables it. Without this no progress is emitted.
                args += ["--progress", "--progress-template", "download:\(Self.progressMarker)%(progress._percent_str)s|||%(progress._speed_str)s|||%(progress._eta_str)s"]
                args += ["--print", "after_move:FILEPATH:%(filepath)s"]
                args += [url]

                process.arguments = args

                let clipDescription: String
                if let clip = clipRange {
                    clipDescription = " clip \(formatSeconds(clip.start))–\(formatSeconds(clip.end))"
                } else {
                    clipDescription = ""
                }
                log.log("Starting \(format == .mp4 ? "MP4" : "MP3") download\(clipDescription)", level: .info)
                logCommand(ytdlpPath, args)

                guard !cancelled.isSet else {
                    continuation.finish()
                    return
                }

                do {
                    let console = log
                    let result = try await runProcess(
                        process,
                        onStdoutLine: { line in
                            if line.contains(Self.progressMarker) {
                                // Progress line — yield an event, don't spam the console
                                if let event = self.parseProgress(line) {
                                    continuation.yield(event)
                                }
                            } else if line.hasPrefix("FILEPATH:") {
                                // Final path is parsed from collected output after exit
                            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                                console.log(line, level: .info)
                            }
                        },
                        onStderrLine: { line in
                            let level: LogLevel = line.contains("ERROR") ? .error : (line.contains("WARNING") ? .warning : .info)
                            console.log(line, level: level)
                        }
                    )

                    if cancelled.isSet {
                        log.log("Download cancelled", level: .warning)
                        continuation.finish()
                        return
                    }

                    if result.status == 0 {
                        // Parse FILEPATH from the collected output rather than the
                        // streaming callback so a line emitted just before exit
                        // can't be lost to a pipe-drain race.
                        let downloadedFilePath = String(decoding: result.stdout, as: UTF8.self)
                            .components(separatedBy: .newlines)
                            .last { $0.hasPrefix("FILEPATH:") }
                            .map { String($0.dropFirst("FILEPATH:".count)) }

                        if let filePath = downloadedFilePath {
                            log.log("Saved: \(filePath)", level: .success)
                        }

                        if let filePath = downloadedFilePath, format == .mp4 {
                            let needsTranscode = quality != nil && !quality!.isH264
                            continuation.yield(.progress(percent: 100, speed: "", eta: ""))
                            if needsTranscode {
                                log.log("Transcoding VP9 → HEVC for QuickTime compatibility", level: .info)
                            } else {
                                log.log("Repackaging MP4 for QuickTime", level: .info)
                            }
                            if await repackageForQuickTime(filePath: filePath, needsTranscode: needsTranscode) {
                                log.log("Repackaging complete", level: .success)
                            } else {
                                log.log("Repackaging failed — keeping the file as downloaded", level: .warning)
                            }
                        }
                        log.log("Download complete", level: .success)
                        continuation.yield(.completed(fileURL: downloadedFilePath.map { URL(fileURLWithPath: $0) }))
                    } else {
                        let errorMsg = errorSummary(from: result.stderr, fallback: "Download failed (exit code \(result.status))")
                        log.log("Download failed: \(errorMsg)", level: .error)
                        continuation.yield(.failed(error: errorMsg))
                    }
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error: error.localizedDescription))
                    continuation.finish()
                }
            }
        }
    }

    func formatSeconds(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Returns a timestamp suitable for inclusion in a filename (no colons).
    /// Under 1h: "MM.SS"; otherwise: "H.MM.SS".
    func formatFilenameTimestamp(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%d.%02d.%02d", h, m, s)
        }
        return String(format: "%02d.%02d", m, s)
    }

    /// Repackage downloaded MP4 for QuickTime compatibility.
    /// Returns false if ffmpeg failed; the original file is kept in that case.
    private func repackageForQuickTime(filePath: String, needsTranscode: Bool) async -> Bool {
        let tempPath = filePath + ".repack.mp4"
        let process = makeProcess(ffmpegPath)

        if needsTranscode {
            process.arguments = ["-y", "-i", filePath, "-c:v", "hevc_videotoolbox", "-q:v", "65", "-tag:v", "hvc1", "-c:a", "copy", "-movflags", "+faststart", tempPath]
        } else {
            process.arguments = ["-y", "-i", filePath, "-c", "copy", "-movflags", "+faststart", tempPath]
        }

        do {
            let result = try await runProcess(process)
            if result.status == 0 {
                try FileManager.default.removeItem(atPath: filePath)
                try FileManager.default.moveItem(atPath: tempPath, toPath: filePath)
                return true
            } else {
                let tail = result.stderr.components(separatedBy: "\n")
                    .filter { !$0.isEmpty }
                    .suffix(3)
                    .joined(separator: "\n")
                log.log("ffmpeg exited with code \(result.status): \(tail)", level: .error)
                try? FileManager.default.removeItem(atPath: tempPath)
                return false
            }
        } catch {
            log.log("ffmpeg failed to run: \(error.localizedDescription)", level: .error)
            try? FileManager.default.removeItem(atPath: tempPath)
            return false
        }
    }

    func parseProgress(_ line: String) -> DownloadEvent? {
        guard let markerRange = line.range(of: Self.progressMarker) else { return nil }
        let content = String(line[markerRange.upperBound...])
        let parts = content.components(separatedBy: "|||")

        let percentStr = parts[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        guard let percent = Double(percentStr) else { return nil }

        let speed = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
        let eta = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""

        return .progress(percent: percent, speed: speed, eta: eta)
    }
}

enum YTDLPError: LocalizedError {
    case fetchFailed(String)
    case parseFailed

    var errorDescription: String? {
        switch self {
        case .fetchFailed(let msg): return msg
        case .parseFailed: return "Failed to parse yt-dlp output"
        }
    }
}
