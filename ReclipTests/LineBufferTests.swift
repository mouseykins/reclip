import XCTest
@testable import Reclip

final class LineBufferTests: XCTestCase {

    func testSimpleNewlineSplit() {
        var buf = LineBuffer()
        XCTAssertEqual(buf.append(Data("a\nb\n".utf8)), ["a", "b"])
        XCTAssertNil(buf.flush())
    }

    func testLineSplitAcrossChunks() {
        var buf = LineBuffer()
        XCTAssertEqual(buf.append(Data("hel".utf8)), [])
        XCTAssertEqual(buf.append(Data("lo\nwor".utf8)), ["hello"])
        XCTAssertEqual(buf.append(Data("ld\n".utf8)), ["world"])
    }

    func testMultiByteUTF8SplitAcrossChunks() {
        // "🎬" is 4 bytes in UTF-8; split it down the middle. Decoding per-chunk
        // (the old implementation) would corrupt or drop this.
        var buf = LineBuffer()
        let emoji = Data("🎬 title\n".utf8)
        XCTAssertEqual(buf.append(emoji.prefix(2)), [])
        XCTAssertEqual(buf.append(emoji.dropFirst(2)), ["🎬 title"])
    }

    func testCarriageReturnTreatedAsTerminator() {
        // yt-dlp emits bare \r for in-place progress updates
        var buf = LineBuffer()
        XCTAssertEqual(buf.append(Data("p1\rp2\r\np3\n".utf8)), ["p1", "p2", "p3"])
    }

    func testFlushReturnsUnterminatedTrailingOutput() {
        var buf = LineBuffer()
        XCTAssertEqual(buf.append(Data("done\nFILEPATH:/tmp/x.mp4".utf8)), ["done"])
        XCTAssertEqual(buf.flush(), "FILEPATH:/tmp/x.mp4")
        XCTAssertNil(buf.flush()) // emptied
    }

    func testEmptyLinesAreDropped() {
        var buf = LineBuffer()
        XCTAssertEqual(buf.append(Data("\n\na\n\n".utf8)), ["a"])
    }
}
