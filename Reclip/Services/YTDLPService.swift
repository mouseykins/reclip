import Foundation

enum DownloadEvent {
    case progress(percent: Double, speed: String, eta: String)
    case completed(fileURL: URL?)
    case failed(error: String)
}

struct YTDLPService {
    private let ytdlpPath: String
    private let ffmpegPath: String
    private let log = ConsoleLog.shared

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

    // MARK: - Fetch Metadata

    func fetchInfo(url: String) async throws -> (title: String, thumbnailURL: URL?, duration: String?, durationSeconds: Double, qualities: [VideoQuality]) {
        log.log("Fetching metadata for \(url)", level: .info)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlpPath)
        process.environment = subprocessEnv
        let args = ["--dump-json", "--no-download", url]
        process.arguments = args
        logCommand(ytdlpPath, args)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let data = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            DispatchQueue.global().async {
                let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    let fullStderr = String(data: errorData, encoding: .utf8) ?? ""
                    let errorLines = fullStderr.components(separatedBy: "\n")
                        .filter { $0.contains("ERROR") }
                    let errorMsg = errorLines.isEmpty ? "yt-dlp failed (exit code \(process.terminationStatus))" : errorLines.joined(separator: "\n")
                    self.log.log(errorMsg, level: .error)
                    continuation.resume(throwing: YTDLPError.fetchFailed(errorMsg))
                } else {
                    self.log.log("Metadata fetched successfully", level: .success)
                    continuation.resume(returning: outputData)
                }
            }
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTDLPError.parseFailed
        }

        let title = json["title"] as? String ?? "Unknown"
        let thumbnail = (json["thumbnail"] as? String).flatMap { URL(string: $0) }
        let durationString = json["duration_string"] as? String
        let durationSeconds = json["duration"] as? Double ?? 0

        let qualities = parseQualities(from: json)

        return (title, thumbnail, durationString, durationSeconds, qualities)
    }

    private func parseQualities(from json: [String: Any]) -> [VideoQuality] {
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

    /// Downloads a low-res (360p) preview copy for native AVPlayer scrubbing.
    /// Returns the local file URL of the downloaded preview.
    func downloadPreview(url: String) async throws -> URL {
        let previewDir = FileManager.default.temporaryDirectory.appendingPathComponent("ReclipPreviews")
        try? FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)

        let uuid = UUID().uuidString
        let outputTemplate = previewDir.appendingPathComponent("\(uuid).%(ext)s").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlpPath)
        process.environment = subprocessEnv

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

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Drain both pipes asynchronously so they never fill up and block the process
        var stderrBuffer = Data()
        let stderrQueue = DispatchQueue(label: "reclip.preview.stderr")
        var stdoutLineBuffer = ""
        let console = log

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            stderrQueue.sync { stderrBuffer.append(data) }
            if let text = String(data: data, encoding: .utf8) {
                for line in text.components(separatedBy: "\n") where !line.isEmpty {
                    let level: LogLevel = line.contains("ERROR") ? .error : (line.contains("WARNING") ? .warning : .info)
                    console.log(line, level: level)
                }
            }
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            stdoutLineBuffer += text
            let lines = stdoutLineBuffer.components(separatedBy: "\n")
            stdoutLineBuffer = lines.last ?? ""
            for line in lines.dropLast() where !line.isEmpty {
                // Skip progress spam but surface destination/merge lines
                if line.contains("[download]") && line.contains("%") { continue }
                console.log(line, level: .info)
            }
        }

        try process.run()

        let fileURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            DispatchQueue.global().async {
                process.waitUntilExit()

                stderrPipe.fileHandleForReading.readabilityHandler = nil
                stdoutPipe.fileHandleForReading.readabilityHandler = nil

                if process.terminationStatus != 0 {
                    let errorStr = stderrQueue.sync { String(data: stderrBuffer, encoding: .utf8) ?? "" }
                    let errorLines = errorStr.components(separatedBy: "\n")
                        .filter { $0.contains("ERROR") }
                    let msg = errorLines.isEmpty
                        ? "Preview download failed (exit \(process.terminationStatus))"
                        : errorLines.joined(separator: "\n")
                    self.log.log("Preview download failed: \(msg)", level: .error)
                    continuation.resume(throwing: YTDLPError.fetchFailed(msg))
                } else {
                    // Find the output file (extension may vary)
                    if let files = try? FileManager.default.contentsOfDirectory(at: previewDir, includingPropertiesForKeys: nil),
                       let match = files.first(where: { $0.lastPathComponent.hasPrefix(uuid) }) {
                        self.log.log("Preview ready: \(match.lastPathComponent)", level: .success)
                        continuation.resume(returning: match)
                    } else {
                        self.log.log("Preview file not found after download", level: .error)
                        continuation.resume(throwing: YTDLPError.fetchFailed("Preview file not found after download"))
                    }
                }
            }
        }

        return fileURL
    }

    // MARK: - Download

    func download(url: String, quality: VideoQuality?, outputDir: URL, format: DownloadFormat, clipRange: (start: Double, end: Double)? = nil) -> AsyncStream<DownloadEvent> {
        AsyncStream { continuation in
            Task {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: ytdlpPath)
                    process.environment = subprocessEnv

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
                    args += ["-o", outputTemplate, "--newline", "--no-overwrites"]
                    args += ["--progress-template", "download:%(progress._percent_str)s|||%(progress._speed_str)s|||%(progress._eta_str)s"]
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

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    var buffer = ""
                    var stderrBuf = ""
                    var downloadedFilePath: String?
                    let console = log

                    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty else { return }
                        guard let text = String(data: data, encoding: .utf8) else { return }

                        buffer += text
                        let lines = buffer.components(separatedBy: "\n")
                        buffer = lines.last ?? ""

                        for line in lines.dropLast() {
                            if line.hasPrefix("FILEPATH:") {
                                downloadedFilePath = String(line.dropFirst("FILEPATH:".count))
                                console.log("Saved: \(line.dropFirst("FILEPATH:".count))", level: .success)
                            } else if line.hasPrefix("download:") {
                                // Progress line — don't spam the console
                                if let event = self.parseProgress(line) {
                                    continuation.yield(event)
                                }
                            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                                console.log(line, level: .info)
                            }
                        }
                    }

                    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                        stderrBuf += text
                        let lines = stderrBuf.components(separatedBy: "\n")
                        stderrBuf = lines.last ?? ""
                        for line in lines.dropLast() where !line.isEmpty {
                            let level: LogLevel = line.contains("ERROR") ? .error : (line.contains("WARNING") ? .warning : .info)
                            console.log(line, level: level)
                        }
                    }

                    try process.run()

                    process.waitUntilExit()

                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    if process.terminationStatus == 0 {
                        if let filePath = downloadedFilePath, format == .mp4 {
                            let needsTranscode = quality != nil && !quality!.isH264
                            continuation.yield(.progress(percent: 100, speed: "", eta: needsTranscode ? "Repackaging..." : ""))
                            if needsTranscode {
                                log.log("Transcoding VP9 → HEVC for QuickTime compatibility", level: .info)
                            } else {
                                log.log("Repackaging MP4 for QuickTime", level: .info)
                            }
                            self.repackageForQuickTime(filePath: filePath, needsTranscode: needsTranscode)
                            log.log("Repackaging complete", level: .success)
                        }
                        log.log("Download complete", level: .success)
                        let finalURL = downloadedFilePath.map { URL(fileURLWithPath: $0) }
                        continuation.yield(.completed(fileURL: finalURL))
                    } else {
                        let fullStderr = stderrBuf
                        let errorLines = fullStderr.components(separatedBy: "\n")
                            .filter { $0.contains("ERROR") }
                        let errorMsg = errorLines.isEmpty ? "Download failed (exit code \(process.terminationStatus))" : errorLines.joined(separator: "\n")
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

    private func formatSeconds(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// Returns a timestamp suitable for inclusion in a filename (no colons).
    /// Under 1h: "MM.SS"; otherwise: "H.MM.SS".
    private func formatFilenameTimestamp(_ seconds: Double) -> String {
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
    private func repackageForQuickTime(filePath: String, needsTranscode: Bool) {
        let tempPath = filePath + ".repack.mp4"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.environment = subprocessEnv

        if needsTranscode {
            process.arguments = ["-y", "-i", filePath, "-c:v", "hevc_videotoolbox", "-q:v", "65", "-tag:v", "hvc1", "-c:a", "copy", "-movflags", "+faststart", tempPath]
        } else {
            process.arguments = ["-y", "-i", filePath, "-c", "copy", "-movflags", "+faststart", tempPath]
        }

        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                try? FileManager.default.removeItem(atPath: filePath)
                try? FileManager.default.moveItem(atPath: tempPath, toPath: filePath)
            } else {
                try? FileManager.default.removeItem(atPath: tempPath)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
        }
    }

    private func parseProgress(_ line: String) -> DownloadEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("download:") else { return nil }

        let content = String(trimmed.dropFirst("download:".count))
        let parts = content.components(separatedBy: "|||")
        guard parts.count >= 1 else { return nil }

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
