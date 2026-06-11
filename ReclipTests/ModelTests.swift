import XCTest
@testable import Reclip

final class ModelTests: XCTestCase {

    // MARK: - VideoQuality

    func testIsH264() {
        func quality(_ codec: String) -> VideoQuality {
            VideoQuality(id: "x", resolution: "1080p", ext: "mp4", filesize: nil, codec: codec, description: "1080p")
        }
        XCTAssertTrue(quality("avc1.640028").isH264)
        XCTAssertTrue(quality("h264").isH264)
        XCTAssertFalse(quality("vp09.00.41.08").isH264)
        XCTAssertFalse(quality("av01.0.08M.08").isH264)
        XCTAssertFalse(quality("").isH264)
    }

    func testDisplayLabelMarksFilesizeAsApproximate() {
        let q = VideoQuality(id: "x", resolution: "1080p", ext: "mp4", filesize: 150_000_000, codec: "avc1", description: "1080p")
        XCTAssertEqual(q.displayLabel, "1080p (~150 MB)")

        let noSize = VideoQuality(id: "x", resolution: "720p", ext: "mp4", filesize: nil, codec: "avc1", description: "720p")
        XCTAssertEqual(noSize.displayLabel, "720p")

        let zeroSize = VideoQuality(id: "x", resolution: "720p", ext: "mp4", filesize: 0, codec: "avc1", description: "720p")
        XCTAssertEqual(zeroSize.displayLabel, "720p")
    }

    // MARK: - VideoItem

    func testFormatTime() {
        XCTAssertEqual(VideoItem.formatTime(0), "0:00")
        XCTAssertEqual(VideoItem.formatTime(65), "1:05")
        XCTAssertEqual(VideoItem.formatTime(600), "10:00")
        XCTAssertEqual(VideoItem.formatTime(3661), "1:01:01")
    }

    func testSourceDomain() {
        XCTAssertEqual(VideoItem(url: "https://www.youtube.com/watch?v=abc").sourceDomain, "www.youtube.com")
        XCTAssertEqual(VideoItem(url: "not a url").sourceDomain, "")
    }

    func testStatusFlags() {
        let item = VideoItem(url: "https://example.com/v")
        XCTAssertFalse(item.isReady)
        item.status = .ready
        XCTAssertTrue(item.isReady)
        XCTAssertFalse(item.isDownloading)
        item.status = .downloading(progress: 50)
        XCTAssertTrue(item.isDownloading)
        XCTAssertFalse(item.isReady)
    }

    // MARK: - ConsoleLog

    @MainActor
    func testConsoleLogCapsEntries() {
        let log = ConsoleLog.shared
        log.clear()
        for i in 0..<1010 {
            log.log("entry \(i)")
        }
        XCTAssertEqual(log.entries.count, 1000)
        XCTAssertEqual(log.entries.first?.message, "entry 10")
        XCTAssertEqual(log.entries.last?.message, "entry 1009")
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }

    // MARK: - DownloadListViewModel

    @MainActor
    func testFetchVideoIgnoresNonHTTPInput() async {
        let vm = DownloadListViewModel()
        vm.urlText = "not a url"
        await vm.fetchVideo()
        XCTAssertNil(vm.currentItem)
        XCTAssertFalse(vm.isFetching)
    }

    @MainActor
    func testClearResetsState() {
        let vm = DownloadListViewModel()
        vm.urlText = "https://example.com"
        vm.currentItem = VideoItem(url: "https://example.com")
        vm.clear()
        XCTAssertNil(vm.currentItem)
        XCTAssertEqual(vm.urlText, "")
    }

    @MainActor
    func testDefaultDestinationIsMoviesReclip() {
        let vm = DownloadListViewModel()
        XCTAssertEqual(vm.destinationFolder.lastPathComponent, "Reclip")
        XCTAssertTrue(vm.destinationFolder.path.contains("Movies"))
    }
}
