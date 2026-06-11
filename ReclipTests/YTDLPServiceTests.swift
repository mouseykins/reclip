import XCTest
@testable import Reclip

final class YTDLPServiceTests: XCTestCase {
    let service = YTDLPService()

    // MARK: - parseProgress

    func testParseProgressValidLine() throws {
        let line = "RECLIP_PROGRESS|  42.3%||| 1.25MiB/s|||00:35"
        guard case .progress(let percent, let speed, let eta)? = service.parseProgress(line) else {
            return XCTFail("Expected a progress event")
        }
        XCTAssertEqual(percent, 42.3, accuracy: 0.001)
        XCTAssertEqual(speed, "1.25MiB/s")
        XCTAssertEqual(eta, "00:35")
    }

    func testParseProgressToleratesTemplateTypePrefix() throws {
        // Defensive: if a yt-dlp version does NOT consume "download:" as a
        // template-type selector, the line arrives with the prefix attached.
        let line = "download:RECLIP_PROGRESS| 100.0%|||Unknown|||00:00"
        guard case .progress(let percent, _, _)? = service.parseProgress(line) else {
            return XCTFail("Expected a progress event")
        }
        XCTAssertEqual(percent, 100.0, accuracy: 0.001)
    }

    func testParseProgressMissingSpeedAndETA() throws {
        guard case .progress(let percent, let speed, let eta)? = service.parseProgress("RECLIP_PROGRESS|7.0%") else {
            return XCTFail("Expected a progress event")
        }
        XCTAssertEqual(percent, 7.0, accuracy: 0.001)
        XCTAssertEqual(speed, "")
        XCTAssertEqual(eta, "")
    }

    func testParseProgressRejectsUnmarkedOrMalformedLines() {
        XCTAssertNil(service.parseProgress("[download] Destination: foo.mp4"))
        XCTAssertNil(service.parseProgress("42.3%||| 1MiB/s|||00:35"))
        // _percent_str can be "N/A" when total size is unknown
        XCTAssertNil(service.parseProgress("RECLIP_PROGRESS|N/A|||1MiB/s|||00:35"))
        XCTAssertNil(service.parseProgress(""))
    }

    // MARK: - Time formatting

    func testFormatSeconds() {
        XCTAssertEqual(service.formatSeconds(0), "00:00:00")
        XCTAssertEqual(service.formatSeconds(59), "00:00:59")
        XCTAssertEqual(service.formatSeconds(75), "00:01:15")
        XCTAssertEqual(service.formatSeconds(3725), "01:02:05")
        XCTAssertEqual(service.formatSeconds(3725.9), "01:02:05") // truncates, not rounds
    }

    func testFormatFilenameTimestamp() {
        XCTAssertEqual(service.formatFilenameTimestamp(0), "00.00")
        XCTAssertEqual(service.formatFilenameTimestamp(75), "01.15")
        XCTAssertEqual(service.formatFilenameTimestamp(3725), "1.02.05")
        // No colons allowed in macOS filenames
        XCTAssertFalse(service.formatFilenameTimestamp(99999).contains(":"))
    }

    // MARK: - parseQualities

    func testParseQualitiesPrefersH264AndSortsDescending() {
        let json: [String: Any] = ["formats": [
            ["format_id": "vp9-1080", "vcodec": "vp09.00.41.08", "height": 1080, "ext": "webm", "filesize": 100],
            ["format_id": "avc-1080", "vcodec": "avc1.640028", "height": 1080, "ext": "mp4", "filesize": 200],
            ["format_id": "avc-720", "vcodec": "avc1.4d401f", "height": 720, "ext": "mp4"],
            ["format_id": "audio-only", "vcodec": "none", "acodec": "mp4a.40.2"],
            ["format_id": "no-height", "vcodec": "avc1.4d401f"],
        ]]
        let qualities = service.parseQualities(from: json)
        XCTAssertEqual(qualities.map(\.id), ["avc-1080", "avc-720"])
        XCTAssertEqual(qualities.first?.resolution, "1080p")
        XCTAssertEqual(qualities.first?.codec, "avc1.640028")
    }

    func testParseQualitiesFallsBackToNonH264WhenNoneAvailable() {
        let json: [String: Any] = ["formats": [
            ["format_id": "vp9-only", "vcodec": "vp09.00.41.08", "height": 720, "ext": "webm"],
        ]]
        let qualities = service.parseQualities(from: json)
        XCTAssertEqual(qualities.map(\.id), ["vp9-only"])
        XCTAssertFalse(qualities[0].isH264)
    }

    func testParseQualitiesUsesApproxFilesizeFallback() {
        let json: [String: Any] = ["formats": [
            ["format_id": "f1", "vcodec": "avc1.4d401f", "height": 480, "filesize_approx": 12345],
        ]]
        XCTAssertEqual(service.parseQualities(from: json).first?.filesize, 12345)
    }

    func testParseQualitiesEmptyOrMissingFormats() {
        XCTAssertTrue(service.parseQualities(from: [:]).isEmpty)
        XCTAssertTrue(service.parseQualities(from: ["formats": [] as [[String: Any]]]).isEmpty)
    }

    // MARK: - errorSummary

    func testErrorSummaryExtractsErrorLines() {
        let stderr = """
        WARNING: something minor
        ERROR: [youtube] abc123: Video unavailable
        some other noise
        """
        let summary = service.errorSummary(from: stderr, fallback: "fallback")
        XCTAssertEqual(summary, "ERROR: [youtube] abc123: Video unavailable")
    }

    func testErrorSummaryFallsBackWhenNoErrorLines() {
        XCTAssertEqual(service.errorSummary(from: "WARNING: only warnings here", fallback: "exit code 1"), "exit code 1")
        XCTAssertEqual(service.errorSummary(from: "", fallback: "fb"), "fb")
    }
}
