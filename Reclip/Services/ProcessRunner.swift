import Foundation

/// Result of running a child process to completion.
struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: String
}

/// A thread-safe one-way boolean flag.
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// Accumulates raw process output and yields complete lines, decoding UTF-8
/// only at line boundaries so multi-byte characters split across pipe reads
/// are never corrupted. Treats \n, \r, and \r\n as terminators (yt-dlp uses
/// bare \r for in-place progress updates); empty lines are dropped.
struct LineBuffer {
    private var data = Data()

    mutating func append(_ chunk: Data) -> [String] {
        data.append(chunk)
        var lines: [String] = []
        while let terminator = data.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let lineData = data[data.startIndex..<terminator]
            data.removeSubrange(data.startIndex...terminator)
            if !lineData.isEmpty {
                lines.append(String(decoding: lineData, as: UTF8.self))
            }
        }
        return lines
    }

    /// Returns any unterminated trailing output.
    mutating func flush() -> String? {
        guard !data.isEmpty else { return nil }
        defer { data.removeAll() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Reads a pipe to EOF on a background thread, emitting complete lines as they
/// arrive and collecting the raw bytes. All state is touched only from the
/// reader thread; `collected` is safe to read once `group` has completed.
private final class PipeDrain {
    private(set) var collected = Data()
    private let onLine: ((String) -> Void)?

    init(onLine: ((String) -> Void)?) {
        self.onLine = onLine
    }

    func start(_ pipe: Pipe, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            var lineBuffer = LineBuffer()
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData // blocks until data or EOF
                if chunk.isEmpty { break }
                collected.append(chunk)
                if let onLine {
                    for line in lineBuffer.append(chunk) { onLine(line) }
                }
            }
            if let onLine, let rest = lineBuffer.flush() { onLine(rest) }
            group.leave()
        }
    }
}

/// Runs a process to completion without blocking the Swift concurrency thread
/// pool. Both pipes are drained concurrently to EOF, so the child can never
/// stall on a full pipe buffer and no output emitted just before exit is lost.
/// The process is registered with ProcessRegistry for app-quit cleanup.
func runProcess(
    _ process: Process,
    onStdoutLine: ((String) -> Void)? = nil,
    onStderrLine: ((String) -> Void)? = nil
) async throws -> ProcessResult {
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let stdoutDrain = PipeDrain(onLine: onStdoutLine)
    let stderrDrain = PipeDrain(onLine: onStderrLine)

    let group = DispatchGroup()
    group.enter()
    process.terminationHandler = { _ in group.leave() }

    try process.run()
    ProcessRegistry.shared.register(process)

    stdoutDrain.start(stdoutPipe, group: group)
    stderrDrain.start(stderrPipe, group: group)

    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        group.notify(queue: .global()) { continuation.resume() }
    }
    ProcessRegistry.shared.unregister(process)

    return ProcessResult(
        status: process.terminationStatus,
        stdout: stdoutDrain.collected,
        stderr: String(decoding: stderrDrain.collected, as: UTF8.self)
    )
}
