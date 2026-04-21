import Foundation

struct Dependency: Identifiable, Hashable {
    let id: String
    let displayName: String
    let brewPackage: String
    let description: String
    let required: Bool
    let candidatePaths: [String]

    var installedPath: String? {
        candidatePaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    var isInstalled: Bool { installedPath != nil }
}

@Observable
class DependencyCheck {
    static let shared = DependencyCheck()

    let dependencies: [Dependency] = [
        Dependency(
            id: "yt-dlp",
            displayName: "yt-dlp",
            brewPackage: "yt-dlp",
            description: "Extracts videos from YouTube, TikTok, Vimeo, and hundreds of other sites.",
            required: true,
            candidatePaths: ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]
        ),
        Dependency(
            id: "ffmpeg",
            displayName: "FFmpeg",
            brewPackage: "ffmpeg",
            description: "Merges video + audio streams and repackages clips for QuickTime playback.",
            required: true,
            candidatePaths: ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        ),
        Dependency(
            id: "deno",
            displayName: "Deno",
            brewPackage: "deno",
            description: "JavaScript runtime required by yt-dlp for modern YouTube extraction.",
            required: true,
            candidatePaths: ["/opt/homebrew/bin/deno", "/usr/local/bin/deno"]
        ),
    ]

    private(set) var missing: [Dependency] = []
    private(set) var installedHomebrew: Bool = false
    private(set) var brewPath: String? = nil
    var isInstalling: Bool = false

    private init() {
        recheck()
    }

    func recheck() {
        missing = dependencies.filter { !$0.isInstalled }
        let brewCandidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        brewPath = brewCandidates.first { FileManager.default.fileExists(atPath: $0) }
        installedHomebrew = brewPath != nil
    }

    var allRequiredInstalled: Bool {
        missing.allSatisfy { !$0.required }
    }

    /// Installs missing dependencies via Homebrew. Streams output to ConsoleLog.
    func installMissingViaHomebrew() async {
        guard let brewPath, !isInstalling else { return }
        let packages = missing.map(\.brewPackage)
        guard !packages.isEmpty else { return }

        await MainActor.run { self.isInstalling = true }
        ConsoleLog.shared.log("Installing via Homebrew: \(packages.joined(separator: ", "))", level: .command)

        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: brewPath)
            process.arguments = ["install"] + packages

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(env["PATH"] ?? "/usr/bin:/bin")"
            // Non-interactive brew
            env["NONINTERACTIVE"] = "1"
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            env["HOMEBREW_NO_ANALYTICS"] = "1"
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for line in text.components(separatedBy: "\n") where !line.isEmpty {
                    ConsoleLog.shared.log(line, level: .info)
                }
            }
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                for line in text.components(separatedBy: "\n") where !line.isEmpty {
                    let level: LogLevel = line.lowercased().contains("error") ? .error : .info
                    ConsoleLog.shared.log(line, level: level)
                }
            }

            do {
                try process.run()
                process.waitUntilExit()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if process.terminationStatus == 0 {
                    ConsoleLog.shared.log("Homebrew install completed successfully", level: .success)
                } else {
                    ConsoleLog.shared.log("Homebrew install exited with code \(process.terminationStatus)", level: .error)
                }
            } catch {
                ConsoleLog.shared.log("Failed to run brew: \(error.localizedDescription)", level: .error)
            }
        }.value

        await MainActor.run {
            self.isInstalling = false
            self.recheck()
        }
    }
}
